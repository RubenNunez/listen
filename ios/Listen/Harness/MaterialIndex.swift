import Foundation

/// The topic's own files as the harness uses them (C1): short passages with their file, an
/// overview of what the files are about, and the names of things in them. Written by
/// `TopicMaterial` when files are added; read when a conversation starts. Pure text work,
/// nothing here reads files or leaves the device.
struct MaterialIndex: Codable, Sendable, Equatable {
    /// User-configured reference cards, never generated from later conversation outcomes.
    struct PreparedHint: Codable, Sendable, Equatable {
        var id: String
        var title: String
        var bullets: [String]
        var sources: [String]
        var keywords: String
        var language: String

        var isValid: Bool {
            id != "none" && id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]{0,47}/) != nil
                && !title.isEmpty && title.count <= 80 && !title.contains("\n")
                && !title.uppercased().hasPrefix("UPDATE")
                && (1...3).contains(bullets.count)
                && bullets.allSatisfy { !$0.isEmpty && $0.count <= 180 && !$0.contains("\n") && !$0.contains("```") }
                && (1...4).contains(sources.count)
                && sources.allSatisfy { !$0.isEmpty && $0.count <= 300 && !$0.contains("\n") }
                && keywords.count <= 400 && ["de", "en"].contains(language)
        }
        var urls: [String] {
            sources.filter { value in
                guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return false }
                return ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            }
        }
        var card: String {
            var text = title + "\n" + bullets.map { "- " + $0 }.joined(separator: "\n")
            if !urls.isEmpty {
                text += "\n\n" + (language == "de" ? "Quellen" : "Sources") + ": "
                    + urls.enumerated().map { "[\($0.offset + 1)](\($0.element))" }.joined(separator: " · ")
            }
            return text
        }
    }
    struct Passage: Codable, Sendable, Equatable {
        /// The file, as a path inside the topic's material folder.
        var source: String
        var text: String
    }

    var passages: [Passage] = []
    var overview = ""
    var terms: [String] = []
    /// Optional for backwards-compatible decoding of previously indexed topics.
    var preparedHints: [PreparedHint]?

    func matchingHints(to text: String, language: String) -> [PreparedHint] {
        var seen = Set<String>()
        let hints = (preparedHints ?? []).prefix(32).filter { $0.isValid && $0.language == language && seen.insert($0.id).inserted }
        let candidates = hints.map { Passage(source: $0.id, text: $0.title + " " + $0.keywords + " " + $0.bullets.joined(separator: " ")) }
        let selected = Self.relevant(candidates, to: text, most: 4)
        return selected.compactMap { candidate in hints.first { $0.id == candidate.source } }
    }

    private static let passageLength = 700

    /// Paragraph-sized pieces of about 700 characters, cut at line or sentence ends.
    static func passages(of text: String, source: String) -> [Passage] {
        let clean = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var result: [Passage] = []
        var current = ""
        for line in clean.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > passageLength, !current.isEmpty {
                result.append(Passage(source: source, text: current.trimmingCharacters(in: .whitespacesAndNewlines)))
                current = ""
            }
            // A single line longer than a passage is cut at sentence ends.
            var rest = Substring(line)
            while rest.count > passageLength {
                let cut = rest.prefix(passageLength).lastIndex(where: { ".!?".contains($0) }).map { rest.index(after: $0) }
                    ?? rest.index(rest.startIndex, offsetBy: passageLength)
                result.append(Passage(source: source, text: String(rest[..<cut]).trimmingCharacters(in: .whitespaces)))
                rest = rest[cut...]
            }
            current += rest + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(Passage(source: source, text: current.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return result
    }

    /// What the files are about, in brief: each file's name and first meaningful line.
    static func overview(_ passages: [Passage], characters: Int = 1500) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for passage in passages where seen.insert(passage.source).inserted {
            let first = passage.text.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*- \t")) }
                .first { $0.count >= 3 } ?? ""
            lines.append("- \(passage.source): \(first.prefix(120))")
        }
        var text = ""
        for line in lines where text.count + line.count < characters { text += line + "\n" }
        return text.trimmingCharacters(in: .newlines)
    }

    /// Names of things in the material, most frequent first: written with a capital, a digit
    /// or a hyphen inside (SQL-Injection, PostgreSQL, OAuth2), not at the start of a sentence only.
    static func terms(in passages: [Passage], most: Int = 40) -> [String] {
        var counts: [String: Int] = [:]
        let pattern = /[\p{L}\d][\p{L}\d\-\.]*[\p{L}\d]/
        for passage in passages {
            for match in passage.text.matches(of: pattern) {
                let word = String(match.output)
                guard word.count >= 3, word.count <= 40 else { continue }
                let inner = word.dropFirst()
                let named = inner.contains(where: \.isUppercase) || word.contains("-") && word.first?.isUppercase == true
                    || (word.contains(where: \.isNumber) && word.contains(where: \.isLetter))
                if named { counts[word, default: 0] += 1 }
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(most).map(\.key)
    }

    /// The passages that share the most specific words with what was just said. Words of five
    /// letters or more count; a word that is in nearly every passage counts little.
    static func relevant(_ passages: [Passage], to text: String, most: Int = 3) -> [Passage] {
        // Mixed-case short names carry meaning too. Learn their spelling from the
        // supplied material so lowercased ASR can retrieve them without opting in
        // every short function word. There is no domain-specific vocabulary here.
        func tokens(_ value: String) -> [Substring] {
            value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        }
        func isShortName(_ word: Substring) -> Bool {
            (2...4).contains(word.count) && word.filter(\.isUppercase).count >= 2
        }
        let suppliedNames = Set(passages.flatMap { tokens($0.text).filter(isShortName).map { $0.lowercased() } })
        let acronyms = Set(tokens(text).filter { isShortName($0) || suppliedNames.contains($0.lowercased()) }.map { $0.lowercased() })
        func words(_ text: String) -> Set<String> {
            Set(Correction.words(text).filter { $0.count >= 5 || acronyms.contains($0) })
        }
        let asked = words(text)
        guard !asked.isEmpty, !passages.isEmpty else { return [] }
        let sets = passages.map { words($0.text) }
        var frequency: [String: Int] = [:]
        for set in sets { for word in set where asked.contains(word) { frequency[word, default: 0] += 1 } }
        let scored = zip(passages, sets).map { passage, set -> (Passage, Double) in
            let score = set.intersection(asked).reduce(0.0) { $0 + 1 / Double(frequency[$1] ?? 1) }
            return (passage, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(most).map(\.0)
    }
}
