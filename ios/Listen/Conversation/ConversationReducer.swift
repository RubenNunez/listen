import Foundation

/// Something that happened, addressed to one session. Adapters translate provider, audio
/// and tool-gateway events into these.
struct ConversationEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        // Session
        case start
        case stop
        case capabilityReported(ConversationCapabilityID, ConversationCapabilityStatus)

        // Input
        case speechStarted(turn: ConversationTurnID, speaker: SpeakerLabel)
        case transcriptRevised(turn: ConversationTurnID, revision: Int, text: String, speaker: SpeakerLabel)
        case utteranceCommitted(turn: ConversationTurnID, text: String, speaker: SpeakerLabel)

        // Output
        case responseStarted(response: ConversationResponseID, inReplyTo: ConversationTurnID?)
        case responseText(response: ConversationResponseID, text: String)
        /// The adapter holds chunk `sequence` and plays it only when told to by an effect.
        case responseAudio(response: ConversationResponseID, sequence: Int)
        case responseCompleted(response: ConversationResponseID)
        case playbackStarted(response: ConversationResponseID)
        case playbackAcknowledged(response: ConversationResponseID, through: Int)
        case playbackFinished(response: ConversationResponseID)
        case playbackFailed(response: ConversationResponseID)
        case interrupted(response: ConversationResponseID)

        // Operations
        case operationProposed(ConversationOperationRequest)
        case operationAuthorization(operation: ConversationOperationID, ConversationAuthorization)
        case operationWithdrawn(operation: ConversationOperationID)
        case operationResult(operation: ConversationOperationID, ConversationOperationOutcome)
        case operationTimedOut(operation: ConversationOperationID)
        /// One tool request lost its route; other operations may use different services.
        case operationRouteLost(operation: ConversationOperationID)
        /// The connection to the tool gateway dropped.
        case toolRouteLost
    }

    let session: ConversationSessionID
    let kind: Kind
}

/// Work for an adapter. The reducer performs none of it.
enum ConversationEffect: Equatable, Sendable {
    case beginCapture
    case endCapture
    /// A committed utterance for the model route. Sent once per turn.
    case submitTurn(ConversationTurn)
    case enqueueAudio(response: ConversationResponseID, sequence: Int)
    /// Silence this response now and drop what is buffered for it.
    case stopPlayback(response: ConversationResponseID)
    /// Tell the provider to stop generating this response.
    case cancelResponse(response: ConversationResponseID)
    /// Ask the installation's authorization for a decision on this operation.
    case requestAuthorization(ConversationOperationRequest)
    /// Hand the operation to the tool gateway. Emitted at most once per operation ID.
    case dispatchOperation(ConversationOperationRequest, grant: ConversationGrant)
    /// An operation reached a state the model route should be told about, so that what
    /// the assistant says matches what was observed.
    case reportOperation(ConversationOperationID, ConversationOperationState)
}

struct ConversationState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case ready
        case active
        /// Final. A new conversation needs a new session.
        case stopped
    }

    let binding: ConversationBinding
    fileprivate(set) var phase = Phase.ready
    /// In the order they were first heard, started or proposed.
    fileprivate(set) var turns: [ConversationTurn] = []
    fileprivate(set) var responses: [ConversationResponse] = []
    fileprivate(set) var operations: [ConversationOperation] = []
    fileprivate(set) var capabilities: [ConversationCapabilityID: ConversationCapabilityStatus] = [:]

    init(binding: ConversationBinding) {
        self.binding = binding
    }

    func turn(_ id: ConversationTurnID) -> ConversationTurn? {
        turns.first { $0.id == id }
    }

    func response(_ id: ConversationResponseID) -> ConversationResponse? {
        responses.first { $0.id == id }
    }

    func operation(_ id: ConversationOperationID) -> ConversationOperation? {
        operations.first { $0.id == id }
    }

    /// A capability nobody reported is unavailable, not assumed.
    func capability(_ id: ConversationCapabilityID) -> ConversationCapabilityStatus {
        capabilities[id] ?? .unavailable(.notConfigured)
    }

    /// Operations whose result is still open, whatever the assistant is saying meanwhile.
    var outstandingOperations: [ConversationOperation] {
        operations.filter { !$0.state.isFinal }
    }
}

/// The rules of one conversation as a pure function: state and event in, effects out.
///
/// - An event for another session changes nothing.
/// - Hearing, speaking and delegated work advance independently of each other.
/// - A turn is submitted once, at its commit. Revisions submit nothing.
/// - Audio is played only through `enqueueAudio`; an interrupted or stopped response
///   gets none, however late its output arrives.
/// - An operation is dispatched only on a grant for that operation and capability, at
///   most once per operation ID, and never after Stop.
/// - Losing the tool route makes every capability unavailable until it is reported again.
/// - A dispatched operation is finished only by an observed result. Without one it
///   becomes `outcomeUnknown` and is not sent again.
enum ConversationReducer {
    static func reduce(_ state: inout ConversationState, _ event: ConversationEvent) -> [ConversationEffect] {
        guard event.session == state.binding.session else { return [] }

        switch state.phase {
        case .ready:
            switch event.kind {
            case .start:
                state.phase = .active
                return [.beginCapture]
            case .capabilityReported(let id, let status):
                state.capabilities[id] = status
                return []
            case .stop:
                state.phase = .stopped
                return []
            default:
                return []
            }
        case .active:
            return active(&state, event.kind)
        case .stopped:
            // Only what was already dispatched can still be accounted for. Nothing is
            // reported onwards: there is no conversation left to speak in.
            _ = settle(&state, event.kind)
            return []
        }
    }

    // MARK: Active session

    private static func active(_ state: inout ConversationState, _ kind: ConversationEvent.Kind) -> [ConversationEffect] {
        switch kind {
        case .start:
            return []

        case .stop:
            return stop(&state)

        case .capabilityReported(let id, let status):
            state.capabilities[id] = status
            return []

        case .speechStarted(let id, let speaker):
            _ = turnIndex(&state, id, speaker: speaker)
            return []

        case .transcriptRevised(let id, let revision, let text, let speaker):
            let index = turnIndex(&state, id, speaker: speaker)
            guard state.turns[index].status == .hearing, revision > state.turns[index].revision else { return [] }
            state.turns[index].revision = revision
            state.turns[index].text = text
            state.turns[index].speaker = speaker
            return []

        case .utteranceCommitted(let id, let text, let speaker):
            let index = turnIndex(&state, id, speaker: speaker)
            guard state.turns[index].status == .hearing else { return [] }
            state.turns[index].text = text
            state.turns[index].speaker = speaker
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state.turns[index].status = .discarded
                return []
            }
            state.turns[index].status = .committed
            return [.submitTurn(state.turns[index])]

        case .responseStarted(let id, let inReplyTo):
            if state.response(id) == nil {
                state.responses.append(ConversationResponse(id: id, inReplyTo: inReplyTo))
            }
            return []

        case .responseText(let id, let text):
            guard let index = generating(&state, id) else { return [] }
            state.responses[index].text += text
            return []

        case .responseAudio(let id, let sequence):
            guard let index = generating(&state, id), state.responses[index].playback != .failed,
                  sequence > state.responses[index].enqueuedThrough ?? -1 else {
                return []
            }
            state.responses[index].enqueuedThrough = sequence
            return [.enqueueAudio(response: id, sequence: sequence)]

        case .responseCompleted(let id):
            guard let index = generating(&state, id) else { return [] }
            state.responses[index].status = .completed
            return []

        case .playbackStarted(let id):
            guard let index = state.responses.firstIndex(where: { $0.id == id }), state.responses[index].isLive,
                state.responses[index].playback != .failed,
                state.responses[index].enqueuedThrough != nil
            else { return [] }
            state.responses[index].playback = .playing
            return []

        case .playbackAcknowledged(let id, let through):
            // What was played stays true after an interruption, so this is recorded for
            // cut-off responses too. It cannot exceed what was handed to playback.
            guard let index = state.responses.firstIndex(where: { $0.id == id }),
                let enqueued = state.responses[index].enqueuedThrough, through <= enqueued,
                through > state.responses[index].heardThrough ?? -1
            else { return [] }
            state.responses[index].heardThrough = through
            return []

        case .playbackFinished(let id):
            guard let index = state.responses.firstIndex(where: { $0.id == id }), state.responses[index].isLive,
                state.responses[index].playback == .playing
            else { return [] }
            state.responses[index].playback = .finished
            return []

        case .playbackFailed(let id):
            guard let index = state.responses.firstIndex(where: { $0.id == id }), state.responses[index].isLive,
                  state.responses[index].playback != .finished else { return [] }
            state.responses[index].playback = .failed
            return [] // Text generation and actual operation outcomes remain independent.

        case .interrupted(let id):
            guard let index = state.responses.firstIndex(where: { $0.id == id }) else {
                // The interruption overtook the provider's start. The response is recorded
                // as cut off, so its start and output are dropped when they arrive. The
                // provider may be generating it already, so it is told to stop as well.
                state.responses.append(ConversationResponse(id: id, inReplyTo: nil))
                return cutOff(&state.responses[state.responses.count - 1], as: .interrupted)
            }
            guard state.responses[index].isLive else { return [] }
            return cutOff(&state.responses[index], as: .interrupted)

        case .operationProposed(let request):
            guard state.operation(request.id) == nil else { return [] }
            var operation = ConversationOperation(request: request)
            defer { state.operations.append(operation) }
            if let proposer = request.proposedBy, let response = state.response(proposer),
                response.status == .interrupted || response.status == .stopped
            {
                operation.state = .cancelledBeforeDispatch(.proposerCutOff)
                return [.reportOperation(request.id, operation.state)]
            }
            let capability = state.capability(request.capability)
            guard capability.canCarryOperations else {
                operation.state = .cancelledBeforeDispatch(.capability(capability))
                return [.reportOperation(request.id, operation.state)]
            }
            return [.requestAuthorization(request)]

        case .operationAuthorization(let id, let authorization):
            guard let index = state.operations.firstIndex(where: { $0.id == id }) else { return [] }
            let request = state.operations[index].request
            guard state.operations[index].state == .proposed || state.operations[index].state == .awaitingAuthorization
            else { return [] }
            switch authorization {
            case .awaitingOwner:
                state.operations[index].state = .awaitingAuthorization
                return []
            case .denied:
                return finish(&state.operations[index], .cancelledBeforeDispatch(.denied))
            case .granted(let grant):
                // A grant for another operation or capability authorizes nothing here.
                guard grant.operation == id, grant.capability == request.capability else { return [] }
                let capability = state.capability(request.capability)
                guard capability.canCarryOperations else {
                    return finish(&state.operations[index], .cancelledBeforeDispatch(.capability(capability)))
                }
                state.operations[index].state = .dispatched
                state.operations[index].grant = grant
                return [.dispatchOperation(request, grant: grant)]
            }

        case .operationWithdrawn(let id):
            guard let index = state.operations.firstIndex(where: { $0.id == id }),
                !state.operations[index].state.wasDispatched, !state.operations[index].state.isFinal
            else { return [] }
            return finish(&state.operations[index], .cancelledBeforeDispatch(.withdrawn))

        case .operationResult, .operationTimedOut, .operationRouteLost, .toolRouteLost:
            return settle(&state, kind)
        }
    }

    /// The turn's place, adding the turn when its beginning was never reported.
    private static func turnIndex(
        _ state: inout ConversationState, _ id: ConversationTurnID, speaker: SpeakerLabel
    ) -> Int {
        if let index = state.turns.firstIndex(where: { $0.id == id }) { return index }
        state.turns.append(ConversationTurn(id: id, speaker: speaker))
        return state.turns.count - 1
    }

    /// The response's place while it still takes output, adding the response when its
    /// start was never reported. Nil for one that completed or was cut off.
    private static func generating(_ state: inout ConversationState, _ id: ConversationResponseID) -> Int? {
        guard let index = state.responses.firstIndex(where: { $0.id == id }) else {
            state.responses.append(ConversationResponse(id: id, inReplyTo: nil))
            return state.responses.count - 1
        }
        return state.responses[index].status == .generating ? index : nil
    }

    private static func cutOff(
        _ response: inout ConversationResponse, as status: ConversationResponse.Status
    ) -> [ConversationEffect] {
        let wasGenerating = response.status == .generating
        response.status = status
        return [.stopPlayback(response: response.id)] + (wasGenerating ? [.cancelResponse(response: response.id)] : [])
    }

    private static func stop(_ state: inout ConversationState) -> [ConversationEffect] {
        state.phase = .stopped
        var effects: [ConversationEffect] = [.endCapture]
        for index in state.responses.indices where state.responses[index].isLive {
            effects += cutOff(&state.responses[index], as: .stopped)
        }
        for index in state.turns.indices where state.turns[index].status == .hearing {
            state.turns[index].status = .discarded
        }
        for index in state.operations.indices
        where state.operations[index].state == .proposed || state.operations[index].state == .awaitingAuthorization {
            state.operations[index].state = .cancelledBeforeDispatch(.sessionStopped)
        }
        return effects
    }

    // MARK: Operations after dispatch

    /// Accounts for operations that may have left the device. Also runs after Stop, where
    /// the caller drops the returned reports.
    private static func settle(_ state: inout ConversationState, _ kind: ConversationEvent.Kind) -> [ConversationEffect] {
        switch kind {
        case .operationResult(let id, let outcome):
            // A result settles a dispatched operation, or one whose outcome was unknown
            // until this observation. It never changes a finished one, and an operation
            // that was not dispatched cannot have a result.
            guard let index = state.operations.firstIndex(where: { $0.id == id }),
                state.operations[index].state.wasDispatched, !state.operations[index].state.isFinal
            else { return [] }
            switch outcome {
            case .succeeded(let detail): return finish(&state.operations[index], .succeeded(detail: detail))
            case .failed(let detail): return finish(&state.operations[index], .failed(detail: detail))
            }

        case .operationTimedOut(let id):
            guard let index = state.operations.firstIndex(where: { $0.id == id }) else { return [] }
            switch state.operations[index].state {
            case .proposed, .awaitingAuthorization:
                return finish(&state.operations[index], .cancelledBeforeDispatch(.expired))
            case .dispatched:
                return finish(&state.operations[index], .outcomeUnknown(.timedOut))
            case .succeeded, .failed, .cancelledBeforeDispatch, .outcomeUnknown:
                return []
            }

        case .operationRouteLost(let id):
            guard let index = state.operations.firstIndex(where: { $0.id == id }),
                state.operations[index].state == .dispatched else { return [] }
            return finish(&state.operations[index], .outcomeUnknown(.routeLost))

        case .toolRouteLost:
            // Every operation goes through the gateway, so nothing can be carried until
            // the adapter reports a capability again. Operations not yet dispatched stay
            // as they are; a grant meanwhile cancels them instead of dispatching.
            for (id, status) in state.capabilities where status.canCarryOperations {
                state.capabilities[id] = .unavailable(.routeUnreachable)
            }
            var effects: [ConversationEffect] = []
            for index in state.operations.indices where state.operations[index].state == .dispatched {
                effects += finish(&state.operations[index], .outcomeUnknown(.routeLost))
            }
            return effects

        default:
            return []
        }
    }

    private static func finish(
        _ operation: inout ConversationOperation, _ newState: ConversationOperationState
    ) -> [ConversationEffect] {
        operation.state = newState
        return [.reportOperation(operation.id, newState)]
    }
}
