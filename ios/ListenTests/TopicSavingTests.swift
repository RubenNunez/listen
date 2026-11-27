import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct TopicSaving {
    private func temporary() -> URL { URL.temporaryDirectory.appending(path: "topic-save-tests-\(UUID())") }

    @Test func createsRenamesAndReloadsStableTopicIdentities() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "topics.json"), store = TopicStore(file: root.appending(path: "topics.json"))
        var first = Topic(name: "  Synthetic first  "), second = Topic(name: "Synthetic second")
        try store.saveTopic(first); try store.saveTopic(second)
        #expect(store.topics.count == 3 && store.selectedID == second.id)
        first.name = "Synthetic renamed"; try store.saveTopic(first)
        let reloaded = TopicStore(file: file)
        #expect(reloaded.topics.count == 3 && reloaded.selectedID == second.id)
        #expect(reloaded.topics.first { $0.id == first.id }?.name == "Synthetic renamed")
        second.name = "Synthetic renamed"; try store.saveTopic(second)
        #expect(store.topics.filter { $0.name == "Synthetic renamed" }.count == 2)
    }
    @Test func failedDiskWriteDoesNotPublishOrSelectAnUnsavedTopic() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appending(path: "blocked")
        try Data("synthetic blocker".utf8).write(to: blocked)
        let store = TopicStore(file: blocked.appending(path: "topics.json"))
        let old = store.topics, selected = store.selectedID
        #expect(throws: (any Error).self) { try store.saveTopic(Topic(name: "Synthetic unsaved")) }
        #expect(store.topics == old && store.selectedID == selected)
        #expect(try String(contentsOf: blocked, encoding: .utf8) == "synthetic blocker")
    }
    @Test func corruptOrChangedStoresAreNotOverwritten() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "topics.json")
        let first = TopicStore(file: file)
        try first.saveTopic(Topic(name: "Synthetic existing"))
        let second = TopicStore(file: file)
        try second.saveTopic(Topic(name: "Synthetic from another window"))
        let newer = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try first.saveTopic(Topic(name: "Synthetic stale")) }
        #expect(try Data(contentsOf: file) == newer)
        let corrupt = Data("synthetic damaged store".utf8)
        try corrupt.write(to: file)
        let damaged = TopicStore(file: file)
        #expect(throws: (any Error).self) { try damaged.saveTopic(Topic(name: "Synthetic replacement")) }
        #expect(try Data(contentsOf: file) == corrupt)
    }
    @Test func blankNamesDoNotChangeTheStore() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "topics.json"), store = TopicStore(file: root.appending(path: "topics.json"))
        let previous = store.topics
        #expect(throws: (any Error).self) { try store.saveTopic(Topic(name: " \n ")) }
        #expect(store.topics == previous && !FileManager.default.fileExists(atPath: file.path))
    }
}
