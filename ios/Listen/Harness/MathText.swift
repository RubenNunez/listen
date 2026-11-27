import Foundation

/// Models write formulas in LaTeX. A card is read at a glance, so the formula is
/// shown in plain signs instead: `\(x^2 \cdot \frac{a}{b}\)` becomes `x² · a/b`.
enum MathText {
    static func plain(_ text: String) -> String {
        guard text.contains("\\") || text.contains("^") || text.contains("$") else { return text }
        var out = text
        // Delimited formulas: inside them `_` means a subscript.
        out.replace(#/(?s)\\\((.+?)\\\)/#) { convert(String($0.1), subscripts: true) }
        out.replace(#/(?s)\\\[(.+?)\\\]/#) { convert(String($0.1), subscripts: true) }
        out.replace(#/\$\$([^$]+)\$\$/#) { convert(String($0.1), subscripts: true) }
        out.replace(#/\$([^$\n]+)\$/#) { match in
            // "$5 and $7" is money, not a formula.
            let inner = String(match.1)
            let isFormula = inner.contains("\\") || inner.contains("^") || inner.contains("=") || inner.contains("_")
            return isFormula ? convert(inner, subscripts: true) : String(match.0)
        }
        // Commands a model left outside any delimiter.
        return convert(out, subscripts: false)
    }

    /// A formula that stands alone: `_` is a subscript throughout.
    static func formula(_ text: String) -> String {
        var out = text
        out.replace(#/^\s*(\\\(|\\\[|\$\$?)|(\\\)|\\\]|\$\$?)\s*$/#, with: "")
        return convert(out, subscripts: true).replacingOccurrences(of: "**", with: "")
    }

    private static let signs: [(String, String)] = [
        ("cdot", "·"), ("times", "×"), ("div", "÷"), ("pm", "±"), ("mp", "∓"),
        ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"), ("neq", "≠"), ("ne", "≠"),
        ("approx", "≈"), ("equiv", "≡"), ("sim", "~"), ("propto", "∝"),
        ("rightarrow", "→"), ("Rightarrow", "⇒"), ("leftarrow", "←"), ("Leftarrow", "⇐"),
        ("leftrightarrow", "↔"), ("Leftrightarrow", "⇔"), ("mapsto", "↦"), ("to", "→"),
        ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("sum", "∑"), ("prod", "∏"), ("int", "∫"),
        ("in", "∈"), ("notin", "∉"), ("subset", "⊂"), ("cup", "∪"), ("cap", "∩"),
        ("forall", "∀"), ("exists", "∃"), ("ldots", "…"), ("dots", "…"), ("cdots", "⋯"),
        ("degree", "°"), ("circ", "°"), ("prime", "′"),
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("epsilon", "ε"), ("varepsilon", "ε"),
        ("theta", "θ"), ("lambda", "λ"), ("mu", "μ"), ("pi", "π"), ("rho", "ρ"), ("sigma", "σ"),
        ("tau", "τ"), ("phi", "φ"), ("varphi", "φ"), ("omega", "ω"), ("eta", "η"), ("xi", "ξ"),
        ("Delta", "Δ"), ("Sigma", "Σ"), ("Omega", "Ω"), ("Phi", "Φ"), ("Pi", "Π"), ("Gamma", "Γ"), ("Lambda", "Λ"),
    ]
    private static let names = ["sin", "cos", "tan", "cot", "log", "ln", "lim", "exp", "min", "max", "det", "arcsin", "arccos", "arctan"]
    private static let raised: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "n": "ⁿ", "i": "ⁱ", "(": "⁽", ")": "⁾",
    ]
    private static let lowered: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "n": "ₙ", "i": "ᵢ", "x": "ₓ", "a": "ₐ", "k": "ₖ", "m": "ₘ",
    ]

    private static func convert(_ formula: String, subscripts: Bool) -> String {
        var out = formula
        // Inner groups first, a few times, so nested fractions resolve.
        for _ in 0..<3 {
            out.replace(#/\\(?:text|mathrm|mathbf|mathit|mathsf|operatorname|textbf|textit)\{([^{}]*)\}/#) { String($0.1) }
            out.replace(#/\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}/#) { "\(group(String($0.1)))/\(group(String($0.2)))" }
            out.replace(#/\\sqrt\{([^{}]*)\}/#) { "√(\($0.1))" }
        }
        out.replace(#/\\(?:left|right|big|Big|bigg|Bigg|displaystyle)(?![A-Za-z])/#, with: "")
        out.replace(#/\\(?:quad|qquad)(?![A-Za-z])|\\[,;:! ]/#, with: " ")
        out.replace(#/\\([A-Za-z]+)/#) { match in
            let name = String(match.1)
            if let sign = signs.first(where: { $0.0 == name }) { return sign.1 }
            if names.contains(name) { return name }
            return String(match.0)
        }
        out.replace(#/\\([{}%&#_])/#) { String($0.1) }
        out.replace(#/\^\{([^{}]*)\}|\^([A-Za-z0-9+-])/#) { match in
            let inner = String(match.1 ?? match.2 ?? "")
            return shifted(inner, with: raised) ?? "^\(group(inner))"
        }
        if subscripts {
            out.replace(#/_\{([^{}]*)\}|_([A-Za-z0-9])(?![A-Za-z])/#) { match in
                let inner = String(match.1 ?? match.2 ?? "")
                return shifted(inner, with: lowered) ?? "_\(inner)"
            }
        }
        out.replace(#/ {2,}/#, with: " ")
        return subscripts ? out.trimmingCharacters(in: .whitespaces) : out
    }

    /// `a+b` needs brackets next to a slash or a caret, `x` does not.
    private static func group(_ part: String) -> String {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(where: { " +-·×/".contains($0) }) ? "(\(trimmed))" : trimmed
    }

    private static func shifted(_ text: String, with table: [Character: Character]) -> String? {
        guard !text.isEmpty else { return nil }
        var out = ""
        for character in text {
            guard let mapped = table[character] else { return nil }
            out.append(mapped)
        }
        return out
    }
}
