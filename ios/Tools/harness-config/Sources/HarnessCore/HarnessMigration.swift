import Foundation

enum HarnessMigration {
    /// The caller supplies its effective v1 defaults at the reviewed engine checkpoint.
    /// No account inventory, credentials or new model defaults are consulted here.
    static func fromLegacy(_ source: Data, defaults: Data) throws -> HarnessConfiguration {
        let own = try legacyObject(source), base = try legacyObject(defaults)
        let effective = merge(own, over: base)
        try compatible(effective, with: base, path: "legacy")
        func section(_ key: String) throws -> [String: HarnessValue] {
            guard let object = effective[key]?.object else { throw HarnessProblem("legacy.\(key)", "object required") }
            return object
        }
        let texts = try section("prompts")
        var prompts: [String: HarnessPrompt] = [:]
        for (id, value) in texts {
            guard let text = value.string else { throw HarnessProblem("legacy.prompts.\(id)", "text required") }
            prompts[id] = HarnessPrompt(text: text)
        }
        let reserved: Set<String> = ["version", "voice", "scheduler", "landing", "agents", "models", "prompts"]
        let legacy = HarnessLegacySettings(agents: try section("agents"), modelSelection: try section("models"),
                                          extra: effective.filter { !reserved.contains($0.key) })
        var result = HarnessConfiguration(activeProfile: "current-listen")
        result.voice = try section("voice")
        result.scheduler = try section("scheduler")
        result.landing = try section("landing")
        result.prompts = prompts
        result.compatibility = legacy
        // Preserve the whole current execution path until native operators replace it.
        // Empty registry collections cannot accidentally activate every saved account.
        result.flows = ["current-listen": HarnessFlow(label: "Current Listen", nodes: ["engine": .init(kind: .currentListen)])]
        result.profiles = ["current-listen": HarnessProfile(label: "Current Listen", evidenceFlow: "current-listen",
                                                           allowedExecution: [.onDevice, .ownerHost, .providerCloud, .unknown])]
        try result.validate()
        return result
    }

    /// Compatibility facade for the existing SystemConfig decoder. Prompts are rebuilt
    /// from their sole v2 source, preserving Unicode, whitespace and literal placeholders.
    static func legacyData(from document: HarnessConfiguration) throws -> Data {
        try document.validate()
        guard let legacy = document.compatibility else { throw HarnessProblem("compatibility", "no legacy execution settings") }
        let reserved: Set<String> = ["version", "voice", "scheduler", "landing", "agents", "models", "prompts"]
        guard reserved.isDisjoint(with: legacy.extra.keys) else { throw HarnessProblem("compatibility.extra", "reserved legacy keys") }
        var root = legacy.extra
        root["version"] = .integer(1)
        root["voice"] = .object(document.voice)
        root["scheduler"] = .object(document.scheduler)
        root["landing"] = .object(document.landing)
        root["agents"] = .object(legacy.agents)
        root["models"] = .object(legacy.modelSelection)
        root["prompts"] = .object(document.prompts.mapValues { .string($0.text) })
        return try HarnessJSON.encode(HarnessValue.object(root))
    }

    private static func legacyObject(_ data: Data) throws -> [String: HarnessValue] {
        try HarnessJSON.checkUniqueKeys(data)
        guard data.count <= 2_000_000,
              let root = try? JSONDecoder().decode(HarnessValue.self, from: data).object,
              root["version"] == .integer(1) else { throw HarnessProblem("legacy.version", "valid v1 configuration required") }
        return root
    }

    private static func merge(_ own: [String: HarnessValue], over base: [String: HarnessValue]) -> [String: HarnessValue] {
        var result = base
        for (key, value) in own {
            if let below = base[key]?.object, let patch = value.object { result[key] = .object(merge(patch, over: below)) }
            else { result[key] = value }
        }
        return result
    }

    /// Validate known legacy types before producing a facade. Unknown data is retained,
    /// never treated as instructions, role definitions or automatic account selection.
    private static func compatible(_ own: [String: HarnessValue], with base: [String: HarnessValue], path: String) throws {
        for (key, expected) in base {
            guard let actual = own[key] else { throw HarnessProblem(path + "." + key, "missing value") }
            switch (actual, expected) {
            case (.object(let a), .object(let b)): try compatible(a, with: b, path: path + "." + key)
            case (.array(let a), .array(let b)):
                // v1's empty model selection list is an array of opaque model strings.
                if key == "drafts", !a.allSatisfy({ $0.string != nil }) { throw HarnessProblem(path + "." + key, "model ID array required") }
                if let first = b.first { for value in a { try compatible(["item": value], with: ["item": first], path: path + "." + key) } }
            case (.string, .string), (.bool, .bool), (.integer, .integer), (.unsigned, .unsigned), (.null, .null): break
            case (.number, .number), (.integer, .number), (.unsigned, .number): break
            default: throw HarnessProblem(path + "." + key, "incorrect legacy value type")
            }
        }
    }
}
