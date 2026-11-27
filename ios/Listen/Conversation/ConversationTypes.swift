import Foundation

// Conversation foundation (VA-1): identities and values for a spoken conversation with
// delegated operations. Foundation only. Nothing here opens a microphone, a connection,
// a provider session or a process; see `ConversationReducer`.
//
// The identifiers are minted by the adapters that feed the reducer, never by the reducer:
// the same logical thing must arrive under the same identifier after a retry or reconnect.

struct ConversationSessionID: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One stretch of heard speech, from its beginning to its commit.
struct ConversationTurnID: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One assistant response: its text, its generated audio and its playback.
struct ConversationResponseID: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One logical delegated action. It stays the same through retries and reconnects.
struct ConversationOperationID: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A symbolic reference to something the installation may be able to do, such as a tool.
/// A reference is not a grant.
struct ConversationCapabilityID: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// What a session is bound to for its whole life. All fields are constants.
struct ConversationBinding: Equatable, Sendable {
    let session: ConversationSessionID
    /// `Topic.id`.
    let topic: UUID
    /// `ListenSystem.id`.
    let system: String
    /// Names the system snapshot taken when the session began, for example a content digest.
    /// Opaque here; the integration decides what it is.
    let systemSnapshot: String
}

// MARK: Input

/// Speech as it was heard. `speaker` is diarization evidence in the app's existing labels,
/// with `unknown` and `overlap` kept as they are. It says nothing about who may do what.
struct ConversationTurn: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case hearing
        case committed
        /// Committed without words, or cut off by Stop. Never submitted.
        case discarded
    }

    let id: ConversationTurnID
    var status = Status.hearing
    /// The newest transcript revision applied; 0 before the first.
    var revision = 0
    var text = ""
    var speaker: SpeakerLabel
}

// MARK: Output

struct ConversationResponse: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case generating
        case completed
        /// Cut off by an interruption. Later output for it is dropped.
        case interrupted
        /// Cut off by Stop. Later output for it is dropped.
        case stopped
    }

    enum Playback: Equatable, Sendable {
        case idle
        case playing
        case finished
        case failed
    }

    let id: ConversationResponseID
    let inReplyTo: ConversationTurnID?
    var status = Status.generating
    var text = ""
    /// The highest audio chunk handed to playback. Generated, not necessarily heard.
    var enqueuedThrough: Int?
    /// The highest audio chunk the playback adapter acknowledged as played.
    var heardThrough: Int?
    var playback = Playback.idle

    /// Still producing output or still holding audio that was not played out.
    var isLive: Bool {
        switch status {
        case .generating: true
        case .completed: enqueuedThrough != nil && playback != .finished && playback != .failed
        case .interrupted, .stopped: false
        }
    }
}

// MARK: Capabilities

enum ConversationUnavailableReason: Equatable, Sendable {
    case notConfigured
    case notGranted
    case routeUnreachable
    case accessDenied
    case unsupported
    case other(String)
}

/// How far a capability got. Only `available` and `verified` can carry an operation, and
/// only `verified` was seen working on this installation.
enum ConversationCapabilityStatus: Equatable, Sendable {
    /// A system asks for it. Nothing more is known.
    case requested
    /// The installation has a binding for it. Not known to be reachable.
    case configured
    /// The route reported it as present.
    case available
    /// Observed working on this installation.
    case verified
    case unavailable(ConversationUnavailableReason)

    var canCarryOperations: Bool {
        self == .available || self == .verified
    }
}

// MARK: Operations

enum ConversationValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([ConversationValue])
}

/// A typed request for one delegated action. The arguments are data for the tool gateway,
/// which validates them against the capability; they are never a command line.
struct ConversationOperationRequest: Equatable, Sendable {
    let id: ConversationOperationID
    let capability: ConversationCapabilityID
    var arguments: [String: ConversationValue] = [:]
    /// The response whose model output proposed this, if any.
    var proposedBy: ConversationResponseID? = nil
}

/// The local permission for one operation. Only the installation's authorization adapter
/// makes one; no speech, transcript or model event carries it.
struct ConversationGrant: Equatable, Sendable {
    enum Basis: Equatable, Sendable {
        /// The owner allowed this capability on this installation beforehand.
        case standing
        /// The owner confirmed this one use.
        case confirmedThisUse
    }

    let operation: ConversationOperationID
    let capability: ConversationCapabilityID
    let basis: Basis
}

enum ConversationAuthorization: Equatable, Sendable {
    case granted(ConversationGrant)
    /// The owner is being asked.
    case awaitingOwner
    case denied
}

enum ConversationOperationOutcome: Equatable, Sendable {
    case succeeded(detail: String)
    case failed(detail: String)
}

enum ConversationOperationState: Equatable, Sendable {
    enum Cancellation: Equatable, Sendable {
        case capability(ConversationCapabilityStatus)
        case denied
        case withdrawn
        case expired
        case sessionStopped
        /// The response that proposed it had already been interrupted or stopped.
        case proposerCutOff
    }

    enum Unknown: Equatable, Sendable {
        case routeLost
        case timedOut
    }

    case proposed
    case awaitingAuthorization
    /// Handed to the tool gateway. The external effect may have happened.
    case dispatched
    case succeeded(detail: String)
    case failed(detail: String)
    case cancelledBeforeDispatch(Cancellation)
    /// Dispatched, and no result was observed. It is not retried.
    case outcomeUnknown(Unknown)

    /// Nothing changes this state any more.
    var isFinal: Bool {
        switch self {
        case .succeeded, .failed, .cancelledBeforeDispatch: true
        case .proposed, .awaitingAuthorization, .dispatched, .outcomeUnknown: false
        }
    }

    var wasDispatched: Bool {
        switch self {
        case .dispatched, .succeeded, .failed, .outcomeUnknown: true
        case .proposed, .awaitingAuthorization, .cancelledBeforeDispatch: false
        }
    }
}

struct ConversationOperation: Equatable, Sendable {
    let request: ConversationOperationRequest
    var state = ConversationOperationState.proposed
    /// The grant the dispatch was made under.
    var grant: ConversationGrant?

    var id: ConversationOperationID { request.id }
}
