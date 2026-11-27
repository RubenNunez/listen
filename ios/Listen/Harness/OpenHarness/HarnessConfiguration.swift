import CryptoKit
import Foundation

/// Portable configuration values. Keep integers exact, including evidence/revision IDs.
/// This type carries data only; it never evaluates text or looks up credentials.
enum HarnessValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), unsigned(UInt64), number(Double), string(String)
    case array([HarnessValue]), object([String: HarnessValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([HarnessValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: HarnessValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .unsigned(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }

    var object: [String: HarnessValue]? { if case .object(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
}

enum HarnessJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One source for forms and file editing. The production loader does not activate v2 yet.
/// The compatibility payload is temporary: it contains no second copy of any prompt.
struct HarnessConfiguration: Codable, Equatable, Sendable {
    var version = 2
    var revision: UInt64 = 1
    var activeProfile: String
    var voice: [String: HarnessValue] = [:]
    var scheduler: [String: HarnessValue] = [:]
    var landing: [String: HarnessValue] = [:]
    var connections: [String: HarnessConnection] = [:]
    var models: [String: HarnessModel] = [:]
    var prompts: [String: HarnessPrompt] = [:]
    var roles: [String: HarnessRole] = [:]
    var flows: [String: HarnessFlow] = [:]
    var profiles: [String: HarnessProfile] = [:]
    var compatibility: HarnessLegacySettings?

    /// Unknown structural fields fail instead of silently discarding an owner's edit.
    /// Opaque core settings and compatibility values remain lossless dictionaries.
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw HarnessProblem("$", "configuration exceeds 2 MB") }
        try HarnessJSON.checkUniqueKeys(data)
        let document: Self
        do { document = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw HarnessProblem("$", "invalid JSON, missing field or incorrect value type") }
        let raw = try JSONDecoder().decode(HarnessValue.self, from: data)
        let known = try JSONDecoder().decode(HarnessValue.self, from: HarnessJSON.encode(document))
        try rejectUnknown(raw, known: known, path: "$")
        try document.validate()
        return document
    }

    private static func rejectUnknown(_ raw: HarnessValue, known: HarnessValue, path: String) throws {
        switch (raw, known) {
        case (.object(let fields), .object(let supported)):
            for key in fields.keys.sorted() {
                guard let below = supported[key] else {
                    throw HarnessProblem(path + "." + key, "unsupported field; omit optional fields instead of null")
                }
                try rejectUnknown(fields[key]!, known: below, path: path + "." + key)
            }
        case (.array(let items), .array(let supported)):
            for (index, item) in items.enumerated() where index < supported.count {
                try rejectUnknown(item, known: supported[index], path: path + "[\(index)]")
            }
        default: break
        }
    }
}

struct HarnessProblem: Error, Equatable, Sendable, CustomStringConvertible {
    let path: String
    let reason: String
    init(_ path: String, _ reason: String) { self.path = path; self.reason = reason }
    var description: String { "\(path): \(reason)" }
}

struct HarnessPrompt: Codable, Equatable, Sendable {
    var text: String
    /// Explicit named inputs; literal braces in prose/code are otherwise untouched.
    var inputs: [String] = []
}

struct HarnessConnection: Codable, Equatable, Sendable {
    var label: String
    var vendor: String
    var enabled = false
    var endpoint: Endpoint
    var authentication: Authentication
    var operations: [String: Operation]

    struct Endpoint: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case http, inProcess, managedAccount, pairedRouter }
        var kind: Kind
        var baseURL: String?
        var runtime: String?
        var bindingSlot: String?
    }
    struct Authentication: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case none, apiKey, managedAccount, routerPairing }
        var kind: Kind
        /// A local slot name, never a key, token, cookie, password or auth header.
        var slot: String?
    }
    struct Operation: Codable, Equatable, Sendable {
        var adapter: Adapter
        var path: String?
    }
    enum Adapter: String, Codable, Sendable {
        case chat = "openai.chat.v1", responses = "openai.responses.v1"
        case messages = "anthropic.messages.v1", systemOne = "systemone.v1"
        case decisions = "openai.decisions.v1", chatGPT = "chatgpt.plan.v1"
        case apple = "apple.foundation.v1", router = "listen.router.v1"
    }
}

enum HarnessExecution: String, Codable, Sendable { case onDevice, ownerHost, providerCloud, unknown }
enum HarnessModelKind: String, Codable, Sendable { case generation, decision }
enum HarnessCapability: String, Codable, Sendable {
    case text, stream, jsonSchema, sources, webSearch, noul, choice, probabilities, judgement, topicSession
}

struct HarnessModel: Codable, Equatable, Sendable {
    var label: String
    var connection: String
    var operation: String
    /// Opaque upstream ID, including slashes. Never split it to pick a recipient.
    var upstreamID: String
    var kind: HarnessModelKind
    var capabilities: [HarnessCapability]
    var execution: HarnessExecution
}

struct HarnessRole: Codable, Equatable, Sendable {
    enum DecisionPolicy: String, Codable, Sendable { case providerProbabilities, categoricalJudgement }
    enum Unavailable: String, Codable, Sendable { case skip, builtin, discardCandidate }
    var label: String
    var kind: HarnessModelKind
    var model: String
    var prompts: [String]
    var context: [HarnessContextField] = []
    var fallbacks: [String] = []
    var requires: [HarnessCapability] = []
    var timeoutMilliseconds: Int
    var maxOutputTokens: Int?
    var decisionPolicy: DecisionPolicy?
    var onUnavailable: Unavailable
}

enum HarnessContextField: String, Codable, Sendable {
    case transcript, blocks, briefing, notes, material, candidate
}

struct HarnessFlow: Codable, Equatable, Sendable {
    var label: String
    var nodes: [String: Node]
    struct Node: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case context, invoke, branch, join, publish, currentListen }
        enum Join: String, Codable, Sendable { case all, firstValid }
        var kind: Kind
        var role: String?
        var inputs: [String: String] = [:]
        var after: [String] = []
        var context: [HarnessContextField] = []
        var condition: Condition?
        var join: Join?
    }
    /// Conditions inspect typed decision fields; they contain no executable expression.
    struct Condition: Codable, Equatable, Sendable {
        enum Comparison: String, Codable, Sendable { case equal, atLeast, atMost }
        var node: String
        var field: String
        var comparison: Comparison
        var value: HarnessValue
    }
}

struct HarnessProfile: Codable, Equatable, Sendable {
    var label: String
    var evidenceFlow: String
    var actionFlow: String?
    var endFlow: String?
    var allowedExecution: [HarnessExecution]
    var limits: Limits?
    struct Limits: Codable, Equatable, Sendable {
        var concurrentCalls: Int
        var callsPerSession: Int
        var fallbacksPerRequest: Int
    }
}

/// Only values still consumed by the old engine. Prompt text lives solely in `prompts`.
struct HarnessLegacySettings: Codable, Equatable, Sendable {
    var agents: [String: HarnessValue]
    var modelSelection: [String: HarnessValue]
    var extra: [String: HarnessValue] = [:]
}
