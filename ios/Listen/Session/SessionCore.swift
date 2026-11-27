import Foundation

/// The client side of one conversation as a pure state machine.
///
/// `handle` takes a user intent or a system event and returns the commands to
/// carry out. It touches no audio, network or UI API, so the rules below are
/// unit-tested without a device:
///
/// - Capture starts only after the backend confirmed it is listening.
/// - Pause and Stop end capture before the backend is told.
/// - An interruption never resumes by itself. Only `resume` leaves it.
/// - While the app reads aloud, or the socket is down, no audio is forwarded.
struct SessionCore {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case pausedByUser
        case interrupted(InterruptionReason)
        /// Socket lost while listening. Capture continues into a bounded buffer.
        case reconnecting
        case speakingAloud(cardID: UInt64)
        case review
    }

    enum InterruptionReason: Equatable, Sendable {
        case audioSession
        case routeChange
        case mediaReset
        case leftForeground
        case connectionLost
        case captureFailed
    }

    enum Notice: Equatable {
        case microphoneDenied
        case notConnected
        case budgetExhausted
        case replayGap
        case server(ErrorCode)
    }

    enum Input {
        // User intents
        case start(language: Language)
        case pause
        case resume
        case stop
        case helpNow
        case cardAction(UInt64, CardAction)
        case thisIsMe(voice: UInt32)
        case readAloud(cardID: UInt64)
        case stopReadingAloud
        case done
        case dismissNotice
        // System events
        case microphonePermission(Bool)
        case transportConnected
        case transportDisconnected
        case envelope(Envelope)
        case audioInterrupted(InterruptionReason)
        case leftForeground
        case speechFinished
        case reconnectTimedOut
        case headphonesChanged(Bool)
    }

    enum Command: Equatable {
        case requestMicrophonePermission
        case connect
        /// Connect again after a short delay.
        case reconnect
        case disconnect
        case send(ClientEvent)
        case startCapture
        case stopCapture
        case flushBufferedAudio
        case discardBufferedAudio
        case speak(String)
        case stopSpeaking
        case keepScreenAwake(Bool)
        case scheduleReconnectTimeout
        case cancelReconnectTimeout
    }

    struct Line: Identifiable, Equatable {
        enum Content: Equatable {
            case speech(TranscriptSegment)
            case audioGap(frames: UInt32)
        }
        let id: String
        var content: Content
    }

    struct Card: Identifiable, Equatable {
        enum Status: Equatable { case streaming, finished, superseded, cancelled, failed }
        var start: CardStart
        var text = ""
        var status = Status.streaming
        var id: UInt64 { start.generationID }
    }

    struct Budget: Equatable {
        var spentNanoUSD: UInt64
        var limitNanoUSD: UInt64
        var exhausted: Bool
    }

    static let maxLines = 300
    static let maxCards = 8
    static let maxVersionsPerBlock = 8

    private(set) var phase = Phase.idle
    private(set) var language = Language.de
    private(set) var lines: [Line] = []
    /// Final sentences that left `lines`, which keeps the last `maxLines` for the screen. With
    /// them the end of a long conversation still has all of it (`allSpeech`).
    private(set) var earlierSpeech: [TranscriptSegment] = []
    private(set) var cards: [Card] = []
    private(set) var meVoice: UInt32?
    private(set) var mappingVersion = 0
    private(set) var budget: Budget?
    private(set) var notice: Notice?
    private(set) var headphones = false

    private(set) var connected = false
    private var serverListening = false
    private var lastServerSeq: UInt64 = 0
    /// No context store exists yet; the backend pins version 0.
    private let contextVersion = 0

    /// Frames go to the backend only in this state.
    var forwardsAudio: Bool { phase == .listening && connected }
    /// Frames are kept in the bounded buffer while the socket is down.
    var buffersAudio: Bool { phase == .reconnecting }
    var isCapturing: Bool {
        switch phase {
        case .listening, .reconnecting, .speakingAloud: true
        default: false
        }
    }
    /// Automatic suggestions need to know which voice is the user's.
    var automaticSuggestionsOn: Bool { meVoice != nil }

    mutating func handle(_ input: Input) -> [Command] {
        switch input {
        case .start(let language): return start(language)
        case .microphonePermission(let granted): return microphonePermission(granted)
        case .transportConnected: return transportConnected()
        case .transportDisconnected: return transportDisconnected()
        case .envelope(let envelope): return apply(envelope)
        case .pause: return pause()
        case .resume: return resume()
        case .stop: return stop()
        case .helpNow: return helpNow()
        case .cardAction(let id, let action): return cardAction(id, action)
        case .thisIsMe(let voice):
            return requireConnection([.send(.mapSpeaker(voice: voice, isMe: true))])
        case .readAloud(let cardID): return readAloud(cardID)
        case .stopReadingAloud: return endSpeaking(stopVoice: true)
        case .speechFinished: return endSpeaking(stopVoice: false)
        case .audioInterrupted(let reason): return interrupt(reason)
        case .leftForeground: return interrupt(.leftForeground)
        case .reconnectTimedOut: return reconnectTimedOut()
        case .headphonesChanged(let on):
            headphones = on
            return []
        case .done:
            guard phase == .review else { return [] }
            let language = language
            self = SessionCore()
            self.language = language
            return []
        case .dismissNotice:
            notice = nil
            return []
        }
    }

    // MARK: Lifecycle

    private mutating func start(_ language: Language) -> [Command] {
        guard phase == .idle else { return [] }
        self.language = language
        notice = nil
        phase = .starting
        return [.requestMicrophonePermission]
    }

    private mutating func microphonePermission(_ granted: Bool) -> [Command] {
        guard phase == .starting else { return [] }
        guard granted else {
            phase = .idle
            notice = .microphoneDenied
            return []
        }
        return [.connect]
    }

    private mutating func transportConnected() -> [Command] {
        connected = true
        let hello = Command.send(.hello(protocolVersion: WireProtocol.version))
        let catchUp = Command.send(.resumeFrom(lastServerSeq: lastServerSeq))
        switch phase {
        case .starting:
            // Capture waits for the backend's `listening` state.
            return [hello, .send(.start(language: language, contextVersion: contextVersion))]
        case .reconnecting:
            phase = .listening
            var commands = [Command.cancelReconnectTimeout, hello, catchUp]
            if !serverListening { commands.append(.send(.resume)) }
            return commands + [.flushBufferedAudio]
        case .pausedByUser, .interrupted, .speakingAloud:
            var commands = [hello, catchUp]
            // The backend still thinks we are listening: bring it in line.
            if serverListening {
                let reason: PauseReason = phase == .pausedByUser ? .user : .interrupted
                commands.append(.send(.pause(reason: reason)))
            }
            return commands
        case .listening:
            return []
        case .idle, .review:
            connected = false
            return [.disconnect]
        }
    }

    private mutating func transportDisconnected() -> [Command] {
        connected = false
        switch phase {
        case .starting:
            phase = .idle
            notice = .notConnected
            return []
        case .listening:
            phase = .reconnecting
            return [.reconnect, .scheduleReconnectTimeout]
        case .reconnecting:
            return [.reconnect]
        case .idle, .pausedByUser, .interrupted, .speakingAloud, .review:
            // Paused states reconnect when the user resumes.
            return []
        }
    }

    private mutating func pause() -> [Command] {
        switch phase {
        case .listening:
            phase = .pausedByUser
            var commands = [Command.stopCapture]
            if connected { commands.append(.send(.pause(reason: .user))) }
            return commands + [.keepScreenAwake(false)]
        case .reconnecting:
            phase = .pausedByUser
            return [.stopCapture, .discardBufferedAudio, .cancelReconnectTimeout, .keepScreenAwake(false)]
        case .speakingAloud:
            // The backend is already paused for the app's own voice.
            phase = .pausedByUser
            return [.stopSpeaking, .stopCapture, .keepScreenAwake(false)]
        default:
            return []
        }
    }

    private mutating func resume() -> [Command] {
        switch phase {
        case .pausedByUser, .interrupted: break
        default: return []
        }
        notice = nil
        guard connected else {
            phase = .reconnecting
            return [.reconnect, .scheduleReconnectTimeout, .startCapture, .keepScreenAwake(true)]
        }
        phase = .listening
        var commands: [Command] = []
        if !serverListening { commands.append(.send(.resume)) }
        return commands + [.startCapture, .keepScreenAwake(true)]
    }

    private mutating func stop() -> [Command] {
        var commands: [Command] = []
        switch phase {
        case .idle, .review: return []
        case .speakingAloud: commands.append(.stopSpeaking)
        default: break
        }
        // Capture ends first; everything else follows.
        commands += [.stopCapture, .discardBufferedAudio, .cancelReconnectTimeout]
        if connected { commands.append(.send(.stop)) }
        commands += [.disconnect, .keepScreenAwake(false)]
        connected = false
        phase = .review
        return commands
    }

    private mutating func interrupt(_ reason: InterruptionReason) -> [Command] {
        switch phase {
        case .listening:
            phase = .interrupted(reason)
            var commands = [Command.stopCapture]
            if connected { commands.append(.send(.pause(reason: .interrupted))) }
            return commands + [.keepScreenAwake(false)]
        case .reconnecting:
            phase = .interrupted(reason)
            return [.stopCapture, .discardBufferedAudio, .cancelReconnectTimeout, .keepScreenAwake(false)]
        case .speakingAloud:
            phase = .interrupted(reason)
            return [.stopSpeaking, .stopCapture, .keepScreenAwake(false)]
        case .starting:
            phase = .idle
            connected = false
            return [.disconnect]
        case .idle, .pausedByUser, .interrupted, .review:
            return []
        }
    }

    private mutating func reconnectTimedOut() -> [Command] {
        guard phase == .reconnecting else { return [] }
        phase = .interrupted(.connectionLost)
        return [.stopCapture, .discardBufferedAudio, .keepScreenAwake(false)]
    }

    // MARK: Suggestions and speech

    private mutating func requireConnection(_ commands: [Command]) -> [Command] {
        guard connected else {
            notice = .notConnected
            return []
        }
        return commands
    }

    private mutating func helpNow() -> [Command] {
        switch phase {
        case .listening, .pausedByUser, .interrupted: return requireConnection([.send(.helpNow)])
        default: return []
        }
    }

    private mutating func cardAction(_ id: UInt64, _ action: CardAction) -> [Command] {
        guard cards.contains(where: { $0.id == id }) else { return [] }
        if action == .dismiss {
            cards.removeAll { $0.id == id }
            return connected ? [.send(.cardAction(generationID: id, action: .dismiss))] : []
        }
        return requireConnection([.send(.cardAction(generationID: id, action: action))])
    }

    private mutating func readAloud(_ cardID: UInt64) -> [Command] {
        guard phase == .listening, connected,
            let card = cards.first(where: { $0.id == cardID }), !card.text.isEmpty
        else { return [] }
        phase = .speakingAloud(cardID: cardID)
        // The backend stops accepting audio before the voice starts.
        return [.send(.pause(reason: .appSpeaking)), .speak(card.text)]
    }

    private mutating func endSpeaking(stopVoice: Bool) -> [Command] {
        guard case .speakingAloud = phase else { return [] }
        var commands: [Command] = stopVoice ? [.stopSpeaking] : []
        if connected {
            phase = .listening
            commands.append(.send(.resume))
        } else {
            phase = .reconnecting
            commands += [.reconnect, .scheduleReconnectTimeout]
        }
        return commands
    }

    // MARK: Server events

    private mutating func apply(_ envelope: Envelope) -> [Command] {
        // Replays after a reconnect may repeat what we already have.
        guard envelope.seq > lastServerSeq else { return [] }
        lastServerSeq = envelope.seq

        switch envelope.event {
        case .state(let state, _):
            serverListening = state == .listening
            if phase == .starting, state == .listening {
                phase = .listening
                return [.startCapture, .keepScreenAwake(true)]
            }
        case .transcript(let segment):
            let id = "s\(segment.segmentID)"
            if let index = lines.lastIndex(where: { $0.id == id }) {
                // A finished line changes only when a later stage sends a newer final.
                if case .speech(let existing) = lines[index].content, existing.isFinal,
                    !segment.isFinal || segment.revision <= existing.revision
                { break }
                lines[index].content = .speech(segment)
            } else {
                append(Line(id: id, content: .speech(segment)))
            }
        case .speakerMapping(let version, let voice):
            mappingVersion = version
            meVoice = voice
        case .audioGap(_, let frames):
            append(Line(id: "g\(envelope.seq)", content: .audioGap(frames: frames)))
        case .cardStarted(let start):
            var start = start
            start.blockID = start.blockID ?? start.sourceCard.flatMap { source in
                cards.first { $0.id == source }.map { $0.start.blockID ?? $0.id }
            } ?? start.sourceCard ?? start.generationID
            cards.append(Card(start: start))
            // Bound subjects and their histories independently. Eight updates to
            // one subject must not evict the other useful cards from the table.
            let grouped = Dictionary(grouping: cards, by: { $0.start.blockID ?? $0.id })
            let pinned = Set(grouped.keys.filter {
                grouped[$0]?.last?.start.meeting == true
                    && grouped[$0]?.last?.status != .cancelled && grouped[$0]?.last?.status != .failed
            }.sorted().prefix(3))
            let ordinary = grouped.keys.filter { !pinned.contains($0) }.sorted {
                (grouped[$0]?.last?.id ?? 0) < (grouped[$1]?.last?.id ?? 0)
            }.suffix(Self.maxCards - pinned.count)
            let retained = pinned.union(ordinary)
            let ids = Set(retained.flatMap { grouped[$0, default: []].suffix(Self.maxVersionsPerBlock).map(\.id) })
            cards.removeAll { !ids.contains($0.id) }
        case .cardDelta(let id, let text):
            update(id) { $0.text += text }
        case .cardFinished(let id):
            update(id) { $0.status = .finished }
        case .cardSuperseded(let id, _):
            update(id) { $0.status = .superseded }
        case .cardCancelled(let id):
            update(id) { $0.status = .cancelled }
        case .cardError(let id, _):
            update(id) { $0.status = .failed }
            notice = .server(.modelProvider)
        case .budget(let spent, let limit, let exhausted):
            budget = Budget(spentNanoUSD: spent, limitNanoUSD: limit, exhausted: exhausted)
            if exhausted { notice = .budgetExhausted }
        case .error(let code):
            notice = code == .replayGap ? .replayGap : .server(code)
        }
        return []
    }

    /// Every sentence of the conversation, oldest first: the ones that left the screen's lines,
    /// then those still on it.
    var allSpeech: [TranscriptSegment] {
        earlierSpeech + lines.compactMap { line -> TranscriptSegment? in
            guard case .speech(let segment) = line.content else { return nil }
            return segment
        }
    }

    private mutating func append(_ line: Line) {
        lines.append(line)
        guard lines.count > Self.maxLines else { return }
        for old in lines.prefix(lines.count - Self.maxLines) {
            if case .speech(let segment) = old.content, segment.isFinal { earlierSpeech.append(segment) }
        }
        lines.removeFirst(lines.count - Self.maxLines)
    }

    private mutating func update(_ id: UInt64, _ change: (inout Card) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
    }
}
