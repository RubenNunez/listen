import Foundation

/// A bounded local fallback, available before a post-conversation model call can fail.
/// Only quoted user statements are retained; assistant claims are never promoted to facts.
enum AssistantMemoryCheckpoint {
    static func text(messages: [HarnessValue], language: Language) -> String? {
        let statements = messages.compactMap { message -> String? in
            guard message.object?["role"] == .string("user"), let text = message.object?["text"]?.string else { return nil }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        guard !statements.isEmpty else { return nil }
        var remaining = 1900
        var quotes: [String] = []
        for statement in statements.suffix(12).reversed() {
            guard remaining > 80 else { break }
            let excerpt = String(statement.prefix(min(200, remaining - 20)))
            guard let data = try? JSONEncoder().encode(excerpt), let quoted = String(data: data, encoding: .utf8) else { continue }
            quotes.append("- " + quoted)
            remaining -= quoted.count + 3
        }
        let notice = language == .de
            ? "Lokale Gesprächsnotiz ohne KI-Zusammenfassung. Neueste Nutzeraussagen zuerst; gekürzte Zitate, keine bestätigten Fakten oder ausgeführten Aktionen:"
            : "Local checkpoint without an AI summary. Latest user statements first; shortened quotations, not verified facts or completed actions:"
        return notice + "\n\n" + quotes.joined(separator: "\n")
    }
}
