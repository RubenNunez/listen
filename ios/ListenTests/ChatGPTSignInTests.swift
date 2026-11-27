import Foundation
import Network
import Testing
@testable import Listen

/// The sign-in up to OpenAI's token endpoint, with the real loopback listener
/// and a stand-in for the in-app page. Nothing here reaches OpenAI.
@MainActor @Suite struct ChatGPTSignInPage {
    /// A page that records what happened to it and plays the browser.
    @MainActor final class FakePage {
        var opened: URL?
        var closedFromCode = 0
        var ended: (@MainActor (ChatGPTPage.End) -> Void)?
        var onOpen: @MainActor (FakePage) -> Void = { _ in }

        var page: ChatGPTPage {
            ChatGPTPage { url, ended in
                self.opened = url
                self.ended = ended
                self.onOpen(self)
                return { self.closedFromCode += 1 }
            }
        }

        /// The browser following OpenAI's redirect to the listener.
        func redirect(state: String? = nil, extra: String = "&code=abc&client_id=oaiapp_1") {
            guard let opened, let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems,
                let callback = items.first(where: { $0.name == "redirect_uri" })?.value,
                let sent = items.first(where: { $0.name == "state" })?.value,
                let url = URL(string: "\(callback)?state=\(state ?? sent)\(extra)")
            else {
                Issue.record("No sign-in page was opened")
                return
            }
            Task { _ = try? await URLSession.shared.data(from: url) }
        }
    }

    @Test func callbackClosesThePageAndStopsTheListener() async throws {
        let flow = ChatGPTSignIn(), fake = FakePage()
        fake.onOpen = { $0.redirect() }
        var shown: URL?
        let answer = try await flow.authorize(saved: nil, page: fake.page) { shown = $0 }
        #expect(answer.code == "abc")
        #expect(answer.clientID == "oaiapp_1")
        #expect(answer.callback.absoluteString.hasPrefix("http://127.0.0.1:"))
        #expect(answer.callback.path == "/auth/callback")
        #expect(shown == fake.opened, "the sheet's link and the page are the same address")
        #expect(fake.closedFromCode == 1)
        #expect(!flow.isListening)
        // The system reports a page closed from code as cancelled: that must change nothing.
        fake.ended?(.user)
    }

    @Test func closingThePageStopsTheListenerWithoutAnError() async throws {
        let flow = ChatGPTSignIn(), fake = FakePage()
        fake.onOpen = { page in Task { @MainActor in page.ended?(.user) } }
        // What the sheet does with it: a cancellation shows no message.
        await #expect(throws: CancellationError.self) {
            _ = try await flow.authorize(saved: nil, page: fake.page) { _ in }
        }
        #expect(!flow.isListening)
    }

    @Test func aPageThatFailsIsReported() async throws {
        let flow = ChatGPTSignIn(), fake = FakePage()
        fake.onOpen = { page in Task { @MainActor in page.ended?(.failed) } }
        await #expect(throws: ChatGPT.Failure.noPage) {
            _ = try await flow.authorize(saved: nil, page: fake.page) { _ in }
        }
        #expect(!flow.isListening)
    }

    @Test func aPageThatCannotOpenStopsTheListener() async throws {
        let flow = ChatGPTSignIn()
        let page = ChatGPTPage { _, _ in nil }
        await #expect(throws: ChatGPT.Failure.noPage) {
            _ = try await flow.authorize(saved: nil, page: page) { _ in }
        }
        #expect(!flow.isListening)
    }

    @Test func anAnswerWithAnotherStateIsRejected() async throws {
        let flow = ChatGPTSignIn(), fake = FakePage()
        fake.onOpen = { $0.redirect(state: "someone-else") }
        await #expect(throws: ChatGPT.Failure.stateMismatch) {
            _ = try await flow.authorize(saved: nil, page: fake.page) { _ in }
        }
        #expect(fake.closedFromCode == 1)
        #expect(!flow.isListening)
    }

    @Test func aRefusalInTheBrowserIsDenied() async throws {
        let flow = ChatGPTSignIn(), fake = FakePage()
        fake.onOpen = { $0.redirect(extra: "&error=access_denied") }
        await #expect(throws: ChatGPT.Failure.denied) {
            _ = try await flow.authorize(saved: nil, page: fake.page) { _ in }
        }
    }

    @Test func withoutAPageTheLinkAloneStillWorks() async throws {
        // Mac: the sheet shows the link and any browser on the machine answers.
        let flow = ChatGPTSignIn(), fake = FakePage()
        let answer = try await flow.authorize(saved: nil, page: nil) { url in
            fake.opened = url
            fake.redirect()
        }
        #expect(answer.code == "abc")
        #expect(!flow.isListening)
    }
}

/// Spike, run by hand: does a page in the system's sign-in sheet reach a
/// listener inside this app on 127.0.0.1, over plain http? It needs the
/// simulator or a device with the app in front, so it only runs when asked:
///
///     TEST_RUNNER_LISTEN_OAUTH_SPIKE=ephemeral xcodebuild test … -only-testing:ListenTests/ChatGPTSignInSpike
///
/// `shared` instead of `ephemeral` uses Safari's cookies, as the app does; the
/// system then asks "Listen wants to use 127.0.0.1 to sign in" and someone has
/// to tap Continue. It opens no OpenAI page.
@MainActor @Suite struct ChatGPTSignInSpike {
    nonisolated static var mode: String? { ProcessInfo.processInfo.environment["LISTEN_OAUTH_SPIKE"] }

    @Test(.enabled(if: mode != nil)) func sheetReachesTheLoopbackListener() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let (requests, requestContinuation) = AsyncStream<String>.makeStream()
        let (ports, portContinuation) = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: portContinuation.yield(listener.port?.rawValue)
            case .failed, .cancelled: portContinuation.yield(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let bytes = data ?? Data()
                // A TLS hello (0x16) would mean the browser upgraded to https.
                let line = bytes.first == 0x16
                    ? "TLS hello"
                    : String(decoding: bytes, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? "(empty)"
                let port = listener.port?.rawValue ?? 0
                let reply: String
                if line.contains(" /start") {
                    reply = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/auth/callback?code=x&state=y\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    let page = "<!doctype html><meta name=viewport content='width=device-width'><h3>Spike: callback served.</h3>"
                    reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
                }
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                print("SPIKE request: \(line)")
                requestContinuation.yield(line)
            }
        }
        listener.start(queue: .main)
        var port: UInt16?
        for await value in ports {
            port = value
            break
        }
        let bound = try #require(port)
        let start = try #require(URL(string: "http://127.0.0.1:\(bound)/start"))

        var end: ChatGPTPage.End?
        let close = ChatGPTPage.system(ephemeral: Self.mode == "ephemeral").open(start) {
            print("SPIKE page ended: \($0)")
            end = $0
        }
        print("SPIKE opened \(start) mode=\(Self.mode ?? "") started=\(close != nil)")
        let closer = try #require(close, "the sign-in sheet did not start")

        let seen = Task { () -> [String] in
            var lines: [String] = []
            for await line in requests {
                lines.append(line)
                if line.contains("/auth/callback") { break }
            }
            return lines
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(Self.mode == "ephemeral" ? 20 : 90))
            requestContinuation.finish()
        }
        let lines = await seen.value
        timeout.cancel()
        print("SPIKE requests: \(lines)")
        #expect(lines.contains { $0.hasPrefix("GET /start") })
        #expect(lines.contains { $0.hasPrefix("GET /auth/callback?code=x&state=y") })
        #expect(!lines.contains("TLS hello"))
        // Left up briefly so that a screenshot can show the served page.
        try await Task.sleep(for: .seconds(4))
        closer()
        try await Task.sleep(for: .seconds(2))
        print("SPIKE closed from code; end reported: \(String(describing: end))")
    }
}
