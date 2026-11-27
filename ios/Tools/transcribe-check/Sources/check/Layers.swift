import Foundation

/// The second listening stage: given the sound of one finished sentence, a
/// slower model writes it again and says who spoke. Runs on the device.
protocol SegmentRefiner: Sendable {
    /// Loads the models; may download them on first use. Reports progress as text.
    func prepare(report: @escaping @Sendable (String) -> Void) async
    func refine(_ request: RefineRequest) async -> Refinement
}

struct RefineRequest: Sendable {
    var segmentID: UInt64
    /// 16 kHz mono sound ending with the sentence, up to a minute, so the
    /// speaker model hears enough of each voice.
    var window: [Float]
    /// When `window` begins, in seconds of sound fed so far.
    var windowStart: Double
    /// Where the sentence lies inside `window`, in samples.
    var sentence: Range<Int>
    /// What the first stage heard.
    var heard: String
}

struct Refinement: Sendable {
    /// The second stage's text, nil when it had none or it was implausible.
    var text: String?
    /// Voices by sentence, for this sentence and for earlier ones whose voice
    /// changed now that more was heard. Numbers are stable within a session.
    var voices: [UInt64: UInt32] = [:]
    /// The speaker model heard this sentence. Its voice (or that it has none yet) is a first
    /// guess until the next sentence's run, which hears more after it, confirms or corrects it.
    var voicesHeard = false
    var textSeconds: Double = 0
    var voiceSeconds: Double = 0
    var note: String?
    /// The dialect layer, when its model is on the device: what it heard, how
    /// long it took, and whether its text was taken.
    var dialect: String?
    var dialectSeconds: Double = 0
    var dialectTaken = false
    /// Its words replaced single non-words of the others.
    var dialectVoted = false
}

/// What happened to one sentence on its way through the layers. For the debug
/// overlay; nothing here leaves the device.
struct LayerTrace: Identifiable, Equatable {
    struct Step: Equatable {
        var name: String
        var detail: String
        var seconds: Double?
        var changed = false
    }

    let id: UInt64
    var text: String
    var audioSeconds: Double
    var steps: [Step]
}

enum Correction {
    /// A second-stage text replaces the first only when it is recognisably the
    /// same sentence. Whisper can invent text on short or quiet sound; such
    /// output shares few words with what was heard and is dropped.
    static func isPlausible(_ candidate: String, for heard: String) -> Bool {
        let a = words(heard)
        let b = words(candidate)
        guard !a.isEmpty, !b.isEmpty else { return false }
        guard Double(b.count) <= Double(a.count) * 1.6 + 2 else { return false }
        return Double(commonSubsequence(a, b)) / Double(max(a.count, b.count)) >= 0.5
    }

    /// Two hearings of one sentence, word by word. The second stage is the
    /// better listener on the whole, but it also invents words that do not
    /// exist. Where the two differ, the second stage's wording is taken unless
    /// it contains something that is not a word while the first stage's is one.
    /// `isWord` is the dictionary; words of the glossary always count.
    static func arbitrate(heard: String, candidate: String, glossary: String = "", isWord: (String) -> Bool) -> String {
        let a = heard.split(separator: " ").map(String.init)
        let b = candidate.split(separator: " ").map(String.init)
        func plain(_ token: String) -> String { token.lowercased().filter { $0.isLetter || $0.isNumber } }
        func bare(_ token: String) -> String { token.trimmingCharacters(in: .punctuationCharacters) }
        let known = Set(words(glossary))
        func ok(_ token: String) -> Bool {
            let word = bare(token)
            return word.isEmpty || word.contains(where: \.isNumber) || known.contains(plain(token)) || isWord(word)
        }
        let x = a.map(plain), y = b.map(plain)
        // Longest common subsequence, kept as a table so the differing runs can be read back.
        var table = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [String] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                result.append(b[j])  // same word: the second stage's spelling and punctuation
                i += 1
                j += 1
                continue
            }
            // A run where the two differ, up to the next word they share.
            var mine: [String] = [], theirs: [String] = []
            while i < x.count || j < y.count {
                if i < x.count, j < y.count, x[i] == y[j] { break }
                if j < y.count, i == x.count || table[i][j + 1] >= table[i + 1][j] {
                    theirs.append(b[j])
                    j += 1
                } else {
                    mine.append(a[i])
                    i += 1
                }
            }
            let keepFirst = !mine.isEmpty && mine.allSatisfy(ok) && !theirs.allSatisfy(ok)
            guard keepFirst else {
                result += theirs
                continue
            }
            // The first stage's words, with the punctuation the second stage ended the run with.
            var kept = mine
            if let end = theirs.last?.last, end.isPunctuation, let last = kept.last, last.last?.isPunctuation != true {
                kept[kept.count - 1] = last + String(end)
            }
            result += kept
        }
        return result.joined(separator: " ")
    }

    /// A third hearing by a model trained on dialect, which writes Standard
    /// German. On Standard German it says what the others say and nothing
    /// changes. Its text is taken when it differs clearly from the others and
    /// there is a sign that they struggled: they disagree with each other, or
    /// they wrote clearly more things that are not words.
    /// The part of the dialect model's text that belongs to this sentence. It hears the same
    /// stretch of sound as the others, and where the first stage's sentence boundaries are only
    /// estimated, that stretch holds the end of the sentence before or the start of the next:
    /// "Das ist wirklich falsch. Ich bin immer noch im Textflow drin." for a sentence that is only
    /// the second one (Swiss German call, 17 November 2026). Its sentences that share no word
    /// with what the first stage heard are cut off at either end; when none shares a word, or
    /// there is only one, the text stays as it is.
    static func trimDialect(_ dialect: String, to heard: String) -> String {
        var sentences: [String] = []
        var current = ""
        for character in dialect {
            current.append(character)
            if ".?!".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }
        guard sentences.count > 1 else { return dialect }
        let known = Set(words(heard).filter { $0.count >= 4 })
        let shares = sentences.map { sentence in words(sentence).contains { $0.count >= 4 && known.contains($0) } }
        guard let first = shares.firstIndex(of: true), let last = shares.lastIndex(of: true) else { return dialect }
        return sentences[first...last].joined().trimmingCharacters(in: .whitespaces)
    }

    static func prefersDialect(
        _ dialect: String, over settled: String, first: String, second: String?, isWord: (String) -> Bool
    ) -> Bool {
        let heard = words(dialect), base = words(settled)
        guard !heard.isEmpty, !base.isEmpty else { return false }
        // Much longer or much shorter than what the others heard: invented or cut off.
        guard Double(heard.count) <= Double(base.count) * 1.8 + 2, Double(heard.count) >= Double(base.count) * 0.4 else { return false }
        guard similarity(dialect, settled) < 0.6 else { return false }
        func realWords(_ list: [String]) -> Double {
            Double(list.count { $0.contains(where: \.isNumber) || isWord($0) }) / Double(list.count)
        }
        let othersDisagree = second.map { similarity(first, $0) < 0.5 } ?? true
        return othersDisagree || realWords(heard) >= realWords(base) + 0.2
    }

    /// Three hearings of the same sentence, settled by a vote. `strongest` is
    /// the largest model's text and the base. Where the second hearing words a
    /// stretch differently, the first hearing decides: if it sides with the
    /// second, two agree and the strongest is overruled; if all three differ,
    /// the strongest stands. Words of the glossary win when the second hearing
    /// wrote them, because only that model was primed with them.
    static func vote(first: String, second: String, strongest: String, glossary: String = "") -> String {
        func plain(_ token: String) -> String { token.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = strongest.split(separator: " ").map(String.init)
        let b = second.split(separator: " ").map(String.init)
        let x = a.map(plain), y = b.map(plain)
        let witness = first.split(separator: " ").map { plain(String($0)) }.filter { !$0.isEmpty }
        let known = Set(words(glossary))
        func heardByFirst(_ run: [String]) -> Bool {
            let wanted = run.map(plain).filter { !$0.isEmpty }
            guard !wanted.isEmpty, wanted.count <= witness.count else { return false }
            return (0...(witness.count - wanted.count)).contains { Array(witness[$0..<$0 + wanted.count]) == wanted }
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [String] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                result.append(a[i])
                i += 1
                j += 1
                continue
            }
            var mine: [String] = [], theirs: [String] = []
            while i < x.count || j < y.count {
                if i < x.count, j < y.count, x[i] == y[j] { break }
                if j < y.count, i == x.count || table[i][j + 1] >= table[i + 1][j] {
                    theirs.append(b[j])
                    j += 1
                } else {
                    mine.append(a[i])
                    i += 1
                }
            }
            let inGlossary = !theirs.isEmpty && theirs.allSatisfy { known.contains(plain($0)) }
            let secondWins: Bool
            if inGlossary {
                secondWins = true
            } else if theirs.isEmpty {
                // Only the strongest has these words: they stay unless nobody else heard them.
                secondWins = !heardByFirst(mine)
            } else {
                secondWins = heardByFirst(theirs) && !heardByFirst(mine)
            }
            result += secondWins ? theirs : mine
        }
        return result.joined(separator: " ")
    }

    /// Share of words two texts have in common, in order: 1 is the same wording.
    static func similarity(_ first: String, _ second: String) -> Double {
        let a = words(first)
        let b = words(second)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(commonSubsequence(a, b)) / Double(max(a.count, b.count))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal + 1 : max(above, row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }
}
