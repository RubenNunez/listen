import Foundation
import Testing
#if canImport(Listen)
@testable import Listen
#else
@testable import HarnessCore
#endif

private func v1Defaults() throws -> Data {
    let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appending(path: "docs/system.default.json"))
}

private func migrated() throws -> HarnessConfiguration {
    let defaults = try v1Defaults()
    return try HarnessMigration.fromLegacy(defaults, defaults: defaults)
}

private func customFlow() -> HarnessConfiguration {
    var config = HarnessConfiguration(activeProfile: "mine")
    config.connections = ["gateway": HarnessConnection(label: "My endpoint", vendor: "My vendor", enabled: true,
        endpoint: .init(kind: .http, baseURL: "https://example.invalid/v1"),
        authentication: .init(kind: .apiKey, slot: "my-key"),
        operations: ["write": .init(adapter: .chat, path: "chat/completions"),
                     "decide": .init(adapter: .systemOne, path: "systemone")])]
    config.models = [
        "fast": HarnessModel(label: "Fast", connection: "gateway", operation: "write",
            upstreamID: "my-provider/my-model", kind: .generation, capabilities: [.text, .stream], execution: .unknown),
        "decider": HarnessModel(label: "Decider", connection: "gateway", operation: "decide",
            upstreamID: "my-decision-alias", kind: .decision, capabilities: [.noul, .choice, .probabilities], execution: .unknown),
    ]
    config.prompts = ["answer-my-way": HarnessPrompt(text: "My prompt. {literal braces}. ä e\u{301}\n"),
                      "my-question": HarnessPrompt(text: "Is this useful?")]
    config.roles = ["my-writer": HarnessRole(label: "My writer", kind: .generation, model: "fast",
        prompts: ["answer-my-way"], timeoutMilliseconds: 3000, onUnavailable: .skip)]
    config.flows = ["my-arrangement": HarnessFlow(label: "My arrangement", nodes: [
        "selected-context": .init(kind: .context, context: [.transcript, .briefing]),
        "write-now": .init(kind: .invoke, role: "my-writer", inputs: ["context": "selected-context"]),
        "show": .init(kind: .publish, inputs: ["candidate": "write-now"]),
    ])]
    config.profiles = ["mine": HarnessProfile(label: "My setup", evidenceFlow: "my-arrangement",
        allowedExecution: [.unknown], limits: .init(concurrentCalls: 2, callsPerSession: 200, fallbacksPerRequest: 1))]
    return config
}

private func withReview(_ input: HarnessConfiguration) -> HarnessConfiguration {
    var config = input
    config.roles["my-reviewer"] = HarnessRole(label: "My reviewer", kind: .decision, model: "decider",
        prompts: ["my-question"], timeoutMilliseconds: 1000, decisionPolicy: .providerProbabilities,
        onUnavailable: .discardCandidate)
    config.flows["my-arrangement"]?.nodes["review"] = .init(kind: .invoke, role: "my-reviewer",
        inputs: ["context": "selected-context", "candidate": "write-now"])
    config.flows["my-arrangement"]?.nodes["show"]?.inputs["approval"] = "review"
    return config
}

private func observed(_ config: HarnessConfiguration, capabilities: Set<HarnessCapability>) throws -> [String: HarnessCapabilityObservation] {
    ["fast": HarnessCapabilityObservation(fingerprint: try config.models["fast"]!.capabilityFingerprint(in: config), capabilities: capabilities)]
}

private func legacyStore(_ file: URL) -> HarnessConfigurationStore {
    HarnessConfigurationStore(file: file, legacyValidator: { data in
        _ = try JSONDecoder().decode(SystemConfig.self, from: data)
    })
}

@Suite struct OpenHarnessMigration {
    #if canImport(Listen) || HARNESS_CONFIG_COMPATIBILITY
    @Test func facadeDecodesTheExactCurrentEngineSettings() throws {
        var settings = SystemConfig()
        settings.prompts.gate = "Owner prompt.\n\n ä e\u{301} {LANGUAGE}\n"
        settings.agents.web = false
        settings.models.drafts = ["my/provider/model"]
        let baseline = Data(SystemConfig().json.utf8)
        let migrated = try HarnessMigration.fromLegacy(Data(settings.json.utf8), defaults: baseline)
        #expect(try JSONDecoder().decode(SystemConfig.self, from: HarnessMigration.legacyData(from: migrated)) == settings)
    }
    #endif
    @Test func currentDefaultsRoundTripWithoutChangingAnyValue() throws {
        let baseline = try v1Defaults()
        let document = try HarnessMigration.fromLegacy(baseline, defaults: baseline)
        let projected = try HarnessMigration.legacyData(from: document)
        #expect(try JSONDecoder().decode(HarnessValue.self, from: projected) == JSONDecoder().decode(HarnessValue.self, from: baseline))
        #expect(document.connections.isEmpty && document.models.isEmpty && document.roles.isEmpty)
        #expect(document.version == 2 && document.compatibility != nil)
    }

    @Test func editedPromptsTimingsModelsAndSwitchesSurvivePartialV1() throws {
        let text = "Use my exact words.\n\n  ä e\u{301} {LANGUAGE} {NOTHING} {UPDATE} {code: true}\n"
        let patch: HarnessValue = .object([
            "version": .integer(1), "prompts": .object(["gate": .string(text)]),
            "scheduler": .object(["pauseSeconds": .number(0.17)]),
            "agents": .object(["web": .bool(false)]),
            "models": .object(["drafts": .array([.string("my/provider/model")]), "main": .string("my-main")]),
            "my-retained-data": .unsigned(UInt64.max),
        ])
        let document = try HarnessMigration.fromLegacy(HarnessJSON.encode(patch), defaults: v1Defaults())
        #expect(Array(document.prompts["gate"]!.text.utf8) == Array(text.utf8))
        let root = try JSONDecoder().decode(HarnessValue.self, from: HarnessMigration.legacyData(from: document)).object!
        #expect(root["scheduler"]?.object?["pauseSeconds"] == .number(0.17))
        #expect(root["agents"]?.object?["web"] == .bool(false))
        #expect(root["models"]?.object?["drafts"] == .array([.string("my/provider/model")]))
        #expect(root["my-retained-data"] == .unsigned(UInt64.max))
    }

    @Test func onlyV2PromptCopyControlsLegacyProjection() throws {
        var document = try migrated()
        document.prompts["gate"]?.text = "My newly edited prompt."
        let root = try JSONDecoder().decode(HarnessValue.self, from: HarnessMigration.legacyData(from: document)).object!
        #expect(root["prompts"]?.object?["gate"] == .string("My newly edited prompt."))
        #expect(document.compatibility?.extra["prompts"] == nil)
    }

    @Test(arguments: ["not-json", "{\"version\":3}", "{\"version\":1,\"agents\":false}",
                     "{\"version\":1,\"voice\":{\"whisper\":\"yes\"}}", "{\"version\":1,\"models\":{\"drafts\":[42]}}"])
    func invalidLegacyCannotBecomeAnActivePreset(_ text: String) throws {
        let baseline = try v1Defaults()
        #expect(throws: (any Error).self) { try HarnessMigration.fromLegacy(Data(text.utf8), defaults: baseline) }
    }
}

@Suite struct OpenHarnessConfiguration {
    @Test func arbitraryRolesVendorAndOpaqueUpstreamNamesRoundTrip() throws {
        let config = customFlow()
        let data = try HarnessJSON.encode(config)
        let read = try HarnessConfiguration.decode(data)
        #expect(read == config)
        #expect(read.models["fast"]?.upstreamID == "my-provider/my-model")
        #expect(read.roles["my-writer"]?.prompts == ["answer-my-way"])
        #expect(try HarnessJSON.encode(read) == data)
    }

    @Test(arguments: ["root", "connection", "authentication", "role", "node"])
    func unknownStructuralFieldsAreNeverSilentlyDropped(_ position: String) throws {
        var object = try JSONDecoder().decode(HarnessValue.self, from: HarnessJSON.encode(customFlow())).object!
        switch position {
        case "connection":
            var connections = object["connections"]!.object!, item = connections["gateway"]!.object!
            item["headers"] = .object([:]); connections["gateway"] = .object(item); object["connections"] = .object(connections)
        case "authentication":
            var connections = object["connections"]!.object!, item = connections["gateway"]!.object!, auth = item["authentication"]!.object!
            auth["apiKey"] = .string("synthetic-test-only"); item["authentication"] = .object(auth)
            connections["gateway"] = .object(item); object["connections"] = .object(connections)
        case "role":
            var roles = object["roles"]!.object!, item = roles["my-writer"]!.object!
            item["shell"] = .string("untrusted text, never executed"); roles["my-writer"] = .object(item); object["roles"] = .object(roles)
        case "node":
            var flows = object["flows"]!.object!, item = flows["my-arrangement"]!.object!, nodes = item["nodes"]!.object!, node = nodes["show"]!.object!
            node["eval"] = .string("untrusted expression"); nodes["show"] = .object(node); item["nodes"] = .object(nodes)
            flows["my-arrangement"] = .object(item); object["flows"] = .object(flows)
        default: object["permissions"] = .object([:])
        }
        let data = try HarnessJSON.encode(HarnessValue.object(object))
        #expect(throws: HarnessProblem.self) { try HarnessConfiguration.decode(data) }
    }

    @Test(arguments: ["https://user:secret@example.invalid/v1", "https://example.invalid/v1?key=synthetic",
                     "https://example.invalid/v1#secret", "http://example.invalid/v1", "https://example.invalid/v1/../other",
                     "https://example.invalid/v1/%2e%2e/other", "file:///tmp/model", "https://example.invalid/v1//other"])
    func unsafeEndpointsAreRejected(_ url: String) {
        var config = customFlow()
        config.connections["gateway"]?.endpoint.baseURL = url
        #expect(throws: HarnessProblem.self) { try config.validate() }
    }

    @Test(arguments: ["http://127.0.0.1:4000/v1", "http://localhost:11434/v1", "http://[::1]:1234/v1"])
    func loopbackCompatibleServersNeedNoVendorCode(_ url: String) throws {
        var config = customFlow()
        config.connections["gateway"]?.endpoint.baseURL = url
        try config.validate()
    }

    @Test(arguments: ["missing-model", "missing-prompt", "wrong-kind", "inflated-capabilities", "device-claim", "policy", "fallback", "missing-decision-policy"])
    func incompatibleAssignmentsFailBeforeExecution(_ mutation: String) {
        var config = withReview(customFlow())
        switch mutation {
        case "missing-model": config.roles["my-writer"]?.model = "absent"
        case "missing-prompt": config.roles["my-writer"]?.prompts = ["absent"]
        case "wrong-kind": config.roles["my-writer"]?.model = "decider"
        case "inflated-capabilities": config.models["fast"]?.capabilities.append(.probabilities)
        case "device-claim": config.models["fast"]?.execution = .onDevice
        case "policy": config.profiles["mine"]?.allowedExecution = [.onDevice]
        case "fallback": config.roles["my-writer"]?.fallbacks = ["fast"]
        default: config.roles["my-reviewer"]?.decisionPolicy = nil
        }
        #expect(throws: HarnessProblem.self) { try config.validate() }
    }

    @Test func noGeneratedScoreCanClaimProviderProbabilitySemantics() {
        var config = withReview(customFlow())
        config.models["decider"]?.operation = "write"
        #expect(throws: HarnessProblem.self) { try config.validate() }
    }

    @Test(arguments: [#"{"version":1,"version":2}"#, #"{"version":1,"\u0076ersion":2}"#,
                     #"{"outer":[{"name":1,"name":2}]}"#])
    func duplicateKeysCannotHideCompetingConfigurationValues(_ text: String) {
        #expect(throws: HarnessProblem.self) { try HarnessJSON.checkUniqueKeys(Data(text.utf8)) }
    }

    @Test func stringEscapesBracesAndUnicodeAreDataRatherThanScannerStructure() throws {
        let input: HarnessValue = .object(["quoted\"key": .string("\" braces {[ ]} \\ ä \n \t"),
                                           "other": .array([.bool(true), .null, .integer(42)])])
        try HarnessJSON.checkUniqueKeys(HarnessJSON.encode(input))
        #expect(throws: HarnessProblem.self) {
            try HarnessJSON.checkUniqueKeys(Data((String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)).utf8))
        }
    }

    @Test func trailingNewlineIsNotAnIdentifierOrDecisionField() {
        var config = customFlow()
        config.roles["writer\n"] = config.roles.removeValue(forKey: "my-writer")
        config.flows["my-arrangement"]?.nodes["write-now"]?.role = "writer\n"
        #expect(throws: HarnessProblem.self) { try config.validate() }
    }
}

@Suite struct OpenHarnessFlows {
    @Test func dependencyOrderAndParallelWritersAreDeterministic() throws {
        var config = customFlow()
        config.roles["another-writer"] = config.roles["my-writer"]
        config.flows["my-arrangement"]?.nodes["other"] = .init(kind: .invoke, role: "another-writer", inputs: ["context": "selected-context"])
        config.flows["my-arrangement"]?.nodes["join"] = .init(kind: .join, inputs: ["a": "write-now", "b": "other"], join: .firstValid)
        config.flows["my-arrangement"]?.nodes["show"]?.inputs["candidate"] = "join"
        try config.validate()
        #expect(try HarnessFlowCompiler.compile("my-arrangement", in: config) == ["selected-context", "other", "write-now", "join", "show"])
    }

    @Test func conditionalWorkDependsOnItsTypedDecision() throws {
        var config = withReview(customFlow())
        config.flows["my-arrangement"]?.nodes["show"]?.condition = .init(node: "review", field: "useful.probability", comparison: .atLeast, value: .number(0.8))
        try config.validate()
        #expect(try HarnessFlowCompiler.compile("my-arrangement", in: config) == ["selected-context", "write-now", "review", "show"])
    }

    @Test(arguments: ["cycle", "missing-node", "wrong-port", "two-publishers", "unavailable-review", "empty-join", "missing-role", "script-condition", "legacy-mix"])
    func invalidArrangementsAreRejected(_ mutation: String) throws {
        var config = withReview(customFlow())
        switch mutation {
        case "cycle": config.flows["my-arrangement"]?.nodes["selected-context"]?.after = ["write-now"]
        case "missing-node": config.flows["my-arrangement"]?.nodes["write-now"]?.after = ["absent"]
        case "wrong-port": config.flows["my-arrangement"]?.nodes["show"]?.inputs["candidate"] = "selected-context"
        case "two-publishers": config.flows["my-arrangement"]?.nodes["show-again"] = .init(kind: .publish, inputs: ["candidate": "write-now"])
        case "unavailable-review": config.roles["my-reviewer"]?.onUnavailable = .skip
        case "empty-join": config.flows["my-arrangement"]?.nodes["empty"] = .init(kind: .join, join: .all)
        case "missing-role": config.flows["my-arrangement"]?.nodes["write-now"]?.role = "absent"
        case "script-condition": config.flows["my-arrangement"]?.nodes["show"]?.condition = .init(node: "review", field: "eval(untrusted)", comparison: .equal, value: .bool(true))
        default: config.flows["my-arrangement"]?.nodes["old-engine"] = .init(kind: .currentListen)
        }
        #expect(throws: HarnessProblem.self) { try config.validate() }
    }

    @Test func snapshotIsImmutableAndDoesNotTreatAnImportAsAccess() throws {
        var config = customFlow()
        let snapshot = try HarnessResolvedPlan(configuration: config)
        config.prompts["answer-my-way"]?.text = "Changed later."
        #expect(snapshot.configuration.prompts["answer-my-way"]?.text != config.prompts["answer-my-way"]?.text)
        #expect(snapshot.availability["fast"] == .unbound)
        #expect(try snapshot.hash == HarnessResolvedPlan(configuration: snapshot.configuration).hash)
        #expect(snapshot.availability["decider"] == nil, "unused models have no active role")
    }

    @Test func availabilityRequiresLocalDestinationBindingAndRealCapabilityObservation() throws {
        var config = customFlow()
        let grant = try config.connections["gateway"]!.bindingFingerprint()
        let bindings = ["gateway": grant]
        #expect(try HarnessResolvedPlan(configuration: config, boundConnections: bindings).availability["fast"] == .untested)
        #expect(try HarnessResolvedPlan(configuration: config, boundConnections: bindings, testedCapabilities: observed(config, capabilities: [])).availability["fast"] == .incompatible)
        #expect(try HarnessResolvedPlan(configuration: config, boundConnections: bindings, testedCapabilities: observed(config, capabilities: [.text])).availability["fast"] == .ready)
        config.connections["gateway"]?.enabled = false
        #expect(try HarnessResolvedPlan(configuration: config, boundConnections: bindings, testedCapabilities: observed(config, capabilities: [.text])).availability["fast"] == .disabled)
        config.connections["gateway"]?.enabled = true
        config.connections["gateway"]?.endpoint.baseURL = "https://another.invalid/v1"
        #expect(try HarnessResolvedPlan(configuration: config, boundConnections: bindings, testedCapabilities: observed(config, capabilities: [.text])).availability["fast"] == .unbound)
    }

    @Test func changingUpstreamModelInvalidatesAnEarlierCapabilityObservation() throws {
        var config = customFlow()
        let grant = try config.connections["gateway"]!.bindingFingerprint()
        let tested = try observed(config, capabilities: [.text, .stream])
        config.models["fast"]?.upstreamID = "different/provider-model"
        #expect(try HarnessResolvedPlan(configuration: config, boundConnections: ["gateway": grant], testedCapabilities: tested).availability["fast"] == .untested)
    }
}

@Suite struct OpenHarnessStore {
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "listen-harness-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "system.json")
    }

    @Test func explicitMigrationBacksUpOriginalBytesAndLoadsV2() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = Data("{\"version\":1,\"prompts\":{\"gate\":\"Use my words.\"}}\n".utf8)
        try original.write(to: file)
        let store = legacyStore(file)
        let before = await store.load()
        #expect(before.origin == .needsMigration && before.configuration == nil)
        #expect(try Data(contentsOf: file) == original)
        let after = try await store.migrate(defaults: v1Defaults(), expectedSourceHash: before.sourceHash!)
        #expect(after.origin == .primary && after.problem == nil)
        #expect(after.configuration?.prompts["gate"]?.text == "Use my words.")
        let backups = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == original)
    }

    @Test func badEditUsesPersistentLastValidAndDoesNotOverwriteTheEdit() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = customFlow()
        let store = HarnessConfigurationStore(file: file)
        _ = try await store.save(config, expectedSourceHash: nil)
        let broken = Data("{broken-owner-edit".utf8)
        try broken.write(to: file)
        let restarted = HarnessConfigurationStore(file: file)
        let read = await restarted.load()
        #expect(read.origin == .recovery && read.configuration == config && read.problem != nil)
        #expect(read.sourceHash == HarnessJSON.hash(broken))
        #expect(try Data(contentsOf: file) == broken)
        var repaired = config
        repaired.revision += 1
        #expect(try await restarted.save(repaired, expectedSourceHash: read.sourceHash).origin == .primary)
    }

    @Test func staleFormCannotOverwriteAnAgentsNewerEdit() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var config = customFlow()
        let store = HarnessConfigurationStore(file: file)
        let read = try await store.save(config, expectedSourceHash: nil)
        let changed = Data("{an-external-edit".utf8)
        try changed.write(to: file)
        config.revision += 1
        await #expect(throws: HarnessProblem.self) { try await store.save(config, expectedSourceHash: read.sourceHash) }
        #expect(try Data(contentsOf: file) == changed)
    }

    @Test func saveRequiresAdvancingRevisionAndCannotBypassLegacyBackup() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = customFlow(), store = HarnessConfigurationStore(file: file)
        let first = try await store.save(config, expectedSourceHash: nil)
        await #expect(throws: HarnessProblem.self) { try await store.save(config, expectedSourceHash: first.sourceHash) }
        let legacy = try v1Defaults()
        try legacy.write(to: file)
        await #expect(throws: HarnessProblem.self) { try await store.save(config, expectedSourceHash: HarnessJSON.hash(legacy)) }
        #expect(try Data(contentsOf: file) == legacy)
    }

    @Test func invalidFileWithoutRecoveryNeverActivatesFreshDefaults() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HarnessConfigurationStore(file: file)
        #expect(await store.load().origin == .missing)
        try Data("{\"version\":99}".utf8).write(to: file)
        let read = await store.load()
        #expect(read.configuration == nil && read.origin == .invalid && read.problem != nil)
    }

    @Test func invalidMigrationLeavesNoBackupAndNoChangedPrimary() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let broken = Data("{\"version\":1,\"agents\":false}".utf8)
        try broken.write(to: file)
        let store = HarnessConfigurationStore(file: file), baseline = try v1Defaults()
        await #expect(throws: HarnessProblem.self) { try await store.migrate(defaults: baseline, expectedSourceHash: HarnessJSON.hash(broken)) }
        #expect(try Data(contentsOf: file) == broken)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["system.json"])
    }

    @Test func invalidLegacyCoreCannotPoisonLastValidSnapshot() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var config = try migrated()
        let store = legacyStore(file)
        _ = try await store.save(config, expectedSourceHash: nil)
        config.voice["speakers"] = .string("an incorrect type")
        config.revision += 1
        let invalid = try HarnessJSON.encode(config)
        try invalid.write(to: file)
        let read = await store.load()
        #expect(read.origin == .recovery && read.configuration?.revision == 1)
        #expect(read.problem?.path == "compatibility")
        #expect(try Data(contentsOf: file) == invalid)
    }

    @Test func compatibilityCannotActivateWithoutTheRealEngineValidator() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = try migrated(), store = HarnessConfigurationStore(file: file)
        await #expect(throws: HarnessProblem.self) { try await store.save(config, expectedSourceHash: nil) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

#if canImport(Listen)
/// Integration regression found while reviewing the shared engine checkpoint.
private struct EmptyChunkWriter: ModelClient {
    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(""))
            let ending = Task {
                try? await Task.sleep(for: .milliseconds(500))
                continuation.finish()
            }
            continuation.onTermination = { _ in ending.cancel() }
        }
    }
}

private struct BoundedWriterFixture: ModelClient {
    var text: String
    var stayOpen = false
    var terminated: (@Sendable () -> Void)?
    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.text(text))
                if stayOpen { try? await Task.sleep(for: .seconds(30)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel(); terminated?() }
        }
    }
}

private actor WriterTerminationProbe {
    var stopped = false
    func stop() { stopped = true }
}

@Suite struct WriterDeadlineReview {
    @Test func theBriefHintPolicyReturnsWholeBulletsWithoutWaitingForTheProvider() async throws {
        let text = "Title\n- First supported point.\n- Second useful point.\n- Third complete point.\n- Unwanted repetition.\n"
        let probe = WriterTerminationProbe()
        let began = ContinuousClock.now
        let result = try await AnswerEngine.write(BoundedWriterFixture(text: text, stayOpen: true,
            terminated: { Task { await probe.stop() } }),
            model: "synthetic", system: "", user: "", maxTokens: 100,
            firstTextWithin: .seconds(1), previewBulletLimit: 3, partial: { _ in })
        #expect(result.text.hasSuffix("- Third complete point.\n"))
        #expect(!result.text.contains("Unwanted"))
        #expect(ContinuousClock.now - began < .seconds(1))
        for _ in 0..<20 {
            if await probe.stopped { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.stopped, "The provider stream is cancelled when the first hint is ready")
        #expect(AnswerEngine.completeBulletPreview("Title\n- An unfinished point", limit: 1) == nil)
        #expect(AnswerEngine.completeBulletPreview("Title\n```text\n- Code inside a fence.\n```\n", limit: 1) == nil)
    }

    @Test func firstTextDoesNotDisableTheTotalDeadline() async {
        let began = ContinuousClock.now
        await #expect(throws: WriterLimit.duration) {
            try await AnswerEngine.write(BoundedWriterFixture(text: "A useful beginning\n", stayOpen: true),
                model: "synthetic", system: "", user: "", maxTokens: 100,
                firstTextWithin: .seconds(1), totalWithin: .milliseconds(50), partial: { _ in })
        }
        #expect(ContinuousClock.now - began < .seconds(1))
    }

    @Test func aProviderIgnoringTokenLimitsCannotPublishAnOversizedChunk() async {
        await #expect(throws: WriterLimit.characters) {
            try await AnswerEngine.write(BoundedWriterFixture(text: String(repeating: "x", count: 5000)),
                model: "synthetic", system: "", user: "", maxTokens: 10,
                firstTextWithin: .seconds(1), maximumCharacters: 100, partial: { _ in
                    Issue.record("Oversized text must be rejected before publication")
                })
        }
    }

    @Test func repeatedProseStopsButRepeatedCodeDoesNot() async throws {
        let line = "- Explain the actual decision and its alternatives.\n"
        #expect(!AnswerEngine.hasRepeatedOutput(line + line))
        #expect(AnswerEngine.hasRepeatedOutput(line + line + line))
        let code = "Example\n```text\n" + line + line + line + "```\n"
        #expect(!AnswerEngine.hasRepeatedOutput(code))
        await #expect(throws: WriterLimit.repetition) {
            try await AnswerEngine.write(BoundedWriterFixture(text: line + line + line),
                model: "synthetic", system: "", user: "", maxTokens: 100,
                firstTextWithin: .seconds(1), partial: { _ in })
        }
        let result = try await AnswerEngine.write(BoundedWriterFixture(text: code),
            model: "synthetic", system: "", user: "", maxTokens: 100,
            firstTextWithin: .seconds(1), partial: { _ in })
        #expect(result.text == code)
    }

    @Test func anEmptyChunkDoesNotDisableTheFirstTextDeadline() async {
        await #expect(throws: WriterStall.self) {
            try await AnswerEngine.write(EmptyChunkWriter(), model: "synthetic", system: "", user: "", maxTokens: 1,
                                         firstTextWithin: .milliseconds(100), partial: { _ in })
        }
    }
}
#endif
