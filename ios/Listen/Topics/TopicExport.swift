import CryptoKit
import Foundation

/// A topic exported with everything that belongs to it, out of Listen, in a format that stays
/// readable without Listen: one folder per topic,
///
///     <yyyy-MM-dd_HH-mm-ss>_<name>.listen-topic/
///       manifest.json   format, version, when, why, each run's facts, every file with size and SHA-256
///       topic.json      the topic as it was saved (briefing, links, repositories)
///       topic/          its own folder: notes of earlier conversations, its files (material)
///       runs/<run>/     audio.wav, events.jsonl (each request with its prompt, reply and usage,
///                       every card version), run.json
///
/// Moving, not copying: the topic leaves Listen's lists and its runs leave the history; nothing
/// is deleted. This is not the archive inside Listen (`Topic.archived`, a topic out of the list
/// but still there). Exports lie beside the runs (`<runs folder>/exports/`), outside the
/// repository, with `index.json` mapping each exported run's name to its new place, so that
/// analyses written against a run's name still find it. The format is versioned; a later
/// version adds, it does not reinterpret.
enum TopicExport {
    static let format = "listen-topic-export"
    static let version = 1

    @MainActor static var root: URL { RunRecorder.folder.appending(path: "exports", directoryHint: .isDirectory) }

    struct Entry: Codable, Equatable {
        var path: String
        var bytes: Int
        var sha256: String
    }

    struct RunFacts: Codable, Equatable {
        var name: String
        var started: String?
        var seconds: Double?
        var audioSeconds: Double?
        var language: String?
        var events: Int
        var requests: Int
        var cards: Int
    }

    struct Manifest: Codable, Equatable {
        var format: String
        var version: Int
        var archived: String
        var app: String
        var topic: String
        var topicID: String?
        var reason: String
        var runs: [RunFacts]
        var contents: [Entry]
    }

    /// Names of topics made by evaluations before topics were marked as such.
    static let evaluationNames = [
        "Scripted", "Token usage check", "Event details check", "YouTube evaluation", "Context routing", "Card speed",
        "Critical path", "UI probe", "UI quick", "Snippet check",
    ]

    static func isEvaluation(_ name: String) -> Bool {
        evaluationNames.contains { name == $0 || name.hasPrefix($0 + " ") }
    }

    static func meta(_ run: URL) -> [String: Any]? {
        (try? Data(contentsOf: run.appending(path: "run.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The recorded runs of a topic, by its name, from every folder Listen records into.
    static func runs(of name: String, among runs: [URL]) -> [URL] {
        runs.filter { meta($0)?["topic"] as? String == name }
    }

    /// Exports one topic: moves its folder and runs into a new export and writes the manifest.
    /// `topic` is nil for runs whose topic no longer exists (only its name is known).
    @discardableResult
    static func pack(name: String, topic: Topic?, sandbox: URL?, runs: [URL], reason: String, into root: URL) throws -> URL {
        let manager = FileManager.default
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
        var folder = root.appending(path: "\(stamp.string(from: .now))_\(slug.isEmpty ? "topic" : slug).listen-topic")
        var number = 2
        while manager.fileExists(atPath: folder.path) {
            folder = root.appending(path: "\(stamp.string(from: .now))_\(slug)-\(number).listen-topic")
            number += 1
        }
        try manager.createDirectory(at: folder.appending(path: "runs"), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let topic {
            try encoder.encode(topic).write(to: folder.appending(path: "topic.json"))
        } else {
            try encoder.encode(["name": name]).write(to: folder.appending(path: "topic.json"))
        }
        if let sandbox, manager.fileExists(atPath: sandbox.path) {
            try manager.moveItem(at: sandbox, to: folder.appending(path: "topic"))
        }
        var facts: [RunFacts] = []
        var moved: [String: String] = [:]
        for run in runs {
            let target = folder.appending(path: "runs/\(run.lastPathComponent)")
            try manager.moveItem(at: run, to: target)
            facts.append(Self.facts(of: target))
            moved[run.lastPathComponent] = folder.lastPathComponent + "/runs/" + run.lastPathComponent
        }
        let manifest = Manifest(
            format: format, version: version, archived: ISO8601DateFormatter().string(from: .now),
            app: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            topic: name, topicID: topic?.id.uuidString, reason: reason, runs: facts, contents: try contents(of: folder))
        try encoder.encode(manifest).write(to: folder.appending(path: "manifest.json"))
        try updateIndex(root: root, moved: moved)
        return folder
    }

    /// Every file of an export except its manifest, with its size and SHA-256.
    static func contents(of folder: URL) throws -> [Entry] {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var entries: [Entry] = []
        while let file = walker?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = String(file.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
            guard path != "manifest.json" else { continue }
            entries.append(Entry(path: path, bytes: (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, sha256: try digest(of: file)))
        }
        return entries.sorted { $0.path < $1.path }
    }

    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func facts(of run: URL) -> RunFacts {
        let meta = meta(run) ?? [:]
        var events = 0, requests = 0, cards = 0
        if let text = try? String(contentsOf: run.appending(path: "events.jsonl"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                events += 1
                if line.contains("\"kind\":\"model_request\"") { requests += 1 }
                if line.contains("\"kind\":\"card_started\"") { cards += 1 }
            }
        }
        return RunFacts(name: run.lastPathComponent, started: meta["started"] as? String, seconds: meta["seconds"] as? Double,
                        audioSeconds: meta["audio_seconds"] as? Double, language: meta["language"] as? String,
                        events: events, requests: requests, cards: cards)
    }

    /// Where each exported run now lies, relative to the exports folder.
    static func updateIndex(root: URL, moved: [String: String]) throws {
        let file = root.appending(path: "index.json")
        var index = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        index["runs", default: [:]].merge(moved) { _, new in new }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(index).write(to: file, options: .atomic)
    }
}
