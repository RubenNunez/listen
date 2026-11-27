import Foundation

// Mirror of backend/crates/protocol. The JSON lines in fixtures/protocol are
// the shared contract; both sides test against them.

enum WireProtocol {
    static let version = 1
    /// 16 kHz mono signed 16-bit little-endian PCM, 100 ms per frame.
    static let sampleRate = 16_000.0
    static let frameBytes = 3_200
}

enum Language: String, Codable, Sendable, CaseIterable {
    case de, en
}

enum SpeakerLabel: Equatable, Sendable, Codable {
    case me
    case speaker(Int)
    case unknown
    case overlap

    private enum CodingKeys: String, CodingKey { case kind, n }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "me": self = .me
        case "speaker": self = .speaker(try container.decode(Int.self, forKey: .n))
        case "unknown": self = .unknown
        case "overlap": self = .overlap
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown speaker kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .me: try container.encode("me", forKey: .kind)
        case .speaker(let n):
            try container.encode("speaker", forKey: .kind)
            try container.encode(n, forKey: .n)
        case .unknown: try container.encode("unknown", forKey: .kind)
        case .overlap: try container.encode("overlap", forKey: .kind)
        }
    }
}

enum ServerSessionState: String, Codable, Sendable {
    case idle, listening, paused, stopped
}

enum PauseReason: String, Codable, Sendable {
    case user
    case interrupted
    case appSpeaking = "app_speaking"
}

enum CardAction: String, Codable, Sendable {
    case explain
    case shorter
    case technicalDetail = "technical_detail"
    case dismiss
}

enum CardStyle: String, Codable, Sendable {
    case answer
    case shorter
    case explain
    case technicalDetail = "technical_detail"
}

enum CardKind: String, Codable, Sendable {
    case fast, deep
}

enum ErrorCode: String, Codable, Sendable {
    case unsupportedVersion = "unsupported_version"
    case invalidState = "invalid_state"
    case noTranscript = "no_transcript"
    case budgetExhausted = "budget_exhausted"
    case replayGap = "replay_gap"
    case unknownCard = "unknown_card"
    case speechProvider = "speech_provider"
    case modelProvider = "model_provider"
}

enum ClientEvent: Equatable, Sendable, Encodable {
    case hello(protocolVersion: Int)
    case start(language: Language, contextVersion: Int)
    case pause(reason: PauseReason)
    case resume
    case stop
    case helpNow
    case cardAction(generationID: UInt64, action: CardAction)
    case mapSpeaker(voice: UInt32, isMe: Bool)
    case resumeFrom(lastServerSeq: UInt64)

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case language
        case contextVersion = "context_version"
        case reason
        case generationID = "generation_id"
        case action
        case voice
        case isMe = "is_me"
        case lastServerSeq = "last_server_seq"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let version):
            try container.encode("hello", forKey: .type)
            try container.encode(version, forKey: .protocolVersion)
        case .start(let language, let contextVersion):
            try container.encode("start", forKey: .type)
            try container.encode(language, forKey: .language)
            try container.encode(contextVersion, forKey: .contextVersion)
        case .pause(let reason):
            try container.encode("pause", forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .resume:
            try container.encode("resume", forKey: .type)
        case .stop:
            try container.encode("stop", forKey: .type)
        case .helpNow:
            try container.encode("help_now", forKey: .type)
        case .cardAction(let id, let action):
            try container.encode("card_action", forKey: .type)
            try container.encode(id, forKey: .generationID)
            try container.encode(action, forKey: .action)
        case .mapSpeaker(let voice, let isMe):
            try container.encode("map_speaker", forKey: .type)
            try container.encode(voice, forKey: .voice)
            try container.encode(isMe, forKey: .isMe)
        case .resumeFrom(let seq):
            try container.encode("resume_from", forKey: .type)
            try container.encode(seq, forKey: .lastServerSeq)
        }
    }
}

struct TranscriptSegment: Equatable, Sendable, Decodable {
    var segmentID: UInt64
    var isFinal: Bool
    var revision: Int
    var voice: UInt32?
    var speaker: SpeakerLabel
    var text: String
    var startMs: UInt64
    var endMs: UInt64
    /// The voice is the speaker model's first guess for the newest sentence, or the sentence is
    /// still waiting for one. The next analysis, which hears more after it, settles it. Local only.
    var voicePending = false

    private enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case isFinal = "is_final"
        case revision, voice, speaker, text
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

struct CardStart: Equatable, Sendable, Decodable {
    var generationID: UInt64
    var kind: CardKind
    var style: CardStyle
    var triggerSegment: UInt64?
    var sourceCard: UInt64?
    var contextVersion: Int
    var mappingVersion: Int
    /// A verbatim answer drawn from this transcript segment, not model knowledge.
    var evidenceSegment: UInt64? = nil
    /// Stable subject identity even after old in-memory versions are evicted.
    var blockID: UInt64? = nil
    /// Reviewed addition displayed ahead of its retained earlier context.
    var focusText: String? = nil
    /// A verified meeting-ledger section; at most three such blocks stay on the live table.
    var meeting: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case generationID = "generation_id"
        case kind, style
        case triggerSegment = "trigger_segment"
        case sourceCard = "source_card"
        case contextVersion = "context_version"
        case mappingVersion = "mapping_version"
        case evidenceSegment = "evidence_segment"
        case blockID = "block_id"
        case focusText = "focus_text"
        case meeting
    }
}

enum ServerEvent: Equatable, Sendable, Decodable {
    case state(ServerSessionState, reason: PauseReason?)
    case transcript(TranscriptSegment)
    case speakerMapping(version: Int, meVoice: UInt32?)
    case audioGap(firstMissingSeq: UInt32, frames: UInt32)
    case cardStarted(CardStart)
    case cardDelta(generationID: UInt64, text: String)
    case cardFinished(generationID: UInt64)
    case cardSuperseded(generationID: UInt64, by: UInt64)
    case cardCancelled(generationID: UInt64)
    case cardError(generationID: UInt64, code: ErrorCode)
    case budget(spentNanoUSD: UInt64, limitNanoUSD: UInt64, exhausted: Bool)
    case error(ErrorCode)

    private enum CodingKeys: String, CodingKey {
        case type, state, reason, version
        case meVoice = "me_voice"
        case firstMissingSeq = "first_missing_seq"
        case frames
        case generationID = "generation_id"
        case text, by, code
        case spent = "spent_nanousd"
        case limit = "limit_nanousd"
        case exhausted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "state":
            self = .state(
                try c.decode(ServerSessionState.self, forKey: .state),
                reason: try c.decodeIfPresent(PauseReason.self, forKey: .reason))
        case "transcript":
            self = .transcript(try TranscriptSegment(from: decoder))
        case "speaker_mapping":
            self = .speakerMapping(
                version: try c.decode(Int.self, forKey: .version),
                meVoice: try c.decodeIfPresent(UInt32.self, forKey: .meVoice))
        case "audio_gap":
            self = .audioGap(
                firstMissingSeq: try c.decode(UInt32.self, forKey: .firstMissingSeq),
                frames: try c.decode(UInt32.self, forKey: .frames))
        case "card_started":
            self = .cardStarted(try CardStart(from: decoder))
        case "card_delta":
            self = .cardDelta(
                generationID: try c.decode(UInt64.self, forKey: .generationID),
                text: try c.decode(String.self, forKey: .text))
        case "card_finished":
            self = .cardFinished(generationID: try c.decode(UInt64.self, forKey: .generationID))
        case "card_superseded":
            self = .cardSuperseded(
                generationID: try c.decode(UInt64.self, forKey: .generationID),
                by: try c.decode(UInt64.self, forKey: .by))
        case "card_cancelled":
            self = .cardCancelled(generationID: try c.decode(UInt64.self, forKey: .generationID))
        case "card_error":
            self = .cardError(
                generationID: try c.decode(UInt64.self, forKey: .generationID),
                code: try c.decode(ErrorCode.self, forKey: .code))
        case "budget":
            self = .budget(
                spentNanoUSD: try c.decode(UInt64.self, forKey: .spent),
                limitNanoUSD: try c.decode(UInt64.self, forKey: .limit),
                exhausted: try c.decode(Bool.self, forKey: .exhausted))
        case "error":
            self = .error(try c.decode(ErrorCode.self, forKey: .code))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown server event \(type)")
        }
    }
}

struct Envelope: Equatable, Sendable, Decodable {
    var v: Int
    var seq: UInt64
    var event: ServerEvent
}

/// One binary message: 4-byte big-endian sequence number, 8-byte big-endian
/// capture time in milliseconds, then PCM samples.
struct AudioFrame: Equatable, Sendable {
    var seq: UInt32
    var captureMs: UInt64
    var pcm: Data
    /// While an app's sound is mixed in: how loud the microphone and the app were (RMS).
    /// Local only, never on the wire.
    var mine: Float? = nil
    var theirs: Float? = nil

    func encoded() -> Data {
        var data = Data(capacity: 12 + pcm.count)
        withUnsafeBytes(of: seq.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: captureMs.bigEndian) { data.append(contentsOf: $0) }
        data.append(pcm)
        return data
    }
}
