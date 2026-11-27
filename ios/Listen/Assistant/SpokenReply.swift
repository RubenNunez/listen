import Foundation

/// One piece of a reply that the voice generates in a single run.
struct SpokenSegment: Equatable, Sendable {
    var text: String
    /// Audio tokens after which the generation is cut off (12.5 tokens are one second).
    var limit: Int
    /// Played while it is generated. Otherwise it is generated in full, and again if it
    /// ran into its limit, before any of it is played.
    var streamed: Bool
}

/// Prepares a reply's text for the local voice. Measured on 120 synthetic replies: every
/// model variant garbled digits, and the 4-bit one turned one-word replies into sighs and
/// let longer replies run past their text. So numbers are written out, the reply is cut
/// into sentences, and each one gets a token limit from its length.
enum SpokenReply {
    /// Sentences shorter than this are spoken together with a neighbour.
    static let shortest = 30
    /// Sentences longer than this are divided at a comma.
    static let longest = 140
    /// A first segment expected to be this short is generated in full before it plays:
    /// that costs about half a second and lets a failed attempt be thrown away.
    static let checkedFirst = 22

    static func segments(_ text: String, language: Language) -> [SpokenSegment] {
        var parts = sentences(spelledOut(text, language: language)).flatMap(divided)
        var index = 0
        while index < parts.count - 1 {
            if parts[index].count < shortest {
                parts[index] += " " + parts.remove(at: index + 1)
            } else {
                index += 1
            }
        }
        if parts.count > 1, let last = parts.last, last.count < shortest {
            parts.removeLast()
            parts[parts.count - 1] += " " + last
        }
        return parts.enumerated().map { index, part in
            SpokenSegment(
                text: part, limit: limit(for: part, language: language),
                streamed: index == 0 && expectedTokens(part, language: language) > Double(checkedFirst))
        }
    }

    /// Audio tokens a text of this length took in the clean replies of the measurement.
    static func expectedTokens(_ text: String, language: Language) -> Double {
        language == .de ? 0.83 * Double(text.count) + 12.8 : 1.03 * Double(text.count) + 4.8
    }

    /// No clean reply came near this; the ones that ran on passed it.
    static func limit(for text: String, language: Language) -> Int {
        Int((expectedTokens(text, language: language) * 1.4 + 6).rounded(.up))
    }

    // MARK: Sentences

    private static let abbreviations: Set<String> = [
        "mr", "ms", "mrs", "dr", "prof", "st", "nr", "no", "vs", "etc", "ca", "bzw", "z", "b", "d", "h", "e", "g", "i",
    ]

    static func isAbbreviation(_ word: String) -> Bool { abbreviations.contains(word.lowercased()) }

    /// Quotes and closing brackets belong to the sentence that just ended. A stream
    /// still waits for the following whitespace; complete text may end right there.
    static func terminalEnd(in text: String, after punctuation: String.Index, allowEnd: Bool) -> String.Index? {
        var end = punctuation
        while end < text.endIndex, "\"'“”’»›)]}".contains(text[end]) { end = text.index(after: end) }
        if end == text.endIndex { return allowEnd ? end : nil }
        return text[end].isWhitespace ? end : nil
    }

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex, index = start
        while index < text.endIndex {
            let character = text[index], next = text.index(after: index)
            guard ".!?…".contains(character), let end = terminalEnd(in: text, after: next, allowEnd: true) else {
                index = next; continue
            }
            let prefix = text[start..<index]
            if character == ".", prefix.last?.isLetter == true,
               let word = prefix.split(whereSeparator: { !$0.isLetter }).last, isAbbreviation(String(word)) {
                index = next; continue
            }
            result.append(String(text[start..<end]))
            start = end; index = end
        }
        result.append(String(text[start...]))
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.contains(where: \.isLetter) }
    }

    /// A long sentence in two or more parts, cut at the comma nearest its middle.
    private static func divided(_ sentence: String) -> [String] {
        guard sentence.count > longest else { return [sentence] }
        let characters = Array(sentence)
        let cuts = characters.indices.filter {
            ",;:".contains(characters[$0]) && $0 + 1 < characters.count && characters[$0 + 1] == " "
                && $0 >= shortest && characters.count - $0 > shortest
        }
        guard let cut = cuts.min(by: { abs($0 - characters.count / 2) < abs($1 - characters.count / 2) }) else { return [sentence] }
        let head = String(characters[...cut]), tail = String(characters[(cut + 2)...])
        return divided(head) + divided(tail)
    }

    // MARK: Numbers

    /// Digits written as words, in the reply's language, in this order: dates, phone numbers
    /// and long digit groups, money, ranges, times, decimals, per cent, days of the month,
    /// years, and whole numbers. Version strings are left as they are.
    static func spelledOut(_ text: String, language: Language) -> String {
        let german = language == .de
        var text = text
        var kept: [String] = []
        func word(_ digits: String) -> String { number(digits, language) }

        // Dates written in digits become a day, a month name and a spoken year.
        rewrite(&text, #"(?<![\d-])(\d{4})-(\d{2})-(\d{2})(?![\d-])"#) { groups, _, _ in
            date(day: groups[3], month: groups[2], year: groups[1], language)
        }
        if german {
            rewrite(&text, #"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4})(?![\d.])"#) { groups, _, _ in
                date(day: groups[1], month: groups[2], year: groups[3], language)
            }
        }
        // Version strings stay untouched: set aside here, put back at the end.
        rewrite(&text, #"\b[vV]?\d+(?:\.\d+){2,}\b|\b[vV]\d+(?:\.\d+)?\b"#) { groups, _, _ in
            kept.append(groups[0] ?? "")
            return String(UnicodeScalar(0xE000 + kept.count - 1)!)
        }
        // Phone numbers, group by group, and digit runs that are no quantity.
        rewrite(&text, #"(?<![\w+])(\+?)(\d{1,4}(?: \d{2,4}){2,5})(?!\d)"#) { groups, _, _ in
            guard let run = groups[2], groups[1] == "+" || run.hasPrefix("0") else { return nil }
            return (groups[1] == "+" ? "plus " : "")
                + run.split(separator: " ").map { digitByDigit(String($0), language) }.joined(separator: ", ")
        }
        rewrite(&text, #"(?<![\d.,])(\d{10,}|0\d{2,})(?!\d|[.,]\d)"#) { groups, _, _ in digitByDigit(groups[1] ?? "", language) }
        // Thousands marks.
        rewrite(&text, #"(?<![\d.,'’])\d{1,3}(?:['’]\d{3})+(?!\d)"#) { groups, _, _ in
            groups[0]?.filter(\.isNumber)
        }
        if !german {
            rewrite(&text, #"(?<![\d.,])\d{1,3}(?:,\d{3})+(?![\d,])"#) { groups, _, _ in groups[0]?.filter(\.isNumber) }
        }
        // Money, with the sign before or after the amount.
        let unit = #"(CHF|SFr\.|Fr\.|EUR|USD|€|\$)"#
        rewrite(&text, #"(?<!\w)"# + unit + #"\s?(\d+)(?:[.,](\d{2}|[-–]))?(?!\d)"#) { groups, _, _ in
            money(groups[2] ?? "", groups[3], unit: groups[1] ?? "", language)
        }
        rewrite(&text, #"(?<![\d.,])(\d+)(?:[.,](\d{2}|[-–]))?\s?"# + unit + #"(?!\w)"#) { groups, _, after in
            let ends = groups[3]?.hasSuffix(".") == true && after.allSatisfy(\.isWhitespace)
            return money(groups[1] ?? "", groups[2], unit: groups[3] ?? "", language) + (ends ? "." : "")
        }
        // Ranges: "3–5", "10-12 Uhr", "9:00–17:00". Not a date, a phone number or a minus.
        rewrite(&text, #"(?<![\d.,:\-–/])(\d+(?::\d{2})?)(?:\s?–\s?|-)(\d+(?::\d{2})?)(?!\d|[-–/]\d|[.,]\d)"#) { groups, _, _ in
            (groups[1] ?? "") + (german ? " bis " : " to ") + (groups[2] ?? "")
        }
        rewrite(&text, #"(?<![\w.,:)])[-−](?=\d)"#) { _, _, _ in "minus " }
        // Times: "14 Uhr 32", "9:15".
        if german {
            rewrite(&text, #"\b(\d{1,2}) Uhr(?: (\d{1,2}))?\b"#) { groups, _, _ in
                hour(groups[1] ?? "") + " Uhr" + (groups[2].map { " " + word($0) } ?? "")
            }
            rewrite(&text, #"\b(\d{1,2}):(\d{2})\b"#) { groups, _, _ in
                hour(groups[1] ?? "") + " Uhr" + (Int(groups[2] ?? "") == 0 ? "" : " " + word(groups[2] ?? ""))
            }
        } else {
            rewrite(&text, #"\b(\d{1,2}):(\d{2})\b"#) { groups, _, _ in
                let minutes = Int(groups[2] ?? "") ?? 0
                return word(groups[1] ?? "") + (minutes == 0 ? "" : minutes < 10 ? " oh " + word("\(minutes)") : " " + word("\(minutes)"))
            }
        }
        // Decimals, read digit by digit after the mark.
        rewrite(&text, german ? #"\b(\d+),(\d+)\b"# : #"\b(\d+)\.(\d+)\b"#) { groups, _, _ in
            word(groups[1] ?? "") + (german ? " Komma " : " point ") + digitByDigit(groups[2] ?? "", language)
        }
        rewrite(&text, #"\s?%"#) { _, _, _ in german ? " Prozent" : " percent" }
        // Days of the month: "am 3. Dezember", "der 3. Dezember", "3. Dezember", "December 3rd".
        if german {
            let months = germanMonths.joined(separator: "|")
            rewrite(&text, #"\b(?:((?i:am|vom|zum|dem|den|des|der)) )?(\d{1,2})\. ("# + months + #")\b"#) { groups, _, _ in
                let article = groups[1] ?? ""
                let ending = article.isEmpty ? "r" : article.lowercased() == "der" ? "" : "n"
                return (article.isEmpty ? "" : article + " ") + germanOrdinal(Int(groups[2] ?? "") ?? 0) + ending + " " + (groups[3] ?? "")
            }
        } else {
            rewrite(&text, #"\b(\d{1,2})(?:st|nd|rd|th)\b"#) { groups, _, _ in englishOrdinal(Int(groups[1] ?? "") ?? 0) }
        }
        // Years, where a word before the number or the end of the clause says it is one.
        rewrite(&text, #"(?<![\d.,:'’\-–/])(\d{4})(?!\d|[.,:]\d|\s?%)"#) { groups, before, after in
            guard let value = Int(groups[1] ?? ""), (1100...2099).contains(value) else { return nil }
            let previous = before.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? ""
            let cues = german ? germanYearCues : englishYearCues
            let closes = value < 2000 && (after.first.map { ".!?,;)".contains($0) } ?? true)
            return cues.contains(previous) || closes ? year(value, language) : nil
        }
        // German "1" before a common noun: "eine Stunde", "ein Tag".
        if german {
            rewrite(&text, #"(?<![\d.,:])\b1 ([A-ZÄÖÜ][a-zäöüß]+)\b"#) { groups, _, _ in
                let noun = groups[1] ?? ""
                return feminine.contains(noun) ? "eine " + noun : neuterOrMasculine.contains(noun) ? "ein " + noun : nil
            }
        }
        rewrite(&text, #"\d+"#) { groups, _, _ in word(groups[0] ?? "") }
        return String(String.UnicodeScalarView(text.unicodeScalars.flatMap { scalar -> [UnicodeScalar] in
            let index = Int(scalar.value) - 0xE000
            return kept.indices.contains(index) ? Array(kept[index].unicodeScalars) : [scalar]
        }))
    }

    /// Replaces every match of `pattern`. `body` gets the groups and the text before and
    /// after the match; nil leaves the match as it is.
    private static func rewrite(
        _ text: inout String, _ pattern: String, _ body: (_ groups: [String?], _ before: String, _ after: String) -> String?
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let source = text as NSString
        var result = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                match.range(at: index).location == NSNotFound ? nil : source.substring(with: match.range(at: index))
            }
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            result += body(groups, source.substring(to: match.range.location), source.substring(from: NSMaxRange(match.range)))
                ?? source.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        text = result + source.substring(from: position)
    }

    private static let germanMonths = [
        "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember",
    ]
    private static let englishMonths = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]
    private static let germanYearCues = Set(
        ["jahr", "jahre", "jahres", "seit", "ab", "bis", "von", "vor", "nach", "anfang", "ende", "mitte", "in", "im", "um",
         "frühling", "sommer", "herbst", "winter"] + germanMonths.map { $0.lowercased() })
    private static let englishYearCues = Set(
        ["in", "since", "from", "until", "till", "during", "before", "after", "year", "early", "late", "mid", "between",
         "spring", "summer", "autumn", "fall", "winter"] + englishMonths.map { $0.lowercased() })
    private static let feminine: Set<String> = [
        "Stunde", "Minute", "Sekunde", "Woche", "Million", "Milliarde", "Nachricht", "Datei", "Seite", "Person", "Aufgabe",
        "Erinnerung", "Frage", "Antwort", "Notiz", "Zeile", "Mail", "Nummer", "Tasse", "Flasche",
    ]
    private static let neuterOrMasculine: Set<String> = [
        "Tag", "Monat", "Jahr", "Termin", "Franken", "Euro", "Dollar", "Rappen", "Cent", "Grad", "Prozent", "Meter",
        "Kilometer", "Kilo", "Kilogramm", "Liter", "Gramm", "Mal", "Stück", "Punkt", "Eintrag", "Ergebnis", "Fehler", "Test",
        "Schritt",
    ]

    private static func cardinal(_ number: Int, _ language: Language) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language == .de ? "de_DE" : "en_US")
        formatter.numberStyle = .spellOut
        // The formatter marks syllable breaks with soft hyphens.
        return (formatter.string(from: NSNumber(value: number)) ?? String(number)).replacingOccurrences(of: "\u{00AD}", with: "")
    }

    /// A whole number in words; one too long to be a quantity is read digit by digit.
    private static func number(_ digits: String, _ language: Language) -> String {
        guard digits.count <= 9, let value = Int(digits) else { return digitByDigit(digits, language) }
        return cardinal(value, language)
    }

    private static func digitByDigit(_ digits: String, _ language: Language) -> String {
        digits.compactMap(\.wholeNumberValue).map { cardinal($0, language) }.joined(separator: " ")
    }

    /// "ein Uhr", not "eins Uhr".
    private static func hour(_ digits: String) -> String {
        Int(digits) == 1 ? "ein" : number(digits, .de)
    }

    /// 1998 as "neunzehnhundertachtundneunzig" and "nineteen ninety-eight", 2026 as
    /// "zweitausendsechsundzwanzig" and "twenty twenty-six".
    private static func year(_ value: Int, _ language: Language) -> String {
        let high = value / 100, low = value % 100
        if language == .de {
            return value < 2000 ? cardinal(high, .de) + "hundert" + (low == 0 ? "" : cardinal(low, .de)) : cardinal(value, .de)
        }
        if (2000...2009).contains(value) { return cardinal(value, .en) }
        return cardinal(high, .en) + (low == 0 ? " hundred" : low < 10 ? " oh " + cardinal(low, .en) : " " + cardinal(low, .en))
    }

    /// The day stays in digits for the day-of-the-month rule in German, which needs the
    /// word before it.
    private static func date(day: String?, month: String?, year: String?, _ language: Language) -> String? {
        guard let day = Int(day ?? ""), let month = Int(month ?? ""), let value = Int(year ?? ""),
            (1...31).contains(day), (1...12).contains(month)
        else { return nil }
        let spoken = (1100...2099).contains(value) ? self.year(value, language) : cardinal(value, language)
        return language == .de
            ? "\(day). \(germanMonths[month - 1]) \(spoken)"
            : "\(englishMonths[month - 1]) \(englishOrdinal(day)), \(spoken)"
    }

    /// "zwölf Franken fünfzig", "four dollars ninety-nine", "fünfzig Rappen".
    private static func money(_ whole: String, _ fraction: String?, unit: String, _ language: Language) -> String {
        let german = language == .de
        let names: (one: String, many: String, part: String, parts: String)
        switch unit {
        case "EUR", "€": names = german ? ("Euro", "Euro", "Cent", "Cent") : ("euro", "euros", "cent", "cents")
        case "USD", "$": names = german ? ("Dollar", "Dollar", "Cent", "Cent") : ("dollar", "dollars", "cent", "cents")
        default: names = german ? ("Franken", "Franken", "Rappen", "Rappen") : ("franc", "francs", "centime", "centimes")
        }
        let part = Int(fraction ?? "") ?? 0
        func counted(_ digits: String, _ one: String, _ many: String) -> String {
            Int(digits) == 1 ? (german ? "ein " : "one ") + one : number(digits, language) + " " + many
        }
        if (Int(whole) ?? 1) == 0, part > 0 { return counted(String(part), names.part, names.parts) }
        return counted(whole, names.one, names.many) + (part > 0 ? " " + cardinal(part, language) : "")
    }

    private static func germanOrdinal(_ number: Int) -> String {
        let irregular = [1: "erste", 3: "dritte", 7: "siebte", 8: "achte"]
        if let word = irregular[number] { return word }
        return cardinal(number, .de) + (number < 20 ? "te" : "ste")
    }

    private static func englishOrdinal(_ number: Int) -> String {
        let units = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
            "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
        switch number {
        case 1..<20: return units[number]
        case 20: return "twentieth"
        case 21..<30: return "twenty-" + units[number - 20]
        case 30: return "thirtieth"
        case 31: return "thirty-first"
        default: return cardinal(number, .en)
        }
    }
}

/// Generates a reply's segments in order and hands on only audio that may be played.
///
/// The first segment plays while it is generated, unless it is short enough to check
/// first. Every later segment is generated in full while the earlier audio plays; an
/// attempt that ran into its limit is thrown away and made again. Nothing handed on is
/// ever taken back. A later segment is checked only when its generation fits into the
/// audio still waiting to be played; otherwise it is streamed as well, unchecked: a pause
/// in the middle of a reply is worse.
enum SpokenVoice {
    enum Piece: Sendable {
        case audio([Float])
        /// The generation is over. `reachedLimit`: it was cut off, it did not end by itself.
        case ended(reachedLimit: Bool)
    }

    typealias Generate = @Sendable (_ text: String, _ limit: Int) -> AsyncThrowingStream<Piece, any Error>

    struct Outcome: Equatable, Sendable {
        var segments = 0
        /// Attempts thrown away.
        var retries = 0
        /// Segments handed on although they ran into their limit.
        var cut = 0
        /// Audio tokens' worth of samples handed on.
        var samples = 0
    }

    /// Attempts per checked segment.
    static let attempts = 3
    /// A segment is generated in full first only if that is expected to take no more than
    /// this share of the audio still unplayed.
    static let share = 0.85

    static func run(
        _ segments: [SpokenSegment], sampleRate: Double, generate: Generate,
        now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }, yield: @Sendable ([Float]) -> Void
    ) async throws -> Outcome {
        var outcome = Outcome()
        let started = now()
        var generated = 0
        var firstHandedOn: Double?
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            outcome.segments += 1
            // How long this segment should take to generate, at the pace so far, against
            // the audio that is handed on and not yet played.
            let pace = generated == 0 ? 0 : (now() - started) / (Double(generated) / sampleRate)
            let needed = Double(segment.limit - 6) / 1.4 / 12.5 * pace
            let unplayed = Double(outcome.samples) / sampleRate - (firstHandedOn.map { now() - $0 } ?? 0)
            if index == 0 ? segment.streamed : needed > share * unplayed {
                for try await piece in generate(segment.text, segment.limit) {
                    switch piece {
                    case .audio(let samples):
                        generated += samples.count
                        outcome.samples += samples.count
                        if firstHandedOn == nil { firstHandedOn = now() }
                        yield(samples)
                    case .ended(let reachedLimit):
                        if reachedLimit { outcome.cut += 1 }
                    }
                }
                continue
            }
            for attempt in 1...attempts {
                var audio: [[Float]] = []
                var reachedLimit = false
                for try await piece in generate(segment.text, segment.limit) {
                    switch piece {
                    case .audio(let samples):
                        generated += samples.count
                        audio.append(samples)
                    case .ended(let limit): reachedLimit = limit
                    }
                }
                try Task.checkCancellation()
                if reachedLimit, attempt < attempts {
                    outcome.retries += 1
                    continue
                }
                if reachedLimit { outcome.cut += 1 }
                if firstHandedOn == nil, !audio.isEmpty { firstHandedOn = now() }
                for samples in audio {
                    outcome.samples += samples.count
                    yield(samples)
                }
                break
            }
        }
        return outcome
    }
}
