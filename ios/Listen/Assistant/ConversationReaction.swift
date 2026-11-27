import Foundation

/// Local conversational acknowledgements, never answers or claims that a tool ran.
/// Substantive answers still come from the topic's existing model/roles.
enum ConversationReaction {
    static let delay = Duration.milliseconds(200)
    static let spacing = 8.0

    enum Kind: String, Codable, CaseIterable, Sendable {
        case neutral, repair, explanation, comparison, followup, research
        var title: String {
            switch self {
            case .neutral: "General"
            case .repair: "Correction"
            case .explanation: "Explanation"
            case .comparison: "Comparison"
            case .followup: "Follow-up"
            case .research: "Research"
            }
        }
    }

    static func kind(for input: String, hasPrevious: Bool = false, researching: Bool = false) -> Kind {
        if researching { return .research }
        let words = input.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let phrase = words.joined(separator: " ")
        if ["moment", "nein", "sorry", "wait", "actually"].contains(words.first ?? "")
            || phrase.hasPrefix("ich meinte") || phrase.hasPrefix("ich meine") || phrase.hasPrefix("no ") { return .repair }
        if !Set(words).isDisjoint(with: ["unterschied", "unterschiede", "vergleich", "vergleiche", "vergleichen", "versus", "vs", "compare", "difference", "differences"]) { return .comparison }
        if !Set(words).isDisjoint(with: ["erklär", "erkläre", "erklären", "warum", "wieso", "weshalb", "explain", "why"]) { return .explanation }
        if hasPrevious, ["und", "dazu", "dann", "außerdem", "and", "also", "then"].contains(words.first ?? "") { return .followup }
        return .neutral
    }

    static func phrases(_ kind: Kind, language: Language) -> [String] {
        switch (language, kind) {
        case (.de, .neutral): ["Einen Moment.", "Ich überlege kurz.", "Einen Augenblick."]
        case (.de, .repair): ["Okay, einen Moment.", "Ich denke noch einmal darüber nach.", "Okay, ich gehe darauf ein."]
        case (.de, .explanation): ["Ich ordne das kurz ein.", "Ich gehe es kurz durch.", "Lass mich kurz überlegen."]
        case (.de, .comparison): ["Ich gehe die Unterschiede durch.", "Ich stelle das kurz gegenüber.", "Ich vergleiche das kurz."]
        case (.de, .followup): ["Ich knüpfe daran an.", "Dazu überlege ich kurz.", "Ich gehe darauf noch ein."]
        case (.de, .research): ["Ich schaue das nach.", "Ich sehe in den Quellen nach.", "Ich suche die passende Quelle."]
        case (.en, .neutral): ["One moment.", "Let me think.", "Give me a moment."]
        case (.en, .repair): ["Okay, one moment.", "Let me consider that again.", "Okay, let me think."]
        case (.en, .explanation): ["Let me think it through.", "Let me go through that.", "I will consider that briefly."]
        case (.en, .comparison): ["Let me compare that.", "I will consider the differences.", "Let me go through the differences."]
        case (.en, .followup): ["Let me build on that.", "Let me consider that next.", "I will think about that too."]
        case (.en, .research): ["Let me look that up.", "I will check the sources.", "Let me find the source."]
        }
    }

    static func text(for input: String, language: Language) -> String {
        phrases(kind(for: input), language: language)[0]
    }

    static func isFixed(_ text: String) -> Bool {
        Language.allCases.contains { language in
            Kind.allCases.contains { validated(text, language: language, kind: $0) == text }
        }
    }

    /// Only short context-free acknowledgements can enter the reusable collection.
    /// Imported/model text stays data; names, facts, URLs, markup and action/result
    /// claims are excluded by a narrow vocabulary, not by a model's self-rating.
    static func validated(_ raw: String, language: Language, kind: Kind) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 64,
              text.allSatisfy({ $0.isLetter || $0 == " " || $0 == "," || $0 == "." }),
              text.dropLast().allSatisfy({ $0 != "." }) else { return nil }
        let normalized = text.hasSuffix(".") ? text : text + "."
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let count = text.split(whereSeparator: { !$0.isLetter }).count
        guard (2...7).contains(count) else { return nil }
        let allowed = language == .de
            ? "einen eine moment augenblick okay ich überlege kurz lass mich überlegen denke noch einmal darüber dazu das gehe es durch ordne ein knüpfe daran an darauf mit schaue nach sehe in den quellen suche die passende quelle unterschiede vergleiche stelle gegenüber sortiere sortieren betrachten einordnen nun warte mal sekunde kleinen kleiner gib mir bitte oh"
            : "one moment let me think give a okay consider that again it through go i will briefly compare the differences build on next about too look up check sources find source take second please into hang hold just brief quick over thinking at this"
        guard words.isSubset(of: Set(allowed.split(separator: " ").map(String.init))) else { return nil }
        let researchWords: Set<String> = ["quellen", "quelle", "suche", "sources", "source", "check", "find"]
        let researchPhrase = !words.isDisjoint(with: researchWords)
            || (words.contains("schaue") && words.contains("nach"))
            || (words.contains("look") && words.contains("up"))
        guard kind == .research || !researchPhrase else { return nil }
        return normalized
    }
}

/// A little extra room for an obviously unfinished German subordinate clause.
/// ASR punctuation is not reliable evidence that a sentence has finished. This is
/// a bounded conservative pause policy, not a general grammatical classifier.
enum ConversationTurnTiming {
    static func quiet(for text: String, language: Language) -> Double {
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let last = words.last else { return 0.8 }
        if VoiceAssistantSession.continuing.contains(last.lowercased()) { return 1.6 }
        if language == .de {
            let lower = words.map { $0.lowercased() }
            let phrase = lower.joined(separator: " ")
            // Corrections often end their question, take a breath, then add a constraint
            // ("Erkläre es kurz"). Punctuation alone used to launch a request in that
            // breath and immediately cancel it. Give explicit repairs a bounded extra
            // half-second without delaying ordinary completed questions.
            let explicitRepair = ["moment ", "nein ", "ich meinte ", "ich meine ", "mir geht es um "]
                .contains { phrase.hasPrefix($0) }
            let repairPrefaces = ["moment mir geht es um", "mir geht es um", "moment ich meinte",
                                  "nein ich meinte", "ich meinte", "nein mir geht es um"]
            let questionWords: Set<String> = ["was", "wie", "warum", "wieso", "weshalb", "wo", "wann", "wer",
                "welche", "welcher", "welches", "kann", "können", "darf", "soll", "sollte", "ist", "sind", "wird", "werden"]
            if repairPrefaces.contains(where: { phrase.hasPrefix($0) }), !lower.contains(where: questionWords.contains) {
                return 1.6
            }
            let subordinators: Set<String> = ["ob", "weil", "dass", "wenn", "obwohl", "damit", "bevor", "nachdem"]
            if let index = words.lastIndex(where: { subordinators.contains($0.lowercased()) }),
               index < words.count - 1, last.first?.isUppercase == true {
                return 1.6
            }
            if explicitRepair { return 1.1 }
        } else {
            let phrase = words.map { $0.lowercased() }.joined(separator: " ")
            if ["wait ", "actually ", "no i meant ", "i meant "].contains(where: { phrase.hasPrefix($0) }) {
                return 1.1
            }
        }
        return text.last.map { ".?!…".contains($0) } == true ? 0.6 : 0.8
    }
}

/// Only fixed, locally synthesized phrases. No user audio or dynamic answers.
/// Cache is bounded and indexed by the exact model, voice, language and phrase.
actor ConversationReactionAudio {
    static let shared = ConversationReactionAudio()
    private var audio: [String: [LocalVoiceChunk]] = [:]
    private var warming: Set<String> = []
    private var recent: [String] = []
    private static func key(_ text: String, model: String, voice: String, language: Language) -> String {
        model + ":" + voice + ":" + language.rawValue + ":" + text
    }
    func get(_ text: String, model: String, voice: String, language: Language) -> [LocalVoiceChunk]? {
        guard ConversationReaction.isFixed(text) else { return nil }
        let key = Self.key(text, model: model, voice: voice, language: language)
        guard let value = audio[key] else { return nil }
        recent.removeAll { $0 == key }
        recent.append(key)
        return value
    }
    func remove(model: String) {
        audio = audio.filter { !$0.key.hasPrefix(model + ":") }
        recent.removeAll { $0.hasPrefix(model + ":") }
    }
    func keep(_ chunks: [LocalVoiceChunk], text: String, model: String, voice: String, language: Language) {
        guard ConversationReaction.isFixed(text), !chunks.isEmpty,
              chunks.allSatisfy({ $0.sampleRate > 0 && $0.samples.allSatisfy(\.isFinite) }),
              chunks.reduce(0.0, { $0 + Double($1.samples.count) / $1.sampleRate }) <= 4 else { return }
        let key = Self.key(text, model: model, voice: voice, language: language)
        recent.removeAll { $0 == key }
        recent.append(key)
        audio[key] = chunks
        while recent.count > 8 { audio[recent.removeFirst()] = nil }
    }
    func prepare(model: String, voice: String, language: Language) async throws {
        let text = ConversationReaction.text(for: "", language: language)
        let key = Self.key(text, model: model, voice: voice, language: language)
        guard get(text, model: model, voice: voice, language: language) == nil, warming.insert(key).inserted else { return }
        defer { warming.remove(key) }
        var chunks: [LocalVoiceChunk] = []
        for try await chunk in try await TalkBack.synthesizer(for: model).speech(text, model: model, voice: voice, language: language) {
            try Task.checkCancellation()
            chunks.append(chunk)
            if chunks.reduce(0.0, { $0 + Double($1.samples.count) / $1.sampleRate }) > 4 { return }
        }
        try Task.checkCancellation()
        keep(chunks, text: text, model: model, voice: voice, language: language)
    }
}
