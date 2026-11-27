import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct TopicMemoryRemoval {
    @Test func removingAllNotesPreservesTopicsMaterialInstructionsAndUnrelatedFolders() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: "Listen-memory-removal-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let topic = root.appending(path: UUID().uuidString)
        let notes = topic.appending(path: "conversations")
        let unrelated = root.appending(path: "unrelated/conversations")
        try files.createDirectory(at: notes, withIntermediateDirectories: true)
        try files.createDirectory(at: unrelated, withIntermediateDirectories: true)
        for file in [notes.appending(path: "synthetic.md"), notes.appending(path: "synthetic.json"),
                     topic.appending(path: "material.txt"), topic.appending(path: "instructions.md"),
                     unrelated.appending(path: "keep.txt")] {
            try Data("synthetic fixture".utf8).write(to: file)
        }
        try TopicSandbox.clearAllNotes(root: root)
        #expect(!files.fileExists(atPath: notes.path))
        #expect(files.fileExists(atPath: topic.path))
        for file in [topic.appending(path: "material.txt"), topic.appending(path: "instructions.md"),
                     unrelated.appending(path: "keep.txt")] {
            #expect(try String(contentsOf: file, encoding: .utf8) == "synthetic fixture")
        }
    }

    @Test func topicSymlinksNeverRemoveMemoryOutsideTheRoot() throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appending(path: "Listen-memory-links-" + UUID().uuidString)
        defer { try? files.removeItem(at: fixture) }
        let root = fixture.appending(path: "topics"), outside = fixture.appending(path: "outside")
        let notes = outside.appending(path: "conversations")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try files.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("synthetic fixture".utf8).write(to: notes.appending(path: "keep.md"))
        try files.createSymbolicLink(at: root.appending(path: UUID().uuidString), withDestinationURL: outside)
        try TopicSandbox.clearAllNotes(root: root)
        #expect(files.fileExists(atPath: notes.appending(path: "keep.md").path))
    }

    @Test func absentRootsAreSafeButUnreadableRootsAreNotReportedAsSuccess() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: "Listen-memory-invalid-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        try TopicSandbox.clearAllNotes(root: root)
        try Data("synthetic fixture".utf8).write(to: root)
        #expect(throws: (any Error).self) { try TopicSandbox.clearAllNotes(root: root) }
        #expect(try String(contentsOf: root, encoding: .utf8) == "synthetic fixture")
    }

    @Test func deletingRecordingsPreservesCustomRootAndUnrelatedData() async throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appending(path: "Listen-recording-removal-" + UUID().uuidString)
        defer { try? files.removeItem(at: fixture) }
        let roots = [fixture.appending(path: "current"), fixture.appending(path: "previous")]
        for root in roots {
            let recording = root.appending(path: "2026-01-01_10-00-00")
            let unrelated = root.appending(path: "2026-01-02_10-00-00")
            try files.createDirectory(at: recording, withIntermediateDirectories: true)
            try files.createDirectory(at: unrelated, withIntermediateDirectories: true)
            let meta: [String: Any] = ["topic": "Synthetic fixture", "started": "2026-01-01T10:00:00Z", "sample_rate": 16000]
            try JSONSerialization.data(withJSONObject: meta).write(to: recording.appending(path: "run.json"))
            try Data("synthetic fixture".utf8).write(to: unrelated.appending(path: "keep.txt"))
            try Data("synthetic fixture".utf8).write(to: root.appending(path: "keep.txt"))
        }
        try await RecordingLibrary().deleteRecordings(roots: roots + roots)
        for root in roots {
            #expect(files.fileExists(atPath: root.path))
            #expect(!files.fileExists(atPath: root.appending(path: "2026-01-01_10-00-00").path))
            #expect(files.fileExists(atPath: root.appending(path: "2026-01-02_10-00-00/keep.txt").path))
            #expect(files.fileExists(atPath: root.appending(path: "keep.txt").path))
        }
    }

    @Test func recordingSymlinksAndInvalidRootsAreNotDeletedAsRecordings() async throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appending(path: "Listen-recording-links-" + UUID().uuidString)
        defer { try? files.removeItem(at: fixture) }
        let root = fixture.appending(path: "root"), outside = fixture.appending(path: "outside")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        let meta: [String: Any] = ["topic": "Synthetic fixture", "started": "2026-01-01T10:00:00Z", "sample_rate": 16000]
        try JSONSerialization.data(withJSONObject: meta).write(to: outside.appending(path: "run.json"))
        let link = root.appending(path: "2026-01-01_10-00-00")
        try files.createSymbolicLink(at: link, withDestinationURL: outside)
        let library = RecordingLibrary()
        try await library.deleteRecordings(roots: [root])
        #expect(files.fileExists(atPath: link.path))
        #expect(files.fileExists(atPath: outside.appending(path: "run.json").path))
        let invalid = fixture.appending(path: "not-a-directory")
        try Data("synthetic fixture".utf8).write(to: invalid)
        await #expect(throws: (any Error).self) { try await library.deleteRecordings(roots: [invalid]) }
    }

}
