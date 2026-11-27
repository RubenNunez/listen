import Foundation
import Testing
@testable import Listen

@Suite struct RecordingLibraryTests {
    private func root() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "library-tests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func run(_ root: URL, second: Int, name: String, id: UUID? = nil, events: String) throws -> URL {
        let folder = root.appending(path: String(format: "2026-11-21_00-00-%02d", second), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var metadata: [String: Any] = ["topic": name, "audio_seconds": 15.0, "language": "de"]
        if let id { metadata["topic_id"] = id.uuidString }
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appending(path: "run.json"))
        try Data(events.utf8).write(to: folder.appending(path: "events.jsonl"))
        return folder
    }
    @Test func historyHandlesFormattingRevisionsLongLinesAndAnUnterminatedLastRecord() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let long = String(repeating: "synthetic ", count: 12_000)
        let data = """
        {"kind": "sentence", "id": 1, "text": "Ja."}
        {"kind": "sentence", "id": 1, "text": "Ja."}
        not json
        {"kind":"model_request","text":"\(long)","note":"sentence"}
        {"kind": "card_started"}
        {"kind": "model_request", "note": "card_started"}
        {"kind":"card_started"}
        """
        _ = try run(base, second: 1, name: "Synthetic", events: data)
        let entries = try await RecordingLibrary().history(roots: [base, base.appending(path: ".")])
        #expect(entries.count == 1)
        #expect(entries.first?.sentences == 1 && entries.first?.cards == 2)
        #expect(entries.first?.first == "Ja.")
    }
    @Test func stableIdentitySurvivesRenameWithoutMixingSameNamedTopics() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let selected = UUID()
        _ = try run(base, second: 1, name: "Before rename", id: selected, events: "")
        _ = try run(base, second: 2, name: "After rename", id: UUID(), events: "")
        _ = try run(base, second: 3, name: "After rename", events: "")
        let entries = try await RecordingLibrary().history(roots: [base], topic: .init(id: selected, name: "After rename"))
        #expect(entries.map { $0.folder.lastPathComponent } == ["2026-11-21_00-00-03", "2026-11-21_00-00-01"])
    }
    @Test func overviewCountsMaterialsNotesAndOrphanTopicsWithoutReadingEvents() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let topicRoot = base.appending(path: "topics"), id = UUID()
        let material = TopicMaterial(topic: id, root: topicRoot).folder
        let notes = TopicSandbox(topic: id, root: topicRoot).folder.appending(path: "conversations")
        for folder in [material, notes] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data().write(to: material.appending(path: "synthetic.txt"))
        try Data().write(to: material.appending(path: ".listen-index.json"))
        try Data().write(to: notes.appending(path: "one.md"))
        try Data().write(to: notes.appending(path: "one.json"))
        _ = try run(base, second: 1, name: "Scripted old", events: "")
        _ = try run(base, second: 2, name: "Scripted old", events: "")
        _ = try run(base, second: 3, name: "Personal", events: "")
        let topics: [RecordingLibrary.TopicReference] = [.init(id: id, name: "Synthetic", evaluation: true)]
        let overview = try await RecordingLibrary().overview(topics: topics, roots: [base], topicRoot: topicRoot)
        #expect(overview.topics[id]?.files == 1 && overview.topics[id]?.notes == 1)
        #expect(overview.evaluations == 2)
    }
    @Test func cancelledScansDoNotPublishPartialHistory() async throws {
        let library = RecordingLibrary()
        let gate = AsyncStream.makeStream(of: Void.self)
        defer { gate.continuation.finish() }
        let task = Task { () throws -> [RecordingLibrary.Entry] in
            for await _ in gate.stream.prefix(1) {}
            return try await library.history(roots: [])
        }
        task.cancel()
        gate.continuation.yield(())
        do { _ = try await task.value; Issue.record("Cancelled history scan succeeded") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error") }
    }
    @Test func corruptAndUnfinishedMetadataNeverBecomeReplayRows() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let folder = try run(base, second: 1, name: "Synthetic", events: "")
        try Data("{\"audio_seconds\":1e100}".utf8).write(to: folder.appending(path: "run.json"))
        let unfinished = base.appending(path: "2026-11-21_00-00-02", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        #expect(try await RecordingLibrary().history(roots: [base]).isEmpty)
    }

    /// Controlled comparison of the removed read-all-then-filter operation with
    /// the real background reader. Synthetic files only; no device-FPS claim.
    @MainActor @Test func syntheticSelectedTopicScanComparison() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let diagnostics = String(repeating: "{\"kind\":\"model_request\",\"text\":\"" + String(repeating: "x", count: 512) + "\"}\n", count: 4000)
        let events = diagnostics + "{\"kind\":\"sentence\",\"id\":2,\"text\":\"Synthetic stable history sentence.\"}\n{\"kind\":\"card_started\"}\n"
        let selected = UUID()
        for i in 0..<12 {
            _ = try run(base, second: i, name: i == 5 ? "Selected" : "Other \(i)", id: i == 5 ? selected : UUID(), events: events)
        }
        let clock = ContinuousClock()
        let began = clock.now
        // The prior TopicRow loaded every event log and only then filtered by name.
        var legacy: [URL] = []
        for folder in RecordingLibrary.runs(in: [base]).reversed() {
            let meta = TopicExport.meta(folder)!
            let text = try String(contentsOf: folder.appending(path: "events.jsonl"), encoding: .utf8)
            var sentences = Set<Int>(), cards = 0
            for line in text.split(separator: "\n") {
                if line.contains("\"kind\":\"card_started\"") { cards += 1 }
                if line.contains("\"kind\":\"sentence\""),
                   let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let id = (value["id"] as? NSNumber)?.intValue { sentences.insert(id) }
            }
            #expect(sentences.count == 1 && cards == 1)
            if meta["topic"] as? String == "Selected" { legacy.append(folder) }
        }
        let before = began.duration(to: clock.now)
        var uiPulses = 0
        let pulse = Task { @MainActor in
            while !Task.isCancelled { uiPulses += 1; try? await Task.sleep(for: .milliseconds(1)) }
        }
        let start = clock.now
        let actual = try await RecordingLibrary().history(roots: [base], topic: .init(id: selected, name: "Selected"))
        let after = start.duration(to: clock.now)
        pulse.cancel()
        #expect(actual.map(\.folder) == legacy)
        #expect(actual.first?.sentences == 1 && actual.first?.cards == 1)
        print("[LibraryBenchmark] 12 synthetic runs; bytesPerLog=\(events.utf8.count); legacyMain=\(before); backgroundSelected=\(after); mainActorPulsesDuringRead=\(uiPulses)")
    }
}
