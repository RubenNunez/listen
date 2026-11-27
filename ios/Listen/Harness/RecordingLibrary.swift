import Foundation

/// Serial disk reads stay off the UI executor. Views keep the returned snapshot
/// until their topics change or a storage-changing sheet closes.
actor RecordingLibrary {
    static let shared = RecordingLibrary()
    private static let sentenceMarker = Data("\"sentence\"".utf8)
    private static let cardMarker = Data("\"card_started\"".utf8)

    struct TopicReference: Sendable {
        var id: UUID
        var name: String
        var evaluation: Bool = false
    }
    struct Counts: Sendable {
        var files = 0
        var notes = 0
    }
    struct Overview: Sendable {
        var topics: [UUID: Counts] = [:]
        var evaluations = 0
    }
    struct StorageCounts: Sendable { var runs: Int; var notes: Int }

    /// User-confirmed cleanup runs on the library's executor, away from UI rendering.
    func clearConversationNotes(root: URL) throws {
        try TopicSandbox.clearAllNotes(root: root)
    }

    /// Remove recognized recordings, never the root or unrelated files in a custom folder.
    func deleteRecordings(roots: [URL]) throws {
        let files = FileManager.default
        var seen = Set<String>()
        for root in roots where seen.insert(root.standardizedFileURL.path).inserted {
            guard files.fileExists(atPath: root.path) else { continue }
            let entries = try files.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for entry in entries {
                guard entry.lastPathComponent.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}/) != nil else { continue }
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let meta = TopicExport.meta(entry), meta["topic"] is String,
                      meta["started"] is String, meta["sample_rate"] is NSNumber else { continue }
                try files.removeItem(at: entry)
            }
        }
    }

    func storageCounts(roots: [URL], topicRoot: URL) throws -> StorageCounts {
        try Task.checkCancellation()
        var notes = 0
        let folders = (try? FileManager.default.contentsOfDirectory(at: topicRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            try Task.checkCancellation()
            if let id = UUID(uuidString: folder.lastPathComponent) { notes += TopicSandbox(topic: id, root: topicRoot).notes.count }
        }
        return StorageCounts(runs: Self.runs(in: roots).count, notes: notes)
    }
    struct Entry: Identifiable, Sendable {
        var id: String { folder.path }
        var folder: URL
        var topic: String
        var seconds: Double
        var language: String
        var sentences: Int
        var cards: Int
        var first: String
    }

    nonisolated static func runs(in roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}/) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func overview(topics: [TopicReference], roots: [URL], topicRoot: URL) throws -> Overview {
        try Task.checkCancellation()
        var result = Overview()
        for topic in topics {
            try Task.checkCancellation()
            result.topics[topic.id] = Counts(files: TopicMaterial(topic: topic.id, root: topicRoot).items.count,
                                            notes: TopicSandbox(topic: topic.id, root: topicRoot).notes.count)
        }
        result.evaluations = topics.filter { $0.evaluation || TopicExport.isEvaluation($0.name) }.count
        let names = Set(topics.map(\.name))
        var orphans = Set<String>()
        for run in Self.runs(in: roots) {
            try Task.checkCancellation()
            if let name = TopicExport.meta(run)?["topic"] as? String,
               !names.contains(name), TopicExport.isEvaluation(name) { orphans.insert(name) }
        }
        result.evaluations += orphans.count
        return result
    }

    func history(roots: [URL], topic: TopicReference? = nil) throws -> [Entry] {
        try Task.checkCancellation()
        var entries: [Entry] = []
        for folder in Self.runs(in: roots).reversed() {
            try Task.checkCancellation()
            if let entry = try Self.entry(folder, topic: topic) { entries.append(entry) }
        }
        return entries
    }

    /// Match metadata before opening a potentially large event log. Stable topic
    /// identity survives renaming; old recordings without an ID retain name matching.
    nonisolated static func entry(_ folder: URL, topic: TopicReference? = nil) throws -> Entry? {
        try Task.checkCancellation()
        guard let meta = TopicExport.meta(folder), let seconds = meta["audio_seconds"] as? Double,
              seconds.isFinite, seconds > 3, seconds < Double(Int.max) else { return nil }
        if let topic {
            if let raw = meta["topic_id"] as? String {
                guard UUID(uuidString: raw) == topic.id else { return nil }
            } else if meta["topic"] as? String != topic.name { return nil }
        }
        var sentences = Set<Int>(), cards = 0
        var first = "", fallback = ""
        func event(_ line: Data) {
            // Most records are diagnostics/prompts. Decode only possible summaries;
            // the parsed kind (not text appearing inside another event) is authoritative.
            guard line.range(of: sentenceMarker) != nil || line.range(of: cardMarker) != nil,
                  let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if value["kind"] as? String == "card_started" { cards += 1 }
            guard value["kind"] as? String == "sentence", let id = (value["id"] as? NSNumber)?.intValue else { return }
            sentences.insert(id)
            let text = value["text"] as? String ?? ""
            if fallback.isEmpty { fallback = text }
            if first.isEmpty, !text.isEmpty, id > 1 || text.count > 20 { first = text }
        }
        if let handle = try? FileHandle(forReadingFrom: folder.appending(path: "events.jsonl")) {
            defer { try? handle.close() }
            // Retain at most the current line plus a chunk, rather than the whole
            // conversation (which also contains prompts and provider output).
            var pending = Data()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                pending.append(chunk)
                var start = pending.startIndex
                while let end = pending[start...].firstIndex(of: 10) {
                    event(Data(pending[start..<end]))
                    start = pending.index(after: end)
                }
                pending.removeSubrange(..<start)
            }
            if !pending.isEmpty { event(pending) }
        }
        return Entry(folder: folder, topic: meta["topic"] as? String ?? "", seconds: seconds,
                     language: meta["language"] as? String ?? "", sentences: sentences.count,
                     cards: cards, first: first.isEmpty ? fallback : first)
    }
}
