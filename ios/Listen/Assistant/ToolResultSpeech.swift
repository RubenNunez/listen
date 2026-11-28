import Foundation

/// The generic result contract a tool server may follow so Listen can say what happened
/// without knowing the service (docs/TOOL_RESULTS.md). It is one reserved object in the
/// structured result:
///
///     "spoken": {"status": "unreachable", "text": "I can't reach the TV.", "language": "en"}
///
/// The text is the service's own sentence. Listen speaks it as data: bounded and plain,
/// never a source of permissions, confirmations or another action.
struct SpokenReport: Equatable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case done, partial, info, unconfirmed, failed, unavailable, unreachable
        case needsChoice = "needs_choice", needsConfirmation = "needs_confirmation"

        /// Only these report an effect or an answer; a failed call never does.
        var reportsSuccess: Bool { self == .done || self == .info }
    }

    var status: Status
    /// The service's sentence, when it is plain text in the session's language.
    var text: String?

    static let maximumText = 300

    /// The report in an observed result, if it has a valid one. `failed` is the MCP
    /// `isError` flag, which stays authoritative: a failure that claims success has no report.
    static func read(_ detail: String, failed: Bool, language: Language) -> Self? {
        guard detail.utf8.count <= 8192 else { return nil }
        let data = Data(detail.utf8)
        guard (try? HarnessJSON.checkUniqueKeys(data)) != nil,
              let spoken = (try? JSONDecoder().decode(HarnessValue.self, from: data))?.object?["spoken"]?.object,
              let status = spoken["status"]?.string.flatMap(Status.init(rawValue:)),
              !(failed && status.reportsSuccess) else { return nil }
        var report = Self(status: status)
        // Unknown fields are ignored, so the contract can grow without breaking older apps.
        if let code = spoken["language"]?.string, primarySubtag(code) == language.rawValue,
           let text = spoken["text"]?.string {
            report.text = plain(text)
        }
        return report
    }

    /// A short paragraph of plain text, or nothing. No markup, links, code or hidden characters.
    static func plain(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= maximumText, !text.contains("://"),
              !text.contains(where: { "{}[]<>`\\".contains($0) }),
              text.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: false
                  default: true
                  }
              }) else { return nil }
        return text
    }

    private static func primarySubtag(_ code: String) -> String? {
        guard code.utf8.count <= 35 else { return nil }
        return code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
    }
}

/// What Listen says about an observed tool result. It knows no particular service: a
/// server that follows the spoken report contract supplies its own sentence or at least
/// a neutral status; any other result gets a generic sentence for its observed state.
/// The model's proposed success text is never used.
enum AssistantToolFeedback {
    static func speech(for result: ConversationOperationState, language: Language) -> String? {
        func text(_ en: String, _ de: String) -> String { language == .de ? de : en }
        switch result {
        case .succeeded(let detail):
            if let report = SpokenReport.read(detail, failed: false, language: language) {
                return report.text ?? sentence(for: report.status, language: language)
            }
            return text("The service has responded. Details are available in the app.", "Die Rückmeldung ist da. Die Details findest du in der App.")
        case .failed(let detail):
            if let report = SpokenReport.read(detail, failed: true, language: language) {
                return report.text ?? sentence(for: report.status, language: language)
            }
            return sentence(for: .failed, language: language)
        case .outcomeUnknown:
            return text("The result is unknown. I will not repeat the action.", "Das Ergebnis ist unbekannt. Ich wiederhole die Aktion nicht.")
        case .cancelledBeforeDispatch:
            return text("The action was not sent.", "Die Aktion wurde nicht gesendet.")
        default: return nil
        }
    }

    /// Listen's own sentence for a status, used when the service's sentence is missing,
    /// in another language or not plain text. It claims nothing beyond the status.
    static func sentence(for status: SpokenReport.Status, language: Language) -> String {
        func text(_ en: String, _ de: String) -> String { language == .de ? de : en }
        switch status {
        case .done: return text("Done.", "Erledigt.")
        case .partial: return text("That only partly worked. Check the details.", "Das hat nur teilweise geklappt. Schau bitte in die Details.")
        case .info: return text("The answer is here. Details are available in the app.", "Die Antwort ist da. Die Details findest du in der App.")
        case .unconfirmed: return text("It was sent, but it is not confirmed. I will not repeat it.", "Das wurde gesendet, aber nicht bestätigt. Ich wiederhole es nicht.")
        case .failed: return text("The service reported an error. Check the details.", "Der Dienst meldet einen Fehler. Schau bitte in die Details.")
        case .unavailable: return text("That is not available there.", "Das ist dort nicht verfügbar.")
        case .unreachable: return text("I can't reach the service right now.", "Ich kann den Dienst gerade nicht erreichen.")
        case .needsChoice: return text("The service needs a more specific choice. Can you be more specific?", "Der Dienst braucht eine genauere Angabe. Kannst du sie genauer benennen?")
        case .needsConfirmation: return text("The service offers an alternative. Nothing has been done yet. Check the details.", "Der Dienst bietet eine Alternative an. Noch ist nichts ausgeführt. Schau bitte in die Details.")
        }
    }
}
