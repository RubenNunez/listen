import Foundation

/// A scripted stand-in for the backend so the app can be exercised before a
/// server exists. It speaks the real wire events but calls no speech or model
/// provider: the transcript and every answer are fixed demo text, and audio
/// frames it receives are counted and discarded.
@MainActor
final class DemoTransport: Transport {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var receivedAudioFrames = 0

    private enum Step {
        case partial(segment: UInt64, voice: UInt32, text: String)
        case final(segment: UInt64, voice: UInt32, text: String, isQuestion: Bool)
    }

    private static let script: [(delayMs: Int, step: Step)] = [
        (900, .partial(segment: 1, voice: 1, text: "Guten Tag,")),
        (700, .final(segment: 1, voice: 1, text: "Guten Tag, schön dass Sie da sind.", isQuestion: false)),
        (1200, .partial(segment: 2, voice: 2, text: "Danke für")),
        (600, .final(segment: 2, voice: 2, text: "Danke für die Einladung.", isQuestion: false)),
        (1500, .partial(segment: 3, voice: 1, text: "Können Sie mir erklären,")),
        (900, .partial(segment: 3, voice: 1, text: "Können Sie mir erklären, wie Sie Backpressure")),
        (900, .final(segment: 3, voice: 1, text: "Können Sie mir erklären, wie Sie Backpressure in einem Streaming-Dienst umsetzen?", isQuestion: true)),
        (4000, .final(segment: 4, voice: 2, text: "Ja, also ich würde mit begrenzten Warteschlangen anfangen.", isQuestion: false)),
        (2500, .final(segment: 5, voice: 1, text: "Und wie testen Sie das unter Last?", isQuestion: true)),
    ]

    private var seq: UInt64 = 0
    private var listening = false
    private var meVoice: UInt32?
    private var mappingVersion = 0
    private var nextStep = 0
    private var nextGeneration: UInt64 = 0
    private var lastSegment: UInt64?
    private var scriptTask: Task<Void, Never>?
    private var cardTask: Task<Void, Never>?
    private var streamingCard: UInt64?

    func connect() {
        Task { self.onEvent?(.connected) }
    }

    func disconnect() {
        scriptTask?.cancel()
        cardTask?.cancel()
        listening = false
        onEvent?(.disconnected)
    }

    func sendAudio(_ frame: AudioFrame) {
        if listening { receivedAudioFrames += 1 }
    }

    func send(_ event: ClientEvent) {
        switch event {
        case .hello, .resumeFrom:
            break
        case .start:
            listening = true
            emit(.state(.listening, reason: nil))
            runScript()
        case .pause(let reason):
            listening = false
            scriptTask?.cancel()
            if reason != .appSpeaking { cancelCard() }
            emit(.state(.paused, reason: reason))
        case .resume:
            listening = true
            emit(.state(.listening, reason: nil))
            runScript()
        case .stop:
            listening = false
            scriptTask?.cancel()
            cancelCard()
            emit(.state(.stopped, reason: nil))
        case .helpNow:
            guard let lastSegment else { return emit(.error(.noTranscript)) }
            streamCard(style: .answer, trigger: lastSegment, source: nil)
        case .mapSpeaker(let voice, let isMe):
            meVoice = isMe ? voice : nil
            mappingVersion += 1
            emit(.speakerMapping(version: mappingVersion, meVoice: meVoice))
        case .cardAction(let id, let action):
            switch action {
            case .dismiss:
                if streamingCard == id { cancelCard() }
            case .explain: streamCard(style: .explain, trigger: lastSegment, source: id)
            case .shorter: streamCard(style: .shorter, trigger: lastSegment, source: id)
            case .technicalDetail: streamCard(style: .technicalDetail, trigger: lastSegment, source: id)
            }
        }
    }

    private func emit(_ event: ServerEvent) {
        seq += 1
        onEvent?(.envelope(Envelope(v: WireProtocol.version, seq: seq, event: event)))
    }

    private func runScript() {
        scriptTask?.cancel()
        scriptTask = Task { [weak self] in
            while true {
                guard let self, self.nextStep < Self.script.count else { return }
                let entry = Self.script[self.nextStep]
                try? await Task.sleep(for: .milliseconds(entry.delayMs))
                if Task.isCancelled { return }
                self.nextStep += 1
                self.play(entry.step)
            }
        }
    }

    private func play(_ step: Step) {
        switch step {
        case .partial(let segment, let voice, let text):
            emit(.transcript(segmentEvent(segment, voice, text, isFinal: false)))
        case .final(let segment, let voice, let text, let isQuestion):
            emit(.transcript(segmentEvent(segment, voice, text, isFinal: true)))
            lastSegment = segment
            // Same gate as the real backend: a mapped session, another voice.
            if isQuestion, let meVoice, meVoice != voice {
                streamCard(style: .answer, trigger: segment, source: nil)
            }
        }
    }

    private func segmentEvent(_ segment: UInt64, _ voice: UInt32, _ text: String, isFinal: Bool) -> TranscriptSegment {
        TranscriptSegment(
            segmentID: segment, isFinal: isFinal, revision: 1, voice: voice,
            speaker: voice == meVoice ? .me : .speaker(Int(voice)), text: text,
            startMs: segment * 4000, endMs: segment * 4000 + 2000)
    }

    private func streamCard(style: CardStyle, trigger: UInt64?, source: UInt64?) {
        nextGeneration += 1
        let id = nextGeneration
        if let old = streamingCard {
            cardTask?.cancel()
            emit(.cardSuperseded(generationID: old, by: id))
        }
        streamingCard = id
        let kind: CardKind = style == .explain || style == .technicalDetail ? .deep : .fast
        emit(.cardStarted(CardStart(
            generationID: id, kind: kind, style: style, triggerSegment: trigger, sourceCard: source,
            contextVersion: 0, mappingVersion: mappingVersion)))
        let chunks = ["Demo-Antwort ", "(\(style.rawValue)): ", "Es wurde kein Modell ", "aufgerufen."]
        cardTask = Task { [weak self] in
            for chunk in chunks {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                self?.emit(.cardDelta(generationID: id, text: chunk))
            }
            self?.emit(.cardFinished(generationID: id))
            self?.streamingCard = nil
        }
    }

    private func cancelCard() {
        guard let id = streamingCard else { return }
        cardTask?.cancel()
        streamingCard = nil
        emit(.cardCancelled(generationID: id))
    }
}
