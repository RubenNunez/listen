import Foundation
import FoundationModels
#if canImport(UIKit)
import UIKit
#endif

/// Foundation Models snapshots contain the whole prefix, whereas ModelClient emits deltas.
struct LocalModelText {
    struct RewrittenSnapshot: Error {}
    private var previous = ""

    mutating func delta(_ snapshot: String) throws -> String {
        guard snapshot.utf8.starts(with: previous.utf8) else { throw RewrittenSnapshot() }
        let text = String(decoding: snapshot.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
        previous = snapshot
        return text
    }
}

/// Apple's language model on the device itself: free, private, and there
/// before any network answer. Small, so its facts are less reliable than a
/// cloud model's; it serves as the first, local layer.
struct LocalModelClient: ModelClient {
    static let model = "local/apple"

    struct Unavailable: Error {}

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { true } else { false }
    }

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard Self.isAvailable else { throw Unavailable() }
                    let session = LanguageModelSession(instructions: system)
                    let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens)
                    if await Self.hasForegroundWindow() {
                        var text = LocalModelText()
                        for try await snapshot in session.streamResponse(to: user, options: options) {
                            try Task.checkCancellation()
                            let delta = try text.delta(snapshot.content)
                            if !delta.isEmpty { continuation.yield(.text(delta)) }
                        }
                    } else {
                        // Apple recommends non-streaming generation in the background.
                        // The windowless CLI and native command-line tools retain this path.
                        let response = try await session.respond(to: user, options: options)
                        try Task.checkCancellation()
                        continuation.yield(.text(response.content))
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func hasForegroundWindow() async -> Bool {
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.connectedScenes.contains { scene in
                scene.activationState == .foregroundActive &&
                    (scene as? UIWindowScene)?.windows.contains(where: { !$0.isHidden }) == true
            }
        }
        #else
        false
        #endif
    }
}

/// Sends each request to the client that serves its model: names starting
/// with "local/" stay on the device; a provider the user attached directly
/// ("openai/…", "google/…", "deepseek/…") is asked directly; everything else
/// goes to the account that reaches all of them.
struct RoutedClient: ModelClient {
    var local: (any ModelClient)?
    var remote: (any ModelClient)?
    /// Clients by the part of the model name in front of the slash.
    var direct: [String: any ModelClient] = [:]

    struct NoRoute: Error {}

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        let prefix = String(model.split(separator: "/").first ?? "")
        let client = prefix == "local" ? local : (direct[prefix] ?? remote)
        guard let client else { return AsyncThrowingStream { $0.finish(throwing: NoRoute()) } }
        return client.stream(model: model, system: system, user: user, maxTokens: maxTokens)
    }
}
