import Foundation
import Testing
@testable import Listen

private final class JevWire: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var status = 200
        var body = Data()
        var request: URLRequest?
    }
    private static let state = State()
    static func configure(status: Int, body: String) {
        state.lock.withLock { state.status = status; state.body = Data(body.utf8); state.request = nil }
    }
    static var recorded: URLRequest? { state.lock.withLock { state.request } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.state.lock.withLock {
            Self.state.request = request
            return (Self.state.status, Self.state.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct JevWireContract {
    private func service() -> JevClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevWire.self]
        return JevClient(key: "dummy-test-key", session: URLSession(configuration: configuration))
    }
    private func context() -> DirectedContext {
        DirectedContext(revision: 1, trigger: 2,
                        evidence: [.init(id: 2, text: "Explain backpressure.", who: "unknown")], blocks: [])
    }

    @Test func usesOfficialTypedAPIAndReportsRealUsage() async throws {
        let response = #"{"model":"jev-1.14.0","answers":{"useful":{"type":"noul","noul":0.99},"research":{"type":"noul","noul":0.1},"target":{"type":"choice","choice":"new","confidence":0.99,"probabilities":{"new":1.0}}},"usage":{"input_tokens":123,"output_tokens":14}}"#
        JevWire.configure(status: 200, body: response)
        let schema = try JSONSerialization.data(withJSONObject: JevClient.questions(for: context()))
        var chunks: [ModelChunk] = []
        for try await chunk in service().stream(model: JevClient.model, system: String(decoding: schema, as: UTF8.self), user: JevClient.state(for: context()), maxTokens: 0) { chunks.append(chunk) }
        let sent = try #require(JevWire.recorded)
        #expect(sent.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(sent.httpMethod == "POST" && sent.timeoutInterval <= 2.5)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-test-key")
        #expect(sent.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
        #expect(chunks == [.text(response), .usage(TokenUsage(input: 123, output: 14))])
        #expect(try !JevClient.read(Data(response.utf8), allowed: []).shouldWait)
    }

    @Test func errorsCannotExposeProviderResponseBodiesOrCredentials() async throws {
        JevWire.configure(status: 401, body: "dummy-test-key · private request details")
        let schema = try JSONSerialization.data(withJSONObject: JevClient.questions(for: context()))
        do {
            for try await _ in service().stream(model: JevClient.model, system: String(decoding: schema, as: UTF8.self), user: JevClient.state(for: context()), maxTokens: 0) {}
            Issue.record("Unauthorized response must fail")
        } catch {
            #expect((error as? any ModelFailure)?.reason == "TypeSafe HTTP 401")
            #expect(!String(describing: error).contains("dummy-test-key"))
            #expect(!String(describing: error).contains("private request details"))
        }
    }
}
