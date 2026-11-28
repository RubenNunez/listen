import Foundation

struct MCPTool: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: [String: HarnessValue]

    static func read(_ value: HarnessValue) throws -> Self {
        guard let object = value.object, let name = object["name"]?.string,
              !name.isEmpty, name.utf8.count <= 128, let schema = object["inputSchema"]?.object else { throw MCPFailure.invalidResponse }
        var tool = Self(name: name, description: String((object["description"]?.string ?? "").prefix(1000)), inputSchema: schema)
        if tool.needsExplicitDomain, tool.fields != nil {
            tool.inputSchema["required"] = .array(tool.required.sorted().map(HarnessValue.string))
        }
        return tool
    }

    /// A deliberately bounded schema subset; unsupported tools remain visible but unavailable.
    var fields: [String: ConversationToolField]? {
        guard name.wholeMatch(of: /[A-Za-z0-9_.-]{1,100}/) != nil,
              inputSchema["type"] == .string("object"),
              Set(inputSchema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "description", "title", "$schema"]),
              let properties = inputSchema["properties"]?.object, properties.count <= 32 else { return nil }
        var result: [String: ConversationToolField] = [:]
        for (name, value) in properties {
            guard name.wholeMatch(of: /[A-Za-z0-9_.-]{1,100}/) != nil, let schema = value.object,
                  let field = Self.field(schema) else { return nil }
            result[name] = field
        }
        if let required = inputSchema["required"] {
            guard case .array(let values) = required, values.allSatisfy({ $0.string != nil && properties[$0.string!] != nil }),
                  Set(values.compactMap(\.string)).count == values.count else { return nil }
        }
        return result
    }

    private static func field(_ schema: [String: HarnessValue], allowArray: Bool = true) -> ConversationToolField? {
        let scalarKeys: Set<String> = ["type", "description", "title", "default", "enum", "minimum", "maximum", "minLength", "maxLength"]
        let isArray = schema["type"] == .string("array")
        let allowed = isArray ? Set(["type", "description", "title", "default", "enum", "items", "minItems", "maxItems", "uniqueItems"]) : scalarKeys
        guard Set(schema.keys).isSubset(of: allowed) else { return nil }
        if let enumeration = schema["enum"] {
            guard case .array = enumeration else { return nil }
        }
        for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
            if let bound = schema[key] {
                guard let n = bound.numeric, n.isFinite else { return nil }
                if key != "minimum" && key != "maximum", n < 0 || n.rounded() != n { return nil }
            }
        }
        switch schema["type"]?.string {
        case "string": return .string
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array":
            guard allowArray, let items = schema["items"]?.object,
                  let item = field(items, allowArray: false) else { return nil }
            if let unique = schema["uniqueItems"], unique != .bool(true) && unique != .bool(false) { return nil }
            return .array(item)
        default: return nil
        }
    }

    /// Home Assistant's generic on/off tools otherwise accept an empty object,
    /// which can fail or imply every device. Require an explicit device domain;
    /// never infer a global scope or manufacture a default target in the executor.
    private var needsExplicitDomain: Bool {
        ["HassTurnOn", "HassTurnOff"].contains(name)
            && inputSchema["properties"]?.object?["domain"]?.object?["type"] == .string("array")
    }

    var required: Set<String> {
        let declared: Set<String>
        if case .array(let values) = inputSchema["required"] { declared = Set(values.compactMap(\.string)) }
        else { declared = [] }
        return needsExplicitDomain ? declared.union(["domain"]) : declared
    }

    func accepts(_ arguments: [String: ConversationValue]) -> Bool {
        if needsExplicitDomain {
            guard case .array(let domains) = arguments["domain"], !domains.isEmpty else { return false }
        }
        guard let fields, required.isSubset(of: Set(arguments.keys)), Set(arguments.keys).isSubset(of: Set(fields.keys)) else { return false }
        for (name, value) in arguments {
            guard fields[name]?.accepts(value) == true, let schema = inputSchema["properties"]?.object?[name]?.object else { return false }
            guard Self.accepts(value, schema: schema) else { return false }
        }
        return true
    }

    private static func accepts(_ value: ConversationValue, schema: [String: HarnessValue]) -> Bool {
        if case .array(let allowed) = schema["enum"], !allowed.contains(value.harness) { return false }
        if let number = value.harness.numeric {
            if !number.isFinite { return false }
            if let minimum = schema["minimum"]?.numeric, number < minimum { return false }
            if let maximum = schema["maximum"]?.numeric, number > maximum { return false }
        }
        if case .string(let text) = value {
            if let minimum = schema["minLength"]?.numeric, Double(text.count) < minimum { return false }
            if let maximum = schema["maxLength"]?.numeric, Double(text.count) > maximum { return false }
        }
        if case .array(let values) = value {
            guard let items = schema["items"]?.object else { return false }
            if let minimum = schema["minItems"]?.numeric, Double(values.count) < minimum { return false }
            if let maximum = schema["maxItems"]?.numeric, Double(values.count) > maximum { return false }
            if schema["uniqueItems"] == .bool(true) {
                for index in values.indices where values[..<index].contains(values[index]) { return false }
            }
            if !values.allSatisfy({ accepts($0, schema: items) }) { return false }
        }
        return true
    }
}

extension HarnessValue {
    var numeric: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .unsigned(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
}

/// Presentation uses only an observed result, never the model's proposed success text.
enum AssistantToolFeedback {
    static func speech(for result: ConversationOperationState, tool: String?,
                       arguments: [String: ConversationValue], language: Language, variant: Int = 0) -> String? {
        func text(_ en: String, _ de: String) -> String { language == .de ? de : en }
        switch result {
        case .succeeded(let detail), .failed(let detail):
            if let offer = languageOffer(detail, arguments: arguments, language: language) { return offer }
        default: break
        }
        switch result {
        case .succeeded(let detail):
            if let receipt = playbackReceipt(detail, arguments: arguments, language: language) { return receipt }
            if ["HassTurnOn", "HassTurnOff"].contains(tool ?? ""),
               arguments["domain"] == .array([.string("light")]),
               let data = detail.data(using: .utf8), (try? HarnessJSON.checkUniqueKeys(data)) != nil,
               let value = try? JSONDecoder().decode(HarnessValue.self, from: data),
               value.object?["response_type"] == .string("action_done"),
               case .array(let success) = value.object?["data"]?.object?["success"],
               case .array(let failed) = value.object?["data"]?.object?["failed"] {
                guard failed.isEmpty else {
                    return success.isEmpty
                        ? text("Home Assistant could not switch the lights.", "Home Assistant konnte die Lichter nicht schalten.")
                        : text("Some lights could not be switched. Check the details.", "Einige Lichter konnten nicht geschaltet werden. Schau bitte in die Details.")
                }
                // Home Assistant includes matched area/floor records alongside the
                // actual entity receipts. Those records are not extra lamps or errors.
                let entities = success.filter { $0.object?["type"] == .string("entity") }
                guard !entities.isEmpty, success.allSatisfy({
                    guard let type = $0.object?["type"]?.string else { return false }
                    return type == "entity" || type == "area" || type == "floor"
                }), entities.allSatisfy({
                    $0.object?["id"]?.string?.hasPrefix("light.") == true
                }) else { return text("Home Assistant has not confirmed any switched lights.", "Home Assistant hat keine geschalteten Lichter bestätigt.") }
                let single = entities.count == 1
                let target: String?
                if arguments["name"] != nil, single {
                    target = label(entities[0].object?["name"]?.string)
                } else { target = nil }
                let areas = success.filter { $0.object?["type"] == .string("area") }
                // A whole-home receipt can contain several areas. Never attribute
                // all its lamps to the first returned room.
                let area = arguments["area"] != nil && areas.count == 1 ? label(areas[0].object?["name"]?.string) : nil
                let index = abs(variant % 3), off = tool == "HassTurnOff"
                if let target {
                    let state = text(off ? "off" : "on", off ? "aus" : "an")
                    let phrases = language == .de
                        ? ["\(target) ist jetzt \(state).", "Erledigt, \(target) ist \(state).", "\(target): Das Licht ist \(state)."]
                        : ["\(target) is now \(state).", "Done, \(target) is \(state).", "The light \(target) is \(state)."]
                    return phrases[index]
                }
                if let area {
                    if language == .de {
                        let location = location(area), noun = single ? "ist das Licht" : "sind die Lichter", state = off ? "aus" : "an"
                        return ["\(location) \(noun) jetzt \(state).", "Erledigt, \(location.prefix(1).lowercased())\(location.dropFirst()) \(noun) \(state).", "\(location) \(noun) \(state)."][index]
                    }
                    let noun = single ? "the light is" : "the lights are", state = off ? "off" : "on"
                    return ["In \(area), \(noun) now \(state).", "Done, \(noun) \(state) in \(area).", "In \(area), \(noun) \(state)."][index]
                }
                let state = text(off ? "off" : "on", off ? "aus" : "an")
                if language == .de {
                    let noun = single ? "Das Licht ist" : "Die Lichter sind"
                    return ["\(noun) \(off ? "ausgeschaltet" : "eingeschaltet").",
                            "Erledigt, \(single ? "das Licht ist" : "die Lichter sind") \(state).",
                            "\(noun) jetzt \(state)."][index]
                }
                let noun = single ? "The light is" : "The lights are"
                return ["\(noun) switched \(state).", "Done, \(single ? "the light is" : "the lights are") \(state).", "\(noun) now \(state)."][index]
            }
            return text("The service has responded. Details are available in the app.", "Die Rückmeldung ist da. Die Details findest du in der App.")
        case .failed(let detail):
            if let playback = playbackFailure(detail, language: language) { return playback }
            if let clarification = titleClarification(detail, language: language) { return clarification }
            if let object = structured(detail), object["outcome"] == .string("episode_unavailable"),
               object["playback_started"] == .bool(false) {
                return text("The requested season or episode is not available there.",
                            "Die angefragte Staffel oder Folge ist dort nicht verfügbar.")
            }
            // Classify a short service error, never narrate its payload or instructions.
            if needsClarification(detail) {
                return text("The service could not identify the selection uniquely. Can you be more specific?",
                            "Der Dienst konnte die Auswahl nicht eindeutig zuordnen. Kannst du sie genauer benennen?")
            }
            if reportsNoPlayableResult(detail) {
                return text("The service couldn't find a playable result for this request.",
                            "Der Dienst hat dafür gerade keinen abspielbaren Treffer gefunden.")
            }
            return text("The service reported an error. Check the details.", "Der Dienst meldet einen Fehler. Schau bitte in die Details.")
        case .outcomeUnknown:
            return text("The result is unknown. I will not repeat the action.", "Das Ergebnis ist unbekannt. Ich wiederhole die Aktion nicht.")
        case .cancelledBeforeDispatch:
            return text("The action was not sent.", "Die Aktion wurde nicht gesendet.")
        default: return nil
        }
    }

    /// Only a coherent, confirmed player receipt may assert playback. Service speech is
    /// untrusted data and is never read verbatim, including when the RPC succeeded.
    private static func playbackReceipt(_ raw: String, arguments: [String: ConversationValue], language: Language) -> String? {
        guard let object = structured(raw), let player = object["player"]?.object,
              ["done", "playing"].contains(object["outcome"]?.string ?? ""),
              player["error"] == nil || player["error"] == .string("") else { return nil }
        if playbackIdentityConflicts(object, player: player, arguments: arguments) {
            return language == .de
                ? "Die Rückmeldung passt nicht zum angefragten Inhalt. Ich kann die Wiedergabe noch nicht bestätigen."
                : "The receipt does not match the requested content. I cannot confirm playback yet."
        }
        let state = player["state"]?.string
        if object["outcome"] == .string("done") {
            if case .string(let action) = arguments["action"] {
                if action == "pause", state == "paused" { return language == .de ? "Die Wiedergabe ist pausiert." : "Playback is paused." }
                if action == "resume", state == "playing" { return language == .de ? "Die Wiedergabe läuft weiter." : "Playback has resumed." }
                if action == "stop", state == "idle" || state == "stopped" { return language == .de ? "Die Wiedergabe ist gestoppt." : "Playback is stopped." }
            } else if arguments["action"] == nil {
                // Continue/status operations can confirm the current state without an
                // action argument. Do not infer that a new playback was started.
                if state == "playing" { return language == .de ? "Die Wiedergabe läuft." : "Playback is running." }
                if state == "paused" { return language == .de ? "Die Wiedergabe ist pausiert." : "Playback is paused." }
            }
            return nil
        }
        guard object["outcome"] == .string("playing"),
              object["playback_started"] == nil || object["playback_started"] == .bool(true), state == "playing" else { return nil }
        let code = player["audio_language"]?.string
        let audio = code.flatMap { languageName($0, language: language) }
        // A reported fallback must identify its actual language; never imply the requested one.
        if object["fallback_used"] == .bool(true), audio == nil { return nil }
        var subject = language == .de ? "Die Wiedergabe läuft" : "Playback is running"
        if let selection = object["selection"]?.object, let title = mediaLabel(selection["series"]?.string),
           case .integer(let season) = selection["season"], (1...999).contains(season),
           case .integer(let episode) = selection["episode"], (1...9999).contains(episode) {
            subject = language == .de ? "„\(title)“, Staffel \(season), Folge \(episode) läuft" : "\"\(title)\", season \(season), episode \(episode) is playing"
        }
        if let audio {
            subject += language == .de ? " auf \(audio)" : " in \(audio)"
        }
        subject += "."
        if object["fallback_used"] == .bool(true) {
            subject += language == .de ? " Als Ersatzsprache." : " Using the fallback language."
        }
        return subject
    }

    /// A verified track plus a failed player start is not a missing-language result.
    private static func playbackFailure(_ raw: String, language: Language) -> String? {
        guard let object = structured(raw), object["outcome"] == .string("playback_failed"),
              object["playback_started"] == .bool(false) else { return nil }
        if object["audio_verified"] == .bool(true),
           let code = object["attempted_audio_language"]?.string, let audio = languageName(code, language: language) {
            return language == .de
                ? "Die Tonspur auf \(audio) ist vorhanden, aber die Wiedergabe konnte nicht gestartet werden."
                : "The \(audio) audio track is available, but playback could not start."
        }
        return language == .de ? "Die Wiedergabe konnte nicht gestartet werden." : "Playback could not start."
    }

    /// Compare supplied identities only. Missing legacy metadata is not an invented
    /// conflict, and matching media IDs permit display aliases, never another episode.
    private static func playbackIdentityConflicts(_ object: [String: HarnessValue], player: [String: HarnessValue],
                                                  arguments: [String: ConversationValue]) -> Bool {
        let selection = object["selection"]?.object ?? [:]
        func integer(_ value: HarnessValue?) -> Int64? {
            guard case .integer(let value) = value else { return nil }
            return value
        }
        func identifier(_ value: HarnessValue?) -> String? {
            guard let value = value?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 256,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return value
        }
        // A start that opts into playback correlation must supply a matching echo.
        // A status/control can describe an existing player's ID without reserving a
        // new start of its own. Legacy receipts keep their available identity checks.
        if object["playback_id"] != nil || (object["playback_started"] == .bool(true) && player["playback_id"] != nil) {
            guard let expected = identifier(object["playback_id"]),
                  let actual = identifier(player["playback_id"]), expected == actual else { return true }
        }
        let parsed = player["title"]?.string.flatMap(episodeTitle)
        for key in ["season", "episode", "year"] {
            var values = [integer(selection[key]), integer(player[key])].compactMap { $0 }
            if case .integer(let requested) = arguments[key] { values.append(Int64(requested)) }
            if key == "season", let parsed { values.append(parsed.season) }
            if key == "episode", let parsed { values.append(parsed.episode) }
            if Set(values).count > 1 { return true }
        }

        var sameMedia = false
        for key in ["imdb_id", "media_id"] {
            if let selected = identifier(selection[key]), let actual = identifier(player[key]) {
                if selected != actual { return true }
                sameMedia = true
            }
        }
        if sameMedia { return false }
        guard let selected = selection["series"]?.string, !selected.isEmpty else { return false }
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
        }
        // A free-form display title may name an episode rather than its series.
        // Only explicit series metadata or our recognized suffix provides a comparison.
        let names = [parsed?.title, player["series"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
        return names.contains { normalized(selected) != normalized($0) }
    }

    /// Only the explicit, trailing SxxExx display marker is interpreted as an
    /// episode identity. Other title formats remain opaque data.
    private static func episodeTitle(_ title: String) -> (title: String, season: Int64, episode: Int64)? {
        guard title.utf8.count <= 512,
              let regex = try? NSRegularExpression(pattern: #"(?i)\s+[–—-]?\s*S([0-9]{1,3})\s*E([0-9]{1,4})\s*$"#),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range, in: title),
              let seasonRange = Range(match.range(at: 1), in: title), let season = Int64(title[seasonRange]),
              let episodeRange = Range(match.range(at: 2), in: title), let episode = Int64(title[episodeRange]) else { return nil }
        return (String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces), season, episode)
    }

    private static func titleClarification(_ raw: String, language: Language) -> String? {
        guard let object = structured(raw), object["outcome"] == .string("ambiguous_title"),
              object["playback_started"] != .bool(true), case .array(let choices) = object["choices"],
              (1...20).contains(choices.count) else { return nil }
        let labels = choices.prefix(3).compactMap { value -> String? in
            guard let choice = value.object, let name = mediaLabel(choice["name"]?.string),
                  let year = releaseStartYear(choice["releaseInfo"]?.string) else { return nil }
            return "\(name) (\(year))"
        }
        guard labels.count == min(3, choices.count), Set(labels).count == labels.count else { return nil }
        if choices.count == 1 {
            // A single alias candidate still reports a pending title clarification,
            // never a service outage, successful playback or permission to retry.
            return language == .de
                ? "Ich habe „\(labels[0])“ als passenden Titel gefunden. Meinst du diesen?"
                : "I found \"\(labels[0])\" as a matching title. Is that the one you mean?"
        }
        let options = labels.joined(separator: language == .de ? " oder " : " or ")
        return language == .de ? "Ich habe mehrere passende Serien gefunden: \(options). Welche meinst du?" : "I found several matching series: \(options). Which one do you mean?"
    }

    private static func releaseStartYear(_ raw: String?) -> Int? {
        guard let raw, raw.count <= 12 else { return nil }
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: "-–")).map { $0.trimmingCharacters(in: .whitespaces) }
        func year(_ text: String) -> Int? {
            guard text.count == 4, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(text), (1888...2200).contains(number) else { return nil }
            return number
        }
        guard (1...2).contains(parts.count), let start = year(parts[0]) else { return nil }
        if parts.count == 2, !parts[1].isEmpty {
            guard let end = year(parts[1]), end >= start else { return nil }
        }
        return start
    }

    private static func structured(_ raw: String) -> [String: HarnessValue]? {
        guard raw.utf8.count <= 8192 else { return nil }
        let data = Data(raw.utf8)
        guard (try? HarnessJSON.checkUniqueKeys(data)) != nil else { return nil }
        return (try? JSONDecoder().decode(HarnessValue.self, from: data))?.object
    }

    private static func mediaLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 120,
              value.allSatisfy({ $0.isLetter || $0.isNumber || " -'’&:.,!?()".contains($0) }) else { return nil }
        return value
    }

    /// A reported alternative is an offer, never evidence of playback or consent.
    private static func languageOffer(_ raw: String, arguments: [String: ConversationValue], language: Language) -> String? {
        guard raw.utf8.count <= 8192 else { return nil }
        let data = Data(raw.utf8)
        guard (try? HarnessJSON.checkUniqueKeys(data)) != nil,
              let value = try? JSONDecoder().decode(HarnessValue.self, from: data),
              let object = value.object,
              object["outcome"] == .string("alternative_available"),
              object["playback_started"] == .bool(false),
              object["requires_language_confirmation"] == .bool(true),
              case .array(let alternatives) = object["available_alternatives"],
              (1...4).contains(alternatives.count),
              let first = alternatives.first?.object,
              first["ready"] == .bool(true), first["audio_verified"] == .bool(true),
              let title = first["series"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 120,
              title.allSatisfy({ $0.isLetter || $0.isNumber || " -'’&:.,!?()".contains($0) }),
              case .integer(let season) = first["season"], (1...999).contains(season),
              case .integer(let episode) = first["episode"], (1...9999).contains(episode),
              let code = first["audio_language"]?.string,
              let offered = languageName(code, language: language) else { return nil }
        let requestedArgument: String?
        if case .string(let code) = arguments["audio_language"] { requestedArgument = code }
        else { requestedArgument = nil }
        let declared = object["requested_audio_language"]?.string
        if let requestedArgument, requestedArgument != "auto", let declared,
           requestedArgument != declared { return nil }
        let requested = declared ?? requestedArgument
        guard requested != code else { return nil }
        let unavailable = requested.flatMap { languageName($0, language: language) }
        if language == .de {
            let opening = unavailable.map { "Auf \($0) habe ich dafür nichts Abspielbares gefunden. " } ?? ""
            return opening + "Ich kann dir „\(title)“, Staffel \(season), Folge \(episode) auf \(offered) anbieten. Soll ich diese Folge auf \(offered) starten?"
        }
        let opening = unavailable.map { "I couldn't find a playable result in \($0). " } ?? ""
        return opening + "I can offer \"\(title)\", season \(season), episode \(episode) in \(offered). Shall I start this episode in \(offered)?"
    }

    private static func languageName(_ code: String, language: Language) -> String? {
        let names = language == .de
            ? ["de": "Deutsch", "en": "Englisch", "es": "Spanisch", "it": "Italienisch", "fr": "Französisch"]
            : ["de": "German", "en": "English", "es": "Spanish", "it": "Italian", "fr": "French"]
        return names[code]
    }

    private static func plainFailure(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 500,
              !value.contains(where: { "{}[]`\n\r".contains($0) }), !value.contains("://"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value.lowercased()
    }

    private static func needsClarification(_ raw: String) -> Bool {
        guard let lower = plainFailure(raw) else { return false }
        return ["nicht eindeutig", "not uniquely", "ambiguous", "not unique"].contains(where: lower.contains)
    }

    private static func reportsNoPlayableResult(_ raw: String) -> Bool {
        guard let lower = plainFailure(raw) else { return false }
        return ["kein abspielbereiter treffer", "kein abspielbarer treffer", "keinen abspielbaren treffer",
                "no playable", "no ready stream", "not ready for playback"].contains(where: lower.contains)
    }

    /// A returned label is data, never speech instructions or raw service output.
    private static func label(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80,
              text.allSatisfy({ $0.isLetter || $0.isNumber || " -'’".contains($0) }) else { return nil }
        return text
    }

    private static func location(_ area: String) -> String {
        let lower = area.lowercased()
        if ["küche", "garage", "diele", "kammer"].contains(where: lower.hasSuffix) { return "In der \(area)" }
        if lower.hasSuffix("terrasse") { return "Auf der \(area)" }
        if lower.hasSuffix("balkon") { return "Auf dem \(area)" }
        if ["zimmer", "büro", "bad", "studio", "atelier", "flur", "keller", "garten"].contains(where: lower.hasSuffix) { return "Im \(area)" }
        return "Im Bereich \(area)"
    }

    static func variant(for operation: ConversationOperationID) -> Int {
        operation.rawValue.utf8.reduce(0) { ($0 * 31 + Int($1)) % 3 }
    }
}
