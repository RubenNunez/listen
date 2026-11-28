import Foundation

/// A display-only projection. The original typed arguments remain the gateway's
/// decision data, and the confirmation's details retain their exact JSON form.
enum ActionConfirmationPresentation {
    struct Field: Identifiable, Equatable {
        let key: String
        let label: String
        let value: String
        var id: String { key }
    }

    static func fields(_ arguments: [String: ConversationValue], language: Language) -> [Field] {
        let leading = ["query", "name", "target", "action", "area", "floor", "season", "episode", "audio_language"]
        let keys = leading.filter { arguments[$0] != nil } + arguments.keys.filter { !leading.contains($0) }.sorted()
        return keys.compactMap { key in
            arguments[key].map { Field(key: key, label: label(key, language: language), value: value($0, field: key, language: language)) }
        }
    }

    static func value(_ value: ConversationValue, field: String, language: Language) -> String {
        let german = language == .de
        switch value {
        case .string(let text):
            if text.isEmpty { return german ? "Leer" : "Empty" }
            if ["audio_language", "fallback_audio_language", "language"].contains(field) {
                let names = german
                    ? ["auto": "Automatisch", "de": "Deutsch", "en": "Englisch", "es": "Spanisch", "fr": "Französisch", "it": "Italienisch"]
                    : ["auto": "Automatic", "de": "German", "en": "English", "es": "Spanish", "fr": "French", "it": "Italian"]
                return names[text] ?? text
            }
            if field == "action" {
                let actions = german
                    ? ["pause": "Pausieren", "resume": "Fortsetzen", "stop": "Stoppen", "seek": "Position ändern", "on": "Einschalten", "off": "Ausschalten"]
                    : ["pause": "Pause", "resume": "Resume", "stop": "Stop", "seek": "Change position", "on": "Switch on", "off": "Switch off"]
                return actions[text] ?? text
            }
            return text
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return german ? (value ? "Ja" : "Nein") : (value ? "Yes" : "No")
        case .array(let values):
            if values.isEmpty { return german ? "Keine Einträge" : "No entries" }
            return values.map { Self.value($0, field: field, language: language) }.joined(separator: ", ")
        }
    }

    private static func label(_ key: String, language: Language) -> String {
        let german = language == .de
        let labels = german
            ? ["query": "Anfrage", "name": "Name", "target": "Ziel", "action": "Aktion", "area": "Bereich", "floor": "Etage",
               "season": "Staffel", "episode": "Folge", "audio_language": "Sprache", "fallback_audio_language": "Ersatzsprache",
               "language": "Sprache", "domain": "Gerätetypen", "device_class": "Geräteklasse", "year": "Jahr",
               "start_seconds": "Startposition (Sekunden)", "brightness_pct": "Helligkeit (%)", "any_season": "Beliebige Staffel"]
            : ["query": "Request", "name": "Name", "target": "Target", "action": "Action", "area": "Area", "floor": "Floor",
               "season": "Season", "episode": "Episode", "audio_language": "Language", "fallback_audio_language": "Fallback language",
               "language": "Language", "domain": "Device types", "device_class": "Device class", "year": "Year",
               "start_seconds": "Start position (seconds)", "brightness_pct": "Brightness (%)", "any_season": "Any season"]
        if let label = labels[key] { return label }
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
