import Foundation

/// Owns only the selected configuration file and adjacent recovery copies.
/// Not wired into SystemConfig.load until the engine checkpoint is reviewed.
actor HarnessConfigurationStore {
    enum Origin: String, Sendable { case primary, recovery, needsMigration, missing, invalid }
    struct Read: Sendable {
        let configuration: HarnessConfiguration?
        let origin: Origin
        /// Hash of the actual primary bytes, even when the recovery copy is returned.
        let sourceHash: String?
        let problem: HarnessProblem?
    }

    let file: URL
    /// The production bridge must decode this through the real SystemConfig type.
    /// Without it, a legacy-backed document cannot become a last-valid snapshot.
    private let legacyValidator: (@Sendable (Data) throws -> Void)?
    private var recovery: URL { file.appendingPathExtension("last-valid") }

    init(file: URL, legacyValidator: (@Sendable (Data) throws -> Void)? = nil) {
        self.file = file
        self.legacyValidator = legacyValidator
    }

    func load() -> Read {
        guard let data = try? Data(contentsOf: file) else {
            // A missing primary is setup, never an excuse to activate cloud defaults.
            return Read(configuration: nil, origin: .missing, sourceHash: nil,
                        problem: HarnessProblem("$", "configuration is missing or unreadable"))
        }
        let sourceHash = HarnessJSON.hash(data)
        if Self.isLegacy(data) {
            return Read(configuration: nil, origin: .needsMigration, sourceHash: sourceHash, problem: nil)
        }
        do {
            let document = try validated(data)
            var problem: HarnessProblem?
            do {
                if (try? Data(contentsOf: recovery)) != data { try data.write(to: recovery, options: .atomic) }
            }
            catch { problem = HarnessProblem("$", "configuration is valid; recovery copy could not be saved") }
            return Read(configuration: document, origin: .primary, sourceHash: sourceHash, problem: problem)
        } catch {
            let problem = (error as? HarnessProblem) ?? HarnessProblem("$", "configuration could not be read")
            if let saved = try? Data(contentsOf: recovery), let good = try? validated(saved) {
                return Read(configuration: good, origin: .recovery, sourceHash: sourceHash, problem: problem)
            }
            return Read(configuration: nil, origin: .invalid, sourceHash: sourceHash, problem: problem)
        }
    }

    /// Migration is explicit, version checked and backed up before replacing v1.
    /// Defaults must be the current engine's encoded defaults, not an unrelated preset.
    func migrate(defaults: Data, expectedSourceHash: String) throws -> Read {
        let original = try checkedSource(expectedSourceHash)
        guard let original else { throw HarnessProblem("$", "legacy file is missing") }
        let document = try HarnessMigration.fromLegacy(original, defaults: defaults)
        let data = try HarnessJSON.encode(document)
        _ = try validated(data)
        let backup = file.appendingPathExtension("v1-" + HarnessJSON.hash(original) + ".backup")
        if FileManager.default.fileExists(atPath: backup.path) {
            guard (try? Data(contentsOf: backup)) == original else { throw HarnessProblem("$", "legacy backup differs; migration stopped") }
        } else { try original.write(to: backup, options: .withoutOverwriting) }
        _ = try checkedSource(expectedSourceHash)
        try data.write(to: file, options: .atomic)
        return load()
    }

    /// A form or agent supplies its read hash; stale edits cannot silently replace
    /// a newer file. Atomic replacement protects against partially written JSON.
    func save(_ document: HarnessConfiguration, expectedSourceHash: String?) throws -> Read {
        try document.validate()
        let data = try HarnessJSON.encode(document)
        _ = try validated(data)
        let old = try checkedSource(expectedSourceHash)
        if let old {
            guard !Self.isLegacy(old) else { throw HarnessProblem("$", "use explicit migration to preserve the v1 backup") }
            let previous = (try? validated(old)) ??
                (try? Data(contentsOf: recovery)).flatMap { try? validated($0) }
            if let previous {
                guard document.revision > previous.revision else { throw HarnessProblem("revision", "must advance the current valid revision") }
                // Preserve the previous working version before replacing the primary.
                try HarnessJSON.encode(previous).write(to: recovery, options: .atomic)
            }
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        _ = try checkedSource(expectedSourceHash)
        try data.write(to: file, options: .atomic)
        return load()
    }

    private func checkedSource(_ expected: String?) throws -> Data? {
        let data: Data?
        do { data = try Data(contentsOf: file) }
        catch {
            guard !FileManager.default.fileExists(atPath: file.path) else { throw HarnessProblem("$", "configuration is unreadable") }
            data = nil
        }
        guard data.map(HarnessJSON.hash) == expected else { throw HarnessProblem("$", "configuration changed; reload before saving") }
        return data
    }

    private func validated(_ data: Data) throws -> HarnessConfiguration {
        let document = try HarnessConfiguration.decode(data)
        if document.compatibility != nil {
            guard let legacyValidator else { throw HarnessProblem("compatibility", "the current engine's validator is required") }
            do { try legacyValidator(HarnessMigration.legacyData(from: document)) }
            catch { throw HarnessProblem("compatibility", "current engine settings have an invalid value") }
        }
        return document
    }

    private static func isLegacy(_ data: Data) -> Bool {
        guard (try? HarnessJSON.checkUniqueKeys(data)) != nil else { return false }
        return (try? JSONDecoder().decode(HarnessValue.self, from: data).object?["version"]) == .integer(1)
    }
}
