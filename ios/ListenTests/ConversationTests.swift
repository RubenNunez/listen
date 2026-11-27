import Foundation
import Testing

@testable import Listen

// Synthetic fixtures only: invented identifiers, words and capabilities.

private let lamp = ConversationCapabilityID("fixture.lamp")
private let session = ConversationSessionID("session-a")

/// Feeds one session and keeps every effect it returned.
private struct Fixture {
    var state = ConversationState(binding: ConversationBinding(
        session: session, topic: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        system: "fixture-system", systemSnapshot: "snapshot-1"))
    var effects: [ConversationEffect] = []

    @discardableResult
    mutating func send(_ kind: ConversationEvent.Kind, to target: ConversationSessionID = session) -> [ConversationEffect] {
        let new = ConversationReducer.reduce(&state, ConversationEvent(session: target, kind: kind))
        effects += new
        return new
    }

    /// A started session in which the lamp capability was reported as available.
    static func active() -> Fixture {
        var fixture = Fixture()
        fixture.send(.capabilityReported(lamp, .available))
        fixture.send(.start)
        return fixture
    }

    var dispatches: [ConversationOperationID] {
        effects.compactMap {
            if case .dispatchOperation(let request, _) = $0 { request.id } else { nil }
        }
    }

    var enqueued: [Int] {
        effects.compactMap {
            if case .enqueueAudio(_, let sequence) = $0 { sequence } else { nil }
        }
    }

    var submitted: [ConversationTurn] {
        effects.compactMap {
            if case .submitTurn(let turn) = $0 { turn } else { nil }
        }
    }
}

private func request(_ id: String, proposedBy: ConversationResponseID? = nil) -> ConversationOperationRequest {
    ConversationOperationRequest(
        id: ConversationOperationID(id), capability: lamp, arguments: ["on": .boolean(true)], proposedBy: proposedBy)
}

private func grant(_ id: String, capability: ConversationCapabilityID = lamp) -> ConversationAuthorization {
    .granted(ConversationGrant(operation: ConversationOperationID(id), capability: capability, basis: .confirmedThisUse))
}

@Suite struct ConversationFoundationTests {
    private let turn1 = ConversationTurnID("turn-1")
    private let turn2 = ConversationTurnID("turn-2")
    private let response1 = ConversationResponseID("response-1")
    private let response2 = ConversationResponseID("response-2")
    private let op1 = ConversationOperationID("op-1")

    // MARK: Input

    @Test func revisionsThenCommitMakeOneTurnSubmittedOnce() {
        var fixture = Fixture.active()
        #expect(fixture.send(.speechStarted(turn: turn1, speaker: .unknown)).isEmpty)
        #expect(fixture.send(.transcriptRevised(turn: turn1, revision: 1, text: "lamp", speaker: .unknown)).isEmpty)
        #expect(fixture.send(.transcriptRevised(turn: turn1, revision: 2, text: "lamp on", speaker: .speaker(1))).isEmpty)
        // An older revision arriving late does not overwrite the newer one.
        fixture.send(.transcriptRevised(turn: turn1, revision: 1, text: "lamp", speaker: .unknown))
        #expect(fixture.state.turn(turn1)?.text == "lamp on")

        let committed = fixture.send(.utteranceCommitted(turn: turn1, text: "lamp on please", speaker: .speaker(1)))
        let expected = ConversationTurn(
            id: turn1, status: .committed, revision: 2, text: "lamp on please", speaker: .speaker(1))
        #expect(committed == [.submitTurn(expected)])

        // Repeated commit and a late revision change nothing and submit nothing.
        #expect(fixture.send(.utteranceCommitted(turn: turn1, text: "lamp off", speaker: .me)).isEmpty)
        #expect(fixture.send(.transcriptRevised(turn: turn1, revision: 9, text: "lamp off", speaker: .me)).isEmpty)
        #expect(fixture.state.turns == [expected])
        #expect(fixture.submitted.count == 1)
    }

    @Test func unknownAndOverlapEvidenceIsKeptAndAuthorizesNothing() {
        var fixture = Fixture.active()
        fixture.send(.utteranceCommitted(turn: turn1, text: "switch the lamp on", speaker: .overlap))
        fixture.send(.utteranceCommitted(turn: turn2, text: "yes do it", speaker: .unknown))
        #expect(fixture.submitted.map(\.speaker) == [.overlap, .unknown])
        // Speech alone, even from the confirmed self label, creates and dispatches no operation.
        fixture.send(.utteranceCommitted(turn: ConversationTurnID("turn-3"), text: "I allow it", speaker: .me))
        #expect(fixture.state.operations.isEmpty)
        #expect(fixture.dispatches.isEmpty)
    }

    @Test func aCommitWithoutWordsIsDiscardedNotSubmitted() {
        var fixture = Fixture.active()
        fixture.send(.speechStarted(turn: turn1, speaker: .unknown))
        #expect(fixture.send(.utteranceCommitted(turn: turn1, text: "  ", speaker: .unknown)).isEmpty)
        #expect(fixture.state.turn(turn1)?.status == .discarded)
    }

    // MARK: Output

    @Test func failedPlaybackStopsAudioButAllowsTheAnswerTextToComplete() {
        var fixture = Fixture.active()
        fixture.send(.responseStarted(response: response1, inReplyTo: turn1))
        fixture.send(.responseAudio(response: response1, sequence: 0))
        fixture.send(.playbackStarted(response: response1))
        #expect(fixture.send(.playbackFailed(response: response1)).isEmpty)
        #expect(fixture.send(.responseAudio(response: response1, sequence: 1)).isEmpty)
        fixture.send(.playbackStarted(response: response1))
        fixture.send(.playbackFinished(response: response1))
        fixture.send(.responseText(response: response1, text: "The complete answer remains available."))
        fixture.send(.responseCompleted(response: response1))
        let response = fixture.state.response(response1)
        #expect(response?.status == .completed && response?.playback == .failed && response?.isLive == false)
        #expect(response?.text == "The complete answer remains available." && response?.heardThrough == nil)
    }

    @Test func generatedAudioIsNotHeardUntilPlaybackAcknowledgesIt() {
        var fixture = Fixture.active()
        fixture.send(.responseStarted(response: response1, inReplyTo: turn1))
        #expect(fixture.send(.responseAudio(response: response1, sequence: 0)) == [
            .enqueueAudio(response: response1, sequence: 0)
        ])
        fixture.send(.responseAudio(response: response1, sequence: 1))
        // A repeated chunk is not played twice.
        #expect(fixture.send(.responseAudio(response: response1, sequence: 1)).isEmpty)
        #expect(fixture.state.response(response1)?.enqueuedThrough == 1)
        #expect(fixture.state.response(response1)?.heardThrough == nil)

        fixture.send(.playbackStarted(response: response1))
        // An acknowledgement beyond what was handed to playback is not believed.
        fixture.send(.playbackAcknowledged(response: response1, through: 5))
        #expect(fixture.state.response(response1)?.heardThrough == nil)
        fixture.send(.playbackAcknowledged(response: response1, through: 0))
        #expect(fixture.state.response(response1)?.heardThrough == 0)

        fixture.send(.responseCompleted(response: response1))
        #expect(fixture.state.response(response1)?.isLive == true)
        fixture.send(.playbackFinished(response: response1))
        #expect(fixture.state.response(response1)?.isLive == false)
    }

    @Test func interruptionStopsPlaybackAndDropsLateOutput() {
        var fixture = Fixture.active()
        fixture.send(.responseStarted(response: response1, inReplyTo: nil))
        fixture.send(.responseText(response: response1, text: "The lamp"))
        fixture.send(.responseAudio(response: response1, sequence: 0))
        fixture.send(.playbackStarted(response: response1))

        #expect(fixture.send(.interrupted(response: response1)) == [
            .stopPlayback(response: response1), .cancelResponse(response: response1),
        ])
        let cut = fixture.state.response(response1)

        // Everything the provider still sends for that response is dropped.
        #expect(fixture.send(.responseText(response: response1, text: " is on")).isEmpty)
        #expect(fixture.send(.responseAudio(response: response1, sequence: 1)).isEmpty)
        #expect(fixture.send(.responseCompleted(response: response1)).isEmpty)
        #expect(fixture.send(.playbackStarted(response: response1)).isEmpty)
        #expect(fixture.send(.playbackFinished(response: response1)).isEmpty)
        #expect(fixture.send(.responseStarted(response: response1, inReplyTo: nil)).isEmpty)
        #expect(fixture.send(.interrupted(response: response1)).isEmpty)
        #expect(fixture.state.response(response1) == cut)
        #expect(cut?.status == .interrupted)
        #expect(cut?.text == "The lamp")
        #expect(fixture.enqueued == [0])

        // What was really played before the cut may still be acknowledged.
        fixture.send(.playbackAcknowledged(response: response1, through: 0))
        #expect(fixture.state.response(response1)?.heardThrough == 0)

        // The next response is unaffected.
        fixture.send(.responseStarted(response: response2, inReplyTo: nil))
        #expect(fixture.send(.responseAudio(response: response2, sequence: 0)) == [
            .enqueueAudio(response: response2, sequence: 0)
        ])
    }

    @Test func anInterruptionThatOvertakesTheStartStillSilencesTheResponse() {
        var fixture = Fixture.active()
        // The user cut in before the provider's start for this response arrived.
        #expect(fixture.send(.interrupted(response: response1)) == [
            .stopPlayback(response: response1), .cancelResponse(response: response1),
        ])
        let cut = fixture.state.response(response1)
        #expect(cut?.status == .interrupted)

        #expect(fixture.send(.responseStarted(response: response1, inReplyTo: turn1)).isEmpty)
        #expect(fixture.send(.responseText(response: response1, text: "The lamp")).isEmpty)
        #expect(fixture.send(.responseAudio(response: response1, sequence: 0)).isEmpty)
        #expect(fixture.send(.responseCompleted(response: response1)).isEmpty)
        #expect(fixture.send(.interrupted(response: response1)).isEmpty)
        #expect(fixture.state.response(response1) == cut)
        #expect(fixture.state.responses.count == 1)
        #expect(fixture.enqueued.isEmpty)
    }

    @Test func outputWithoutAReportedStartCreatesTheResponse() {
        var fixture = Fixture.active()
        // Audio first, the start never reported.
        #expect(fixture.send(.responseAudio(response: response1, sequence: 0)) == [
            .enqueueAudio(response: response1, sequence: 0)
        ])
        fixture.send(.responseText(response: response1, text: "On."))
        #expect(fixture.state.response(response1)?.status == .generating)
        #expect(fixture.state.response(response1)?.inReplyTo == nil)
        #expect(fixture.state.response(response1)?.text == "On.")

        // A start arriving late neither duplicates nor resets it, and it can be interrupted.
        fixture.send(.responseStarted(response: response1, inReplyTo: turn1))
        #expect(fixture.state.responses.count == 1)
        #expect(fixture.state.response(response1)?.enqueuedThrough == 0)
        #expect(fixture.send(.interrupted(response: response1)) == [
            .stopPlayback(response: response1), .cancelResponse(response: response1),
        ])

        // Text or completion alone creates one too.
        fixture.send(.responseText(response: response2, text: "Yes"))
        #expect(fixture.state.response(response2)?.text == "Yes")
        let response3 = ConversationResponseID("response-3")
        fixture.send(.responseCompleted(response: response3))
        #expect(fixture.state.response(response3)?.status == .completed)
    }

    @Test func interruptingAfterGenerationEndedStopsPlaybackOnly() {
        var fixture = Fixture.active()
        fixture.send(.responseStarted(response: response1, inReplyTo: nil))
        fixture.send(.responseAudio(response: response1, sequence: 0))
        fixture.send(.responseCompleted(response: response1))
        fixture.send(.playbackStarted(response: response1))
        #expect(fixture.send(.interrupted(response: response1)) == [.stopPlayback(response: response1)])

        // A response that was played out has nothing left to interrupt.
        fixture.send(.responseStarted(response: response2, inReplyTo: nil))
        fixture.send(.responseCompleted(response: response2))
        #expect(fixture.send(.interrupted(response: response2)).isEmpty)
        #expect(fixture.state.response(response2)?.status == .completed)
    }

    // MARK: Operations

    @Test func aSlowOperationFinishesWhileAnotherUtteranceIsAccepted() {
        var fixture = Fixture.active()
        fixture.send(.responseStarted(response: response1, inReplyTo: turn1))
        fixture.send(.operationProposed(request("op-1", proposedBy: response1)))
        fixture.send(.operationAuthorization(operation: op1, grant("op-1")))
        #expect(fixture.dispatches == [op1])

        // The user interrupts the response and speaks again while the tool still works.
        fixture.send(.responseAudio(response: response1, sequence: 0))
        fixture.send(.interrupted(response: response1))
        #expect(fixture.state.operation(op1)?.state == .dispatched)
        fixture.send(.speechStarted(turn: turn2, speaker: .me))
        #expect(fixture.send(.utteranceCommitted(turn: turn2, text: "and what time is it", speaker: .me)).count == 1)
        #expect(fixture.state.outstandingOperations.map(\.id) == [op1])
        fixture.send(.responseStarted(response: response2, inReplyTo: turn2))

        // The result arrives later and is reported as observed. It plays nothing by itself.
        #expect(fixture.send(.operationResult(operation: op1, .succeeded(detail: "on"))) == [
            .reportOperation(op1, .succeeded(detail: "on"))
        ])
        #expect(fixture.state.outstandingOperations.isEmpty)
        #expect(fixture.state.response(response2)?.status == .generating)
        #expect(fixture.dispatches == [op1])
    }

    @Test func aProposalWithoutALocalGrantDispatchesNothing() {
        var fixture = Fixture.active()
        #expect(fixture.send(.operationProposed(request("op-1"))) == [.requestAuthorization(request("op-1"))])
        #expect(fixture.state.operation(op1)?.state == .proposed)

        // Being asked is not being allowed, and neither is anything said meanwhile.
        fixture.send(.operationAuthorization(operation: op1, .awaitingOwner))
        #expect(fixture.state.operation(op1)?.state == .awaitingAuthorization)
        fixture.send(.utteranceCommitted(turn: turn1, text: "yes go ahead", speaker: .me))
        fixture.send(.responseStarted(response: response1, inReplyTo: turn1))
        fixture.send(.responseText(response: response1, text: "Done, the lamp is on."))
        fixture.send(.responseCompleted(response: response1))

        // A grant for another operation or another capability does not fit.
        fixture.send(.operationAuthorization(operation: op1, grant("op-2")))
        fixture.send(.operationAuthorization(operation: op1, grant("op-1", capability: ConversationCapabilityID("fixture.door"))))
        // A result for something never dispatched is not believed.
        #expect(fixture.send(.operationResult(operation: op1, .succeeded(detail: "on"))).isEmpty)
        #expect(fixture.state.operation(op1)?.state == .awaitingAuthorization)
        #expect(fixture.dispatches.isEmpty)

        #expect(fixture.send(.operationAuthorization(operation: op1, .denied)) == [
            .reportOperation(op1, .cancelledBeforeDispatch(.denied))
        ])
        // A grant after the denial comes too late.
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.dispatches.isEmpty)
    }

    @Test func duplicatesAndReconnectReplayNeverDispatchTwice() {
        var fixture = Fixture.active()
        fixture.send(.operationProposed(request("op-1")))
        let granted = fixture.send(.operationAuthorization(operation: op1, grant("op-1")))
        #expect(granted == [
            .dispatchOperation(
                request("op-1"),
                grant: ConversationGrant(operation: op1, capability: lamp, basis: .confirmedThisUse))
        ])

        // Duplicate grant, and a reconnect that replays proposal and grant under the same ID.
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.send(.operationProposed(request("op-1"))).isEmpty)
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.send(.operationAuthorization(operation: op1, .denied)).isEmpty)
        #expect(fixture.send(.operationWithdrawn(operation: op1)).isEmpty)
        #expect(fixture.state.operation(op1)?.state == .dispatched)

        #expect(fixture.send(.operationResult(operation: op1, .failed(detail: "busy"))).count == 1)
        // A finished result does not change, whatever arrives afterwards.
        #expect(fixture.send(.operationResult(operation: op1, .succeeded(detail: "on"))).isEmpty)
        #expect(fixture.send(.operationResult(operation: op1, .failed(detail: "busy"))).isEmpty)
        #expect(fixture.send(.operationTimedOut(operation: op1)).isEmpty)
        #expect(fixture.send(.toolRouteLost).isEmpty)
        #expect(fixture.send(.operationProposed(request("op-1"))).isEmpty)
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.state.operation(op1)?.state == .failed(detail: "busy"))
        #expect(fixture.dispatches == [op1])
    }

    @Test func aLostRouteAfterDispatchLeavesTheOutcomeUnknownAndRetriesNothing() {
        var fixture = Fixture.active()
        fixture.send(.operationProposed(request("op-1")))
        fixture.send(.operationProposed(request("op-2")))
        fixture.send(.operationAuthorization(operation: op1, grant("op-1")))

        // Only the dispatched operation becomes unknown; the other was never sent.
        #expect(fixture.send(.toolRouteLost) == [.reportOperation(op1, .outcomeUnknown(.routeLost))])
        #expect(fixture.state.operation(ConversationOperationID("op-2"))?.state == .proposed)

        // Coming back: replayed proposal and grant do not send it again.
        fixture.send(.capabilityReported(lamp, .available))
        #expect(fixture.send(.operationProposed(request("op-1"))).isEmpty)
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.send(.operationTimedOut(operation: op1)).isEmpty)
        #expect(fixture.state.operation(op1)?.state == .outcomeUnknown(.routeLost))
        #expect(fixture.state.outstandingOperations.contains { $0.id == op1 })
        #expect(fixture.dispatches == [op1])

        // Only an observed result settles it.
        #expect(fixture.send(.operationResult(operation: op1, .succeeded(detail: "on"))) == [
            .reportOperation(op1, .succeeded(detail: "on"))
        ])
    }

    @Test func aTimeoutNeverBecomesSuccess() {
        var fixture = Fixture.active()
        fixture.send(.operationProposed(request("op-1")))
        fixture.send(.operationProposed(request("op-2")))
        fixture.send(.operationAuthorization(operation: op1, grant("op-1")))
        fixture.send(.operationTimedOut(operation: op1))
        fixture.send(.operationTimedOut(operation: ConversationOperationID("op-2")))
        #expect(fixture.state.operation(op1)?.state == .outcomeUnknown(.timedOut))
        #expect(fixture.state.operation(ConversationOperationID("op-2"))?.state == .cancelledBeforeDispatch(.expired))
        // The expired one can no longer be granted.
        #expect(fixture.send(.operationAuthorization(operation: ConversationOperationID("op-2"), grant("op-2"))).isEmpty)
        #expect(fixture.dispatches == [op1])
    }

    @Test func aProposalFromAnInterruptedResponseIsNotPursued() {
        var fixture = Fixture.active()
        fixture.send(.responseStarted(response: response1, inReplyTo: nil))
        fixture.send(.interrupted(response: response1))
        // The model route is told, like for every other cancellation in a running session.
        #expect(fixture.send(.operationProposed(request("op-1", proposedBy: response1))) == [
            .reportOperation(op1, .cancelledBeforeDispatch(.proposerCutOff))
        ])
        #expect(fixture.state.operation(op1)?.state == .cancelledBeforeDispatch(.proposerCutOff))
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
    }

    @Test func aGrantWhileTheToolRouteIsLostCancelsAndAfterItsReturnDispatches() {
        var fixture = Fixture.active()
        fixture.send(.operationProposed(request("op-1")))
        fixture.send(.operationProposed(request("op-2")))
        fixture.send(.operationAuthorization(operation: op1, .awaitingOwner))

        // Nothing was dispatched, so the loss reports nothing; the operations stay pending.
        #expect(fixture.send(.toolRouteLost).isEmpty)
        #expect(fixture.state.capability(lamp) == .unavailable(.routeUnreachable))
        #expect(fixture.state.operation(op1)?.state == .awaitingAuthorization)
        #expect(fixture.state.operation(ConversationOperationID("op-2"))?.state == .proposed)

        // A grant now has no gateway to go to.
        let unreachable = ConversationOperationState.cancelledBeforeDispatch(
            .capability(.unavailable(.routeUnreachable)))
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))) == [
            .reportOperation(op1, unreachable)
        ])
        // A new proposal is refused the same way.
        #expect(fixture.send(.operationProposed(request("op-3"))) == [
            .reportOperation(ConversationOperationID("op-3"), unreachable)
        ])
        #expect(fixture.dispatches.isEmpty)

        // The adapter reports the capability again: the still pending operation goes out,
        // the cancelled one does not come back.
        fixture.send(.capabilityReported(lamp, .available))
        fixture.send(.operationAuthorization(operation: ConversationOperationID("op-2"), grant("op-2")))
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.dispatches == [ConversationOperationID("op-2")])
    }

    @Test func aRouteLossLeavesUnusableCapabilitiesWithTheirOwnReason() {
        var fixture = Fixture.active()
        let door = ConversationCapabilityID("fixture.door")
        let gate = ConversationCapabilityID("fixture.gate")
        fixture.send(.capabilityReported(door, .unavailable(.accessDenied)))
        fixture.send(.capabilityReported(gate, .configured))
        fixture.send(.toolRouteLost)
        #expect(fixture.state.capability(door) == .unavailable(.accessDenied))
        #expect(fixture.state.capability(gate) == .configured)
        #expect(fixture.state.capability(lamp) == .unavailable(.routeUnreachable))
    }

    // MARK: Stop and other sessions

    @Test func stopEndsOutputAndDispatchButKeepsLateResultsAsHistory() {
        var fixture = Fixture.active()
        fixture.send(.speechStarted(turn: turn1, speaker: .me))
        fixture.send(.responseStarted(response: response1, inReplyTo: nil))
        fixture.send(.responseAudio(response: response1, sequence: 0))
        fixture.send(.operationProposed(request("op-1")))
        fixture.send(.operationAuthorization(operation: op1, grant("op-1")))
        fixture.send(.operationProposed(request("op-2")))

        #expect(fixture.send(.stop) == [
            .endCapture, .stopPlayback(response: response1), .cancelResponse(response: response1),
        ])
        #expect(fixture.state.phase == .stopped)
        #expect(fixture.state.turn(turn1)?.status == .discarded)
        #expect(fixture.state.response(response1)?.status == .stopped)
        #expect(fixture.state.operation(ConversationOperationID("op-2"))?.state == .cancelledBeforeDispatch(.sessionStopped))
        // Stop does not pretend the dispatched action was undone.
        #expect(fixture.state.operation(op1)?.state == .dispatched)

        // Nothing restarts speech, capture or dispatch afterwards.
        let stopped = fixture.state
        let late: [ConversationEvent.Kind] = [
            .start, .stop,
            .utteranceCommitted(turn: turn2, text: "lamp off", speaker: .me),
            .responseAudio(response: response1, sequence: 1),
            .responseStarted(response: response2, inReplyTo: nil),
            .responseAudio(response: response2, sequence: 0),
            .operationAuthorization(operation: ConversationOperationID("op-2"), grant("op-2")),
            .operationProposed(request("op-3")),
            .operationAuthorization(operation: ConversationOperationID("op-3"), grant("op-3")),
        ]
        for kind in late {
            #expect(fixture.send(kind).isEmpty)
        }
        #expect(fixture.state == stopped)

        // The dispatched operation's late result is recorded, silently.
        #expect(fixture.send(.operationResult(operation: op1, .succeeded(detail: "on"))).isEmpty)
        #expect(fixture.state.operation(op1)?.state == .succeeded(detail: "on"))
        #expect(fixture.dispatches == [op1])
    }

    @Test func anotherSessionsEventsChangeNothing() {
        var fixture = Fixture.active()
        fixture.send(.responseStarted(response: response1, inReplyTo: nil))
        fixture.send(.operationProposed(request("op-1")))
        let before = fixture.state
        let other = ConversationSessionID("session-b")
        let foreign: [ConversationEvent.Kind] = [
            .stop,
            .utteranceCommitted(turn: turn1, text: "lamp on", speaker: .me),
            .responseAudio(response: response1, sequence: 0),
            .interrupted(response: response1),
            .operationAuthorization(operation: op1, grant("op-1")),
            .operationResult(operation: op1, .succeeded(detail: "on")),
            .capabilityReported(lamp, .unavailable(.accessDenied)),
            .toolRouteLost,
        ]
        for kind in foreign {
            #expect(fixture.send(kind, to: other).isEmpty)
        }
        #expect(fixture.state == before)

        // The same holds once this session has stopped.
        fixture.send(.operationAuthorization(operation: op1, grant("op-1")))
        fixture.send(.stop)
        let stopped = fixture.state
        #expect(fixture.send(.operationResult(operation: op1, .succeeded(detail: "on")), to: other).isEmpty)
        #expect(fixture.state == stopped)
    }

    // MARK: Capabilities

    @Test func anUnavailableCapabilityIsRefusedWithItsReason() {
        var fixture = Fixture.active()
        fixture.send(.capabilityReported(lamp, .unavailable(.routeUnreachable)))
        let refused = ConversationOperationState.cancelledBeforeDispatch(.capability(.unavailable(.routeUnreachable)))
        // The refusal is the only effect: no authorization request, no dispatch, no other route.
        #expect(fixture.send(.operationProposed(request("op-1"))) == [.reportOperation(op1, refused)])
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.send(.operationResult(operation: op1, .succeeded(detail: "on"))).isEmpty)
        #expect(fixture.state.operation(op1)?.state == refused)

        // It does not come back to life when the capability returns.
        fixture.send(.capabilityReported(lamp, .verified))
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))).isEmpty)
        #expect(fixture.dispatches.isEmpty)
    }

    @Test func onlyAvailableOrVerifiedCapabilitiesCarryOperations() {
        var fixture = Fixture.active()
        let door = ConversationCapabilityID("fixture.door")
        // Never reported: unavailable, with a reason.
        #expect(fixture.state.capability(door) == .unavailable(.notConfigured))
        #expect(!ConversationCapabilityStatus.requested.canCarryOperations)
        #expect(!ConversationCapabilityStatus.configured.canCarryOperations)
        #expect(ConversationCapabilityStatus.available.canCarryOperations)
        #expect(ConversationCapabilityStatus.verified.canCarryOperations)

        fixture.send(.capabilityReported(door, .configured))
        let viaDoor = ConversationOperationRequest(id: op1, capability: door)
        #expect(fixture.send(.operationProposed(viaDoor)) == [
            .reportOperation(op1, .cancelledBeforeDispatch(.capability(.configured)))
        ])
    }

    @Test func aCapabilityLostBeforeTheGrantCancelsInsteadOfDispatching() {
        var fixture = Fixture.active()
        fixture.send(.operationProposed(request("op-1")))
        fixture.send(.capabilityReported(lamp, .unavailable(.accessDenied)))
        #expect(fixture.send(.operationAuthorization(operation: op1, grant("op-1"))) == [
            .reportOperation(op1, .cancelledBeforeDispatch(.capability(.unavailable(.accessDenied))))
        ])
        #expect(fixture.dispatches.isEmpty)
    }

    // MARK: Session

    @Test func nothingHappensBeforeStartAndTheBindingIsFixed() {
        var fixture = Fixture()
        #expect(fixture.send(.utteranceCommitted(turn: turn1, text: "lamp on", speaker: .me)).isEmpty)
        #expect(fixture.send(.operationProposed(request("op-1"))).isEmpty)
        #expect(fixture.state.turns.isEmpty && fixture.state.operations.isEmpty)
        #expect(fixture.send(.start) == [.beginCapture])
        #expect(fixture.send(.start).isEmpty)
        #expect(fixture.state.binding.system == "fixture-system")
    }
}
