import SwiftUI

/// The first screen: nothing but the orb. With the microphone allowed it is
/// alive and reacts to sound on the phone. It understands nothing here; it
/// only gives audio feedback. A tap flows on to the topics.
struct StartView: View {
    let model: SessionModel
    let accounts: AccountStore
    let topics: TopicStore
    private enum Sheet: String, Identifiable {
        case settings, voice
        var id: String { rawValue }
    }
    @State private var sheet: Sheet?
    let orbSpace: Namespace.ID
    let openTopics: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Button(action: openTopics) {
                SessionOrb(model: model, isActive: model.microphoneOn, isVisible: sheet == nil)
                    .matchedGeometryEffect(id: "orb", in: orbSpace)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 340)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open topics")
            Spacer()
            Button("Talk with Listen", systemImage: "waveform") {
                do {
                    let topic = try AssistantLaunch.topic(store: topics, systems: SystemStore())
                    AssistantLaunch.shared.launch(topic: topic.id)
                } catch AssistantLaunchFailure.topic {
                    sheet = .voice
                } catch { model.startFailure = error.localizedDescription }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("start.voice")
            .padding(.bottom, 16)
            if model.microphoneDenied {
                Label("Microphone access is off. Allow it for Listen in Settings.", systemImage: "mic.slash.fill")
                    .foregroundStyle(.orange)
                    .glassBanner()
                    .padding(.bottom, 12)
            }
            Toggle(isOn: Binding(get: { model.microphoneOn }, set: { model.setMicrophone($0) })) {
                Label("Microphone", systemImage: model.microphoneOn ? "mic.fill" : "mic.slash.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.green)
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: 230)
            .glassEffect(.regular, in: .capsule)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") · Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .padding(.top, 10)
                .accessibilityIdentifier("start.version")
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .settings: AccountView(accounts: accounts, topics: topics)
            case .voice:
                NavigationStack {
                    VoiceQuickStartView(topics: topics)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } }
                        }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                ListenSettingsButton(identifier: "start.settings") { sheet = .settings }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
        }
    }
}
