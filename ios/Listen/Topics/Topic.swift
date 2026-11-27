import Foundation
import Observation

/// What a conversation is about: the briefing and the repositories whose
/// documents should ground the answers.
struct Topic: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var language = Language.de
    /// Free text the user wrote: goal, role, facts about themselves.
    var notes = ""
    /// GitHub repositories as "owner/name". Listed here only; nothing is
    /// fetched until a GitHub connection exists.
    var repositories: [String] = []
    /// Web pages that belong to the topic. They are read when a conversation
    /// starts and given to the models; a card may link back to them.
    var links: [String] = []
    /// Put away: not in the list of topics, but kept with everything it holds.
    var archived = false
    /// Made by an evaluation run (a scripted or file-fed conversation), not by the user: exported in one go.
    var evaluation = false
    /// The system a conversation in this topic runs with (`ListenSystem.id`); nil for Interview.
    var system: String?

    init(name: String) {
        self.name = name
    }

    /// Written by hand so that topics saved before a field existed still load.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        language = try values.decodeIfPresent(Language.self, forKey: .language) ?? .de
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        repositories = try values.decodeIfPresent([String].self, forKey: .repositories) ?? []
        links = try values.decodeIfPresent([String].self, forKey: .links) ?? []
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        evaluation = try values.decodeIfPresent(Bool.self, forKey: .evaluation) ?? false
        system = try values.decodeIfPresent(String.self, forKey: .system)
    }

    static func isValidLink(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host() else { return false }
        return (scheme == "https" || scheme == "http") && host.contains(".") && !value.contains(" ")
    }

    /// Words the second listening stage should expect: the topic's name and
    /// the start of its notes. Stays on the device.
    var glossary: String {
        [name, String(notes.prefix(400))].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func isValidRepository(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil
    }
}

/// Topics live in one JSON file in the app's Application Support directory.
/// They are configuration the user typed, never transcripts or audio.
@MainActor
@Observable
final class TopicStore {
    private(set) var topics: [Topic]
    var selectedID: Topic.ID

    @ObservationIgnored private let file: URL

    init(file: URL = TopicStore.defaultFile) {
        self.file = file
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let topics = stored?.topics.isEmpty == false ? stored!.topics : [Topic(name: "General")]
        self.topics = topics
        self.selectedID = topics.contains { $0.id == stored?.selectedID } ? stored!.selectedID : topics[0].id
    }

    var selected: Topic { topics.first { $0.id == selectedID } ?? topics[0] }

    func select(_ topic: Topic) {
        selectedID = topic.id
        save()
    }

    /// Inserts a new topic or replaces the one with the same ID.
    func upsert(_ topic: Topic) {
        if let index = topics.firstIndex(where: { $0.id == topic.id }) {
            topics[index] = topic
        } else {
            topics.append(topic)
            selectedID = topic.id
        }
        save()
    }

    /// Editing UI only reports success after the complete store is on disk.
    /// A damaged or concurrently changed store must not be silently replaced.
    func saveTopic(_ source: Topic) throws {
        var topic = source
        topic.name = topic.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.name.isEmpty else { throw SystemPackageError(message: "Give the topic a name before saving.") }
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Saved.self, from: data) else {
                throw SystemPackageError(message: "Stored topics could not be read. They have not been replaced; your edits are still here.")
            }
            guard stored.topics == topics, stored.selectedID == selectedID else {
                throw SystemPackageError(message: "Topics changed elsewhere. Your edits are still here; reopen Listen before saving again.")
            }
        }
        var next = topics
        let selected: Topic.ID
        if let index = next.firstIndex(where: { $0.id == topic.id }) {
            next[index] = topic; selected = selectedID
        } else {
            next.append(topic); selected = topic.id
        }
        let data = try JSONEncoder().encode(Saved(topics: next, selectedID: selected))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        topics = next; selectedID = selected
    }

    /// Setup import creates a fresh topic and reports write failures before publishing it.
    /// It never overwrites another topic or repairs a corrupt store by discarding it.
    func installSetup(_ source: Topic, system: String) throws -> Topic {
        let previous = try? Data(contentsOf: file)
        if FileManager.default.fileExists(atPath: file.path) {
            guard let previous, let saved = try? JSONDecoder().decode(Saved.self, from: previous),
                  saved.topics == topics, saved.selectedID == selectedID else {
                throw SystemPackageError(message: "Topics changed or could not be read. Reopen setup import before trying again.")
            }
        }
        var topic = source
        topic.id = UUID(); topic.archived = false; topic.evaluation = false; topic.system = system
        var index = 2
        while topics.contains(where: { $0.name == topic.name }) { topic.name = source.name + " \(index)"; index += 1 }
        let next = topics + [topic]
        let data = try JSONEncoder().encode(Saved(topics: next, selectedID: topic.id))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous { try previous.write(to: file.appendingPathExtension("backup"), options: [.atomic, .completeFileProtection]) }
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        topics = next; selectedID = topic.id
        return topic
    }

    /// Puts a topic away or brings it back. The last topic in the list stays: a session always has one.
    func setArchived(_ archived: Bool, _ topic: Topic) {
        guard let index = topics.firstIndex(where: { $0.id == topic.id }) else { return }
        if archived, topics.filter({ !$0.archived }).count <= 1 { return }
        topics[index].archived = archived
        if archived, selectedID == topic.id, let next = topics.first(where: { !$0.archived }) { selectedID = next.id }
        save()
    }

    /// Exports a topic with its folder and every recorded run (`TopicExport`) and takes it out of
    /// Listen. Nothing is deleted. Unlike `setArchived`, the topic does not stay in Listen.
    /// The last topic stays: a session always has one.
    @discardableResult
    func export(_ topic: Topic, reason: String = "exported by the user") async -> URL? {
        guard topics.count > 1, topics.contains(where: { $0.id == topic.id }) else { return nil }
        let sandbox = TopicSandbox(topic: topic.id).folder
        let runs = TopicExport.runs(of: topic.name, among: RunRecorder.runs())
        let root = TopicExport.root
        let packed = await Task.detached {
            try? TopicExport.pack(name: topic.name, topic: topic, sandbox: sandbox, runs: runs, reason: reason, into: root)
        }.value
        guard let packed else { return nil }
        topics.removeAll { $0.id == topic.id }
        if selectedID == topic.id { selectedID = topics[0].id }
        save()
        return packed
    }

    /// Topics made by evaluations, and runs of evaluation topics that no longer exist in the list.
    var evaluationLeftovers: (topics: [Topic], orphans: [String: [URL]]) {
        let made = topics.filter { $0.evaluation || TopicExport.isEvaluation($0.name) }
        let names = Set(topics.map(\.name))
        var orphans: [String: [URL]] = [:]
        for run in RunRecorder.runs() {
            guard let name = TopicExport.meta(run)?["topic"] as? String, !names.contains(name), TopicExport.isEvaluation(name) else { continue }
            orphans[name, default: []].append(run)
        }
        return (made, orphans)
    }

    /// Exports every evaluation topic, and the runs of evaluation topics that were lost from the
    /// list. Returns how many exports were written.
    @discardableResult
    func exportEvaluations() async -> Int {
        let (made, orphans) = evaluationLeftovers
        var written = 0
        for topic in made where await export(topic, reason: "evaluation") != nil { written += 1 }
        let root = TopicExport.root
        for (name, runs) in orphans.sorted(by: { $0.key < $1.key }) {
            let packed = await Task.detached {
                try? TopicExport.pack(name: name, topic: nil, sandbox: nil, runs: runs, reason: "evaluation; its topic was no longer listed", into: root)
            }.value
            if packed != nil { written += 1 }
        }
        return written
    }

    /// The last topic cannot be deleted: a session always has one.
    func delete(_ topic: Topic) {
        guard topics.count > 1 else { return }
        topics.removeAll { $0.id == topic.id }
        TopicSandbox(topic: topic.id).delete()
        if selectedID == topic.id { selectedID = topics[0].id }
        save()
    }

    private struct Saved: Codable {
        var topics: [Topic]
        var selectedID: Topic.ID
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(topics: topics, selectedID: selectedID)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    nonisolated static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "topics.json")
    }
}
