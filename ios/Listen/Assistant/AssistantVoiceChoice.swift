import Observation
import SwiftUI

/// A voice changes only speech output, never the answer model, tool bindings or permissions.
///
/// A local voice is its engine's model and a speaker of that model: "Serena" on the 8-bit
/// Qwen checkpoint and "Serena" on the 4-bit one are two choices, and so are saved apart.
struct AssistantVoiceChoice: Equatable, Identifiable, Sendable {
    var engine: TalkBackEngine
    var model: String
    var voice: String

    var id: String { engine == .system ? "system" : "local.\(TalkBack.model(model)?.slug ?? model).\(voice)" }
    var name: String { engine == .system ? "Device voice" : TalkBack.voiceName(voice) }
    /// The model that speaks, where there is one to name.
    var detail: String? { engine == .system ? nil : TalkBack.model(model)?.short ?? model }
    var title: String { detail.map { name + " · " + $0 } ?? name }

    init(engine: TalkBackEngine, model: String = TalkBack.defaultModel, voice: String) {
        self.engine = engine
        self.model = model
        self.voice = voice
    }

    init(_ configuration: VoiceAssistantConfiguration) {
        engine = configuration.talkBackEngine
        model = configuration.talkBackModel
        voice = configuration.talkBackVoice
    }

    /// The three voice fields, and for the device voice the engine alone: the local model
    /// and speaker a system had stay as they were.
    func applying(to configuration: VoiceAssistantConfiguration) throws -> VoiceAssistantConfiguration {
        var next = configuration
        next.talkBackEngine = engine
        if engine == .local {
            next.talkBackModel = model
            next.talkBackVoice = voice
        }
        try next.validate()
        return next
    }

    /// Reloaded at the point of saving, so another editor's unrelated changes are retained.
    @MainActor func save(system id: String, in store: SystemStore) throws {
        guard var system = store.system(id), var settings = system.configuration,
              let conversation = settings.conversation else {
            throw SystemPackageError(message: "This voice system is no longer available. Reopen the conversation.")
        }
        settings.conversation = try applying(to: conversation)
        system.configuration = settings
        store.lastError = nil
        store.update(system)
        if let error = store.lastError { throw SystemPackageError(message: error) }
    }

    /// One model and the voices of it that are offered.
    struct Offer: Equatable, Identifiable {
        let model: TalkBack.Model
        let choices: [AssistantVoiceChoice]
        var id: String { model.id }
    }

    /// What a conversation offers for comparison: female voices of models that run on this
    /// device. Pocket TTS, experimental Supertonic, the default Qwen checkpoint, and another Qwen checkpoint only if
    /// it is the one in use or already downloaded. The device voice and the other speakers
    /// are not offered; a system that has one keeps it until another voice is chosen.
    static func offered(
        current: AssistantVoiceChoice, downloaded: (String) -> Bool = { LocalVoice.complete($0) != nil }
    ) -> [Offer] {
        let models = TalkBack.models.filter { $0.family != .qwen } + TalkBack.models.filter {
            $0.family == .qwen && ($0.id == TalkBack.defaultModel || (current.engine == .local && current.model == $0.id) || downloaded($0.id))
        }
        return models.map { model in
            Offer(model: model, choices: TalkBack.comparedVoices(for: model.id).map { .init(engine: .local, model: model.id, voice: $0) })
        }
    }
}

/// Fixed, user-requested samples. No microphone, model request, download or tool access.
@MainActor @Observable final class AssistantVoicePreview {
    private(set) var playing: AssistantVoiceChoice?
    private(set) var audible = false
    private(set) var failure: String?
    /// A sample that was playing has stopped, by itself or not.
    @ObservationIgnored var ended: (() -> Void)?
    @ObservationIgnored private var output: (any AssistantSpeechOutput)?
    @ObservationIgnored private var response: ConversationResponseID?
    @ObservationIgnored private let makeSpeaker: (VoiceAssistantConfiguration) -> any AssistantSpeechOutput

    init(makeSpeaker: @escaping (VoiceAssistantConfiguration) -> any AssistantSpeechOutput = { TalkBack.speaker(for: $0) }) {
        self.makeSpeaker = makeSpeaker
    }

    static func text(_ language: Language) -> String {
        language == .de ? "Hallo. Welche Stimme gefällt dir am besten?" : "Hello. Which voice do you like best?"
    }

    func play(_ choice: AssistantVoiceChoice, configuration: VoiceAssistantConfiguration, language: Language) {
        stop()
        failure = nil
        do {
            var next = try choice.applying(to: configuration)
            next.speakReplies = true
            if choice.engine == .local {
                // Said here, before a voice is made: a sample never loads or fetches a model it lacks.
                if let reason = LocalVoice.cannotRun(next.talkBackModel) ?? TalkBack.unsupported(next.talkBackModel, language: language) {
                    throw LocalVoiceUnavailable(message: reason)
                }
                guard LocalVoice.complete(next.talkBackModel) != nil else {
                    throw LocalVoiceUnavailable(message: "Download \(choice.detail ?? "the voice") to hear this sample.")
                }
            }
            let id = ConversationResponseID(UUID().uuidString)
            let speaker = makeSpeaker(next)
            response = id
            playing = choice
            output = speaker
            speaker.began = { [weak self] received in
                guard let self, response == received else { return }
                audible = true
            }
            speaker.finished = { [weak self] received in
                guard self?.response == received else { return }
                self?.stop()
            }
            speaker.cancelled = { [weak self] received in
                guard let self, response == received else { return }
                failure = LocalVoice.shared.notice ?? "The voice sample could not be played."
                stop()
            }
            speaker.speak(Self.text(language), response: id, language: language)
        } catch {
            failure = (error as? LocalVoiceUnavailable)?.message ?? "The voice sample could not be played."
        }
    }

    /// Ends the sample. Its voice is retired, so nothing it still does is heard or reported.
    func stop() {
        let wasPlaying = playing != nil
        response = nil
        playing = nil
        audible = false
        let previous = output
        output = nil
        previous?.retire()
        if wasPlaying { ended?() }
    }

    func clearFailure() { failure = nil }
}

/// The voice of a conversation as a menu, with a sample beside it. Choosing an entry
/// changes the voice at once; opening the menu loads and downloads nothing.
struct AssistantVoiceMenu: View {
    let current: AssistantVoiceChoice
    let language: Language
    let preview: AssistantVoicePreview
    var canSample = true
    var canPreviewPulse = true
    let choose: (AssistantVoiceChoice) throws -> Void
    let sample: () -> Void
    @State private var failure: String? = nil
    private let store = LocalVoice.shared

    private var groups: [AssistantVoiceChoice.Offer] { AssistantVoiceChoice.offered(current: current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    voiceMenu.fixedSize(horizontal: true, vertical: false)
                    sampleControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    voiceMenu
                    sampleControls
                }
            }
            if let message = failure ?? preview.failure {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.choice.error")
            }
        }
    }

    private var voiceMenu: some View {
        Menu { entries } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(current.name).font(.subheadline.weight(.semibold))
                            if let detail = current.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.glass)
                .accessibilityLabel("Voice")
                .accessibilityValue(current.title)
                .accessibilityIdentifier("assistant.voice")
    }

    private var sampleControls: some View {
        HStack(spacing: 8) {
                Button {
                    failure = nil
                    preview.clearFailure()
                    sample()
                } label: {
                    Group {
                        if preview.playing != nil, !preview.audible { ProgressView().controlSize(.small) }
                        else { Image(systemName: preview.playing == nil ? "play.fill" : "stop.fill") }
                    }
                    .frame(width: 44, height: 44).contentShape(.rect)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(!canSample)
                .accessibilityLabel(preview.playing == nil ? "Play a sample of this voice" : "Stop the sample")
                .accessibilityIdentifier("assistant.voice.sample")
                ThinkingSoundControl(language: language, canPreview: canSample && canPreviewPulse && preview.playing == nil)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var entries: some View {
        if !groups.contains(where: { $0.choices.contains(current) }) {
            // A device voice or a speaker saved earlier: shown, kept, and not offered again.
            Section("In use") {
                Button {} label: { Label(current.title, systemImage: "checkmark") }.disabled(true)
            }
        }
        ForEach(groups) { group in
            Section(group.model.short + " · " + readiness(group.model)) {
                ForEach(group.choices) { choice in
                    Button { pick(choice) } label: {
                        if choice == current { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                    }
                    .disabled(TalkBack.unsupported(group.model.id, language: language) != nil)
                    .accessibilityIdentifier("voice.choice." + choice.id)
                }
            }
        }
        Section("Not available") {
            ForEach(TalkBack.unavailable, id: \.title) { model in
                Button(model.title + " · " + model.reason) {}.disabled(true)
            }
        }
    }

    /// Whether the model can speak now, read from the device. Nothing is fetched to find out.
    private func readiness(_ model: TalkBack.Model) -> String {
        if let reason = TalkBack.unsupported(model.id, language: language) { return reason }
        if LocalVoice.cannotRun(model.id) != nil { return "cannot run on this device" }
        switch store.state(model.id) {
        case .ready: return "on this device"
        case .absent: return "not downloaded (\(TalkBackSettings.size(model)))"
        case .downloading(let fraction): return "downloading \(Int(fraction * 100)) %"
        case .failed: return "download failed"
        }
    }

    private func pick(_ choice: AssistantVoiceChoice) {
        failure = nil
        preview.clearFailure()
        do { try choose(choice) } catch { failure = error.localizedDescription }
    }
}

#if DEBUG
/// Explicit, isolated voice menu UI tests. No owner settings or live conversation are opened.
struct AssistantVoicePickerFixture: View, Identifiable {
    let id: UUID
    @State private var store: SystemStore
    @State private var preview = AssistantVoicePreview()
    @Environment(\.dismiss) private var dismiss

    init(id: UUID) {
        self.id = id
        _store = State(initialValue: SystemStore(file: URL.temporaryDirectory.appending(path:
            "ListenVoiceChoiceUITests/\(id)/systems.json"), current: SystemConfig()))
    }

    @MainActor static func requested() -> Self? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-voiceChoiceFixture"), args.indices.contains(index + 1),
              let id = UUID(uuidString: args[index + 1]) else { return nil }
        return Self(id: id)
    }

    private var configuration: VoiceAssistantConfiguration {
        store.system("voice-assistant")?.configuration?.conversation ?? .init()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AssistantVoiceMenu(current: .init(configuration), language: .de, preview: preview,
                        choose: { try $0.save(system: "voice-assistant", in: store) },
                        sample: {
                            if preview.playing == nil { preview.play(.init(configuration), configuration: configuration, language: .de) }
                            else { preview.stop() }
                        })
                    LocalVoiceNotice(configuration: configuration)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Voice")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { preview.stop(); dismiss() }.accessibilityIdentifier("voice.choice.done")
                }
            }
        }
        .onDisappear { preview.stop() }
    }
}
#endif

struct ListenSettingsButton: View {
    var identifier = "listen.settings"
    let action: () -> Void
    var body: some View {
        Button("Settings", systemImage: "gearshape", action: action)
            .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            .frame(width: 44, height: 44)
            .accessibilityIdentifier(identifier)
    }
}

/// Conversation controls live behind one settings button on a phone.
struct LiveVoiceSettings: View {
    let configuration: VoiceAssistantConfiguration
    let language: Language
    let preview: AssistantVoicePreview
    let canSample: Bool
    let canPreviewPulse: Bool
    let choose: (AssistantVoiceChoice) throws -> Void
    let sample: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    AssistantVoiceMenu(current: .init(configuration), language: language, preview: preview,
                        canSample: canSample, canPreviewPulse: canPreviewPulse, choose: choose, sample: sample)
                    LocalVoiceNotice(configuration: configuration)
                }
            }
            .navigationTitle("Voice settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onDisappear { @Sendable [preview] in Task { @MainActor in preview.stop() } }
    }
}
