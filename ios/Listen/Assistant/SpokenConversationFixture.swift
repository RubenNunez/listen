#if DEBUG
import SwiftUI

/// Explicit isolated layout fixture. No account, recognizer, model, microphone or audio
/// device is used. It renders the production conversation view, not a copied layout.
@MainActor struct SpokenConversationFixture: View, Identifiable {
    let id: UUID
    @State private var model: SessionModel
    private let transport: FixtureVoiceTransport
    @State private var started = false

    init(id: UUID) {
        self.id = id
        let transport = FixtureVoiceTransport()
        self.transport = transport
        var config = SystemConfig()
        var voice = VoiceAssistantConfiguration()
        voice.enabled = true; voice.answerSource = .harness; voice.recordAudio = false
        config.conversation = voice
        let frozenConfig = config
        let system = ListenSystem(id: "fixture-" + id.uuidString, name: "Interview", summary: "Synthetic layout only",
                                  symbol: "waveform", blocks: [], configuration: config)
        let parts = SessionModel.Parts(
            system: { _ in (.init(config: frozenConfig, problem: nil, edited: false), system) },
            answers: { _, loaded, _, form in
                var settings = AnswerEngine.Settings()
                settings.system = loaded.config; settings.spoken = form
                return AnswerEngine(client: FixtureVoiceClient(), settings: settings)
            },
            transport: { _, _ in transport }, speaker: { _ in FixtureSilentVoice() })
        _model = State(initialValue: SessionModel(parts: parts))
    }

    static func requested() -> Self? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-spokenConversationFixture"), args.indices.contains(index + 1),
              let id = UUID(uuidString: args[index + 1]) else { return nil }
        return Self(id: id)
    }

    var body: some View {
        ListenView(model: model)
            .task {
                guard !started else { return }
                started = true
                var topic = Topic(name: "iOS Interview")
                topic.id = id
                topic.language = .de
                model.start(topic, spoken: true)
                for _ in 0..<100 {
                    if model.core.phase == .listening { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                transport.emit(.transcript(.init(segmentID: 1, isFinal: true, revision: 1, voice: nil, speaker: .unknown,
                    text: "Wie funktioniert ein Request mit URLSession?", startMs: 0, endMs: 2_000)))
                transport.emit(.cardStarted(.init(generationID: 1, kind: .fast, style: .answer, triggerSegment: 1,
                    contextVersion: 0, mappingVersion: 0, blockID: 1)))
                transport.emit(.cardDelta(generationID: 1, text: "URLSession\nMit URLSession startest du einen asynchronen Request.\nPrüfe danach Statuscode und Antwortdaten."))
                transport.emit(.cardFinished(generationID: 1))
            }
            .onDisappear { model.stopAndSave() }
    }
}

private struct FixtureVoiceClient: ModelClient {
    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor private final class FixtureSilentVoice: AssistantSpeechOutput {
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    func speak(_ text: String, response: ConversationResponseID, language: Language) { began?(response) }
    func stop() {}
}

@MainActor private final class FixtureVoiceTransport: Transport {
    var onEvent: ((TransportEvent) -> Void)?
    private var seq: UInt64 = 0
    func connect() { Task { self.onEvent?(.connected) } }
    func disconnect() { onEvent?(.disconnected) }
    func sendAudio(_ frame: AudioFrame) {}
    func send(_ event: ClientEvent) {
        switch event {
        case .start, .resume: emit(.state(.listening, reason: nil))
        case .pause(let reason): emit(.state(.paused, reason: reason))
        case .stop: emit(.state(.stopped, reason: nil))
        default: break
        }
    }
    func emit(_ event: ServerEvent) {
        seq += 1
        onEvent?(.envelope(.init(v: WireProtocol.version, seq: seq, event: event)))
    }
}
#endif
