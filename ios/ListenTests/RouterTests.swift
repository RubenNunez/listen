import Foundation
import GRPCCore
import Testing
@testable import Listen

private actor RouterDouble: RouterRPC {
    var opens: [Listen_Router_V1_OpenSessionRequest] = []
    var closed: [String] = []
    var paired = 0
    var pairFailure: RouterFailure?
    var statusCalls = 0
    var statusFailure: RouterFailure?
    var toolEnabled = true
    var asks = Set<String>()
    var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    var closeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var holdsStatus = false
    private var heldStatusCount = 0
    private var statusReplies: [Int: CheckedContinuation<Listen_Router_V1_StatusResponse, any Error>] = [:]
    private var statusWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var holdsPair = false
    private var pairReply: CheckedContinuation<Void, Never>?
    private var pairWaiters: [CheckedContinuation<Void, Never>] = []
    let missingEnd: Bool
    init(missingEnd: Bool = false) { self.missingEnd = missingEnd }
    func setFailure(_ failure: RouterFailure?) { statusFailure = failure }
    func setPairFailure(_ failure: RouterFailure?) { pairFailure = failure }
    func setEnabled(_ enabled: Bool) { toolEnabled = enabled }
    func pair(code: String, deviceName: String) async throws -> Listen_Router_V1_PairResponse {
        paired += 1
        if holdsPair {
            await withCheckedContinuation { continuation in
                pairReply = continuation
                let waiting = pairWaiters
                pairWaiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }
        if let pairFailure { throw pairFailure }
        var response = Listen_Router_V1_PairResponse()
        response.deviceToken = String(repeating: "a", count: 64)
        response.routerName = "Synthetic router"
        return response
    }
    func holdPairing() { holdsPair = true }
    func waitForPairing() async {
        if pairReply != nil { return }
        await withCheckedContinuation { pairWaiters.append($0) }
    }
    func finishPairing() { pairReply?.resume(); pairReply = nil }
    func status() async throws -> Listen_Router_V1_StatusResponse {
        statusCalls += 1
        if holdsStatus {
            heldStatusCount += 1
            let number = heldStatusCount
            return try await withCheckedThrowingContinuation { continuation in
                statusReplies[number] = continuation
                for count in statusWaiters.keys.filter({ $0 <= number }) {
                    statusWaiters.removeValue(forKey: count)?.resume()
                }
            }
        }
        if let statusFailure { throw statusFailure }
        var status = Listen_Router_V1_StatusResponse()
        var tool = Listen_Router_V1_ToolStatus()
        tool.tool = .claude; tool.found = true; tool.enabled = toolEnabled; tool.signedIn = .unknown
        status.tools = [tool]
        return status
    }
    func holdStatusChecks() { holdsStatus = true }
    func waitForStatusCheck(_ number: Int) async {
        if heldStatusCount >= number { return }
        await withCheckedContinuation { statusWaiters[number] = $0 }
    }
    /// Deliberately ignores cancellation, as a response already arriving from the network may do.
    func replyToStatus(_ number: Int, failure: RouterFailure? = nil, version: String = "test") {
        guard let continuation = statusReplies.removeValue(forKey: number) else {
            Issue.record("No pending synthetic status request \(number)")
            return
        }
        if let failure { continuation.resume(throwing: failure) }
        else {
            var status = Listen_Router_V1_StatusResponse()
            status.routerVersion = version
            continuation.resume(returning: status)
        }
    }
    func open(_ request: Listen_Router_V1_OpenSessionRequest) async throws -> Listen_Router_V1_OpenSessionResponse {
        opens.append(request)
        var response = Listen_Router_V1_OpenSessionResponse()
        response.sessionID = request.sessionID.isEmpty ? UUID().uuidString : request.sessionID
        return response
    }
    func deliver(session: String, text: String) async throws {}
    func waitForAsk(_ text: String) async {
        if asks.contains(text) { return }
        await withCheckedContinuation { waiting[text] = $0 }
    }
    private func began(_ text: String) { asks.insert(text); waiting.removeValue(forKey: text)?.resume() }
    nonisolated func ask(session: String, text: String) -> AsyncThrowingStream<Listen_Router_V1_AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await began(text)
                if text == "slow" {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { continuation.finish(throwing: CancellationError()); return }
                }
                var event = Listen_Router_V1_AskEvent()
                event.text = text; continuation.yield(event)
                event.source = "https://example.com/evidence"; continuation.yield(event)
                var usage = Listen_Router_V1_Usage()
                usage.inputTokens = 12; usage.outputTokens = 3; usage.costUsd = 0.01
                event.usage = usage; continuation.yield(event)
                if !missingEnd { event.end = .init(); continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func waitForCloseCount(_ count: Int) async {
        if closed.count >= count { return }
        await withCheckedContinuation { closeWaiters[count] = $0 }
    }
    func close(session: String) async throws {
        closed.append(session)
        for count in closeWaiters.keys.filter({ $0 <= closed.count }) { closeWaiters.removeValue(forKey: count)?.resume() }
    }
}

@Suite(.timeLimit(.minutes(1))) struct RouterConnections {
    private let fingerprint = String(repeating: "ab", count: 32)
    private func link() throws -> RouterLink {
        try RouterLink.parse("listen://pair?host=127.0.0.1,localhost&port=50551&code=ABCD2389&fp=\(fingerprint)")
    }
    private func consume(_ client: RouterModelClient, _ text: String = "hello", system: String = "Synthetic prompt") async throws -> [ModelChunk] {
        var chunks: [ModelChunk] = []
        for try await chunk in client.stream(model: "router/test-model", system: system, user: text, maxTokens: 100) { chunks.append(chunk) }
        return chunks
    }

    @Test func linksAreStrictAndParsingHasNoPairingSideEffects() throws {
        let good = try link()
        #expect(good.hosts == ["127.0.0.1", "localhost"] && good.port == 50551)
        for text in [
            "listen://pair?host=127.0.0.1&port=0&code=ABCD2389&fp=\(fingerprint)",
            "listen://pair?host=127.0.0.1&port=1&code=ABCD2389&fp=ab",
            "listen://pair?host=127.0.0.1&host=other&port=1&code=ABCD2389&fp=\(fingerprint)",
            "listen://pair?host=127.0.0.1,,localhost&port=1&code=ABCD2389&fp=\(fingerprint)",
            "listen://pair?host=a%2Fb&port=1&code=ABCD2389&fp=\(fingerprint)",
            "listen://pair?host=localhost&port=1&code=ABCD2389&fp=\(fingerprint)#extra",
            "https://pair?host=localhost&port=1&code=ABCD2389&fp=\(fingerprint)",
        ] { #expect(throws: RouterFailure.invalidLink) { try RouterLink.parse(text) } }
    }

    @Test func fingerprintAndFailuresDoNotExposeRemoteDetails() {
        #expect(RouterConnection.fingerprint(Array("Man".utf8)) == "20fe1bd201cd900bdbffeaec0b42e40b51cbf6b37ae5fbeaddd83aab9a221837")
        #expect(RouterConnection.failure(RPCError(code: .unauthenticated, message: "private details")) == .unpaired)
        #expect(RouterConnection.failure(RPCError(code: .resourceExhausted, message: "private details")) == .limit)
        #expect(!RouterConnection.failure(RPCError(code: .internalError, message: "private details")).reason.contains("private"))
    }

    @Test func protobufPreservesEveryEventKind() throws {
        var event = Listen_Router_V1_AskEvent()
        for kind: Listen_Router_V1_AskEvent.OneOf_Kind in [.text("text"), .step(.init()), .source("source"), .usage(.init()), .end(.init()), .failure(.init())] {
            event.kind = kind
            #expect(try Listen_Router_V1_AskEvent(serializedBytes: event.serializedData()) == event)
        }
    }

    @Test func realAdapterMapsChunksBindsTopicAndResumesOnlySamePrompt() async throws {
        let rpc = RouterDouble()
        let topic = UUID()
        let client = RouterModelClient(session: .init(rpc: rpc, topic: topic))
        let chunks = try await consume(client)
        #expect(chunks.contains(.text("hello")))
        #expect(chunks.contains(.usage(.init(input: 12, output: 3))))
        #expect(chunks.contains(.source("https://example.com/evidence")))
        _ = try await consume(client)
        _ = try await consume(client, system: "Different prompt")
        let requests = await rpc.opens
        #expect(requests.count == 3 && requests.allSatisfy { $0.topicID == topic.uuidString && $0.model == "test-model" })
        #expect(requests[0].sessionID.isEmpty && !requests[1].sessionID.isEmpty && requests[2].sessionID.isEmpty)
        #expect(await rpc.closed.count == 3)
    }

    @Test func disabledToolAndMissingEndAreFailures() async throws {
        let disabled = RouterDouble()
        await disabled.setEnabled(false)
        await #expect(throws: RouterFailure.disabledTool) { try await consume(.init(session: .init(rpc: disabled, topic: UUID()))) }
        #expect(await disabled.opens.isEmpty)
        let interrupted = RouterDouble(missingEnd: true)
        await #expect(throws: RouterFailure.interrupted) { try await consume(.init(session: .init(rpc: interrupted, topic: UUID()))) }
        #expect(await interrupted.closed.count == 1)
    }

    @Test func newerSameRoleCancelsAndClosesOlderTurnBeforeOpening() async throws {
        let rpc = RouterDouble()
        let client = RouterModelClient(session: .init(rpc: rpc, topic: UUID()))
        let first = Task { try await consume(client, "slow") }
        await rpc.waitForAsk("slow")
        let chunks = try await consume(client, "new")
        await #expect(throws: RouterFailure.cancelled) { try await first.value }
        #expect(chunks.contains(.text("new")))
        #expect(await rpc.closed.count == 2)
    }

    @Test func otherRolesDoNotCancelOneAnother() async throws {
        let rpc = RouterDouble()
        let client = RouterModelClient(session: .init(rpc: rpc, topic: UUID()))
        let first = Task { try await consume(client, "slow", system: "First role") }
        await rpc.waitForAsk("slow")
        _ = try await consume(client, "new", system: "Other role")
        #expect(await rpc.closed.count == 1, "the first role is still running")
        first.cancel()
        // AsyncThrowingStream may end normally when its consumer cancels next().
        if case .success(let chunks) = await first.result { #expect(chunks.isEmpty) }
        await rpc.waitForCloseCount(2)
        #expect(await rpc.closed.count == 2)
    }
}

@MainActor @Suite struct RouterBindings {
    private func file() -> URL { FileManager.default.temporaryDirectory.appending(path: "router-tests-\(UUID())/routers.json") }
    private func link() throws -> RouterLink {
        try RouterLink.parse("listen://pair?host=localhost&port=50551&code=ABCDEFGH&fp=\(String(repeating: "ab", count: 32))")
    }

    private func deferredStatusStore() async throws -> (RouterStore, RouterDouble, UUID) {
        let rpc = RouterDouble()
        var secrets: [String: String] = [:]
        let store = RouterStore(file: file(), readSecret: { secrets[$0] }, writeSecret: { secrets[$0] = $1 }, deleteSecret: { secrets[$0] = nil }, connect: { _, _ in rpc })
        try await store.pair(link(), deviceName: "Synthetic device")
        let id = try #require(store.routers.first?.id)
        await store.refresh(id)
        await rpc.holdStatusChecks()
        return (store, rpc, id)
    }

    @Test func newerConnectionFailureIsNotOverwrittenByOlderSuccess() async throws {
        let (store, rpc, id) = try await deferredStatusStore()
        let older = Task { await store.refresh(id) }
        await rpc.waitForStatusCheck(1)
        let newer = Task { await store.refresh(id) }
        await rpc.waitForStatusCheck(2)
        await rpc.replyToStatus(2, failure: .unreachable)
        await newer.value
        await rpc.replyToStatus(1, version: "stale")
        await older.value
        #expect(store.states[id] == .failed(.unreachable))
    }

    @Test func newerConnectionSuccessIsNotOverwrittenByOlderFailure() async throws {
        let (store, rpc, id) = try await deferredStatusStore()
        let older = Task { await store.refresh(id) }
        await rpc.waitForStatusCheck(1)
        let newer = Task { await store.refresh(id) }
        await rpc.waitForStatusCheck(2)
        await rpc.replyToStatus(2, version: "latest")
        await newer.value
        await rpc.replyToStatus(1, failure: .unreachable)
        await older.value
        guard case .connected(let status) = store.states[id] else {
            Issue.record("An older failure replaced the successful check")
            return
        }
        #expect(status.routerVersion == "latest")
    }

    @Test func reloadDropsAnEarlierConnectionResult() async throws {
        let (store, rpc, id) = try await deferredStatusStore()
        let check = Task { await store.refresh(id) }
        await rpc.waitForStatusCheck(1)
        store.reloadAfterTransfer()
        await rpc.replyToStatus(1, version: "before-reload")
        await check.value
        #expect(store.states[id] == nil)
    }

    @Test func cancellingAConnectionCheckKeepsThePriorStatus() async throws {
        let (store, rpc, id) = try await deferredStatusStore()
        let before = store.states[id]
        let check = Task { await store.refresh(id) }
        await rpc.waitForStatusCheck(1)
        check.cancel()
        await rpc.replyToStatus(1, version: "cancelled-response")
        await check.value
        #expect(store.states[id] == before)
    }

    @Test func missingTokenDuringAnotherCheckRemainsUnpaired() async throws {
        let rpc = RouterDouble()
        var secrets: [String: String] = [:]
        let store = RouterStore(file: file(), readSecret: { secrets[$0] }, writeSecret: { secrets[$0] = $1 }, deleteSecret: { secrets[$0] = nil }, connect: { _, _ in rpc })
        try await store.pair(link(), deviceName: "Synthetic device")
        let id = try #require(store.routers.first?.id)
        await rpc.holdStatusChecks()
        let older = Task { await store.refresh(id) }
        await rpc.waitForStatusCheck(1)
        secrets.removeAll()
        await store.refresh(id)
        await rpc.replyToStatus(1, version: "stale")
        await older.value
        #expect(store.states[id] == .failed(.unpaired))
    }

    @Test func pairingSavesOnlyLocalTokenAndNeverEnablesInference() async throws {
        let rpc = RouterDouble(), file = file()
        var secrets: [String: String] = [:]
        let store = RouterStore(file: file, readSecret: { secrets[$0] }, writeSecret: { secrets[$0] = $1 }, deleteSecret: { secrets[$0] = nil }, connect: { _, _ in rpc })
        let pairsBeforeConfirmation = await rpc.paired
        #expect(store.routers.isEmpty && pairsBeforeConfirmation == 0)
        try await store.pair(link(), deviceName: "Synthetic device")
        let saved = try #require(store.routers.first)
        #expect(!saved.enabled && store.active == nil)
        #expect(secrets.count == 1 && secrets[saved.secretAccount] != nil)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(String(repeating: "a", count: 64)))
        try store.configure(saved.id, enabled: true, model: "test", usesCodex: false)
        let client = try #require(store.client(topic: UUID()))
        #expect(store.active?.id == saved.id)
        try await store.remove(saved.id)
        #expect(secrets.isEmpty && store.routers.isEmpty)
        await #expect(throws: RouterFailure.unpaired) {
            for try await _ in client.stream(model: "router/test", system: "Synthetic", user: "After removal", maxTokens: 10) {}
        }
    }

    @Test func staleStoreRollsBackItsTokenWithoutOverwritingOtherPairing() async throws {
        let rpc = RouterDouble(), file = file()
        var secrets: [String: String] = [:]
        func store() -> RouterStore {
            RouterStore(file: file, readSecret: { secrets[$0] }, writeSecret: { secrets[$0] = $1 }, deleteSecret: { secrets[$0] = nil }, connect: { _, _ in rpc })
        }
        let first = store(), stale = store()
        try await first.pair(link(), deviceName: "First")
        let before = try Data(contentsOf: file)
        await #expect(throws: RouterFailure.storage) { try await stale.pair(link(), deviceName: "Stale") }
        #expect(try Data(contentsOf: file) == before)
        #expect(secrets.count == 1 && stale.routers.isEmpty)
    }

    @Test func plannerUsesTheOptedInRouterAndPreservesExplicitSystemModels() async throws {
        let rpc = RouterDouble(), file = file()
        var secrets: [String: String] = [:]
        let store = RouterStore(file: file, readSecret: { secrets[$0] }, writeSecret: { secrets[$0] = $1 }, deleteSecret: { secrets[$0] = nil }, connect: { _, _ in rpc })
        try await store.pair(link(), deviceName: "Synthetic device")
        let topic = Topic(name: "Synthetic topic")
        var config = SystemConfig()
        config.models.drafts = []
        config.models.main = ""
        let before = SessionModel.plan(for: topic, system: .init(config: config, problem: nil, edited: false), routers: store)
        #expect(before.direct["router"] == nil)
        let id = try #require(store.routers.first?.id)
        try store.configure(id, enabled: true, model: "test-model", usesCodex: false)
        let enabled = SessionModel.plan(for: topic, system: .init(config: config, problem: nil, edited: false), routers: store)
        #expect(enabled.direct["router"] != nil)
        #expect(enabled.settings.drafters.contains("router/test-model"))
        #expect(enabled.settings.merger == "router/test-model")
        config.models.drafts = ["local/apple"]
        config.models.main = "local/apple"
        let explicit = SessionModel.plan(for: topic, system: .init(config: config, problem: nil, edited: false), routers: store)
        #expect(explicit.settings.drafters == ["local/apple"] && explicit.settings.merger == "local/apple")
    }

    @Test func corruptSourceAndRevokedPairingStayExplicit() async throws {
        let rpc = RouterDouble(), file = file()
        var secrets: [String: String] = [:]
        let store = RouterStore(file: file, readSecret: { secrets[$0] }, writeSecret: { secrets[$0] = $1 }, deleteSecret: { secrets[$0] = nil }, connect: { _, _ in rpc })
        try await store.pair(link(), deviceName: "Synthetic device")
        let id = try #require(store.routers.first?.id)
        await rpc.setFailure(.unpaired)
        await store.refresh(id)
        #expect(store.states[id] == .failed(.unpaired))
        let invalid = Data("not json".utf8)
        try invalid.write(to: file)
        let broken = RouterStore(file: file)
        #expect(broken.problem != nil)
        await #expect(throws: RouterFailure.storage) { try await broken.pair(link(), deviceName: "Synthetic device") }
        #expect(try Data(contentsOf: file) == invalid)
    }
}


@MainActor @Suite struct RouterPairingFlow {
    private func link(hosts: String = "localhost,127.0.0.1", code: String = "ABCDEFGH", fingerprint: String = String(repeating: "ab", count: 32)) throws -> RouterLink {
        try RouterLink.parse("listen://pair?host=\(hosts)&port=50551&code=\(code)&fp=\(fingerprint)")
    }

    private func make() throws -> (RouterPairing, RouterStore, RouterDouble) {
        let rpc = RouterDouble()
        let file = FileManager.default.temporaryDirectory.appending(path: "pairing-tests-\(UUID())/routers.json")
        var secrets: [String: String] = [:]
        let store = RouterStore(file: file, readSecret: { secrets[$0] }, writeSecret: { secrets[$0] = $1 }, deleteSecret: { secrets[$0] = nil }, connect: { _, _ in rpc })
        return (RouterPairing(link: try link(), store: store), store, rpc)
    }

    @Test func rejectedCodesNeedANewValidatedProposalBeforeRetry() async throws {
        for failure: RouterFailure in [.expiredCode, .wrongCode] {
            let (pairing, store, rpc) = try make()
            await rpc.setPairFailure(failure)
            await pairing.pair(deviceName: "Synthetic device")?.value
            #expect(pairing.phase == .review && pairing.failure == failure && !pairing.canPair)
            await pairing.pair(deviceName: "Repeated tap")?.value
            #expect(await rpc.paired == 1)
            let previous = pairing.link
            pairing.review("not a router code")
            #expect(pairing.link == previous && !pairing.canPair)
            let fresh = try link(code: "ABCD2345", fingerprint: String(repeating: "cd", count: 32))
            pairing.review("listen://pair?host=localhost,127.0.0.1&port=50551&code=\(fresh.code)&fp=\(fresh.fingerprint)")
            #expect(pairing.link == fresh && pairing.canPair && pairing.failure == nil)
            #expect(store.routers.isEmpty)
            #expect(await rpc.paired == 1)
            await rpc.setPairFailure(nil)
            await pairing.pair(deviceName: "Synthetic device")?.value
            #expect(pairing.phase == .paired && !pairing.canPair)
            #expect(store.routers.first?.address.fingerprint == fresh.fingerprint)
            #expect(store.active == nil)
        }
    }

    @Test func scanningOnlyChangesTheProposal() async throws {
        let (pairing, store, rpc) = try make()
        pairing.review("listen://pair?host=127.0.0.1&port=50551&code=ABCD2345&fp=\(String(repeating: "cd", count: 32))")
        #expect(pairing.link.hosts == ["127.0.0.1"] && pairing.link.code == "ABCD2345")
        #expect(pairing.canPair && pairing.phase == .review)
        // A new link from the system Camera uses the same confirmation gate.
        let external = try link(code: "ABCD2389")
        pairing.review(external)
        #expect(pairing.link == external && pairing.canPair)
        #expect(store.routers.isEmpty && store.active == nil)
        #expect(await rpc.paired == 0)
    }

    @Test func invalidScanKeepsTheReviewedAddress() throws {
        let (pairing, store, _) = try make()
        let before = pairing.link
        pairing.selectHost(1)
        pairing.review("https://example.invalid/not-a-router")
        #expect(pairing.link == before && pairing.selectedHost == 1)
        #expect(pairing.failure == .invalidLink && store.routers.isEmpty)
    }

    @Test func newCodesKeepTheChosenHostWhenStillOffered() throws {
        let (pairing, _, _) = try make()
        pairing.selectHost(1)
        pairing.review("listen://pair?host=127.0.0.1,localhost&port=50551&code=ABCD2345&fp=\(String(repeating: "ab", count: 32))")
        #expect(pairing.selectedHost == 0 && pairing.link.hosts[pairing.selectedHost] == "127.0.0.1")
    }

    @Test func pairingIgnoresRepeatedActionsAndKeepsTheReviewedAddress() async throws {
        let (pairing, store, rpc) = try make()
        let before = pairing.link
        await rpc.holdPairing()
        let first = try #require(pairing.pair(deviceName: "Synthetic device"))
        #expect(pairing.phase == .pairing, "the proposal is locked before yielding to network work")
        await rpc.waitForPairing()
        pairing.selectHost(1)
        pairing.review("listen://pair?host=other.local&port=50551&code=ABCD2345&fp=\(String(repeating: "cd", count: 32))")
        await pairing.pair(deviceName: "Repeated tap")?.value
        #expect(pairing.phase == .pairing && pairing.link == before && pairing.selectedHost == 0)
        await rpc.finishPairing()
        await first.value
        #expect(pairing.phase == .paired && store.routers.first?.address.host == "localhost")
        pairing.selectHost(1)
        await pairing.pair(deviceName: "Already paired")?.value
        #expect(pairing.selectedHost == 0)
        #expect(await rpc.paired == 1)
    }

    @Test func successfulPairingDoesNotWaitForASecondNetworkCheck() async throws {
        let (pairing, store, rpc) = try make()
        await rpc.setFailure(.unreachable)
        await pairing.pair(deviceName: "Synthetic device")?.value
        #expect(pairing.phase == .paired && pairing.failure == nil)
        #expect(await rpc.statusCalls == 0)
        #expect(store.routers.count == 1 && store.active == nil)
        let id = try #require(store.routers.first?.id)
        #expect(store.states[id] == nil)
    }
}
