import Foundation
import Observation

/// An accumulating local phrase bank. Usage means playback began, not that a
/// listener rated the phrase positively. It does not change model instructions.
@MainActor @Observable final class ConversationReactionBank {
    typealias Kind = ConversationReaction.Kind
    enum Origin: String, Codable { case bundled, owner, playedReply }
    struct Entry: Codable, Identifiable, Equatable {
        let text: String
        let language: Language
        let kind: Kind
        let origin: Origin
        var id: String { language.rawValue + ":" + text.lowercased() }
    }
    private struct Use: Codable { var count = 0; var last: Date? }
    private struct Saved: Codable {
        var version = 1
        var entries: [Entry]
        var uses: [String: Use]
        var recent: [String]
    }
    static let shared = ConversationReactionBank(file: defaultFile)
    private(set) var entries: [Entry]
    private(set) var lastError: String?
    @ObservationIgnored private let file: URL?
    private var uses: [String: Use] = [:]
    private var recent: [String] = []
    static let maximumCustom = 64

    private static var defaultFile: URL? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["LISTEN_REACTIONS_FILE"], path.contains("/runs/") { return URL(fileURLWithPath: path) }
        if env["LISTEN_TEST_NO_MICROPHONE"] == "1" { return nil }
        return URL.applicationSupportDirectory.appending(path: "Listen/ConversationReactions.json")
    }

    init(file: URL? = nil) {
        self.file = file
        entries = Language.allCases.flatMap { language in Kind.allCases.flatMap { kind in
            ConversationReaction.phrases(kind, language: language).map {
                Entry(text: $0, language: language, kind: kind, origin: .bundled)
            }
        } }
        if let file, let bytes = try? Data(contentsOf: file), bytes.count <= 128_000,
           let saved = try? JSONDecoder().decode(Saved.self, from: bytes), saved.version == 1 {
            for entry in saved.entries.prefix(Self.maximumCustom) where entry.origin != .bundled {
                if ConversationReaction.validated(entry.text, language: entry.language, kind: entry.kind) == entry.text,
                   !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
            }
            let allowed = Set(entries.map(\.id))
            uses = saved.uses.filter { allowed.contains($0.key) && $0.value.count >= 0 && $0.value.count < 1_000_000 }
            recent = Array(saved.recent.filter(allowed.contains).suffix(8))
        }
    }

    func choose(for input: String, language: Language, hasPrevious: Bool = false, researching: Bool = false) -> Entry {
        let kind = ConversationReaction.kind(for: input, hasPrevious: hasPrevious, researching: researching)
        let pool = entries.filter { $0.kind == kind && $0.language == language }
        let fresh = pool.filter { !recent.suffix(5).contains($0.id) }
        let candidates = fresh.isEmpty ? pool.filter { $0.id != recent.last } : fresh
        return (candidates.isEmpty ? pool : candidates).enumerated().min {
            let a = uses[$0.element.id]?.count ?? 0, b = uses[$1.element.id]?.count ?? 0
            return a == b ? $0.offset < $1.offset : a < b
        }!.element // Bundled entries guarantee a pool for every kind/language.
    }

    func used(_ text: String, language: Language) {
        guard let entry = entries.first(where: { $0.language == language && $0.text == text }) else { return }
        var use = uses[entry.id] ?? Use()
        use.count = min(use.count + 1, 999_999)
        use.last = Date()
        uses[entry.id] = use
        recent.removeAll { $0 == entry.id }; recent.append(entry.id)
        recent = Array(recent.suffix(8))
        save()
    }

    func count(for entry: Entry) -> Int { uses[entry.id]?.count ?? 0 }

    @discardableResult func add(_ raw: String, language: Language, kind: Kind, origin: Origin = .owner) -> Bool {
        guard let text = ConversationReaction.validated(raw, language: language, kind: kind),
              entries.filter({ $0.origin != .bundled }).count < Self.maximumCustom else { return false }
        let entry = Entry(text: text, language: language, kind: kind, origin: origin)
        guard !entries.contains(where: { $0.id == entry.id }) else { return false }
        entries.append(entry); save(); return true
    }

    /// Harvest only a complete, generic opening from an actually finished reply.
    /// Fact-bearing sentences and canceled/partial generations never belong here.
    @discardableResult func accumulate(from playedReply: String, language: Language,
        kind: Kind, researchObserved: Bool = false) -> Bool {
        guard let end = playedReply.firstIndex(where: { ".!?".contains($0) }), playedReply[end] == "." else { return false }
        let candidate = String(playedReply[...end])
        let scope = kind == .research && !researchObserved ? .neutral : kind
        guard let safe = ConversationReaction.validated(candidate, language: language, kind: scope) else { return false }
        let added = add(safe, language: language, kind: scope, origin: .playedReply)
        used(safe, language: language)
        return added
    }

    func remove(_ entry: Entry) {
        guard entry.origin != .bundled else { return }
        entries.removeAll { $0.id == entry.id }
        uses[entry.id] = nil; recent.removeAll { $0 == entry.id }; save()
    }

    private func save() {
        guard let file else { return }
        do {
            let saved = Saved(entries: entries.filter { $0.origin != .bundled }, uses: uses, recent: recent)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: file, options: .atomic)
            var location = file, values = URLResourceValues(); values.isExcludedFromBackup = true
            try? location.setResourceValues(values)
            lastError = nil
        } catch { lastError = "The reaction collection could not be saved on this device." }
    }
}
