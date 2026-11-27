import CryptoKit
import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct CompleteDeviceSetupTransfer {
    struct Topics: Codable { var topics: [Topic]; var selectedID: UUID }
    private func fixture(_ support: URL) throws -> Topic {
        var topic = Topic(name: "Synthetic migration topic")
        topic.notes = "Synthetic briefing"
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(Topics(topics: [topic], selectedID: topic.id)).write(to: support.appending(path: "topics.json"))
        let systems = SystemStore(file: support.appending(path: "Listen/systems.json"), current: SystemConfig())
        try #require(systems.storageProblem == nil)
        let files: [String: Data] = [
            "Listen/system.json": Data(SystemConfig().json.utf8),
            "Listen/Topics/\(topic.id)/material/example.md": Data("Synthetic topic evidence".utf8),
            "Listen/Topics/\(topic.id)/conversations/2026-11-20_12-00-00.md": Data("Synthetic note".utf8),
            "Listen/Instructions/cards.md": Data("Synthetic instruction".utf8),
            "Listen/Runs/2026-11-20_12-00-00/run.json": Data("{}".utf8),
            "Listen/Runs/2026-11-20_12-00-00/audio.wav": Data((0..<100_000).map { UInt8($0 % 251) }),
        ]
        for (path, data) in files {
            let file = support.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return topic
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw KeyTransferFailure.unavailable
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ListenSyntheticMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test(arguments: [false, true]) func wholeSetupStreamsOverRealSocketAndPreservesIDsAndAudio(includeAPIKey: Bool) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source"), destination = root.appending(path: "destination")
        let expected = try fixture(source), old = try fixture(destination)
        let run = source.appending(path: "Listen/Runs/2026-11-20_12-00-00")
        let plan = try DeviceSetupMigration.prepare(support: source, runs: [run], preferences: ["accountName": .string("Synthetic owner"), "recordRuns": .bool(false)])
        let domain = "ListenSyntheticMigration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain)); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("Previous synthetic owner", forKey: "accountName")
        var backup: URL?, installed = false
        var reads = 0, receivedKeys: [TransferAPI: String] = [:]
        let sourceStorage = KeyTransferSecrets(read: { provider in reads += 1; return includeAPIKey && provider == .openAI ? "synthetic-migrated-key" : nil }, write: { _, _ in }, remove: { _ in })
        let storage = KeyTransferSecrets(read: { receivedKeys[$0] }, write: { receivedKeys[$0] = $1 }, remove: { receivedKeys[$0] = nil })
        let sender = KeyTransferSender(secrets: sourceStorage)
        let receiver = KeyTransferReceiver(secrets: storage, makeChannel: { _, port in KeyTransferChannel(host: "127.0.0.1", port: port) }, installSetup: { stage, manifest in
            backup = try DeviceSetupMigration.install(stage: stage, manifest: manifest, support: destination, defaults: defaults, notify: false)
        })
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: Set(TransferAPI.allCases), setup: plan)
        try await wait { sender.code != nil }
        receiver.scan(try #require(sender.code), copySetup: true) { installed = true }
        try await wait { sender.waitingDevice != nil }
        #expect(!installed && backup == nil && reads == 0)
        sender.approve()
        try await wait { sender.code == nil }
        #expect(installed && receiver.status.contains("copied") && sender.status.contains("Setup copied"))
        #expect(reads == TransferAPI.allCases.count)
        #expect(receivedKeys == (includeAPIKey ? [.openAI: "synthetic-migrated-key"] : [:]))
        let topics = try JSONDecoder().decode(Topics.self, from: Data(contentsOf: destination.appending(path: "topics.json")))
        #expect(topics.selectedID == expected.id && topics.topics.first?.id == expected.id)
        let preserved = try JSONDecoder().decode(Topics.self, from: Data(contentsOf: #require(backup).appending(path: "topics.json")))
        #expect(preserved.selectedID == old.id)
        #expect(defaults.string(forKey: "accountName") == "Synthetic owner")
        #expect(defaults.bool(forKey: "recordRuns") == false)
        for file in plan.manifest.files {
            #expect(try Data(contentsOf: source.appending(path: file.path)) == Data(contentsOf: destination.appending(path: file.path)))
        }
    }
    @Test func sourceGrowthAfterTheInventoryCannotCommitATruncatedSetup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        _ = try fixture(source)
        let plan = try DeviceSetupMigration.prepare(support: source, runs: [], preferences: [:])
        let storage = KeyTransferSecrets(read: { _ in nil }, write: { _, _ in }, remove: { _ in })
        let sender = KeyTransferSender(secrets: storage)
        var installed = false
        let receiver = KeyTransferReceiver(secrets: storage, makeChannel: { _, port in KeyTransferChannel(host: "127.0.0.1", port: port) }, installSetup: { _, _ in installed = true })
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: [], setup: plan)
        try await wait { sender.code != nil }
        receiver.scan(try #require(sender.code), copySetup: true)
        try await wait { sender.waitingDevice != nil }
        let file = try FileHandle(forWritingTo: source.appending(path: "topics.json"))
        try file.seekToEnd(); try file.write(contentsOf: Data(" ".utf8)); try file.close()
        sender.approve()
        try await wait { sender.code == nil && receiver.verification == nil }
        #expect(!installed && sender.status.contains("not confirmed"))
    }
    @Test func identicalMirroredRunsTransferOnceButConflictingCopiesAreRejected() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        _ = try fixture(source)
        let run = source.appending(path: "Listen/Runs/2026-11-20_12-00-00"), mirror = root.appending(path: "mirror/2026-11-20_12-00-00")
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: run, to: mirror)
        let single = try DeviceSetupMigration.prepare(support: source, runs: [run], preferences: [:])
        let duplicated = try DeviceSetupMigration.prepare(support: source, runs: [run, mirror], preferences: [:])
        #expect(duplicated.manifest.files.count == single.manifest.files.count)
        #expect(duplicated.sources.count == duplicated.manifest.files.count)
        #expect(duplicated.manifest.bytes == single.manifest.bytes)
        try Data("different synthetic contents".utf8).write(to: mirror.appending(path: "run.json"))
        #expect(throws: (any Error).self) { try DeviceSetupMigration.prepare(support: source, runs: [run, mirror], preferences: [:]) }
    }
    @Test func pathsAndAmbiguousManifestsAreRejected() throws {
        for path in ["/topics.json", "Listen/Topics/../keys", "topics.json/child", "Listen/system.json/child", "Listen/Topics//a", "Listen/Topics/./a", "Listen/Topics/a\\b", "Listen/credentials.json"] {
            #expect(!DeviceSetupMigration.validPath(path))
        }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root)
        var manifest = try DeviceSetupMigration.prepare(support: root, runs: [], preferences: [:]).manifest
        manifest.files.append(.init(path: "Listen/Topics/X", bytes: 0, sha256: HarnessJSON.hash(Data())))
        manifest.files.append(.init(path: "Listen/Topics/x", bytes: 0, sha256: HarnessJSON.hash(Data())))
        #expect(throws: (any Error).self) { try manifest.validate() }
        manifest.files.removeLast(2)
        manifest.preferences["chatgptOAuthToken"] = .string("synthetic-forbidden")
        #expect(throws: (any Error).self) { try manifest.validate() }
    }
    @Test func corruptStagedMetadataNeverReplacesExistingSetup() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appending(path: "stage"), destination = root.appending(path: "destination")
        _ = try fixture(stage); _ = try fixture(destination)
        let before = try Data(contentsOf: destination.appending(path: "topics.json"))
        let plan = try DeviceSetupMigration.prepare(support: stage, runs: [], preferences: [:])
        try Data("corrupt".utf8).write(to: stage.appending(path: "topics.json"))
        #expect(throws: (any Error).self) { try DeviceSetupMigration.install(stage: stage, manifest: plan.manifest, support: destination, notify: false) }
        #expect(try Data(contentsOf: destination.appending(path: "topics.json")) == before)
    }
    @Test func partialFileMoveFailureRestoresThePreviousFilesAndPreferences() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source"), destination = root.appending(path: "destination"), stage = root.appending(path: "stage")
        _ = try fixture(source); _ = try fixture(destination)
        let run = source.appending(path: "Listen/Runs/2026-11-20_12-00-00")
        let plan = try DeviceSetupMigration.prepare(support: source, runs: [run], preferences: ["accountName": .string("Synthetic replacement")])
        try FileManager.default.copyItem(at: source, to: stage)
        let previous = try Data(contentsOf: destination.appending(path: "topics.json"))
        let domain = "ListenSyntheticMigration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain)); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("Synthetic previous", forKey: "accountName")
        var count = 0
        #expect(throws: (any Error).self) {
            try DeviceSetupMigration.install(stage: stage, manifest: plan.manifest, support: destination, defaults: defaults, notify: false, move: { from, to in
                count += 1
                if count == 4 { throw KeyTransferFailure.storage }
                try FileManager.default.moveItem(at: from, to: to)
            })
        }
        #expect(count > 4)
        #expect(try Data(contentsOf: destination.appending(path: "topics.json")) == previous)
        #expect(defaults.string(forKey: "accountName") == "Synthetic previous")
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Listen/Runs/2026-11-20_12-00-00/audio.wav").path))
    }
    @Test func fileChunksCannotBeReorderedOrReusedForAnotherFile() throws {
        let claim = KeyTransferCrypto.Claim(id: UUID(), publicKey: Data(repeating: 1, count: 32), nonce: Data(repeating: 2, count: 32), device: "Synthetic")
        let key = SymmetricKey(size: .bits256), data = Data("synthetic bytes".utf8)
        let encrypted = try KeyTransferCrypto.sealBytes(data, key: key, claim: claim, purpose: "file/0/0")
        #expect(try KeyTransferCrypto.openBytes(encrypted, key: key, claim: claim, purpose: "file/0/0") == data)
        for purpose in ["file/1/0", "file/0/32768", "keys"] {
            #expect(throws: (any Error).self) { try KeyTransferCrypto.openBytes(encrypted, key: key, claim: claim, purpose: purpose) }
        }
    }
    @Test func failedFileCommitRollsBackImportedAPIKeys() {
        var values: [TransferAPI: String] = [.openAI: "synthetic-existing"]
        let storage = KeyTransferSecrets(read: { values[$0] }, write: { values[$0] = $1 }, remove: { values[$0] = nil })
        #expect(throws: KeyTransferFailure.storage) {
            try storage.install([.init(provider: .openAI, value: "synthetic-replacement"), .init(provider: .deepSeek, value: "synthetic-added")]) { throw KeyTransferFailure.storage }
        }
        #expect(values == [.openAI: "synthetic-existing"])
    }
}
