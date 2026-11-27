import Foundation
import CoreFoundation

/// Portable configuration only. No topic identity, audio, files, credentials or grants.
struct SetupPackage {
    let topic: Topic
    let system: SystemPackage
    static let maximumBytes = 600_000

    init(topic: Topic, system: SystemPackage, includeBriefing: Bool = false) {
        var copy = topic
        copy.id = UUID(); copy.archived = false; copy.evaluation = false
        if !includeBriefing { copy.notes = "" }
        self.topic = copy
        self.system = system
    }

    private var topicObject: [String: Any] {
        ["name": topic.name, "language": topic.language.rawValue, "briefing": topic.notes,
         "links": topic.links, "repositories": topic.repositories]
    }

    func data() throws -> Data {
        let value: [String: Any] = ["format": "listen-setup", "version": 1, "topic": topicObject,
            "system": try JSONSerialization.jsonObject(with: system.data())]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        guard data.count <= Self.maximumBytes else { throw Self.failure("This setup is too large to transfer.") }
        return data
    }

    /// Compact overrides against a fingerprinted shipped definition. A changed baseline
    /// is rejected rather than silently changing prompts; the full file remains portable.
    func link() throws -> URL {
        let base = try Self.baseline(system.system.isVoiceAssistant ? "voice-assistant" : "interview")
        let complete = try JSONSerialization.jsonObject(with: system.data()) as! [String: Any]
        let reference = try JSONSerialization.jsonObject(with: base.data()) as! [String: Any]
        let value: [String: Any] = ["format": "listen-setup-link", "version": 1, "topic": topicObject,
            "base": base.system.id, "fingerprint": HarnessJSON.hash(try base.data()), "overrides": Self.delta(complete, reference)]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(); url.scheme = "listen"; url.host = "setup"
        url.queryItems = [URLQueryItem(name: "p", value: payload)]
        guard let result = url.url, result.absoluteString.utf8.count <= 2800 else {
            throw Self.failure("This setup is too large for a reliable QR code. Share its JSON file instead.")
        }
        return result
    }

    static func read(link: URL) throws -> SetupPackage {
        guard link.absoluteString.utf8.count <= 4096, let url = URLComponents(url: link, resolvingAgainstBaseURL: false),
              url.scheme == "listen", url.host == "setup", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let items = url.queryItems, items.count == 1, items[0].name == "p", let payload = items[0].value,
              payload.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { throw failure("This setup link is invalid.") }
        var encoded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw failure("This setup link is invalid.") }
        let root = try object(data)
        guard Set(root.keys) == ["format", "version", "topic", "base", "fingerprint", "overrides"],
              root["format"] as? String == "listen-setup-link", version(root["version"]),
              let id = root["base"] as? String, let fingerprint = root["fingerprint"] as? String,
              let overrides = root["overrides"] as? [String: Any] else { throw failure("This setup-link version is not supported.") }
        let base = try baseline(id)
        guard fingerprint == HarnessJSON.hash(try base.data()) else {
            throw failure("This code uses a different system baseline. Ask for the full setup JSON file instead.")
        }
        let reference = try JSONSerialization.jsonObject(with: base.data()) as! [String: Any]
        let expanded: [String: Any] = ["format": "listen-setup", "version": 1, "topic": root["topic"]!,
                                     "system": merge(reference, overrides)]
        return try read(JSONSerialization.data(withJSONObject: expanded))
    }

    static func read(_ data: Data) throws -> SetupPackage {
        let root = try object(data)
        guard Set(root.keys) == ["format", "version", "topic", "system"], root["format"] as? String == "listen-setup", version(root["version"]),
              let raw = root["topic"] as? [String: Any], Set(raw.keys) == ["name", "language", "briefing", "links", "repositories"],
              let name = raw["name"] as? String, (1...100).contains(name.count), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let language = (raw["language"] as? String).flatMap(Language.init(rawValue:)),
              let notes = raw["briefing"] as? String, notes.count <= 8000,
              let links = raw["links"] as? [String], links.count <= 20, links.allSatisfy({ $0.count <= 2048 && Topic.isValidLink($0) }),
              let repositories = raw["repositories"] as? [String], repositories.count <= 20, repositories.allSatisfy(Topic.isValidRepository),
              let system = root["system"] as? [String: Any] else { throw failure("This is not a supported Listen setup file.") }
        let package = try SystemPackage.read(JSONSerialization.data(withJSONObject: system))
        var topic = Topic(name: name); topic.language = language; topic.notes = notes
        topic.links = links; topic.repositories = repositories; topic.system = package.system.id
        return SetupPackage(topic: topic, system: package, includeBriefing: true)
    }

    static func read(file: URL) throws -> SetupPackage {
        guard file.isFileURL else { throw failure("Choose a local setup file.") }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else { throw failure("This setup file is too large or unreadable.") }
        return try read(Data(contentsOf: file))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes else { throw failure("This setup is too large to import.") }
        try HarnessJSON.checkUniqueKeys(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("The setup must be a JSON object.") }
        return root
    }
    private static func version(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
        return value.doubleValue == 1
    }
    private static func baseline(_ id: String) throws -> SystemPackage {
        guard ["interview", "voice-assistant"].contains(id), let system = ListenSystem.builtIns.first(where: { $0.id == id }) else {
            throw failure("This setup baseline is unavailable in this app.")
        }
        return SystemPackage(system: system, defaults: SystemConfig())
    }
    private static func delta(_ value: [String: Any], _ base: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, item) in value {
            if let item = item as? [String: Any], let previous = base[key] as? [String: Any] {
                let changes = delta(item, previous)
                if !changes.isEmpty { result[key] = changes }
            } else if let previous = base[key], NSDictionary(dictionary: ["v": item]).isEqual(to: ["v": previous]) {
                continue
            } else { result[key] = item }
        }
        // Optional keys removed from a base are represented explicitly and validated
        // after expansion. They cannot remove required schema fields successfully.
        for key in base.keys where value[key] == nil { result[key] = NSNull() }
        return result
    }
    private static func merge(_ base: [String: Any], _ changes: [String: Any]) -> [String: Any] {
        var result = base
        for (key, item) in changes {
            if item is NSNull { result[key] = nil }
            else if let item = item as? [String: Any], let previous = result[key] as? [String: Any] { result[key] = merge(previous, item) }
            else { result[key] = item }
        }
        return result
    }
    private static func failure(_ message: String) -> SystemPackageError { SystemPackageError(message: message) }
}
