import CryptoKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

struct RouterAddress: Codable, Equatable, Sendable {
    var host: String
    var port: Int
    var fingerprint: String
}

/// Low-level protocol permits deterministic in-process tests without owner credentials.
protocol RouterRPC: Sendable {
    func pair(code: String, deviceName: String) async throws -> Listen_Router_V1_PairResponse
    func status() async throws -> Listen_Router_V1_StatusResponse
    func open(_ request: Listen_Router_V1_OpenSessionRequest) async throws -> Listen_Router_V1_OpenSessionResponse
    func deliver(session: String, text: String) async throws
    func ask(session: String, text: String) -> AsyncThrowingStream<Listen_Router_V1_AskEvent, Error>
    func close(session: String) async throws
}

/// Each call has a bounded connection lifetime. No hidden failover/replay of a model turn.
struct RouterConnection: RouterRPC {
    let address: RouterAddress
    var token: String = ""
    private typealias Client = Listen_Router_V1_Router.Client<HTTP2ClientTransport.Posix>

    static func fingerprint(_ der: [UInt8]) -> String {
        SHA256.hash(data: Data(der)).map { String(format: "%02x", $0) }.joined()
    }

    private func call<Result: Sendable>(
        pairing: Bool = false,
        _ body: @Sendable (Client, Metadata) async throws -> Result
    ) async throws -> Result {
        let rejected = Mutex(false)
        let expected = address.fingerprint
        var configuration = HTTP2ClientTransport.Posix.Config.defaults
        // Addresses may be IP literals; the router's TLS server name stays stable.
        configuration.http2.authority = "listen-router"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: address.host, port: address.port),
            transportSecurity: .tls { tls in
                tls.serverCertificateVerification = .noHostnameVerification
                tls.trustRoots = .certificates([])
                // A pinned leaf is the trust anchor. BoringSSL still proves possession
                // of its key during the handshake. No system root or hostname fallback.
                tls.customVerificationCallback = { chain, promise in
                    guard let leaf = chain.first, let der = try? leaf.toDERBytes(),
                          Self.fingerprint(der) == expected else {
                        rejected.withLock { $0 = true }
                        promise.succeed(.failed)
                        return
                    }
                    promise.succeed(.certificateVerified(.init(.init([leaf]))))
                }
            }, config: configuration)
        var metadata: Metadata = [:]
        if !token.isEmpty { metadata.addString("Bearer \(token)", forKey: "authorization") }
        do {
            return try await withGRPCClient(transport: transport) { grpc in
                try await body(Client(wrapping: grpc), metadata)
            }
        } catch {
            if rejected.withLock({ $0 }) { throw RouterFailure.otherCertificate }
            throw Self.failure(error, pairing: pairing)
        }
    }

    private static func options(_ seconds: Int64 = 8) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(seconds)
        options.waitForReady = false
        options.maxRequestMessageBytes = 512 * 1024
        options.maxResponseMessageBytes = 512 * 1024
        return options
    }

    static func failure(_ error: Error, pairing: Bool = false) -> RouterFailure {
        if let error = error as? RouterFailure { return error }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        guard let error = error as? RPCError else { return .unreachable }
        switch error.code {
        case .unauthenticated: return .unpaired
        case .permissionDenied: return pairing ? .wrongCode : .disabledTool
        case .failedPrecondition: return pairing ? .expiredCode : .remote
        case .resourceExhausted: return .limit
        case .cancelled: return .cancelled
        case .unavailable, .deadlineExceeded: return .unreachable
        default: return .remote
        }
    }

    func pair(code: String, deviceName: String) async throws -> Listen_Router_V1_PairResponse {
        try await call(pairing: true) { client, _ in
            var message = Listen_Router_V1_PairRequest()
            message.code = code
            message.deviceName = String(deviceName.prefix(64))
            return try await client.pair(request: .init(message: message), options: Self.options())
        }
    }

    func status() async throws -> Listen_Router_V1_StatusResponse {
        try await call { client, metadata in
            try await client.status(request: .init(message: .init(), metadata: metadata), options: Self.options())
        }
    }

    func open(_ request: Listen_Router_V1_OpenSessionRequest) async throws -> Listen_Router_V1_OpenSessionResponse {
        try await call { client, metadata in
            try await client.openSession(request: .init(message: request, metadata: metadata), options: Self.options())
        }
    }

    func deliver(session: String, text: String) async throws {
        try await call { client, metadata in
            var message = Listen_Router_V1_DeliverRequest()
            message.sessionID = session
            message.text = text
            _ = try await client.deliver(request: .init(message: message, metadata: metadata), options: Self.options())
        }
    }

    func ask(session: String, text: String) -> AsyncThrowingStream<Listen_Router_V1_AskEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task {
                do {
                    try await call { client, metadata in
                        var message = Listen_Router_V1_AskRequest()
                        message.sessionID = session
                        message.text = text
                        try await client.ask(request: .init(message: message, metadata: metadata), options: Self.options(120)) { response in
                            for try await event in response.messages {
                                try Task.checkCancellation()
                                switch continuation.yield(event) {
                                case .enqueued: break
                                case .dropped: throw RouterFailure.limit
                                case .terminated: throw CancellationError()
                                @unknown default: throw RouterFailure.invalidResponse
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close(session: String) async throws {
        try await call { client, metadata in
            var message = Listen_Router_V1_CloseSessionRequest()
            message.sessionID = session
            _ = try await client.closeSession(request: .init(message: message, metadata: metadata), options: Self.options())
        }
    }
}
