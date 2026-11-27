#if DEBUG
import SwiftUI

/// An isolated rendering fixture. No physical input, model, provider, files or playback.
@MainActor struct AssistantPresentationFixture: View, Identifiable {
    let id: UUID
    @State private var model: SessionModel
    @State private var assistant: VoiceAssistantSession

    init(id: UUID) {
        self.id = id
        _model = State(initialValue: SessionModel(transport: DemoTransport(), interface: .terminal))
        var topic = Topic(name: "Synthetic voice presentation")
        topic.language = .de
        let store = MCPStore(file: URL.temporaryDirectory.appending(path: "voice-render-\(id)/mcp.json"),
                             readSecret: { _ in nil }, writeSecret: { _, _ in }, deleteSecret: { _ in })
        let session = VoiceAssistantSession(topic: topic, system: ListenSystem.builtIns.first { $0.id == "voice-assistant" }!,
            configuration: VoiceAssistantConfiguration(enabled: true), client: PresentationClient(),
            model: "synthetic/render", speaker: PresentationVoice(), toolStore: store)
        session.setDuplexListening(true)
        _assistant = State(initialValue: session)
    }

    static func requested() -> Self? {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-assistantPresentationFixture"), args.indices.contains(at + 1),
              let id = UUID(uuidString: args[at + 1]) else { return nil }
        return Self(id: id)
    }

    var body: some View {
        AssistantView(model: model, assistant: assistant)
            .task {
                assistant.start()
                for _ in 0..<100 where !assistant.ready { try? await Task.sleep(for: .milliseconds(10)) }
                assistant.submit("Synthetic rendering input")
            }
            .onDisappear { assistant.stop() }
    }
}

private struct PresentationClient: ModelClient {
    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream {
            $0.yield(.text("Cape Suzette ist eine erfundene Hafenstadt. Die hohen Gebäude zeigen klare geometrische Formen und abgestufte Spitzen. Ich höre dir weiter zu, auch wenn ich gerade spreche."))
            $0.finish()
        }
    }
}

@MainActor private final class PresentationVoice: AssistantStreamingSpeechOutput {
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    private var response: ConversationResponseID?
    private var started = false
    func begin(response: ConversationResponseID, language: Language) { self.response = response; started = false }
    func append(_ text: String, response: ConversationResponseID) {
        if self.response == response, !started { started = true; began?(response) }
    }
    func complete(response: ConversationResponseID) {}
    func speak(_ text: String, response: ConversationResponseID, language: Language) { begin(response: response, language: language); append(text, response: response) }
    func stop() { response = nil; started = false }
}
#endif
