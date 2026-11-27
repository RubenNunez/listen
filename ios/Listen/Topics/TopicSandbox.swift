import Foundation

/// A topic's own folder on this device. After each conversation the app writes
/// one Markdown note into it: who was there and what Listen showed. The next
/// conversation in the same topic gets the latest notes as context, which is
/// how a conversation is continued.
///
/// The notes hold names, cards and, when a model is attached, a short summary
/// it wrote from the transcript. The transcript itself and audio are not kept here.
struct TopicSandbox {
    struct Conversation {
        var topic: String
        var began: Date
        var seconds: Int
        var people: [String]
        var cards: [String]
        /// The same cards as blocks with the versions each went through, oldest first.
        var blocks: [[String]] = []
        var sentences: Int
        /// Written by a model after the conversation, when one is attached.
        var summary: String?
        /// The recording's stable ID, also for an asynchronous rewrite of this same note.
        var runID: String? = nil
    }

    let folder: URL

    init(topic: Topic.ID, root: URL = TopicSandbox.root) {
        folder = root.appending(path: topic.uuidString, directoryHint: .isDirectory)
    }

    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/Topics", directoryHint: .isDirectory)
    }

    private var conversations: URL { folder.appending(path: "conversations", directoryHint: .isDirectory) }

    /// The notes of this topic, oldest first.
    var notes: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: conversations, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Writes the note for one conversation, replacing an earlier version of
    /// it. With neither a card nor a summary there is nothing to continue from,
    /// and no file is written.
    @discardableResult
    func write(_ conversation: Conversation) -> URL? {
        guard !conversation.cards.isEmpty || conversation.summary != nil else { return nil }
        let name = DateFormatter()
        name.locale = Locale(identifier: "en_US_POSIX")
        name.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = conversation.runID ?? name.string(from: conversation.began)
        guard id.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}/) != nil else { return nil }
        let file = conversations.appending(path: id + ".md")
        do {
            try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
            try Self.markdown(conversation).write(to: file, atomically: true, encoding: .utf8)
            // Beside the note: the blocks with their earlier versions, so an opened topic shows its stacks again.
            if !conversation.blocks.isEmpty, let data = try? JSONEncoder().encode(conversation.blocks) {
                try? data.write(to: file.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            }
            return file
        } catch {
            return nil
        }
    }

    static func markdown(_ conversation: Conversation) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HH:mm"
        let length = conversation.seconds < 60
            ? "\(conversation.seconds) s" : "\(conversation.seconds / 60) min"
        var text = "# \(conversation.topic) · \(day.string(from: conversation.began))\n\n"
        text += "\(length), \(conversation.sentences) sentences heard.\n\n"
        if !conversation.people.isEmpty {
            text += "## At the table\n\n" + conversation.people.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let summary = conversation.summary {
            text += "## Summary\n\n\(summary)\n\n"
        }
        if !conversation.cards.isEmpty {
            text += "## Listen showed\n\n"
            text += conversation.cards.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n---\n\n")
            text += "\n"
        }
        return text
    }

    /// A conversation as its note tells it, for looking at a topic without listening.
    struct Past: Identifiable {
        var id: String
        /// "2026-11-15 11:32", as written in the note.
        var when: String
        /// "2 min, 18 sentences heard."
        var length: String
        var people: [String]
        var summary: String
        var cards: [String]
        /// Each card with its earlier versions, oldest first; one version each when none were kept.
        var blocks: [[String]]
    }

    /// Reads a note back. Nil when the file is not one of ours.
    static func read(_ file: URL) -> Past? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("# ") else { return nil }
        // Sections start with "## " at the beginning of a line; a card never does (its title is bold).
        var sections: [String: String] = [:]
        var name = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## "), ["At the table", "Summary", "Listen showed"].contains(String(line.dropFirst(3))) {
                name = String(line.dropFirst(3))
            } else {
                sections[name, default: ""] += line + "\n"
            }
        }
        let head = (sections[""] ?? "").split(separator: "\n").map(String.init)
        let title = head.first ?? ""
        let cards = (sections["Listen showed"] ?? "")
            .components(separatedBy: "\n\n---\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Past(
            id: file.lastPathComponent,
            when: title.split(separator: " · ").last.map(String.init) ?? String(title.dropFirst(2)),
            length: head.dropFirst().first { !$0.isEmpty } ?? "",
            people: (sections["At the table"] ?? "").split(separator: "\n").map { String($0.dropFirst(2)) }.filter { !$0.isEmpty },
            summary: (sections["Summary"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            cards: cards,
            blocks: (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("json")))
                .flatMap { try? JSONDecoder().decode([[String]].self, from: $0) } ?? cards.map { [$0] })
    }

    /// What earlier conversations in this topic showed, newest notes preferred,
    /// cut to a size that fits a prompt. Empty when there are none.
    func context(notes limit: Int = 3, characters: Int = 2500) -> String {
        var parts: [String] = []
        var left = characters
        for file in notes.suffix(limit).reversed() {
            guard left > 200, let text = try? String(contentsOf: file, encoding: .utf8) else { break }
            let piece = String(text.prefix(left))
            parts.insert(piece, at: 0)
            left -= piece.count
        }
        return parts.joined(separator: "\n")
    }

    /// Forgets what earlier conversations left; files the user put there stay.
    func clearNotes() {
        try? FileManager.default.removeItem(at: conversations)
    }

    func delete() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Clear conversation memory without removing topic material or instructions.
    static func clearAllNotes(root: URL = TopicSandbox.root) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: root.path) else { return }
        let folders = try files.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let notes = folder.appending(path: "conversations", directoryHint: .isDirectory)
            if files.fileExists(atPath: notes.path) { try files.removeItem(at: notes) }
        }
    }

    static func noteCount(root: URL = TopicSandbox.root) -> Int {
        let topics = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return topics.reduce(0) { count, folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return count }
            return count + TopicSandbox(topic: id, root: root).notes.count
        }
    }
}
