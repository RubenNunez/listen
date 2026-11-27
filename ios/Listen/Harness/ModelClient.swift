import Foundation

/// One piece of a model's streamed reply.
enum ModelChunk: Sendable, Equatable {
    case text(String)
    /// What the request cost, in US dollars, when the provider reports it.
    case cost(Double)
    /// The address of a web page the model used, when it searched the web.
    case source(String)
    /// Provider-reported cumulative usage for this request, including hidden output tokens.
    case usage(TokenUsage)
    /// The provider reports a web search of its own for this request: that one began, or
    /// that one is done. Only a provider's event becomes this chunk, never a guess from text.
    case webSearch(WebSearchStep)
}

enum WebSearchStep: Sendable, Equatable {
    case started, completed
}

/// Input includes cached tokens; output includes reasoning tokens. Neither is added twice.
struct TokenUsage: Sendable, Equatable {
    var input: Int
    var output: Int
    var cachedInput: Int?
    var reasoningOutput: Int?
    var total: Int { input + output }

    static func read(_ object: [String: Any], responses: Bool) -> TokenUsage? {
        let inputKey = responses ? "input_tokens" : "prompt_tokens"
        let outputKey = responses ? "output_tokens" : "completion_tokens"
        guard let input = object[inputKey] as? Int, input >= 0,
              let output = object[outputKey] as? Int, output >= 0,
              !input.addingReportingOverflow(output).overflow else { return nil }
        let cached = (object[inputKey + "_details"] as? [String: Any])?["cached_tokens"] as? Int
        let reasoning = (object[outputKey + "_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        return TokenUsage(input: input, output: output,
                          cachedInput: cached.flatMap { (0...input).contains($0) ? $0 : nil },
                          reasoningOutput: reasoning.flatMap { (0...output).contains($0) ? $0 : nil })
    }

    var fields: [String: Any] {
        var fields: [String: Any] = ["input_tokens": input, "output_tokens": output]
        if let cachedInput { fields["input_tokens_details"] = ["cached_tokens": cachedInput] }
        if let reasoningOutput { fields["output_tokens_details"] = ["reasoning_tokens": reasoningOutput] }
        return fields
    }
}

/// Reports each actual model call once, including gates, empty answers and failures.
/// Repeated cumulative usage chunks replace each other rather than being summed.
struct UsageReportingClient: ModelClient {
    struct Start: Sendable {
        var id: String
        var model: String
        var instructions: String
        var input: String

        var fields: [String: Any] {
            let route = model.hasPrefix("local/") ? "on device" : model.hasPrefix("chatgpt/") ? "ChatGPT plan"
                : model.hasPrefix("router/") ? "Listen Router" : "API key"
            return ["request_id": id, "model": model, "route": route, "instructions": instructions, "input": input]
        }
    }

    struct Report: Sendable {
        var id: String
        var model: String
        var usage: TokenUsage?
        var outcome: String
        var response: String?
        var sources: [String] = []
        var costUSD: Double?
        var failure: String?
        /// Receipt of the first nonempty text chunk, not necessarily useful text.
        var firstTextSeconds: Double? = nil

        var fields: [String: Any] {
            var fields = usage?.fields ?? [:]
            fields["request_id"] = id
            fields["model"] = model
            fields["outcome"] = outcome
            if let response { fields["response"] = response }
            if !sources.isEmpty { fields["sources"] = sources }
            if let costUSD { fields["cost_usd"] = costUSD }
            if let failure { fields["failure"] = failure }
            if let firstTextSeconds { fields["first_text_seconds"] = firstTextSeconds }
            return fields
        }
    }

    var base: any ModelClient
    /// Only model text is recorded: never HTTP headers, authentication or provider internals.
    var started: (@Sendable (Start) async -> Void)? = nil
    var report: @Sendable (Report) async -> Void

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let id = UUID().uuidString
                var usage: TokenUsage?
                var response = ""
                var sources: [String] = []
                var cost: Double?
                var firstTextSeconds: Double?
                if let started { await started(Start(id: id, model: model, instructions: system, input: user)) }
                let began = Date()
                do {
                    try Task.checkCancellation()
                    for try await chunk in base.stream(model: model, system: system, user: user, maxTokens: maxTokens) {
                        if case .text(let text) = chunk, !text.isEmpty, firstTextSeconds == nil {
                            firstTextSeconds = Date().timeIntervalSince(began)
                        }
                        if started != nil {
                            switch chunk {
                            case .text(let text): response += text
                            case .source(let url): if !sources.contains(url) { sources.append(url) }
                            case .cost(let value): cost = value
                            case .usage, .webSearch: break
                            }
                        }
                        if case .usage(let value) = chunk { usage = value } else { continuation.yield(chunk) }
                    }
                    await report(Report(id: id, model: model, usage: usage,
                                        outcome: Task.isCancelled ? "cancelled" : "completed",
                                        response: started == nil ? nil : response, sources: sources, costUSD: cost, firstTextSeconds: firstTextSeconds))
                    continuation.finish()
                } catch {
                    // Error descriptions can contain request details. Keep only a provider's
                    // explicit reason, or the error domain/code, never a raw HTTP response.
                    let failure = (error as? any ModelFailure)?.reason ?? "\((error as NSError).domain) (\((error as NSError).code))"
                    await report(Report(id: id, model: model, usage: usage,
                                        outcome: Task.isCancelled ? "cancelled" : "failed",
                                        response: started == nil ? nil : response, sources: sources, costUSD: cost, failure: failure, firstTextSeconds: firstTextSeconds))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// An error of a model connection that can say in a few words what went wrong.
protocol ModelFailure: Error {
    var reason: String { get }
}

/// A connection that can ask a model and stream its reply.
protocol ModelClient: Sendable {
    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error>
}

/// A provider that speaks the "chat completions" protocol with streaming:
/// OpenRouter (one account, models of many providers), and OpenAI, DeepSeek
/// and Gemini directly with the user's own key. Requests are billed to the user.
///
/// OpenRouter was exercised once from the Mac check tool. The direct providers
/// were not: no key was available when this was written.
struct OpenRouterClient: ModelClient {
    struct Failure: Error, Equatable { let status: Int }

    enum Provider: Sendable {
        case openRouter, openAI, deepSeek, gemini

        var endpoint: URL {
            switch self {
            case .openRouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")!
            case .deepSeek: URL(string: "https://api.deepseek.com/chat/completions")!
            case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
            }
        }
    }

    let key: String
    var provider = Provider.openRouter

    init(key: String) { self.key = key }

    init(key: String, provider: Provider) {
        self.key = key
        self.provider = provider
    }

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: provider.endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: Any] = [
                        // Directly at a provider the model has no "provider/" in front.
                        "model": provider == .openRouter ? model : String(model.split(separator: "/").last ?? Substring(model)),
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user],
                        ],
                    ]
                    switch provider {
                    case .openRouter:
                        body["max_tokens"] = maxTokens
                        body["temperature"] = 0.3
                        body["usage"] = ["include": true]
                    case .openAI:
                        // OpenAI's newer models take this name and no temperature.
                        body["max_completion_tokens"] = maxTokens
                        body["stream_options"] = ["include_usage": true]
                    case .deepSeek, .gemini:
                        body["max_tokens"] = maxTokens
                        body["temperature"] = 0.3
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { throw Failure(status: status) }
                    for try await line in bytes.lines {
                        for chunk in Self.chunks(inLine: line) { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses one line of the server-sent event stream.
    static func chunks(inLine line: String) -> [ModelChunk] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var chunks: [ModelChunk] = []
        if let choices = object["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
            let text = delta["content"] as? String, !text.isEmpty
        {
            chunks.append(.text(text))
        }
        if let usage = object["usage"] as? [String: Any], let cost = usage["cost"] as? Double {
            chunks.append(.cost(cost))
        }
        if let usage = object["usage"] as? [String: Any], let tokens = TokenUsage.read(usage, responses: false) {
            chunks.append(.usage(tokens))
        }
        return chunks
    }
}
