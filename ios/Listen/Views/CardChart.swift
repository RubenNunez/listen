import SwiftUI

/// A small chart a card can carry. The model writes it as a block inside the
/// card's text:
///
///     ```chart
///     title: iOS versions in use
///     unit: %
///     iOS 26: 54.2
///     iOS 18: 31
///     ```
///
/// The app only draws what the block says; it never makes up a value.
struct CardChart: Equatable {
    struct Row: Equatable, Identifiable {
        var label: String
        var value: Double
        var id: String { label }
    }

    var title = ""
    var unit = ""
    var rows: [Row] = []

    /// What a card consists of besides its running text.
    struct Parts: Equatable {
        var text: String
        var chart: CardChart?
        /// A code example, without its fence.
        var code: String?
        /// The language the fence names ("swift", "python"), lowercased; empty when it names none.
        var codeLanguage = ""
        /// A formula that stands alone, in plain signs.
        var formula: String?
        /// The code when it is a complete SVG: it is drawn as well as shown.
        var drawing: String? {
            guard let code, code.range(of: "<svg", options: .caseInsensitive) != nil, code.range(of: "</svg>", options: .caseInsensitive) != nil
            else { return nil }
            return code
        }
        /// The line that names the sources, without its label: Markdown links.
        var sources: String?
    }

    /// Splits a card into its text, its chart and its code example.
    static func split(_ card: String) -> Parts {
        var text = card
        var chart: CardChart?
        if let match = text.firstMatch(of: /(?s)```chart[ \t]*\n(.*?)(```\n?|$)/) {
            var found = CardChart()
            for line in match.1.split(separator: "\n") {
                guard let colon = line.lastIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " -*"))
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key.lowercased() {
                case "title", "titel": found.title = value
                case "unit", "einheit": found.unit = value
                default:
                    // "54,2 %" and "1'200" are numbers too.
                    let digits = value.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." || $0 == "-" }
                    if !key.isEmpty, let number = Double(digits) { found.rows.append(Row(label: key, value: number)) }
                }
            }
            text.removeSubrange(match.range)
            if (2...12).contains(found.rows.count) { chart = found }
        }
        var formula: String?
        if let match = text.firstMatch(of: /(?s)```(?:formula|formel|math|latex)[ \t]*\n(.*?)(```\n?|$)/) {
            let body = MathText.formula(String(match.1).trimmingCharacters(in: .whitespacesAndNewlines))
            if !body.isEmpty { formula = body }
            text.removeSubrange(match.range)
        }
        var code: String?
        var codeLanguage = ""
        if let match = text.firstMatch(of: /(?s)```([A-Za-z0-9+#-]*)[ \t]*\n(.*?)(```\n?|$)/) {
            let body = String(match.2).trimmingCharacters(in: .newlines)
            if !body.isEmpty { code = body }
            codeLanguage = match.1.lowercased()
            text.removeSubrange(match.range)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A model that put the formula in bold on a line of its own meant the same thing.
        if formula == nil, let index = lines.indices.dropFirst().first(where: { isFormula(lines[$0]) }) {
            formula = MathText.formula(lines[index].trimmingCharacters(in: CharacterSet(charactersIn: "* ")))
            lines.remove(at: index)
        }
        var sources: String?
        if let index = lines.lastIndex(where: { $0.hasPrefix("Quellen:") || $0.hasPrefix("Sources:") }) {
            sources = String(lines[index].drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
            lines.remove(at: index)
        }
        text = lines.joined(separator: "\n")
        // Blank lines the blocks left behind.
        text.replace(/\n{3,}/, with: "\n\n")
        // Formulas in plain signs; code keeps its backslashes.
        return Parts(
            text: MathText.plain(text).trimmingCharacters(in: .whitespacesAndNewlines), chart: chart, code: code,
            codeLanguage: codeLanguage, formula: formula, sources: sources)
    }

    /// A whole line in bold that is an equation: "**t = t₀ × 2ⁿ**".
    private static func isFormula(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("**"), text.hasSuffix("**"), text.count <= 60 else { return false }
        let inner = text.dropFirst(2).dropLast(2)
        guard !inner.contains("**"), let equals = inner.firstIndex(of: "=") else { return false }
        // Both sides hold something, and the line is signs rather than a sentence.
        let sides = [inner[..<equals], inner[inner.index(after: equals)...]].map { $0.trimmingCharacters(in: .whitespaces) }
        return sides.allSatisfy { !$0.isEmpty } && inner.split(separator: " ").filter { $0.count > 3 && $0.allSatisfy(\.isLetter) }.count <= 3
    }

    func label(_ value: Double) -> String {
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// The value a full bar stands for: 100 for shares, otherwise the largest value.
    var full: Double {
        let largest = rows.map(\.value).max() ?? 1
        return unit.contains("%") && largest <= 100 ? 100 : max(largest, 0.0001)
    }
}

/// Each row is a label with its value, and under it a bar. Labels of any
/// length fit, and two rows look as considered as eight.
struct CardChartView: View {
    let chart: CardChart

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !chart.title.isEmpty {
                Text(chart.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(chart.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label).font(.subheadline).lineLimit(2)
                        Spacer(minLength: 8)
                        Text(chart.label(row.value)).font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(.primary.opacity(0.8))
                                .frame(width: max(4, geometry.size.width * min(1, max(0, row.value / chart.full))))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.title.isEmpty ? "Chart" : chart.title)
        .accessibilityValue(chart.rows.map { "\($0.label) \(chart.label($0.value))" }.joined(separator: ", "))
    }
}

/// A formula on its own: larger than the text and centred, so it reads as the thing itself.
struct CardFormulaView: View {
    let formula: String

    var body: some View {
        Text(formula)
            .font(.system(.title2, design: .serif).weight(.medium))
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14))
            .accessibilityLabel("Formula")
            .accessibilityValue(formula)
    }
}

/// A code example in a card: monospaced, scrolls sideways instead of wrapping.
struct CardCodeView: View {
    let code: String
    var language = ""
    @State private var copied = false

    /// Comments, strings, numbers and keywords in their own colours. It knows no grammar:
    /// it marks what looks the same in most languages, which is enough to read twelve lines.
    static func highlighted(_ code: String, language: String) -> AttributedString {
        var out = AttributedString(code)
        let hash = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml", "r", "perl"].contains(language)
        let comment = hash ? "#[^\\n]*" : "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
        let pattern = "(\(comment))|(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*')|(\\b\\d[\\d_.]*\\b)|(\\b[A-Za-z_][A-Za-z0-9_]*\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let whole = NSRange(code.startIndex..., in: code)
        for match in regex.matches(in: code, range: whole) {
            let color: Color?
            if match.range(at: 1).location != NSNotFound {
                color = .secondary
            } else if match.range(at: 2).location != NSNotFound {
                color = .orange
            } else if match.range(at: 3).location != NSNotFound {
                color = .blue
            } else if let range = Range(match.range(at: 4), in: code), keywords.contains(String(code[range])) {
                color = .pink
            } else {
                color = nil
            }
            guard let color, let range = Range(match.range, in: code),
                let from = AttributedString.Index(range.lowerBound, within: out),
                let to = AttributedString.Index(range.upperBound, within: out)
            else { continue }
            out[from..<to].foregroundColor = color
        }
        return out
    }

    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "protocol",
        "extension", "guard", "switch", "case", "default", "break", "continue", "do", "try", "catch", "throw", "throws",
        "async", "await", "in", "where", "self", "nil", "true", "false", "static", "private", "public", "init", "defer",
        "def", "from", "as", "with", "lambda", "None", "True", "False", "elif", "except", "finally", "raise", "pass",
        "yield", "and", "or", "not", "is", "print", "const", "function", "new", "this", "null", "undefined", "export",
        "typeof", "interface", "type", "fn", "mut", "impl", "trait", "pub", "use", "match", "mod", "val", "fun", "when",
        "override", "package", "void", "int", "float", "double", "bool", "string", "select", "SELECT", "FROM", "WHERE",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // What it is written in, and a way to take it along.
            HStack {
                Text(language.isEmpty ? "CODE" : language.uppercased())
                    .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, CardMetrics.panelInset)
            .padding(.vertical, 9)
            Divider().opacity(0.6)
            ScrollView(.horizontal) {
                Text(Self.highlighted(code, language: language))
                    .font(.footnote.monospaced())
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(CardMetrics.panelInset)
            }
            .scrollIndicators(.hidden)
        }
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: CardMetrics.panelCorner))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code example")
        .accessibilityValue(code)
    }
}
