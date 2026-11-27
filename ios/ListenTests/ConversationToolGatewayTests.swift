import Foundation
import Testing
@testable import Listen

private actor SyntheticAutomation {
    var calls = 0
    var unknown: ConversationOperationState.Unknown?
    func setUnknown(_ reason: ConversationOperationState.Unknown = .timedOut) { unknown = reason }
    func execute(_ request: ConversationOperationRequest) -> ConversationToolObservation {
        calls += 1
        if let unknown { return .unknown(unknown) }
        return .completed(.succeeded(detail: "Synthetic lamp acknowledged."))
    }
}

@Suite struct ConversationToolGateways {
    private let session = ConversationSessionID("synthetic-session")
    private let lamp = ConversationCapabilityID("synthetic-lamp")
    private func request(_ id: String = "synthetic-operation") -> ConversationOperationRequest {
        .init(id: .init(id), capability: lamp, arguments: ["on": .boolean(true)])
    }
    private func gateway(_ service: SyntheticAutomation, standing: Bool = false) -> ConversationToolGateway {
        let tool = RegisteredConversationTool(id: lamp, fields: ["on": .boolean], required: ["on"], execute: { await service.execute($0) })
        return .init(session: session, tools: [tool], standingGrants: standing ? [lamp] : [])
    }

    @Test func forgedGrantAndSchemaMismatchNeverReachTheService() async {
        let service = SyntheticAutomation(), gateway = gateway(service)
        let original = request()
        let forged = ConversationGrant(operation: original.id, capability: lamp, basis: .standing)
        #expect(await gateway.dispatch(session: session, request: original, grant: forged) == .refused(.notAuthorized))
        var invalid = request("invalid")
        invalid.arguments["on"] = .string("true")
        #expect(await gateway.authorize(invalid) == .denied)
        invalid.arguments = ["on": .boolean(true), "command": .string("untrusted text")]
        #expect(await gateway.authorize(invalid) == .denied)
        #expect(await service.calls == 0)
    }

    @Test func explicitConfirmationBindsExactArgumentsAndDuplicatesShareOneResult() async throws {
        let service = SyntheticAutomation(), gateway = gateway(service)
        let original = request()
        #expect(await gateway.authorize(original) == .awaitingOwner)
        let authorization = await gateway.confirm(original)
        guard case .granted(let grant) = authorization else { Issue.record("No confirmed grant"); return }
        async let first = gateway.dispatch(session: session, request: original, grant: grant)
        async let second = gateway.dispatch(session: session, request: original, grant: grant)
        let results = await (first, second)
        #expect(results.0 == results.1)
        #expect(await service.calls == 1)
        var changed = original
        changed.arguments["on"] = .boolean(false)
        #expect(await gateway.dispatch(session: session, request: changed, grant: grant) == .refused(.idConflict))
        #expect(await gateway.dispatch(session: .init("other-session"), request: original, grant: grant) == .refused(.wrongSession))
        #expect(await service.calls == 1)
    }

    @Test func unknownOutcomeIsObservedAndNeverRetried() async {
        let service = SyntheticAutomation(), gateway = gateway(service, standing: true)
        await service.setUnknown()
        let original = request()
        guard case .granted(let grant) = await gateway.authorize(original) else { Issue.record("No standing grant"); return }
        let result = await gateway.dispatch(session: session, request: original, grant: grant)
        #expect(result == .observation(.init(session: session, kind: .operationTimedOut(operation: original.id))))
        #expect(await gateway.dispatch(session: session, request: original, grant: grant) == result)
        #expect(await service.calls == 1)
    }

    @Test func rememberingRequiresTheExactPendingProposalAndNeverAuthorizesOtherTools() async {
        let service = SyntheticAutomation()
        let other = ConversationCapabilityID("other-tool")
        let tools = [lamp, other].map { id in
            RegisteredConversationTool(id: id, fields: ["on": .boolean], required: ["on"], execute: { await service.execute($0) })
        }
        let gateway = ConversationToolGateway(session: session, tools: tools)
        let original = request()
        #expect(await gateway.confirm(original, remember: true) == .denied)
        #expect(await gateway.authorize(original) == .awaitingOwner)
        var altered = original; altered.arguments["on"] = .boolean(false)
        #expect(await gateway.confirm(altered, remember: true) == .denied)
        guard case .granted = await gateway.confirm(original, remember: true) else { Issue.record("No owner grant"); return }
        guard case .granted = await gateway.authorize(request("next")) else { Issue.record("No remembered grant"); return }
        let another = ConversationOperationRequest(id: .init("other"), capability: other, arguments: ["on": .boolean(true)])
        #expect(await gateway.authorize(another) == .awaitingOwner)
        #expect(await service.calls == 0)
    }

    @Test func oneRequestsLostRouteDoesNotInvalidateOtherOperations() async {
        let service = SyntheticAutomation(), gateway = gateway(service, standing: true)
        await service.setUnknown(.routeLost)
        var state = ConversationState(binding: .init(session: session, topic: UUID(), system: "synthetic", systemSnapshot: "test"))
        _ = ConversationReducer.reduce(&state, .init(session: session, kind: .start))
        _ = ConversationReducer.reduce(&state, .init(session: session, kind: .capabilityReported(lamp, .available)))
        var grants: [ConversationGrant] = []
        for proposal in [request("lost"), request("other")] {
            _ = ConversationReducer.reduce(&state, .init(session: session, kind: .operationProposed(proposal)))
            let authorization = await gateway.authorize(proposal)
            _ = ConversationReducer.reduce(&state, .init(session: session, kind: .operationAuthorization(operation: proposal.id, authorization)))
            if case .granted(let grant) = authorization { grants.append(grant) }
        }
        guard let grant = grants.first else { Issue.record("No grant"); return }
        let result = await gateway.dispatch(session: session, request: request("lost"), grant: grant)
        guard case .observation(let event) = result else { Issue.record("No observation"); return }
        _ = ConversationReducer.reduce(&state, event)
        #expect(state.operation(.init("lost"))?.state == .outcomeUnknown(.routeLost))
        #expect(state.operation(.init("other"))?.state == .dispatched)
    }

    @Test func stopRevokesUndispatchedWorkAndReducerReportsOnlyObservedSuccess() async {
        let service = SyntheticAutomation(), gateway = gateway(service, standing: true)
        let original = request()
        var state = ConversationState(binding: .init(session: session, topic: UUID(), system: "synthetic", systemSnapshot: "test"))
        _ = ConversationReducer.reduce(&state, .init(session: session, kind: .start))
        _ = ConversationReducer.reduce(&state, .init(session: session, kind: .capabilityReported(lamp, .available)))
        _ = ConversationReducer.reduce(&state, .init(session: session, kind: .operationProposed(original)))
        let authorization = await gateway.authorize(original)
        let effects = ConversationReducer.reduce(&state, .init(session: session, kind: .operationAuthorization(operation: original.id, authorization)))
        guard case .dispatchOperation(let request, let grant) = effects.first else { Issue.record("Missing dispatch"); return }
        #expect(state.operation(original.id)?.state == .dispatched)
        let observation = await gateway.dispatch(session: session, request: request, grant: grant)
        guard case .observation(let event) = observation else { Issue.record("Missing observation"); return }
        _ = ConversationReducer.reduce(&state, event)
        #expect(state.operation(original.id)?.state == .succeeded(detail: "Synthetic lamp acknowledged."))
        let pending = self.request("pending")
        guard case .granted(let pendingGrant) = await gateway.authorize(pending) else { Issue.record("No pending grant"); return }
        await gateway.stop()
        #expect(await gateway.dispatch(session: session, request: pending, grant: pendingGrant) == .refused(.sessionStopped))
        #expect(await service.calls == 1)
    }
}
