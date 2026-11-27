import Foundation

/// Asks a model through OpenAI's Responses API with the user's ChatGPT plan
/// ("Sign in with ChatGPT"). The request follows the limits of that route:
/// streamed, not stored, the system text as `instructions`, and none of the
/// fields the route rejects (no token limit, no temperature).
///
/// Built from the documentation; the parsing is unit-tested. No request was
/// made yet: that needs a signed-in account.
struct ResponsesClient: ModelClient {
    struct Failure: ModelFailure, Equatable {
        let status: Int
        let code: String
        var reason: String { code.isEmpty ? "HTTP \(status)" : code }

        /// The plan's or the app's limit is reached; the user manages that in ChatGPT's settings.
        var isUsageLimit: Bool { code == "subscription_sharing_usage_limit_exceeded" }
    }

    /// Where the access token comes from; replaced in tests.
    var token: @Sendable () async throws -> String = { try await ChatGPTSession.shared.accessToken() }

    /// Added to a model's name to let it search the web: "chatgpt/gpt-x+web".
    static let web = "+web"
    /// The same for a spoken turn: the model may search, and is still asked for little
    /// reasoning, because most turns need no search and must not answer slower for it.
    static let quickWeb = "+web.quick"

    /// Whether the service takes a request for little reasoning. A draft has to be fast, and
    /// most of the wait for its first word is the model thinking before it writes. Set to
    /// false the first time the service refuses the field, and not sent again after that.
    nonisolated(unsafe) static var takesEffort = true
    /// The same for little reasoning together with web search, which the service may refuse
    /// by itself. Not exercised against the service when this was written.
    nonisolated(unsafe) static var takesEffortWithWeb = true

    static func body(model: String, system: String, user: String, quick: Bool) -> [String: Any] {
        var body = body(model: model, system: system, user: user)
        // A research request keeps its own depth: it has to decide what to look up.
        let asked = body["tools"] == nil ? takesEffort : model.hasSuffix(quickWeb) && takesEffortWithWeb
        // A complex-task Astra route keeps the provider's default reasoning depth.
        // Do not force the fast-writer setting onto that lane.
        if quick, asked, !(body["model"] as? String ?? "").contains("astra") { body["reasoning"] = ["effort": "low"] }
        return body
    }

    static func body(model: String, system: String, user: String) -> [String: Any] {
        // Without the "chatgpt/" in front that routes the request here.
        var name = String(model.split(separator: "/").last ?? Substring(model))
        var body: [String: Any] = [
            "instructions": system,
            "input": [["role": "user", "content": user]],
            "store": false,
            "stream": true,
        ]
        for suffix in [quickWeb, web] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            body["tools"] = [["type": "web_search"]]
        }
        body["model"] = name
        return body
    }

    enum Event: Equatable {
        case text(String)
        case completed
        /// Web pages the model cited.
        case sources([String])
        /// The service began a web search for this response, or finished one.
        case webSearch(WebSearchStep)
        case failed(String)
        case other
    }

    /// One line of the event stream.
    static func event(inLine line: String) -> Event {
        guard line.hasPrefix("data:"),
            let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
            let type = json["type"] as? String
        else { return .other }
        switch type {
        case "response.output_text.delta": return .text(json["delta"] as? String ?? "")
        // One text message may end before a search and another follow afterwards.
        // Give the speech segmenter a boundary now, rather than holding the last
        // sentence until the final answer or joining two messages without a space.
        case "response.output_text.done": return .text("\n")
        case "response.completed": return .completed
        // "in_progress" opens a search call and "searching" follows for the same call.
        case "response.web_search_call.in_progress": return .webSearch(.started)
        case "response.web_search_call.completed": return .webSearch(.completed)
        case "response.output_text.annotation.added":
            let annotation = json["annotation"] as? [String: Any]
            return (annotation?["url"] as? String).map { .sources([$0]) } ?? .other
        case "response.failed", "response.incomplete", "error":
            let error = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any] ?? json
            return .failed(error["code"] as? String ?? type)
        default: return .other
        }
    }

    /// Every address cited anywhere in an event, such as the final one that
    /// carries the whole answer with its annotations.
    static func citedAddresses(inLine line: String) -> [String] {
        guard line.hasPrefix("data:"), let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) else { return [] }
        var found: [String] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if object["type"] as? String == "url_citation", let address = object["url"] as? String { found.append(address) }
                object.values.forEach(walk)
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        walk(json)
        return found
    }

    /// Terminal events may carry usage even when a response is incomplete or failed.
    static func tokenUsage(inLine line: String) -> TokenUsage? {
        guard line.hasPrefix("data:"),
              let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
              let type = json["type"] as? String,
              ["response.completed", "response.incomplete", "response.failed"].contains(type),
              let response = json["response"] as? [String: Any],
              let usage = response["usage"] as? [String: Any] else { return nil }
        return TokenUsage.read(usage, responses: true)
    }

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: ChatGPT.resource + "/responses")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let first = Self.body(model: model, system: system, user: user, quick: true)
                    request.httpBody = try JSONSerialization.data(withJSONObject: first)
                    var (bytes, response) = try await URLSession.shared.bytes(for: request)
                    var status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    // Only a request that carried the field can have been refused for it.
                    if status == 400, first["reasoning"] != nil {
                        // The field is not accepted here: ask again without it, and leave it out from now on.
                        if first["tools"] == nil { Self.takesEffort = false } else { Self.takesEffortWithWeb = false }
                        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, system: system, user: user))
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                        status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    }
                    guard (200..<300).contains(status) else {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                        throw Failure(status: status, code: (json?["error"] as? [String: Any])?["code"] as? String ?? "")
                    }
                    var completed = false
                    for try await line in bytes.lines {
                        if let usage = Self.tokenUsage(inLine: line) { continuation.yield(.usage(usage)) }
                        switch Self.event(inLine: line) {
                        case .text(let piece): continuation.yield(.text(piece))
                        case .completed:
                            completed = true
                            Self.citedAddresses(inLine: line).forEach { continuation.yield(.source($0)) }
                        case .sources(let addresses): addresses.forEach { continuation.yield(.source($0)) }
                        case .webSearch(let step): continuation.yield(.webSearch(step))
                        case .failed(let code): throw Failure(status: status, code: code)
                        case .other: break
                        }
                    }
                    // Only a completed response counts; a stream that just ends was cut off.
                    guard completed else { throw Failure(status: status, code: "incomplete") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
