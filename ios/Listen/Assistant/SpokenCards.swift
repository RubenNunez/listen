import Foundation

/// Decides which words of the harness's cards are said aloud.
///
/// The cards are what Listen's roles publish (`AnswerEngine`: decisions, drafters, merger,
/// research). This type asks no model and writes no answer. The policy, exactly:
///
/// 1. Only a finished card is said (`cardFinished`). Text that is still being written, and a
///    card that is replaced, cancelled or failed before it finished, is never said.
/// 2. Said are the card's own sentences, in order. Its title is a heading for the eye and is
///    said only when the card has nothing else. Code, drawings (SVG), formulas, charts, the
///    sources line, addresses, tables and anything that looks like markup or JSON stay on
///    screen. An answer is at most eight sentences and 900 characters, cut between sentences.
/// 3. Three kinds of speech, per block (one subject) and turn (the sentence a card answers):
///    - an *answer*: the first thing said for a block, or for a newer sentence about it;
///    - an *addition*: more for a turn that was already answered aloud (a merged or researched
///      version). It opens with a short fixed transition and holds only sentences not heard
///      yet, at most four, and at most twice per turn;
///    - a *correction*: a later version that the decision service classified as a correction,
///      or one of whose sentences changes a number (digits or number words) or a yes into a
///      no in a sentence already heard. It opens with a fixed transition that says so, so a heard claim is never
///      contradicted silently.
///    The transitions are the only words that are not the card's own. They claim nothing about
///    checking or sources.
/// 4. A sentence counts as heard once the player has begun it (`heard`), sentence by
///    sentence, not when it was chosen or prepared: what a missing, cancelled or replaced
///    voice never reached can still be said later. A
///    sentence that says what a heard one said, in the same or nearly the same words, is not
///    said again. The comparison is by words, not by meaning: a paraphrase in other words
///    can pass, and a contradiction without a changed number or negation is not recognised
///    here (the decision service's classification covers it where the system has decisions).
/// 5. Not said at all: meeting ledger cards, verbatim quotes of what was said in the
///    conversation, cards that answer no sentence of this conversation (blocks carried over
///    from an earlier one), and a card whose sentence has three or more newer finished
///    sentences after it.
///
/// What is said is therefore a subset of what is on screen, plus at most one transition.
struct SpokenCards {
    enum Part: String, Sendable { case answer, addition, correction }

    struct Utterance: Equatable, Sendable {
        var card: UInt64
        var block: UInt64
        /// Which finished version of its block the card is, from 1.
        var version: Int
        /// The sentence the card answers: the turn this speech belongs to.
        var sentence: UInt64
        /// The card's own sentences that are said.
        var sentences: [String]
        var part: Part
        var kind: CardKind
        /// The fixed transition an addition or correction opens with.
        var lead: String?
        var text: String { ([lead].compactMap { $0 } + sentences).joined(separator: " ") }
    }

    enum Skip: String, Sendable {
        case meeting = "meeting ledger"
        case quoted = "quotes what was said in the conversation"
        case carried = "answers no sentence of this conversation"
        case stale = "newer speech since its sentence"
        case empty = "nothing to say aloud"
        case repeated = "nothing that was not heard"
        case limit = "addition limit of its turn"
    }

    enum Decision: Equatable, Sendable {
        case speak(Utterance)
        case skip(card: UInt64, block: UInt64, sentence: UInt64?, reason: Skip)
    }

    static let maximumSentences = 8
    static let maximumCharacters = 900
    static let maximumAdditionSentences = 4
    static let maximumAdditionCharacters = 500
    static let maximumAdditions = 2
    static let staleAfterSentences = 3

    private let language: Language
    private var open: [UInt64: (start: CardStart, text: String)] = [:]
    private var versions: [UInt64: Int] = [:]
    /// Per block: the sentences whose audio was scheduled.
    private var heardSentences: [UInt64: [String]] = [:]
    /// Per block: the turn last spoken for, and how many additions it has had.
    private var turns: [UInt64: (sentence: UInt64, additions: Int)] = [:]
    private var finals: [UInt64] = []
    /// Cards the decision service classified as a correction (`AnswerEngine.onCorrection`).
    private var corrections: Set<UInt64> = []
    /// Finished cards, kept so one that waited can be composed again against what was heard since.
    private var finished: [UInt64: (start: CardStart, text: String, version: Int)] = [:]

    init(language: Language = .de) { self.language = language }

    /// Follows the harness's own events. Returns a decision when a card finishes.
    mutating func receive(_ event: ServerEvent) -> Decision? {
        switch event {
        case .transcript(let segment) where segment.isFinal:
            if !finals.contains(segment.segmentID) {
                finals.append(segment.segmentID)
                if finals.count > 64 { finals.removeFirst(finals.count - 64) }
            }
        case .cardStarted(let start):
            open[start.generationID] = (start, "")
            if open.count > 32, let oldest = open.keys.min() { open[oldest] = nil }
        case .cardDelta(let id, let text):
            if let card = open[id], card.text.count < 20_000 { open[id]?.text += text }
        case .cardFinished(let id):
            guard let card = open.removeValue(forKey: id) else { return nil }
            let block = card.start.blockID ?? card.start.sourceCard ?? id
            versions[block, default: 0] += 1
            finished[id] = (card.start, card.text, versions[block] ?? 1)
            if finished.count > 32, let oldest = finished.keys.min() { finished[oldest] = nil }
            return compose(card.start, card.text, version: versions[block] ?? 1)
        case .cardSuperseded(let id, _), .cardCancelled(let id), .cardError(let id, _):
            open[id] = nil
        default: break
        }
        return nil
    }

    /// The decision service classified this card as a correction of what its block said.
    /// Reported by the engine before the card's own events.
    mutating func markCorrection(card: UInt64) {
        corrections.insert(card)
        if corrections.count > 64, let oldest = corrections.min() { corrections.remove(oldest) }
    }

    /// The whole utterance reached the player.
    mutating func heard(_ utterance: Utterance) {
        for (index, sentence) in utterance.sentences.enumerated() { heard(sentence, of: utterance, first: index == 0) }
    }

    /// The player has begun this sentence of the utterance: it counts as heard from now on.
    /// `first`: it is the first sentence of the utterance to be heard, which opens its turn
    /// (an answer) or uses one of the turn's additions.
    mutating func heard(_ sentence: String, of utterance: Utterance, first: Bool) {
        heardSentences[utterance.block, default: []].append(sentence)
        if let count = heardSentences[utterance.block]?.count, count > 80 { heardSentences[utterance.block]?.removeFirst(count - 80) }
        guard first else { return }
        if utterance.part == .addition, let turn = turns[utterance.block], turn.sentence >= utterance.sentence {
            turns[utterance.block] = (turn.sentence, turn.additions + 1)
        } else {
            turns[utterance.block] = (max(utterance.sentence, turns[utterance.block]?.sentence ?? 0), 0)
        }
        if heardSentences.count > 64, let oldest = heardSentences.keys.min() {
            heardSentences[oldest] = nil
            turns[oldest] = nil
            versions[oldest] = nil
        }
    }

    /// Whether the block's listener has heard this sentence, or one that says the same.
    func hasHeard(_ sentence: String, block: UInt64) -> Bool {
        (heardSentences[block] ?? []).contains { Self.says($0, sentence) }
    }

    /// An utterance that waited, composed again against what has been heard since: nil when
    /// nothing of it is left to say.
    func refreshed(_ utterance: Utterance) -> Utterance? {
        guard let card = finished[utterance.card] else { return utterance }
        if case .speak(let fresh) = compose(card.start, card.text, version: card.version) { return fresh }
        return nil
    }

    private func compose(_ start: CardStart, _ text: String, version: Int) -> Decision {
        let id = start.generationID, block = start.blockID ?? start.sourceCard ?? id
        func skip(_ reason: Skip) -> Decision { .skip(card: id, block: block, sentence: start.triggerSegment, reason: reason) }
        if start.meeting == true { return skip(.meeting) }
        // A verbatim quote from the conversation is not read back to the people who said it.
        if start.evidenceSegment != nil { return skip(.quoted) }
        guard let sentence = start.triggerSegment, sentence > 0 else { return skip(.carried) }
        if finals.filter({ $0 > sentence }).count >= Self.staleAfterSentences { return skip(.stale) }
        let before = heardSentences[block] ?? []
        // A version with a reviewed addition is asked about that addition; the rest of the
        // block is retained context.
        let all = Self.sentences(of: before.isEmpty ? text : start.focusText ?? text)
        guard !all.isEmpty else { return skip(.empty) }
        let fresh = all.filter { candidate in !before.contains { Self.says($0, candidate) } }
        guard !fresh.isEmpty else { return skip(before.isEmpty ? .empty : .repeated) }
        let corrects = !before.isEmpty && (corrections.contains(id)
            || fresh.contains { candidate in before.contains { Self.changed(candidate, $0) } })
        let part: Part
        if before.isEmpty { part = .answer }
        else if corrects { part = .correction }
        else if sentence > (turns[block]?.sentence ?? 0) { part = .answer }
        else {
            guard (turns[block]?.additions ?? 0) < Self.maximumAdditions else { return skip(.limit) }
            guard fresh.reduce(0, { $0 + $1.count }) >= 12 else { return skip(.repeated) }
            part = .addition
        }
        let kept = Self.cut(fresh, sentences: part == .answer ? Self.maximumSentences : Self.maximumAdditionSentences,
                            characters: part == .answer ? Self.maximumCharacters : Self.maximumAdditionCharacters)
        guard !kept.isEmpty else { return skip(.empty) }
        return .speak(Utterance(card: id, block: block, version: version, sentence: sentence, sentences: kept, part: part,
                                kind: start.kind, lead: Self.lead(part, language)))
    }

    /// Whole sentences up to the limits. The first sentence is said even when it alone is
    /// longer than the character limit, up to twice that.
    private static func cut(_ sentences: [String], sentences limit: Int, characters: Int) -> [String] {
        var kept: [String] = [], count = 0
        for sentence in sentences.prefix(limit) {
            if kept.isEmpty ? sentence.count > characters * 2 : count + sentence.count > characters { break }
            kept.append(sentence)
            count += sentence.count + 1
        }
        return kept
    }

    /// The only words said that are not a card's own. They name the kind of speech and
    /// nothing else: no source, no check, no certainty.
    static func lead(_ part: Part, _ language: Language) -> String? {
        switch (part, language) {
        case (.answer, _): nil
        case (.addition, .de): "Dazu noch:"
        case (.addition, _): "One more thing on that:"
        case (.correction, .de): "Eine Korrektur dazu:"
        case (.correction, _): "A correction to that:"
        }
    }

    /// Two sentences about the same thing that differ in a number or in a negation. Spoken
    /// answers write numbers as words, so a number word counts like a digit ("zehn Stunden"
    /// against "sechs Stunden"). Not a judgement of meaning: other contradictions pass.
    static func changed(_ a: String, _ b: String) -> Bool {
        if AnswerEngine.changedClaim(a, b) { return true }
        guard Correction.similarity(a, b) >= 0.6 else { return false }
        return numberWords(a) != numberWords(b)
    }

    private static let numbers: Set<String> = [
        "null", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf", "hundert", "tausend",
        "million", "millionen", "milliarde", "milliarden", "halb", "halbe", "doppelt", "dutzend",
        "zero", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "hundred", "thousand",
        "millions", "billion", "billions", "half", "double", "dozen",
    ]

    /// The number words of a sentence. "ein" and "one" are left out: they are articles and
    /// pronouns far more often than numbers.
    static func numberWords(_ text: String) -> Set<String> {
        Set(Correction.words(text).filter { word in
            numbers.contains(word) || (word.count > 5 && ["zehn", "zig", "ßig", "hundert", "tausend", "teen"].contains { word.hasSuffix($0) })
                || (word.count > 4 && word.hasSuffix("ty") && ["twen", "thir", "for", "fif", "six", "seven", "eigh", "nine"].contains { word.hasPrefix($0) })
        })
    }

    /// The new sentence says what the heard one said: the same words, or nearly all of them,
    /// without a changed number or negation.
    static func says(_ heard: String, _ candidate: String) -> Bool {
        if key(heard) == key(candidate) { return true }
        guard !changed(candidate, heard) else { return false }
        return Correction.similarity(heard, candidate) >= 0.75 || AnswerEngine.novelty(of: candidate, over: heard) < 0.2
    }

    // MARK: Words

    /// The sentences of a card that can be said: its text lines, without the title when
    /// there is anything else.
    static func sentences(of card: String) -> [String] {
        var fenced = false
        let lines = CardChart.split(card).text.split(separator: "\n").compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A second code block, or one that was never closed: nothing inside a fence is read.
            if line.hasPrefix("```") { fenced.toggle(); return nil }
            return fenced ? nil : sentence(line)
        }
        let body = lines.count > 1 ? Array(lines.dropFirst()) : lines
        return body.flatMap(split)
    }

    /// One card line as spoken text, or nil when it is not prose.
    static func sentence(_ line: String) -> String? {
        var text = line
        // Tables, markup, JSON and quoted wrappers are for the eye.
        guard let first = text.first, !"|<{[".contains(first) || text.hasPrefix("["), !text.contains("</"), !text.hasSuffix("}"),
              !text.hasSuffix("/>") else { return nil }
        // The sources of a card are shown, not read: a labelled line, or one that is only links.
        let plain = text.replacing(/^(#{1,6}|[-*•>]|\d+[.)])\s+/, with: "").replacing(/[*_`~]+/, with: "")
        if plain.hasPrefix("Quellen:") || plain.hasPrefix("Sources:") || plain.hasPrefix("Quelle:") || plain.hasPrefix("Source:") { return nil }
        if text.contains("]("), !text.replacing(/!?\[[^\]]*\]\([^)]*\)/, with: "").contains(where: \.isLetter) { return nil }
        text.replace(/!\[[^\]]*\]\([^)]*\)/, with: "")
        text.replace(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        text.replace(/https?:\/\/\S+/, with: "")
        text.replace(/^(#{1,6}|[-*•>]|\d+[.)])\s+/, with: "")
        text.replace(/[*_`~]+/, with: "")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A line that is still a bracketed structure, or has no word in it, says nothing.
        guard text.contains(where: \.isLetter), !(text.hasPrefix("[") && text.hasSuffix("]")),
              !(text.hasPrefix("{") || text.hasPrefix("<")) else { return nil }
        if let last = text.last, !".!?…:".contains(last) { text += "." }
        if text.hasSuffix(":") { text = String(text.dropLast()) + "." }
        return text
    }

    private static let abbreviations: Set<String> = [
        "bzw", "ca", "vgl", "etc", "inkl", "exkl", "evtl", "ggf", "nr", "dr", "vs", "z", "b", "d", "h", "u", "a", "e", "g", "i",
        "st", "mr", "mrs", "prof", "sog", "max", "min",
    ]

    /// A line as its sentences. A full stop after a number, a single letter or a common
    /// abbreviation ends none ("3. Schritt", "z. B.", "ca. 5").
    static func split(_ line: String) -> [String] {
        var result: [String] = [], current = ""
        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".?!…".contains(character), index + 1 < characters.count, characters[index + 1].isWhitespace else { continue }
            if character == "." {
                let word = current.dropLast().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).last.map { $0.lowercased() } ?? ""
                if word.isEmpty || word.allSatisfy(\.isNumber) || abbreviations.contains(word) { continue }
            }
            // The next sentence begins with a capital, a digit or a quotation mark.
            guard let next = characters[(index + 1)...].first(where: { !$0.isWhitespace }),
                  next.isUppercase || next.isNumber || "\"„«'(".contains(next) else { continue }
            result.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// Two sentences are the same sentence when their letters and digits are.
    static func key(_ line: String) -> String {
        String(line.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
