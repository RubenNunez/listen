import CryptoKit
import Foundation

/// Topic-scoped text adapter. Audio and external actions are separate capabilities.
struct RouterModelClient: ModelClient {
    let session: RouterModelSession

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task { await session.begin(id: id, model: model, system: system, user: user, continuation: continuation) }
            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                task.cancel()
                Task { await session.cancel(id: id) }
            }
        }
    }
}

actor RouterModelSession {
    private let rpc: any RouterRPC
    private let topic: UUID
    private let tool: Listen_Router_V1_Tool
    private var remembered: [String: String] = [:]
    private var flights: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var invalidated = false
    private let failed: @Sendable (RouterFailure) async -> Void

    init(rpc: any RouterRPC, topic: UUID, tool: Listen_Router_V1_Tool = .claude,
         failed: @escaping @Sendable (RouterFailure) async -> Void = { _ in }) {
        self.rpc = rpc
        self.topic = topic
        self.tool = tool
        self.failed = failed
    }

    // The wrapper's request identity also permits cancellation before begin reaches this actor.
    func begin(id: UUID, model: String, system: String, user: String,
               continuation: AsyncThrowingStream<ModelChunk, Error>.Continuation) {
        if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
        guard !invalidated else { continuation.finish(throwing: RouterFailure.unpaired); return }
        let key = SHA256.hash(data: Data("\(model)\u{0}\(system)".utf8)).map { String(format: "%02x", $0) }.joined()
        let previous = flights[key]?.task
        previous?.cancel()
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
            await perform(model: model, system: system, user: user, continuation: continuation)
            if flights[key]?.id == id { flights[key] = nil }
        }
        flights[key] = (id, task)
    }

    func cancel(id: UUID) {
        flights.values.first(where: { $0.id == id })?.task.cancel()
    }

    func invalidate() {
        invalidated = true
        for flight in flights.values { flight.task.cancel() }
    }

    private func perform(model: String, system: String, user: String,
                         continuation: AsyncThrowingStream<ModelChunk, Error>.Continuation) async {
        var opened: String?
        var failure: RouterFailure?
        do {
            try Task.checkCancellation()
            let status = try await rpc.status()
            try Task.checkCancellation()
            guard status.tools.contains(where: { $0.tool == tool && $0.found && $0.enabled && $0.signedIn != .no }) else {
                throw RouterFailure.disabledTool
            }
            let upstream = model.hasPrefix("router/") ? String(model.dropFirst(7)) : model
            let key = SHA256.hash(data: Data("\(tool.rawValue)\u{0}\(upstream)\u{0}\(system)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            var request = Listen_Router_V1_OpenSessionRequest()
            request.topicID = topic.uuidString
            request.tool = tool
            request.role = "listen-main"
            request.model = upstream
            request.system = system
            request.sessionID = remembered[key] ?? ""
            let response = try await rpc.open(request)
            guard !response.sessionID.isEmpty else { throw RouterFailure.invalidResponse }
            opened = response.sessionID
            remembered[key] = response.sessionID
            try Task.checkCancellation()
            var ended = false
            for try await event in rpc.ask(session: response.sessionID, text: user) {
                try Task.checkCancellation()
                switch event.kind {
                case .text(let text): continuation.yield(.text(text))
                case .source(let source):
                    if source.utf8.count <= 4096, let url = URL(string: source), url.user == nil, url.password == nil,
                       ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        continuation.yield(.source(source))
                    }
                case .usage(let usage):
                    if usage.costUsd.isFinite, usage.costUsd >= 0 { continuation.yield(.cost(usage.costUsd)) }
                    if usage.inputTokens <= UInt64(Int.max), usage.outputTokens <= UInt64(Int.max) {
                        let input = Int(usage.inputTokens), output = Int(usage.outputTokens)
                        if !input.addingReportingOverflow(output).overflow {
                            continuation.yield(.usage(.init(input: input, output: output)))
                        }
                    }
                case .step: break // Tool details may contain private local paths; not card text.
                case .end: ended = true
                case .failure(let error):
                    switch error.kind {
                    case .cancelled: throw RouterFailure.cancelled
                    case .limit: throw RouterFailure.limit
                    default: throw RouterFailure.remote
                    }
                case nil: throw RouterFailure.invalidResponse
                }
                if ended { break }
            }
            guard ended else { throw RouterFailure.interrupted }
        } catch { failure = Task.isCancelled ? .cancelled : RouterConnection.failure(error) }
        if let opened {
            // Cleanup must run even when the turn was cancelled, before its successor opens.
            let rpc = rpc
            await Task.detached { try? await rpc.close(session: opened) }.value
        }
        if let failure {
            await failed(failure)
            continuation.finish(throwing: failure)
        } else { continuation.finish() }
    }
}
