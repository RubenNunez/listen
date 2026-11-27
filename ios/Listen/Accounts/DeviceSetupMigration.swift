import CryptoKit
import Foundation

/// A direct device migration, distinct from a public system preset. Files are streamed
/// inside the authenticated encrypted connection, never embedded in the QR code.
enum DeviceSetupMigration {
    static let topPaths = ["topics.json", "Listen/systems.json", "Listen/system.json", "Listen/Topics", "Listen/Runs", "Listen/Instructions", "Listen/mcp.json", "Listen/routers.json"]
    static let preferenceKeys = ["accountName", "myFigure", "recordRuns", "jevDecisionsEnabled", "chatgptAlsoAsked", "assistant.quickStartTopic", "gitHubClientID"]
    static let chunkSize = 32_768
    struct File: Codable, Sendable { var path: String; var bytes: Int64; var sha256: String }
    struct Manifest: Codable, Sendable {
        var version = 1
        var files: [File]
        var preferences: [String: HarnessValue]
        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
        func validate() throws {
            guard version == 1, files.count <= 20_000, Set(files.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count == files.count,
                  Set(preferences.keys).isSubset(of: Set(preferenceKeys)),
                  files.contains(where: { $0.path == "topics.json" }), files.contains(where: { $0.path == "Listen/systems.json" }) else { throw KeyTransferFailure.invalid }
            for (name, value) in preferences {
                switch (name, value) {
                case ("recordRuns", .bool), ("jevDecisionsEnabled", .bool): break
                case ("chatgptAlsoAsked", .array(let models)):
                    guard models.count <= 100, models.allSatisfy({ $0.string.map { $0.utf8.count <= 256 } == true }) else { throw KeyTransferFailure.invalid }
                case ("accountName", .string(let text)), ("myFigure", .string(let text)), ("assistant.quickStartTopic", .string(let text)), ("gitHubClientID", .string(let text)):
                    guard text.utf8.count <= 4096 else { throw KeyTransferFailure.invalid }
                default: throw KeyTransferFailure.invalid
                }
            }
            let paths = Set(files.map(\.path))
            for file in files {
                var parent = (file.path as NSString).deletingLastPathComponent
                while !parent.isEmpty { guard !paths.contains(parent) else { throw KeyTransferFailure.invalid }; parent = (parent as NSString).deletingLastPathComponent }
            }
            for file in files where file.path.hasSuffix(".json") && !file.path.hasPrefix("Listen/Topics/") && !file.path.hasPrefix("Listen/Runs/") {
                guard file.bytes <= (file.path == "Listen/systems.json" ? 32_000_000 : 4_000_000) else { throw KeyTransferFailure.invalid }
            }
            guard (try JSONEncoder().encode(self)).count <= KeyTransferCrypto.maximumFrame - 40_000 else { throw KeyTransferFailure.invalid }
            var total: Int64 = 0
            for file in files {
                guard DeviceSetupMigration.validPath(file.path), file.bytes >= 0, file.bytes <= 1_099_511_627_776,
                      file.sha256.wholeMatch(of: /[a-f0-9]{64}/) != nil,
                      !total.addingReportingOverflow(file.bytes).overflow else { throw KeyTransferFailure.invalid }
                total += file.bytes
                guard total <= 1_099_511_627_776 else { throw KeyTransferFailure.invalid }
            }
        }
    }
    struct Plan: Sendable { var manifest: Manifest; var sources: [URL] }

    static func validPath(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 2048, !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        return topPaths.contains { path == $0 } || ["Listen/Topics", "Listen/Runs", "Listen/Instructions"].contains { path.hasPrefix($0 + "/") }
    }

    /// Source paths are selected by the app, not supplied by a remote packet.
    static func prepare(support: URL, runs: [URL], preferences: [String: HarnessValue]) throws -> Plan {
        let manager = FileManager.default
        var sources: [(String, URL)] = []
        func append(_ folder: URL, as prefix: String) throws {
            guard manager.fileExists(atPath: folder.path) else { return }
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw KeyTransferFailure.invalid }
            if values.isDirectory != true { guard values.isRegularFile == true else { throw KeyTransferFailure.invalid }; sources.append((prefix, folder)); return }
            let base = folder.standardizedFileURL.path + "/"
            var walkError: Error?
            let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in walkError = error; return false })
            while let file = walker?.nextObject() as? URL {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw KeyTransferFailure.invalid }
                guard info.isRegularFile == true, file.lastPathComponent != ".DS_Store" else { continue }
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(base) else { throw KeyTransferFailure.invalid }
                sources.append((prefix + "/" + path.dropFirst(base.count), file))
                guard sources.count <= 20_000 else { throw KeyTransferFailure.invalid }
            }
            if let walkError { throw walkError }
        }
        for path in topPaths where path != "Listen/Runs" { try append(support.appending(path: path), as: path) }
        for run in runs {
            guard run.lastPathComponent.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}/) != nil,
                  manager.fileExists(atPath: run.appending(path: "run.json").path) else { continue }
            try append(run, as: "Listen/Runs/" + run.lastPathComponent)
        }
        sources.sort { $0.0 < $1.0 }
        var files: [File] = [], uniqueSources: [URL] = []
        var byPath: [String: File] = [:]
        for (path, url) in sources {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256(), bytes: Int64 = 0
            while let data = try handle.read(upToCount: 262_144), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data); bytes += Int64(data.count)
            }
            let file = File(path: path, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
            if let earlier = byPath[path] {
                // Recorded runs may be visible from both a development location and
                // Application Support. Only byte-identical copies share one ID.
                guard earlier.bytes == file.bytes, earlier.sha256 == file.sha256 else { throw KeyTransferFailure.invalid }
                continue
            }
            byPath[path] = file; files.append(file); uniqueSources.append(url)
        }
        let manifest = Manifest(files: files, preferences: preferences)
        try manifest.validate()
        return Plan(manifest: manifest, sources: uniqueSources)
    }

    static func send(_ plan: Plan, channel: KeyTransferChannel, key: SymmetricKey, claim: KeyTransferCrypto.Claim,
                     progress: @escaping @Sendable (Int64, Int64) async -> Void) async throws {
        var done: Int64 = 0, last = Date.distantPast
        for (index, file) in plan.manifest.files.enumerated() {
            let input = try FileHandle(forReadingFrom: plan.sources[index])
            defer { try? input.close() }
            var offset: Int64 = 0, hash = SHA256()
            while offset < file.bytes {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: min(chunkSize, Int(file.bytes - offset))), !data.isEmpty else { throw KeyTransferFailure.invalid }
                hash.update(data: data)
                try await channel.send(KeyTransferCrypto.sealBytes(data, key: key, claim: claim, purpose: "file/\(index)/\(offset)"))
                offset += Int64(data.count); done += Int64(data.count)
                if Date().timeIntervalSince(last) > 0.2 { await progress(done, plan.manifest.bytes); last = .now }
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256,
                  (try input.read(upToCount: 1))?.isEmpty != false else { throw KeyTransferFailure.invalid }
        }
        await progress(done, plan.manifest.bytes)
    }

    static func receive(_ manifest: Manifest, channel: KeyTransferChannel, key: SymmetricKey, claim: KeyTransferCrypto.Claim,
                        progress: @escaping @Sendable (Int64, Int64) async -> Void) async throws -> URL {
        try manifest.validate()
        let manager = FileManager.default
        if let available = try? URL.cachesDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            guard available > manifest.bytes + 50_000_000 else { throw KeyTransferFailure.storage }
        }
        let stage = URL.cachesDirectory.appending(path: "ListenIncoming/" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? manager.removeItem(at: stage) } }
        var done: Int64 = 0, last = Date.distantPast
        for (index, file) in manifest.files.enumerated() {
            let url = stage.appending(path: file.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw KeyTransferFailure.storage }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var offset: Int64 = 0, hash = SHA256()
            while offset < file.bytes {
                try Task.checkCancellation()
                let data = try KeyTransferCrypto.openBytes(await channel.receive(), key: key, claim: claim, purpose: "file/\(index)/\(offset)")
                guard !data.isEmpty, data.count <= chunkSize, Int64(data.count) <= file.bytes - offset else { throw KeyTransferFailure.invalid }
                try output.write(contentsOf: data); hash.update(data: data)
                offset += Int64(data.count); done += Int64(data.count)
                if Date().timeIntervalSince(last) > 0.2 { await progress(done, manifest.bytes); last = .now }
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw KeyTransferFailure.invalid }
        }
        await progress(done, manifest.bytes)
        complete = true
        return stage
    }

    @MainActor static func preferences() -> [String: HarnessValue] {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.meowop.listen") ?? [:]
        var result: [String: HarnessValue] = [:]
        for name in preferenceKeys {
            if let value = domain[name], JSONSerialization.isValidJSONObject(["value": value]),
               let data = try? JSONSerialization.data(withJSONObject: ["value": value]),
               let raw = try? JSONDecoder().decode(HarnessValue.self, from: data).object?["value"] { result[name] = raw }
        }
        return result
    }

    /// Validate staged configuration before touching the destination. A dated backup
    /// keeps the prior setup; failures roll file moves back in reverse order.
    @MainActor static func install(stage: URL, manifest: Manifest, support: URL = .applicationSupportDirectory, defaults: UserDefaults = .standard, notify: Bool = true, move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> URL {
        try manifest.validate()
        // The network receiver hashes while staging. Recheck the small metadata here;
        // no unbounded JSON allocation and no symlink can enter the installed tree.
        let expectedFiles = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        let expectedPaths = Set(expectedFiles.keys)
        var seenPaths = Set<String>()
        let stageBase = stage.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { throw KeyTransferFailure.invalid }
        for case let url as URL in walker {
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard info.isSymbolicLink != true else { throw KeyTransferFailure.invalid }
            guard info.isRegularFile == true else { continue }
            let actualPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard actualPath.hasPrefix(stageBase) else { throw KeyTransferFailure.invalid }
            let path = String(actualPath.dropFirst(stageBase.count))
            guard expectedPaths.contains(path), let file = expectedFiles[path],
                  try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(file.bytes) else { throw KeyTransferFailure.invalid }
            if ["topics.json", "Listen/system.json", "Listen/systems.json", "Listen/mcp.json", "Listen/routers.json"].contains(path) {
                guard HarnessJSON.hash(try Data(contentsOf: url)) == file.sha256 else { throw KeyTransferFailure.invalid }
            }
            seenPaths.insert(path)
        }
        guard seenPaths == expectedPaths else { throw KeyTransferFailure.invalid }
        struct Topics: Decodable { var topics: [Topic]; var selectedID: UUID }
        let topics = try JSONDecoder().decode(Topics.self, from: Data(contentsOf: stage.appending(path: "topics.json")))
        guard !topics.topics.isEmpty, Set(topics.topics.map(\.id)).count == topics.topics.count, topics.topics.contains(where: { $0.id == topics.selectedID }) else { throw KeyTransferFailure.invalid }
        let configurationFile = stage.appending(path: "Listen/system.json")
        let validationDomain = "ListenTransferValidation." + UUID().uuidString
        let isolatedDefaults = UserDefaults(suiteName: validationDomain)!
        defer { isolatedDefaults.removePersistentDomain(forName: validationDomain) }
        let configuration: SystemConfig
        if FileManager.default.fileExists(atPath: configurationFile.path) {
            let loaded = SystemConfig.load(from: configurationFile, remembering: isolatedDefaults)
            guard loaded.problem == nil else { throw KeyTransferFailure.invalid }
            configuration = loaded.config
        } else { configuration = SystemConfig() }
        try configuration.conversation?.validate()
        let store = SystemStore(file: stage.appending(path: "Listen/systems.json"), current: configuration)
        guard store.storageProblem == nil else { throw KeyTransferFailure.invalid }
        for system in store.systems { _ = try SystemPackage.read(store.package(for: system).data()) }
        let mcp = MCPStore(file: stage.appending(path: "Listen/mcp.json"), readSecret: { _ in nil })
        guard mcp.problem == nil else { throw KeyTransferFailure.invalid }
        let routers = RouterStore(file: stage.appending(path: "Listen/routers.json"), readSecret: { _ in nil })
        guard routers.problem == nil else { throw KeyTransferFailure.invalid }
        // Device credentials are never cloned. Retain the configured routes, disabled
        // until the receiving device is paired in the normal router UI.
        for router in routers.routers where router.enabled { try routers.configure(router.id, enabled: false, model: router.model, usesCodex: router.usesCodex) }
        let manager = FileManager.default
        for folder in [support.appending(path: "Listen"), support.appending(path: "ListenTransferBackups")] where manager.fileExists(atPath: folder.path) {
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw KeyTransferFailure.invalid }
        }
        let backup = support.appending(path: "ListenTransferBackups/" + UUID().uuidString)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        let savedPreferences = Dictionary(uniqueKeysWithValues: (preferenceKeys + ["runsFolder", "runsFolderKept"]).compactMap { name in defaults.object(forKey: name).map { (name, $0) } })
        try PropertyListSerialization.data(fromPropertyList: savedPreferences, format: .binary, options: 0).write(to: backup.appending(path: "preferences.plist"), options: .atomic)
        var moved: [String] = [], installed: [String] = []
        do {
            for path in topPaths {
                let destination = support.appending(path: path), incoming = stage.appending(path: path), old = backup.appending(path: path)
                if manager.fileExists(atPath: destination.path) {
                    try manager.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try move(destination, old); moved.append(path)
                }
                if manager.fileExists(atPath: incoming.path) {
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try move(incoming, destination); installed.append(path)
                }
            }
        } catch {
            for path in installed.reversed() { try? move(support.appending(path: path), stage.appending(path: path)) }
            for path in moved.reversed() { try? move(backup.appending(path: path), support.appending(path: path)) }
            throw KeyTransferFailure.storage
        }
        for name in preferenceKeys { defaults.removeObject(forKey: name) }
        for (name, value) in manifest.preferences {
            let wrapped: HarnessValue = .object(["value": value])
            if let data = try? JSONEncoder().encode(wrapped), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { defaults.set(object["value"], forKey: name) }
        }
        defaults.removeObject(forKey: "systemConfigWritten")
        defaults.removeObject(forKey: "runsFolder")
        defaults.removeObject(forKey: "runsFolderKept")
        defaults.set(backup.path, forKey: "listen.lastSetupBackup")
        if notify { NotificationCenter.default.post(name: .listenSetupInstalled, object: nil) }
        try? manager.removeItem(at: stage)
        return backup
    }
}
