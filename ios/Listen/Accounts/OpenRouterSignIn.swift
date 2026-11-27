import CryptoKit
import Foundation
import Network

/// OpenRouter's OAuth flow with PKCE. The user signs in on openrouter.ai in the
/// browser; the app only ever receives a key for their account, never a password.
///
/// Two ways to get the one-time code back, both documented by OpenRouter:
/// a redirect to this device (`http://localhost:<port>/callback`, caught by a
/// listener that exists only during sign-in), or the user copies the code
/// shown on the page.
///
/// Not completed against OpenRouter yet: no account was available to test with.
@MainActor
final class OpenRouterSignIn {
    enum Failure: Error, Equatable {
        case refused(Int)
        case network
        case noListener

        var message: String {
            switch self {
            case .refused(let status): "OpenRouter did not accept the code (HTTP \(status)). Start again."
            case .network: "No connection to OpenRouter."
            case .noListener: "Could not wait for the answer on this device. Use the code shown on the page instead."
            }
        }
    }

    /// Random, kept only in memory until the code is exchanged.
    let verifier: String
    private var listener: NWListener?

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Self.base64URL(Data(bytes))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// The page to open. Without a callback OpenRouter shows the code to copy.
    func authorizationURL(callback: URL?) -> URL {
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let callback { components.queryItems?.insert(URLQueryItem(name: "callback_url", value: callback.absoluteString), at: 0) }
        return components.url!
    }

    /// Starts listening on this device and returns the callback address and a
    /// task that finishes with the code once the browser was sent back.
    func listen() async throws -> (callback: URL, code: Task<String?, Never>) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { throw Failure.noListener }
        self.listener = listener
        let (codes, codeContinuation) = AsyncStream<String>.makeStream()
        let (ports, portContinuation) = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: portContinuation.yield(listener.port?.rawValue)
            case .failed, .cancelled:
                portContinuation.yield(nil)
                codeContinuation.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let code = Self.code(inRequest: request)
                let body = code == nil
                    ? "<h3>No code received.</h3>" : "<h3>Signed in.</h3><p>You can go back to Listen.</p>"
                let page = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                    + "<body style='font:17px -apple-system;margin:15vh 8vw'>" + body
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let code { codeContinuation.yield(code) }
            }
        }
        listener.start(queue: .main)
        var port: UInt16?
        for await value in ports {
            port = value
            break
        }
        guard let port, let callback = URL(string: "http://localhost:\(port)/callback") else {
            stop()
            throw Failure.noListener
        }
        let code = Task { () -> String? in
            for await code in codes { return code }
            return nil
        }
        return (callback, code)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The `code` query value in the first line of an HTTP request.
    nonisolated static func code(inRequest request: String) -> String? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://localhost" + parts[1]) else { return nil }
        return components.queryItems?.first { $0.name == "code" }?.value
    }

    /// Exchanges the one-time code for the account's key.
    func key(for code: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "code_verifier": verifier, "code_challenge_method": "S256",
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
            let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["key"] as? String
        else { throw Failure.refused(status) }
        return key
    }
}
