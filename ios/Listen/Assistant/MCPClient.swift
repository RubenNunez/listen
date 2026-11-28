import Foundation

enum MCPRevision: String, Codable, CaseIterable, Sendable {
    case current = "2026-07-28"
    case legacy = "2025-11-25"
}

enum MCPFailure: Error, LocalizedError, Equatable {
    case endpoint, authentication, unavailable, unsupported, invalidResponse, tooLarge, remote
    var errorDescription: String? {
        switch self {
        case .endpoint: "Use HTTPS, or HTTP for a local network or loopback MCP server."
        case .authentication: "The MCP server requires a valid server token."
        case .unavailable: "The MCP server could not be reached."
        case .unsupported: "This MCP feature or tool schema is not supported by this version of Listen."
        case .invalidResponse: "The MCP server returned an invalid or incomplete response."
        case .tooLarge: "The MCP response exceeded the supported size."
        case .remote: "The MCP server refused the request."
        }
    }
}

struct MCPHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var data: Data
}

/// No redirects, shared cookies, credential-store login or automatic application retry.
private final class MCPRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct MCPHTTPTransport: Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: MCPRedirectPolicy(), delegateQueue: nil)
    }

    func send(_ request: URLRequest, responseID: String?) async throws -> MCPHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw MCPFailure.invalidResponse }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) {
            if let key = $1.key as? String, let value = $1.value as? String { $0[key.lowercased()] = value }
        }
        if response.statusCode == 202 { return .init(status: 202, headers: headers, data: Data()) }
        let mime = (headers["content-type"] ?? "").lowercased()
        guard mime.hasPrefix("application/json") || mime.hasPrefix("text/event-stream") else {
            if response.statusCode == 401 || response.statusCode == 403 { throw MCPFailure.authentication }
            throw MCPFailure.invalidResponse
        }
        var data = Data(), line = Data(), fields: [String] = []
        var count = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= 1_048_576 else { throw MCPFailure.tooLarge }
            if mime.hasPrefix("application/json") { data.append(byte); continue }
            if byte != 10 { line.append(byte); continue }
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
            line.removeAll(keepingCapacity: true)
            if text.hasPrefix("data:") {
                let value = text.dropFirst(5)
                fields.append(String(value.hasPrefix(" ") ? value.dropFirst() : value))
            } else if text.isEmpty, !fields.isEmpty {
                let payload = Data(fields.joined(separator: "\n").utf8)
                fields.removeAll(keepingCapacity: true)
                let object = try JSONDecoder().decode(HarnessValue.self, from: payload).object
                if object?["id"]?.string == responseID {
                    return .init(status: response.statusCode, headers: headers, data: payload)
                }
                // A server request needs a client feature that Listen did not advertise.
                if object?["id"] != nil, object?["method"] != nil { throw MCPFailure.unsupported }
            }
        }
        guard !mime.hasPrefix("text/event-stream") else { throw MCPFailure.invalidResponse }
        return .init(status: response.statusCode, headers: headers, data: data)
    }
}

actor MCPClient {
    typealias Exchange = @Sendable (URLRequest, String?) async throws -> MCPHTTPResponse
    typealias Observer = @Sendable (String, [String: String]) async -> Void
    private var observer: Observer?
    func observe(_ observer: @escaping Observer) { self.observer = observer }
    private let endpoint: URL
    private let revision: MCPRevision
    private let token: String?
    private let exchange: Exchange
    private var legacySession: String?
    private var initialized = false

    static func validEndpoint(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              let host = url.host, !host.isEmpty, url.absoluteString.utf8.count <= 2048 else { return false }
        return url.scheme == "https" || (url.scheme == "http" && LocalNetworkHost.accepts(host))
    }

    init(endpoint: URL, revision: MCPRevision = .current, token: String? = nil, exchange: Exchange? = nil) throws {
        guard Self.validEndpoint(endpoint) else { throw MCPFailure.endpoint }
        self.endpoint = endpoint
        self.revision = revision
        self.token = token
        let transport = MCPHTTPTransport()
        self.exchange = exchange ?? { try await transport.send($0, responseID: $1) }
    }

    private func rpc(_ method: String, params original: [String: HarnessValue] = [:], notification: Bool = false) async throws -> HarnessValue {
        let id = UUID().uuidString
        var fields = ["request_id": id, "method": method, "tool": original["name"]?.string ?? ""]
        if let arguments = original["arguments"], let data = try? JSONEncoder().encode(arguments) {
            fields["input"] = String(decoding: data, as: UTF8.self)
        }
        await observer?("mcp_request", fields)
        do {
            let value = try await exchangeRPC(method, params: original, notification: notification)
            fields["outcome"] = "completed"
            await observer?("mcp_result", fields)
            return value
        } catch {
            fields["outcome"] = Task.isCancelled ? "cancelled" : "unknown"
            await observer?("mcp_result", fields)
            throw error
        }
    }

    private func exchangeRPC(_ method: String, params original: [String: HarnessValue], notification: Bool) async throws -> HarnessValue {
        let id = notification ? nil : UUID().uuidString
        var params = original
        if revision == .current {
            params["_meta"] = .object([
                "io.modelcontextprotocol/protocolVersion": .string(revision.rawValue),
                "io.modelcontextprotocol/clientInfo": .object(["name": .string("Listen"), "version": .string("0.1.0")]),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
            ])
        }
        var body: [String: HarnessValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]
        if let id { body["id"] = .string(id) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(revision.rawValue, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let name = params["name"]?.string { request.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        if let legacySession { request.setValue(legacySession, forHTTPHeaderField: "Mcp-Session-Id") }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let response: MCPHTTPResponse
        do { response = try await exchange(request, id) }
        catch let error as MCPFailure { throw error }
        catch { throw MCPFailure.unavailable }
        if response.status == 401 || response.status == 403 { throw MCPFailure.authentication }
        guard (200..<300).contains(response.status) else { throw MCPFailure.remote }
        if notification { guard response.status == 202 else { throw MCPFailure.invalidResponse }; return .null }
        guard response.data.count <= 1_048_576 else { throw MCPFailure.tooLarge }
        try HarnessJSON.checkUniqueKeys(response.data)
        let object = try JSONDecoder().decode(HarnessValue.self, from: response.data).object
        guard object?["jsonrpc"] == .string("2.0"), object?["id"]?.string == id else { throw MCPFailure.invalidResponse }
        if object?["error"] != nil { throw MCPFailure.remote }
        guard let result = object?["result"], result.object?["inputRequests"] == nil else { throw MCPFailure.unsupported }
        if revision == .legacy, method == "initialize", let session = response.headers["mcp-session-id"] {
            guard !session.isEmpty, session.utf8.count <= 256, session.utf8.allSatisfy({ (33...126).contains($0) }) else { throw MCPFailure.invalidResponse }
            legacySession = session
        }
        return result
    }

    private func prepare() async throws {
        guard revision == .legacy, !initialized else { return }
        let result = try await rpc("initialize", params: [
            "protocolVersion": .string(revision.rawValue), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Listen"), "version": .string("0.1.0")]),
        ])
        guard result.object?["protocolVersion"] == .string(revision.rawValue) else { throw MCPFailure.unsupported }
        _ = try await rpc("notifications/initialized", notification: true)
        initialized = true
    }

    func listTools() async throws -> [MCPTool] {
        try await prepare()
        var tools: [MCPTool] = [], cursor: String?
        var seen = Set<String>()
        repeat {
            var params: [String: HarnessValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await rpc("tools/list", params: params)
            guard let object = result.object, case .array(let entries) = object["tools"] else { throw MCPFailure.invalidResponse }
            for entry in entries {
                let tool = try MCPTool.read(entry)
                guard seen.insert(tool.name).inserted, tools.count < 128 else { throw MCPFailure.invalidResponse }
                tools.append(tool)
            }
            let next = object["nextCursor"]?.string
            guard next != cursor || next == nil, next?.utf8.count ?? 0 <= 1024 else { throw MCPFailure.invalidResponse }
            cursor = next
        } while cursor != nil
        return tools
    }

    func call(_ tool: MCPTool, arguments: [String: ConversationValue]) async -> ConversationToolObservation {
        guard tool.accepts(arguments) else { return .completed(.failed(detail: "The tool arguments do not match its supported schema.")) }
        do {
            try await prepare()
            let result = try await rpc("tools/call", params: ["name": .string(tool.name), "arguments": .object(arguments.mapValues(\.harness))])
            guard let object = result.object, case .array(let content) = object["content"] else { return .unknown(.routeLost) }
            let text = content.compactMap { part -> String? in
                guard part.object?["type"] == .string("text") else { return nil }
                return part.object?["text"]?.string
            }.joined(separator: "\n")
            let detail = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }.prefix(2000))
            if object["isError"] == .bool(true) { return .completed(.failed(detail: detail.isEmpty ? "The tool reported an error." : detail)) }
            return .completed(.succeeded(detail: detail.isEmpty ? "The tool reported completion." : detail))
        } catch {
            // The request may have reached the service. Never retry or claim failure/rollback.
            return .unknown(.routeLost)
        }
    }
}

extension ConversationValue {
    var harness: HarnessValue {
        switch self {
        case .string(let value): .string(value)
        case .integer(let value): .integer(Int64(value))
        case .number(let value): .number(value)
        case .boolean(let value): .bool(value)
        case .array(let values): .array(values.map(\.harness))
        }
    }
    init?(harness: HarnessValue) {
        switch harness {
        case .string(let value): self = .string(value)
        case .integer(let value) where value >= Int64(Int.min) && value <= Int64(Int.max): self = .integer(Int(value))
        case .number(let value) where value.isFinite: self = .number(value)
        case .bool(let value): self = .boolean(value)
        case .array(let values) where values.count <= 64:
            var items: [ConversationValue] = []
            for value in values {
                if case .array = value { return nil }
                guard let item = ConversationValue(harness: value) else { return nil }
                items.append(item)
            }
            self = .array(items)
        default: return nil
        }
    }
}
