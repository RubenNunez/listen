import SwiftUI
import WebKit

/// The layout system of a card: one indent, one column, one scale of type and one
/// set of distances, used by every part so that text, code, drawings and charts
/// stand in the same rhythm.
enum CardMetrics {
    /// Text inside a card begins this far from the card's edge; headings, labels and
    /// loose lines around cards begin on the same line.
    static let inset: CGFloat = 18
    /// How wide a card is at most, on every screen. Around it each screen adds its own margin.
    static let column: CGFloat = 760
    /// Between the parts of a card (text, formula, drawing, code, chart, sources).
    static let partGap: CGFloat = 14
    /// Between one answer with its details and the next.
    static let groupGap: CGFloat = 10
    /// Between the lines of one answer.
    static let lineGap: CGFloat = 3
    /// Inside a panel (code, formula, drawing) and its corner.
    static let panelInset: CGFloat = 14
    static let panelCorner: CGFloat = 14
}

/// The type of a card. `large` is the feed, `regular` the end screen.
struct CardType: Equatable {
    var title: Font
    var answer: Font
    var detail: Font
    static let large = CardType(title: .subheadline.weight(.semibold), answer: .title3, detail: .body)
    static let regular = CardType(title: .footnote.weight(.semibold), answer: .body, detail: .subheadline)
}

/// The text of a card as its layout reads it: what the block is about, then answers,
/// each with the lines that belong to it.
struct CardText: Equatable {
    struct Group: Equatable, Identifiable {
        var id: Int
        /// The line that carries the answer in bold; nil for lines that stand before any answer.
        var answer: String?
        var details: [String]
    }

    var title: String
    var groups: [Group]

    init(_ text: String) {
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        title = lines.isEmpty ? "" : lines.removeFirst().replacingOccurrences(of: "**", with: "")
        var groups: [Group] = []
        for line in lines {
            if line.contains("**") {
                groups.append(Group(id: groups.count, answer: line, details: []))
            } else if groups.isEmpty {
                groups.append(Group(id: 0, answer: nil, details: [line]))
            } else {
                groups[groups.count - 1].details.append(line)
            }
        }
        self.groups = groups
    }
}

/// A short-lived mark on the parts that actually changed, shared by a block's newest page.
/// Keeping this above the pager also covers the first update that introduces a history page.
struct CardUpdateHighlights: Equatable {
    enum Part: Hashable {
        case title, line(String), formula, code, chart, sources
    }

    struct Pulse: Equatable {
        var sequence: UInt64
        var began: Date
        static let duration = 2.0
    }

    private struct Snapshot: Equatable {
        var title: String
        var lines: [String]
        var parts: CardChart.Parts

        init(_ card: SessionCore.Card) {
            parts = CardChart.split(card.text)
            let focused = card.text.split(separator: "\n").count >= 2
                ? card.start.focusText.map { CardChart.split($0).text } : nil
            let layout = CardText(focused ?? parts.text)
            title = layout.title
            lines = layout.groups.flatMap { group in
                (group.answer.map { [$0] } ?? []) + group.details
            }.map(CardUpdateHighlights.lineKey)
        }

        var hasBody: Bool {
            !lines.isEmpty || parts.formula != nil || parts.code != nil || parts.chart != nil
        }
    }

    private var previous: Snapshot?
    private var sequence: UInt64 = 0
    private(set) var pulses: [Part: Pulse] = [:]

    /// The first appearance is a baseline, not an update. An empty streaming replacement must
    /// not erase the old answer before its first useful line arrives.
    mutating func observe(_ card: SessionCore.Card, at now: Date = .now) {
        let next = Snapshot(card)
        guard next.hasBody else { return }
        defer { previous = next }
        guard let previous else { return }

        pulses = pulses.filter { now.timeIntervalSince($0.value.began) < Pulse.duration }
        var changed: Set<Part> = []
        if next.title != previous.title { changed.insert(.title) }
        let difference = next.lines.difference(from: previous.lines).inferringMoves()
        var removed = false
        for change in difference {
            switch change {
            case .insert(_, let line, associatedWith: nil): changed.insert(.line(line))
            case .remove(_, _, associatedWith: nil): removed = true
            default: break
            }
        }
        if next.parts.formula != previous.parts.formula { changed.insert(.formula) }
        if next.parts.code != previous.parts.code || next.parts.codeLanguage != previous.parts.codeLanguage { changed.insert(.code) }
        if next.parts.chart != previous.parts.chart { changed.insert(.chart) }
        if next.parts.sources != previous.parts.sources { changed.insert(.sources) }
        // A deletion has no new line to mark. The heading signals that the answer changed.
        if removed, changed.isEmpty { changed.insert(.title) }
        sequence &+= 1
        for part in changed { pulses[part] = Pulse(sequence: sequence, began: now) }
        let visibleLines = Set(next.lines)
        pulses = pulses.filter {
            if case .line(let line) = $0.key { return visibleLines.contains(line) }
            return true
        }
    }

    static func lineKey(_ markdown: String) -> String {
        String(CardBody.markdown(markdown).characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CardUpdateHighlightsKey: EnvironmentKey {
    static let defaultValue = CardUpdateHighlights()
}

extension EnvironmentValues {
    var cardUpdateHighlights: CardUpdateHighlights {
        get { self[CardUpdateHighlightsKey.self] }
        set { self[CardUpdateHighlightsKey.self] = newValue }
    }
}

/// Only the changed line gets a background; it never changes the card's size or text colour.
/// There is no timer or per-frame work after the fade has ended.
private struct CardUpdateFlash: ViewModifier {
    let part: CardUpdateHighlights.Part
    @Environment(\.cardUpdateHighlights) private var highlights
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var strength = 0.0

    func body(content: Content) -> some View {
        let pulse = highlights.pulses[part]
        content
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.yellow.opacity(0.30 * strength))
                    // A pager suppresses inherited feed animations. Declare the fade here so
                    // it still runs inside that transaction; the instant reset disables it.
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.65), value: strength)
                    .padding(.horizontal, -3).padding(.vertical, -1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task(id: pulse) {
                let remaining = pulse.map { CardUpdateHighlights.Pulse.duration - Date().timeIntervalSince($0.began) } ?? 0
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { strength = remaining > 0 ? 1 : 0 }
                guard remaining > 0 else { return }
                do {
                    // A brief hold makes the update visible even when several tokens arrive together.
                    try await Task.sleep(for: .seconds(reduceMotion ? remaining : min(0.35, remaining)))
                    try Task.checkCancellation()
                    if reduceMotion {
                        withTransaction(instant) { strength = 0 }
                    } else {
                        withAnimation(.easeOut(duration: max(0, remaining - 0.35))) { strength = 0 }
                    }
                } catch { /* A newer change or a page leaving view cancels this pulse. */ }
            }
    }
}

private extension View {
    func cardUpdateFlash(_ part: CardUpdateHighlights.Part) -> some View {
        modifier(CardUpdateFlash(part: part))
    }
}

/// What a card shows, in one order everywhere: what it is about, the answers, then
/// the formula, the drawing, the code, the chart, and the sources small at the end.
struct CardBody: View, Equatable {
    let text: String
    var type = CardType.large
    var dimmed = false
    /// The card is still being written: lines to come are shown as shimmering bars.
    var isWriting = false
    /// A checked version of this card is on its way: the text shimmers until it arrives.
    var isUpdating = false
    var focusText: String? = nil

    var body: some View {
        let parts = CardChart.split(text)
        let focused = text.split(separator: "\n").count >= 2 ? focusText.map { CardChart.split($0).text } : nil
        let layout = CardText(focused ?? parts.text)
        let earlier = focused.map { Self.earlierContext(whole: parts.text, focus: $0) } ?? []
        VStack(alignment: .leading, spacing: CardMetrics.partGap) {
            VStack(alignment: .leading, spacing: CardMetrics.groupGap) {
                if !layout.title.isEmpty {
                    Text(layout.title)
                        .font(type.title)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .cardUpdateFlash(.title)
                }
                ForEach(layout.groups) { group in
                    VStack(alignment: .leading, spacing: CardMetrics.lineGap) {
                        if let answer = group.answer {
                            Text(Self.markdown(answer)).font(type.answer).foregroundStyle(dimmed ? .secondary : .primary)
                                .cardUpdateFlash(.line(CardUpdateHighlights.lineKey(answer)))
                        }
                        ForEach(Array(group.details.enumerated()), id: \.offset) { _, line in
                            Text(Self.markdown(line)).font(type.detail)
                                .foregroundStyle(group.answer == nil && !dimmed ? .primary : .secondary)
                                .cardUpdateFlash(.line(CardUpdateHighlights.lineKey(line)))
                        }
                    }
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if isWriting {
                    // Lines that are still to come.
                    VStack(alignment: .leading, spacing: 8) {
                        if layout.title.isEmpty { SkeletonBar(width: 180, height: 12) }
                        SkeletonBar(width: layout.groups.isEmpty ? 320 : 100, height: layout.groups.isEmpty ? 14 : 6)
                        if layout.groups.isEmpty { SkeletonBar(width: 240, height: 14) }
                    }
                    .shimmering()
                    .transition(.opacity)
                }
            }
            // Existing facts stay readable while work continues. New text does
            // not wait for a whole-card crossfade or shimmer over the answer.
            if !earlier.isEmpty {
                DisclosureGroup("Earlier context") {
                    VStack(alignment: .leading, spacing: CardMetrics.lineGap) {
                        ForEach(Array(earlier.enumerated()), id: \.offset) { _, line in
                            Text(Self.markdown(line)).font(type.detail).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            if let formula = parts.formula { CardFormulaView(formula: formula).cardUpdateFlash(.formula) }
            if let drawing = parts.drawing {
                // A drawing is shown as a drawing; its SVG source is one tap away, never in the way.
                CardDrawingView(svg: drawing)
                    .overlay(alignment: .bottomTrailing) { CopyButton(text: drawing, label: "Copy SVG").padding(8) }
                    .cardUpdateFlash(.code)
            } else if let code = parts.code {
                CardCodeView(code: code, language: parts.codeLanguage)
                    .cardUpdateFlash(.code)
            }
            if let chart = parts.chart, !dimmed {
                // In the middle of the card, like a drawing or a formula.
                CardChartView(chart: chart).frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .cardUpdateFlash(.chart)
            }
            if let line = parts.sources, !line.isEmpty, let sources = try? AttributedString(markdown: line) {
                VStack(alignment: .leading, spacing: 3) {
                    if focused != nil { Text("Earlier context sources").font(.caption2) }
                    Label { Text(sources) } icon: { Image(systemName: "link") }
                        .font(.caption).tint(.secondary).labelStyle(.titleAndIcon)
                }
                .foregroundStyle(.secondary)
                .cardUpdateFlash(.sources)
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func earlierContext(whole: String, focus: String) -> [String] {
        let newLines = Set(focus.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) })
        var retained = whole.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !newLines.contains($0) }
        if !retained.isEmpty, CardText(whole).title != CardText(focus).title {
            retained.insert(CardText(whole).title, at: 0)
        }
        return retained
    }
}

/// Copies a text and says so for a moment.
struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.black.opacity(0.06), in: .capsule)
                .foregroundStyle(.black.opacity(0.6))
        }
        .buttonStyle(.plain)
    }
}

/// A bar that stands for a line that is not there yet.
struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 14

    var body: some View {
        Capsule().fill(.quaternary).frame(maxWidth: width).frame(height: height)
            .accessibilityHidden(true)
    }
}

/// A band of light that travels across a view while it waits for something: text that
/// is still being written, a card whose checked version is on its way.
private struct Shimmer: ViewModifier {
    var active: Bool
    @State private var travelled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active, !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, Color(.systemBackground).opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(80, geometry.size.width * 0.45))
                            .offset(x: travelled ? geometry.size.width : -max(80, geometry.size.width * 0.45))
                            .onAppear {
                                travelled = false
                                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { travelled = true }
                            }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .opacity(active && reduceMotion ? 0.6 : 1)
    }
}

extension View {
    func shimmering(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}

/// The cards of a conversation as blocks: one per subject, each with the
/// versions it went through, oldest first.
enum CardBlocks {
    struct Block: Identifiable {
        var id: UInt64
        var versions: [SessionCore.Card]
        var current: SessionCore.Card { versions[versions.count - 1] }
        /// The versions a `CardStack` shows as pages of their own: `versions` without those
        /// that a later one only completed, extended or carried on (see `CardHistory`). The
        /// last page is always `current`. Nothing is taken out of `versions` itself.
        var pages: [SessionCore.Card] { CardHistory.pages(of: versions) }
    }

    /// The id of the page of a `CardStack` that always shows the newest version, whatever card that is.
    static let newestPage: UInt64 = .max

    static func blocks(from cards: [SessionCore.Card]) -> [Block] {
        // A better version names the card it replaces; the first card of the chain is the block.
        let origin = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.start.sourceCard) })
        let explicit = Dictionary(uniqueKeysWithValues: cards.compactMap { card in card.start.blockID.map { (card.id, $0) } })
        func root(_ id: UInt64) -> UInt64 {
            var id = id
            var steps = 0
            while let source = origin[id] ?? nil, steps < 50 {
                if let block = explicit[id] { return block }
                id = source
                steps += 1
            }
            return explicit[id] ?? id
        }
        // A request that was replaced before it wrote anything is not shown; a dismissed card is gone.
        let kept = cards.filter { (!$0.text.isEmpty || $0.status == .streaming) && $0.status != .cancelled && $0.status != .failed }
        return Dictionary(grouping: kept, by: { root($0.id) })
            .map { Block(id: $0.key, versions: $0.value.sorted { $0.id < $1.id }) }
            // A block whose newest version was dismissed has left the table.
            .filter { $0.current.status != .superseded }
            .sorted { $0.id < $1.id }
    }

    /// Generation IDs are monotonic. The latest meaningful accepted card is the
    /// current focus, including an update to a subject above the last block.
    static func focused(in blocks: [Block]) -> Block? {
        blocks.filter { $0.current.text.split(separator: "\n").count >= 2 }
            .max { $0.current.id < $1.current.id }
    }
}

enum CardEvidence: String {
    case conversation = "Conversation quote"
    case sources = "With sources"
    case draft = "Draft"

    static func of(_ card: SessionCore.Card) -> Self {
        let parts = CardChart.split(card.start.focusText ?? card.text)
        if parts.sources?.contains("](http") == true || parts.text.contains("](http") { return .sources }
        return card.start.evidenceSegment == nil ? .draft : .conversation
    }
}

struct CardEvidenceBadge: View {
    let card: SessionCore.Card
    var body: some View {
        let evidence = CardEvidence.of(card)
        Label(evidence.rawValue, systemImage: evidence == .sources ? "link" : evidence == .conversation ? "quote.bubble" : "pencil")
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .help(evidence == .sources ? "Contains source links; this is not verification of every line." : evidence == .conversation ? "Includes a quote from recognised speech; recognition can be wrong." : "Model-written text. Source support is shown separately.")
    }
}

/// Which versions of a block are worth a page of their own to turn back to.
///
/// This is about what is shown, nothing else. Every version stays in `Block.versions`,
/// in the recording and in the timeline; the newest version is always the page in view
/// with its text as it is. What is decided here is only whether the version before it
/// stays reachable as an earlier page, or whether the newer one simply took its place.
///
/// It is a heuristic that compares words. It does not understand what a card says,
/// so it folds only what it can see to be the same and keeps a page for the rest.
/// A step from one version to the next is folded (no page for the earlier one) when:
///
/// - the later one is still being written (decided when it is finished);
/// - only the sources line or the formatting differ, in the text or in the title;
/// - every line of the earlier one is carried by a line of the later one: its words
///   in their order with nothing between them, a few fillers aside (articles, "is",
///   "that", "also"), numbers with their sign and their currency or percent sign.
///   What follows them may continue the line, unless it negates or qualifies it
///   ("not", "only", "rarely", "may", "but", "if") or the line ended in a number or
///   its unit, which the next word could change ("100" then "100 million"). Lines
///   the earlier version did not have may be added unless they negate or qualify;
/// - the title is unchanged, except that a title-only preview may be continued;
/// - the code is the same, or the earlier code block was never closed (that version
///   ended while its code was being written) and the later code begins with it; the
///   same formula; a chart with the same unit whose rows kept their label and value.
///
/// Everything else keeps the earlier version as a page, including every edit this
/// cannot judge: a word that was replaced, moved or put between the others, a
/// qualifying word that came or went, a number or a unit that is gone or different,
/// a "yes" that became a "no", a negation that came or went, another title, finished
/// code that got more code, changed code or formula, a line or a chart row that is
/// gone, another answer altogether.
///
/// Known limits, each shown in `CardHistoryPages`. It keeps a page for edits that
/// change nothing: a synonym, a reworded title, a word put into a line, a line that
/// ended in a number and was continued, first lines that were cut inside a word.
/// Added lines without explicit negating or qualifying words may still change meaning;
/// this word comparison is no substitute for semantic verification.
enum CardHistory {
    enum Step: Equatable {
        case folds(Fold)
        case page(Reason)

        var isFold: Bool { if case .folds = self { true } else { false } }
    }

    enum Fold: Equatable {
        /// The later version is still being written.
        case writing
        /// The same title, lines, code, formula and chart; sources or formatting may differ.
        case same
        /// Everything the earlier version said stands in the later one as it stood, and the later one says more.
        case kept
    }

    /// Why the earlier version stays a page. The first that applies is named.
    enum Reason: Equatable {
        /// A line began with yes and the later version answers no, or the other way round.
        case reversal
        /// Fewer than four in ten of the words of the two versions are shared.
        case different
        /// A number of the earlier version is gone and another one is there.
        case number
        /// The words of a line are still there, with a negation more or less.
        case negation
        /// The words of a line are still there, with a qualifying word more or less ("only", "rarely", "may").
        case qualifier
        /// The words of a line are still there, with another currency or percent sign, or without it.
        case unit
        /// The words of a line are all still there and no others, in another order.
        case order
        /// The title of an existing answer has other words or numbers.
        case title
        /// Code, a formula or a chart value is not what it was.
        case code
        /// Something the earlier version said is gone, or says something this cannot compare.
        case changed
    }

    /// A card as this compares it: its title and the lines under it as words, and its other parts.
    struct Reading {
        var title: [String]
        var lines: [[String]]
        var code: String?
        /// The code block was never closed: the version ended while its code was being written.
        var codeIsOpen = false
        var formula: String?
        var chart: CardChart?

        init(_ card: String) {
            let parts = CardChart.split(card)
            // The first line is the title (see `CardText`); the sources line is already gone.
            var rows = parts.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            title = rows.isEmpty ? [] : CardHistory.words(in: rows.removeFirst())
            lines = rows.map { CardHistory.words(in: $0) }.filter { !$0.isEmpty }
            code = parts.code?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let code {
                // Only the last block of a card can be without its closing fence, and then the card ends with it.
                let fences = card.components(separatedBy: "```").count - 1
                codeIsOpen = fences % 2 == 1 && card.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(code)
            }
            formula = parts.formula.map { String($0.filter { !$0.isWhitespace }) }
            chart = parts.chart
        }
    }

    /// Words that may come or go in a line without the line counting as changed. Kept short
    /// on purpose: no "and", no "a" ("Plan A"), no "ein" (a number word), no quantifier.
    private static let fillers: Set<String> = ["the", "der", "die", "das", "den", "dem", "des", "is", "are", "ist", "sind", "that", "which", "also", "auch"]
    private static let negations: Set<String> = [
        "nicht", "nichts", "nie", "niemals", "nirgends", "weder", "ohne", "nein",
        "not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without", "cannot",
    ]
    /// Words that change how far a statement holds: how often, how surely, how exactly, on
    /// what condition. One of them more or less in a line is another statement.
    private static let qualifiers: Set<String> = [
        "only", "nur", "always", "immer", "rarely", "selten", "sometimes", "manchmal", "often", "oft",
        "usually", "meist", "meistens", "normalerweise",
        "may", "might", "could", "can", "kann", "könnte", "können", "könnten",
        "should", "sollte", "sollten", "must", "muss", "müssen",
        "probably", "wahrscheinlich", "possibly", "möglicherweise", "vielleicht", "perhaps", "maybe",
        "likely", "unlikely", "unwahrscheinlich",
        "almost", "nearly", "beinahe", "roughly", "approximately", "ungefähr", "etwa", "circa", "ca",
        "mindestens", "höchstens",
        "but", "aber", "however", "jedoch", "allerdings", "except", "außer", "unless", "if", "wenn", "falls", "sofern",
    ]
    /// Currencies and shares written as words, as the sign they stand for: "100 EUR" is "100 €".
    private static let unitWords: [String: String] = [
        "eur": "€", "euro": "€", "euros": "€", "usd": "$", "gbp": "£", "prozent": "%", "percent": "%",
    ]
    private static let yes: Set<String> = ["ja", "yes"]
    private static let no: Set<String> = ["nein", "no"]
    /// Signs in front of a number that belong to it: "-5" is not "5", "<5" is not ">5".
    private static let signs = "<>≤≥~≈±+-−"
    private static let edges = CharacterSet.punctuationCharacters.union(.symbols)

    private static func isNegation(_ word: String) -> Bool {
        negations.contains(word) || word.hasPrefix("kein") || word.hasSuffix("n't") || word.hasSuffix("n’t")
    }

    private static func isQualifier(_ word: String) -> Bool { qualifiers.contains(word) }

    private static func isNumber(_ word: String) -> Bool { word.contains { $0.isASCII && $0.isNumber } }

    /// A sign that says what a number counts: a currency, a share.
    private static func isUnitMark(_ sign: Character) -> Bool { sign.isCurrencySymbol || sign == "%" || sign == "‰" }

    /// A word that is such a sign (see `words(in:)`).
    private static func isUnit(_ word: String) -> Bool { word.count == 1 && word.allSatisfy(isUnitMark) }

    /// A line as the words it consists of: without Markdown, the address of a link,
    /// punctuation around a word and capitals. "54,2 %" and "54.2%" are the same number.
    /// A currency or percent sign is a word of its own after the word it stood at, so
    /// "100€", "100 €", "€100" and "100 EUR" read the same and "100 $" does not.
    static func words(in line: String) -> [String] {
        var text = line
        text.replace(#/\[([^\]]*)\]\([^)]*\)/#) { $0.1 }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        var words: [String] = []
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let word = raw.trimmingCharacters(in: edges).lowercased()
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else {
                // Signs on their own: the "%" of "54,2 %", the "€" of "100 €".
                words.append(contentsOf: raw.filter(isUnitMark).map { String($0) })
                continue
            }
            // What stands around the word and was cut off with the punctuation.
            let front = raw.prefix(while: { !$0.isLetter && !$0.isNumber })
            let back = raw.reversed().prefix(while: { !$0.isLetter && !$0.isNumber })
            let marks = (Array(front) + Array(back)).filter(isUnitMark).map { String($0) }
            if let first = word.first, first.isASCII, first.isNumber {
                let sign = String(raw.prefix { !$0.isNumber }.filter { signs.contains($0) }).replacingOccurrences(of: "−", with: "-")
                words.append(sign + word.filter { $0 != "'" && $0 != "’" }.replacingOccurrences(of: ",", with: "."))
            } else {
                words.append(unitWords[word] ?? word)
            }
            words.append(contentsOf: marks)
        }
        return words
    }

    /// A line without the words that may come or go.
    private static func content(of line: [String]) -> [String] { line.filter { !fillers.contains($0) } }

    /// Whether a line of the later version still says what a line of the earlier one said:
    /// the same words in the same order with nothing between them, fillers aside. What
    /// comes after them continues the line. A continuation is not accepted when it negates
    /// or qualifies, or when the earlier line ended in a number or its unit: the next word
    /// could be its magnitude, its unit or what it is counted per.
    private static func carries(_ earlier: [String], in later: [String]) -> Bool {
        let before = content(of: earlier)
        let after = content(of: later)
        guard after.count >= before.count, Array(after.prefix(before.count)) == before else { return false }
        let more = after.dropFirst(before.count)
        if more.isEmpty { return true }
        if let last = before.last, isNumber(last) || isUnit(last) { return false }
        return !more.contains { isNegation($0) || isQualifier($0) }
    }

    /// What the step from one version's text to the next one's is. `writing`: the later
    /// one is not finished, so what it lacks cannot be held against it yet.
    static func step(from earlier: String, to later: String, writing: Bool = false) -> Step {
        writing ? .folds(.writing) : step(from: Reading(earlier), to: Reading(later))
    }

    static func step(from earlier: Reading, to later: Reading) -> Step {
        if let code = earlier.code {
            guard let now = later.code else { return .page(.changed) }
            // More code after code that was finished is new behaviour. Only code that was
            // visibly cut off (its fence never closed) counts as completed by what follows.
            if now != code, !(earlier.codeIsOpen && now.hasPrefix(code)) { return .page(.code) }
        }
        if let formula = earlier.formula {
            guard let now = later.formula else { return .page(.changed) }
            if now != formula { return .page(.code) }
        }
        if let chart = earlier.chart {
            guard let now = later.chart else { return .page(.changed) }
            if chart.unit != now.unit { return .page(.code) }
            for row in chart.rows {
                guard let same = now.rows.first(where: { $0.label == row.label }) else { return .page(.changed) }
                if same.value != row.value { return .page(.code) }
            }
        }
        for line in earlier.lines where !later.lines.contains(where: { carries(line, in: $0) }) {
            return .page(reason(for: line, earlier, later))
        }
        // A completed answer's title identifies its subject: "iPhone" becoming
        // "iPhone 16" can narrow that subject even when its body stayed identical.
        let preview = earlier.lines.isEmpty && earlier.code == nil && earlier.formula == nil && earlier.chart == nil
        if content(of: earlier.title) != content(of: later.title),
           !(preview && carries(earlier.title, in: later.title)) { return .page(.title) }
        for line in later.lines where !earlier.lines.contains(where: { carries($0, in: line) }) {
            // A separate line can retract the statement above it too.
            if line.contains(where: isNegation) { return .page(.negation) }
            if line.contains(where: isQualifier) { return .page(.qualifier) }
        }
        let same =
            earlier.title == later.title && earlier.lines == later.lines && earlier.code == later.code
            && earlier.formula == later.formula && earlier.chart == later.chart
        return .folds(same ? .same : .kept)
    }

    /// Why a line of the earlier version that is not carried on counts as changed.
    private static func reason(for line: [String], _ earlier: Reading, _ later: Reading) -> Reason {
        if let first = line.first, yes.contains(first) || no.contains(first) {
            let (same, opposite) = yes.contains(first) ? (yes, no) : (no, yes)
            let starts = later.lines.compactMap(\.first)
            if !starts.contains(where: { same.contains($0) }), starts.contains(where: { opposite.contains($0) }) { return .reversal }
        }
        let before = Set(earlier.lines.joined()).subtracting(fillers)
        let after = Set(later.lines.joined()).subtracting(fillers)
        let words = before.filter { !isNumber($0) && !isUnit($0) }
        let wordsAfter = after.filter { !isNumber($0) && !isUnit($0) }
        let all = words.union(wordsAfter).count
        if all > 0, Double(words.intersection(wordsAfter).count) / Double(all) < 0.4 { return .different }
        if line.contains(where: { isNumber($0) && !after.contains($0) }), after.contains(where: { isNumber($0) && !before.contains($0) }) {
            return .number
        }
        // The first line of the later version that has the words of this one, whatever
        // negates, qualifies or counts them: what differs there is the reason.
        let said = content(of: line)
        let core = Set(said.filter { !isNegation($0) && !isQualifier($0) && !isUnit($0) })
        for other in later.lines.map({ content(of: $0) }) where core.isSubset(of: Set(other)) {
            if said.count(where: isNegation) != other.count(where: isNegation) { return .negation }
            if said.filter(isQualifier).sorted() != other.filter(isQualifier).sorted() { return .qualifier }
            if said.filter(isUnit).sorted() != other.filter(isUnit).sorted() { return .unit }
            if said.sorted() == other.sorted() { return .order }
            return .changed
        }
        return .changed
    }

    /// The versions that are pages, oldest first; the last one is always the newest version.
    ///
    /// A version is left out when the one after it folds it. Small steps must not add up
    /// unseen: the later version also has to fold the oldest version that was left out
    /// since the last page, or the version before it stays a page.
    static func pages(of versions: [SessionCore.Card]) -> [SessionCore.Card] {
        guard versions.count > 1 else { return versions }
        let readings = versions.map { Reading($0.text) }
        var pages: [SessionCore.Card] = []
        var oldest = 0
        for index in 1..<versions.count {
            let folds =
                versions[index].status == .streaming
                || (step(from: readings[index - 1], to: readings[index]).isFold
                    && (oldest == index - 1 || step(from: readings[oldest], to: readings[index]).isFold))
            if !folds {
                pages.append(versions[index - 1])
                oldest = index
            }
        }
        pages.append(versions[versions.count - 1])
        return pages
    }
}

/// A block on the table. Its versions are pages side by side in a paging scroll
/// view, the newest on the right: a swipe (two fingers on a trackpad), the arrows
/// or the dots turn back through them, with the system's own movement.
///
/// Not every version is a page: one that the next only completed, extended or
/// carried on is not kept to turn back to (`Block.pages`, decided by `CardHistory`).
/// The newest version is always shown, at once, whatever was folded into it.
///
/// A new version does not arrive as a new page that slides in. The page on the
/// right is always "the newest", whatever card that is: its text changes in place,
/// new lines fading in under the ones that stay, and the version it replaced
/// becomes a page to its left without anything moving. A reader who had turned
/// back to an earlier page is brought to the newest when another card becomes the
/// newest version, and can turn back again until the next one arrives.
///
/// The stack is as tall as the page in view, and that is decided by the layout
/// itself, in the same pass that places the pages: nothing is measured first and
/// applied a frame later. So a recording opens at the right height, a page that is
/// being written grows with its text, and another width, another version or an
/// earlier moment of a replay need nothing to be measured again.
struct CardStack<Content: View>: View {
    let block: CardBlocks.Block
    var cornerRadius: CGFloat = 24
    /// Only the live feed opts in. Opening history or moving a replay is not a live update.
    var highlightsUpdates = false
    /// The page in view, when whoever shows the stack wants to hold it: an earlier version's
    /// id, or `CardBlocks.newestPage`. Nil, as everywhere in the app so far: the stack holds
    /// it itself. The tests turn the pages of a mounted stack through this.
    var turnedTo: Binding<UInt64?>? = nil
    /// Counts the moments whoever shows the stack chose by hand (a replay's seeks). When it
    /// changes, the newest version is in view again, also when the versions are the same.
    var seeks = 0
    let content: (_ card: SessionCore.Card, _ isCurrent: Bool) -> Content
    /// The versions that are pages (`Block.pages`), read once for this layout. Called
    /// `versions` below: for the stack, these are the versions there are to turn through.
    private let versions: [SessionCore.Card]
    /// The page in view while nobody outside holds it: an earlier version's id, or `newest`.
    @State private var ownPosition: UInt64? = CardBlocks.newestPage
    @State private var updateHighlights = CardUpdateHighlights()

    init(
        block: CardBlocks.Block, cornerRadius: CGFloat = 24, highlightsUpdates: Bool = false,
        turnedTo: Binding<UInt64?>? = nil, seeks: Int = 0,
        @ViewBuilder content: @escaping (_ card: SessionCore.Card, _ isCurrent: Bool) -> Content
    ) {
        self.block = block
        self.cornerRadius = cornerRadius
        self.highlightsUpdates = highlightsUpdates
        self.turnedTo = turnedTo
        self.seeks = seeks
        self.content = content
        versions = block.pages
    }

    /// The page in view, wherever it is held.
    private var position: UInt64? {
        get {
            if let turnedTo { return turnedTo.wrappedValue }
            return ownPosition
        }
        nonmutating set {
            if let turnedTo { turnedTo.wrappedValue = newValue } else { ownPosition = newValue }
        }
    }

    /// The id of the page that always shows the newest version.
    private static var newest: UInt64 { CardBlocks.newestPage }
    private let peek: CGFloat = 12
    private let gap: CGFloat = 10

    private struct Viewport: Equatable {
        var width: CGFloat
        var contentWidth: CGFloat
    }

    private var earlier: [SessionCore.Card] { Array(versions.dropLast()) }
    private var index: Int { earlier.firstIndex { $0.id == position } ?? versions.count - 1 }
    private var isNewest: Bool { index == versions.count - 1 }
    private func id(of page: Int) -> UInt64 { page >= versions.count - 1 ? Self.newest : versions[page].id }
    /// The id of the page in view. A position that names a page that is gone counts as the newest.
    private var shown: UInt64 { id(of: index) }

    private func page(_ card: SessionCore.Card, id: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content(card, id == Self.newest)
                .environment(\.cardUpdateHighlights, highlightsUpdates && id == Self.newest && isNewest ? updateHighlights : CardUpdateHighlights())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CardMetrics.inset)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) : .white }))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        }
        // A page is as tall as its content at the width it is given, whatever height the
        // row of pages has at that moment: a row that is still as low as a shorter version
        // must not squeeze the text that is being written into it.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A page in the row of versions. Only the page in view counts for the height of the
    /// row; the others hang from the top edge at their own height and are cut off by the
    /// scroll view where they are longer.
    private func paged(_ card: SessionCore.Card, id: UInt64) -> some View {
        page(card, id: id)
            .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                view.opacity(phase.isIdentity ? 1 : 0.5).scaleEffect(phase.isIdentity ? 1 : 0.97)
            }
            .frame(height: id == shown ? nil : 0, alignment: .top)
            .containerRelativeFrame(.horizontal)
            .id(id)
    }

    private func go(to target: Int) {
        guard versions.indices.contains(target) else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.18)) { position = id(of: target) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if versions.count == 1 {
                page(block.current, id: Self.newest)
            } else {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(earlier) { card in paged(card, id: card.id) }
                            // One page for the newest version, the same page whichever card it shows.
                            paged(block.current, id: Self.newest)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollPosition(id: turnedTo ?? $ownPosition, anchor: .center)
                    // The selected id alone does not establish the first content offset on
                    // Catalyst: the row can open at its oldest page while using the newest
                    // page's height. Start at the newest (rightmost) page explicitly.
                    .defaultScrollAnchor(.trailing, for: .initialOffset)
                    .scrollIndicators(.hidden)
                    .contentMargins(.horizontal, peek + gap, for: .scrollContent)
                    .contentMargins(.vertical, 10, for: .scrollContent)
                    // As tall as its row, and the row is as tall as the page in view (see `paged`):
                    // no height is set here, so none can be out of date.
                    .clipped()
                    // Turning to another version changes the height smoothly. Text that is being
                    // written does not wait for an animation: the page is as tall as it at once.
                    .animation(.smooth(duration: 0.35), value: shown)
                    .padding(.horizontal, -(peek + gap))
                    .padding(.vertical, -10)
                    .onScrollGeometryChange(for: Viewport.self) {
                        Viewport(width: $0.containerSize.width, contentWidth: $0.contentSize.width)
                    } action: { _, viewport in
                        guard viewport.width > 0, viewport.contentWidth > 0 else { return }
                        // Replay creates this row after loading its timeline, sometimes in
                        // an animated parent. Place the selected page once the viewport has
                        // its actual width, also after a window resize or history insertion.
                        withTransaction(.withoutAnyAnimation) { scroll.scrollTo(shown, anchor: .center) }
                    }
                }
                // Feed insertions animate their surrounding rows. They must not animate
                // this scroll view's initial offset or its response to inserted history.
                // The page-turn animation above still applies when `shown` changes.
                .transaction { $0.animation = nil }
                pager.padding(.horizontal, CardMetrics.inset)
            }
        }
        .onChange(of: block.current, initial: true) { _, card in
            guard highlightsUpdates else { return }
            updateHighlights.observe(card)
        }
        .onChange(of: [block.versions.map(\.id), versions.map(\.id)]) { before, now in
            // Every version of the block counts here, also one that is no page of its own:
            // a version folded into the newest page is still another card that arrived.
            let (old, new) = (before[0], now[0])
            // Another card is the block's newest version (a better one arrived, a replay moved
            // back), or the page in view is gone (a version was dismissed, or is no page of
            // its own any more): the newest is in view. Otherwise the reader stays where they
            // are: text that is still being written into the newest version does not take
            // them away from an earlier one.
            if position != Self.newest, new.last != old.last || !earlier.contains(where: { $0.id == position }) {
                position = Self.newest
            }
        }
        .onChange(of: seeks) {
            // A moment chosen by hand shows the table as it lay then, not a page turned to before.
            if position != Self.newest {
                withTransaction(.withoutAnyAnimation) { position = Self.newest }
            }
        }
    }

    /// Page dots as under the Home Screen, with arrows for a pointer.
    private var pager: some View {
        HStack(spacing: 10) {
            Button { go(to: index - 1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(.rect) }
                .disabled(index == 0)
                .accessibilityLabel("Earlier version")
            HStack(spacing: 7) {
                ForEach(versions.indices, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 7, height: 7)
                        .scaleEffect(dot == index ? 1.15 : 1)
                        .onTapGesture { go(to: dot) }
                }
            }
            .animation(.spring(duration: 0.3), value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Version \(index + 1) of \(versions.count)")
            Button { go(to: index + 1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(.rect) }
                .disabled(isNewest)
                .accessibilityLabel("Later version")
            if !isNewest {
                Text("Version \(index + 1) of \(versions.count)").font(.caption.monospacedDigit())
                    .transition(.opacity)
            }
            Spacer()
        }
        .font(.caption.weight(.bold))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .animation(.smooth(duration: 0.25), value: index)
    }
}

/// An SVG a model wrote, drawn. The page it is drawn in can run no script and
/// load nothing: the model's text is shown as a picture, never executed.
struct CardDrawingView: UIViewRepresentable {
    let svg: String

    /// The SVG without anything that could act: scripts, event handlers, embedded
    /// pages and references to other places.
    static func harmless(_ svg: String) -> String {
        var text = svg
        text.replace(#/(?is)<script\b.*?(</script>|$)/#, with: "")
        text.replace(#/(?is)<(foreignObject|iframe|image|use|style|animate\w*|set)\b.*?(</\1>|/>)/#, with: "")
        text.replace(#/(?i)\son\w+\s*=\s*("[^"]*"|'[^']*')/#, with: "")
        text.replace(#/(?i)\s(xlink:)?href\s*=\s*("[^"]*"|'[^']*')/#, with: "")
        text.replace(#/(?i)url\([^)]*\)/#, with: "none")
        // An opening tag that lost its address ("xmlns=" and a line break) still has to parse.
        text.replace(#/(?i)\sxmlns(:\w+)?\s*=\s*"(?=\s)/#, with: " ")
        text.replace(#/(?i)\sxmlns(:\w+)?\s*=\s*"[^"]*"/#, with: "")
        // Without a viewBox the drawing cannot be scaled to the card: take it from the size.
        if !text.contains("viewBox"),
            let width = text.firstMatch(of: #/(?i)<svg[^>]*\swidth\s*=\s*"([\d.]+)/#)?.1,
            let height = text.firstMatch(of: #/(?i)<svg[^>]*\sheight\s*=\s*"([\d.]+)/#)?.1
        {
            text.replace(#/(?i)<svg/#, with: "<svg viewBox=\"0 0 \(width) \(height)\"", maxReplacements: 1)
        }
        return text
    }

    static func page(_ svg: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>html,body{margin:0;height:100%;background:#fff;overflow:hidden}
        body{display:flex;align-items:center;justify-content:center}
        svg{width:92%;height:92%}</style></head><body>\(harmless(svg))</body></html>
        """
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.isOpaque = true
        view.backgroundColor = .white
        view.layer.cornerRadius = 14
        view.layer.masksToBounds = true
        view.accessibilityLabel = "Drawing"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != svg else { return }
        context.coordinator.shown = svg
        view.loadHTMLString(Self.page(svg), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown = "" }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        // As wide as the card, so the drawing stands in its middle.
        CGSize(width: proposal.width ?? 320, height: 220)
    }
}
