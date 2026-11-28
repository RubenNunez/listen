import Foundation

/// Stable topic/tool prefixes precede growing dialogue; dictionary hash order must
/// not invalidate an otherwise reusable prompt prefix. All values are preserved.
enum VoiceTurnInput {
    static func encode(_ payload: HarnessValue) throws -> String {
        guard let fields = payload.object else { throw MCPFailure.invalidResponse }
        let prefix = ["topic", "voice", "public_web_search", "tools", "unavailableTools"]
        // Historical/context evidence must not trail the most recent dialogue.
        // This changes presentation order only, never the values or their authority.
        let tail = ["evidence", "preparation", "working_context", "recent_actions", "messages"]
        let keys = prefix.filter { fields[$0] != nil }
            + fields.keys.filter { !prefix.contains($0) && !tail.contains($0) }.sorted()
            + tail.filter { fields[$0] != nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "{" + (try keys.map { key in
            let name = String(decoding: try encoder.encode(key), as: UTF8.self)
            let value = String(decoding: try encoder.encode(fields[key]!), as: UTF8.self)
            return name + ":" + value
        }).joined(separator: ",") + "}"
    }
}

