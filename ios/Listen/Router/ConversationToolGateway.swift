import Foundation

enum ConversationToolField: Sendable {
    case string, integer, number, boolean
    indirect case array(ConversationToolField)

    func accepts(_ value: ConversationValue) -> Bool {
        switch (self, value) {
        case (.string, .string(let text)): return text.utf8.count <= 4096
        case (.integer, .integer(let value)), (.number, .integer(let value)): return (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value)
        case (.boolean, .boolean): return true
        case (.number, .number(let number)): return number.isFinite
        case (.array(let item), .array(let values)):
            if case .array = item { return false }
            return values.count <= 64 && values.allSatisfy { item.accepts($0) }
        default: return false
        }
    }
}

/// A native installation binding. Imported configuration cannot create its executor or grants.
struct RegisteredConversationTool: Sendable {
    let id: ConversationCapabilityID
    let fields: [String: ConversationToolField]
    let required: Set<String>
    let execute: @Sendable (ConversationOperationRequest) async -> ConversationToolObservation
}

enum ConversationToolObservation: Equatable, Sendable {
    case completed(ConversationOperationOutcome)
    /// The request may have reached the service. Reconciliation is a separate observation.
    case unknown(ConversationOperationState.Unknown)
}

enum ConversationToolRefusal: Equatable, Sendable {
    case wrongSession, sessionStopped, unregistered, invalidArguments, notAuthorized, idConflict, capacity
}

enum ConversationToolDispatch: Equatable, Sendable {
    case observation(ConversationEvent)
    case refused(ConversationToolRefusal)
}

/// One executor per conversation. It performs only native registered tool functions;
/// there is no command interpreter or automatic retry. Not yet wired into the live app.
actor ConversationToolGateway {
    let session: ConversationSessionID
    private let tools: [ConversationCapabilityID: RegisteredConversationTool]
    private var standing: Set<ConversationCapabilityID>
    private var accepting = true
    private var proposals: [ConversationOperationID: ConversationOperationRequest] = [:]
    private var grants: [ConversationOperationID: ConversationGrant] = [:]
    private var dispatched: [ConversationOperationID: Task<ConversationToolDispatch, Never>] = [:]
    private let maximumOperations: Int

    init(session: ConversationSessionID, tools: [RegisteredConversationTool],
         standingGrants: Set<ConversationCapabilityID> = [], maximumOperations: Int = 256) {
        self.session = session
        // Duplicate registrations are unavailable instead of arbitrarily choosing an executor.
        let grouped = Dictionary(grouping: tools, by: \.id)
        self.tools = grouped.compactMapValues { $0.count == 1 ? $0[0] : nil }
        standing = standingGrants
        self.maximumOperations = max(0, maximumOperations)
    }

    private func valid(_ request: ConversationOperationRequest) -> Bool {
        guard let tool = tools[request.capability], !request.id.rawValue.isEmpty,
              request.id.rawValue.utf8.count <= 128, request.arguments.count <= 32,
              tool.required.isSubset(of: Set(tool.fields.keys)),
              tool.required.isSubset(of: Set(request.arguments.keys)),
              Set(request.arguments.keys).isSubset(of: Set(tool.fields.keys)) else { return false }
        return request.arguments.allSatisfy { tool.fields[$0.key]?.accepts($0.value) == true }
    }

    /// Receives requestAuthorization from the reducer, not provider-supplied permission flags.
    func authorize(_ request: ConversationOperationRequest) -> ConversationAuthorization {
        guard accepting, valid(request) else { return .denied }
        if let existing = proposals[request.id], existing != request { return .denied }
        guard proposals[request.id] != nil || proposals.count < maximumOperations else { return .denied }
        proposals[request.id] = request
        if let grant = grants[request.id] { return .granted(grant) }
        guard standing.contains(request.capability) else { return .awaitingOwner }
        let grant = ConversationGrant(operation: request.id, capability: request.capability, basis: .standing)
        grants[request.id] = grant
        return .granted(grant)
    }

    /// The owner-facing confirmation adapter calls this for the exact proposal displayed.
    func confirm(_ request: ConversationOperationRequest, remember: Bool = false) -> ConversationAuthorization {
        guard accepting, proposals[request.id] == request, valid(request) else { return .denied }
        if remember { standing.insert(request.capability) }
        let grant = ConversationGrant(operation: request.id, capability: request.capability, basis: .confirmedThisUse)
        grants[request.id] = grant
        return .granted(grant)
    }

    func stop() { accepting = false; grants.removeAll() }

    func dispatch(session requestedSession: ConversationSessionID, request: ConversationOperationRequest,
                  grant: ConversationGrant) async -> ConversationToolDispatch {
        guard requestedSession == session else { return .refused(.wrongSession) }
        guard proposals[request.id] == request else {
            return .refused(proposals[request.id] == nil ? .notAuthorized : .idConflict)
        }
        if let existing = dispatched[request.id] { return await existing.value }
        guard accepting else { return .refused(.sessionStopped) }
        guard let tool = tools[request.capability] else { return .refused(.unregistered) }
        guard valid(request) else { return .refused(.invalidArguments) }
        guard grants[request.id] == grant, grant.operation == request.id, grant.capability == request.capability else {
            return .refused(.notAuthorized)
        }
        let task = Task { () -> ConversationToolDispatch in
            guard accepting else {
                return .observation(.init(session: session, kind: .operationResult(operation: request.id,
                    .failed(detail: "Stopped before the tool request was sent."))))
            }
            // Once handed to a service, caller cancellation is not evidence of rollback.
            let observed = await tool.execute(request)
            let kind: ConversationEvent.Kind
            switch observed {
            case .completed(let outcome): kind = .operationResult(operation: request.id, outcome)
            case .unknown(.routeLost): kind = .operationRouteLost(operation: request.id)
            case .unknown(.timedOut): kind = .operationTimedOut(operation: request.id)
            }
            return .observation(.init(session: session, kind: kind))
        }
        dispatched[request.id] = task
        return await task.value
    }
}
