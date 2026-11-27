import Foundation

/// Natural replies can reach speech before EOF. Structured replies wait for full validation:
/// an empty calls prefix cannot rule out duplicate keys or malformed content later.
struct AssistantReplyText {
    private enum Format { case undecided, text, json }
    private var format = Format.undecided
    private var raw = ""
    private var pending = ""
    private var lead = ""
    private var released = false
    /// Plain text is spoken as it arrives. False where the reply must be JSON.
    private let speaksText: Bool
    /// A reply that may come from a web search: its links and citation marks are left out.
    private let dropsLinks: Bool

    init(speaksText: Bool = true, dropsLinks: Bool = false) {
        self.speaksText = speaksText
        self.dropsLinks = dropsLinks
    }

    private func tidy(_ text: String) -> String { dropsLinks ? Self.withoutLinks(text) : Self.clean(text) }

    /// What a voice must not read out and the reply does not need as text: a search answer's
    /// links, bare addresses and citation marks. The sources are shown beside the reply.
    static func withoutLinks(_ text: String) -> String {
        // "([site](https://…))" goes; of "[words](https://…)" the words stay unless they are
        // an address themselves; then bare addresses and marks like "[1]".
        var text = text.replacing(/\s*\(\s*\[[^\]]*\]\([^)\s]*\)\s*\)/, with: "")
        text = text.replacing(/\[([^\]]*)\]\(https?:[^)\s]*\)/) { match in
            match.1.contains(".") && !match.1.contains(" ") ? "" : String(match.1)
        }
        text = text.replacing(/https?:\/\/[^\s)\]]+/, with: "")
        text = text.replacing(/\[\d+\]|【[^】]*】|\(\s*\)/, with: "")
        return clean(text).replacing(/\s+([.,;:!?])/) { String($0.1) }
    }

    mutating func append(_ text: String) throws -> [String] {
        raw += text
        guard raw.utf8.count <= 32_768 else { throw MCPFailure.tooLarge }
        if format == .undecided, let first = raw.first(where: { !$0.isWhitespace }) {
            format = "{[`".contains(first) ? .json : .text
        }
        guard format != .json else { return [] }
        guard raw.count <= 2000 else { throw MCPFailure.tooLarge }
        guard speaksText else { return [] }
        pending += text
        var result: [String] = []
        while let end = sentenceEnd(in: pending) {
            let sentence = tidy(String(pending[..<end]))
            let lower = sentence.lowercased()
            // A standalone greeting/apology resets Qwen for just a second of sound and
            // can run dry while the useful sentence is prepared. Keep the wording, join
            // it to that sentence. Genuine short answers are still released immediately.
            if !released, sentence.count < 60,
               lower.hasPrefix("hey listen") || lower.hasPrefix("entschuldige") {
                lead += (lead.isEmpty ? "" : " ") + sentence
            } else {
                result.append((lead.isEmpty ? "" : lead + " ") + sentence)
                lead = ""
                released = true
            }
            pending = String(pending[end...])
        }
        return result.filter { !$0.isEmpty }
    }

    mutating func finish() throws -> (text: String, remaining: [String]) {
        if format == .json {
            let decision = try AssistantDecision.read(raw, tools: [:])
            let speech = tidy(decision.speech)
            guard !speech.isEmpty else { throw MCPFailure.invalidResponse }
            return (speech, [speech])
        }
        let text = tidy(raw)
        guard !text.isEmpty else { throw MCPFailure.invalidResponse }
        let tail = tidy((lead.isEmpty ? "" : lead + " ") + pending)
        lead = ""
        pending = ""
        return (text, tail.isEmpty ? [] : [tail])
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func sentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard ".!?…".contains(character), let end = SpokenReply.terminalEnd(in: text, after: next, allowEnd: false) else {
                index = next
                continue
            }
            if character == "." {
                let prefix = text[..<index]
                // A digit period may still be a date, ordinal or a number split across chunks.
                if prefix.last?.isNumber == true { index = next; continue }
                if prefix.last?.isLetter == true,
                   let word = prefix.split(whereSeparator: { !$0.isLetter }).last,
                   SpokenReply.isAbbreviation(String(word)) { index = next; continue }
            }
            return end
        }
        return nil
    }
}
