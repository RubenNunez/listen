import SwiftUI

/// One setup page, shared by Settings and recovery from an unconfigured Talk action.
struct VoiceQuickStartView: View {
    let topics: TopicStore
    @State private var systems = SystemStore()
    @State private var draft: Topic?
    @AppStorage(AssistantLaunch.topicKey) private var selected = ""

    private var available: [Topic] { AssistantLaunch.availableTopics(store: topics, systems: systems) }
    private var savedUnavailable: Bool {
        !selected.isEmpty && !available.contains { $0.id == UUID(uuidString: selected) }
    }
    private var selection: Binding<String> {
        Binding(get: { UUID(uuidString: selected)?.uuidString ?? selected }, set: { selected = $0 })
    }
    private var creationSystem: ListenSystem? {
        Self.creationSystem(in: systems, current: topics.topics.first { $0.id == topics.selectedID })
    }

    /// A new topic starts with a system whose own roles answer: one already set up to speak,
    /// else the current topic's, else the default. The editor offers every other system.
    static func creationSystem(in systems: SystemStore, current: Topic?) -> ListenSystem? {
        let choices = systems.systems.filter(\.isRunnable)
        let own = systems.system(current?.system ?? ListenSystem.defaultID)
        return choices.first { $0.speaksCards }
            ?? own.flatMap { $0.isRunnable && !$0.isVoiceAssistant ? $0 : nil }
            ?? choices.first { $0.id == ListenSystem.defaultID } ?? choices.first
    }

    /// Which system will answer for a topic, in its own name.
    static func answering(_ topic: Topic, systems: SystemStore) -> String? {
        guard let system = systems.system(topic.system ?? ListenSystem.defaultID) else { return nil }
        return system.isVoiceAssistant
            ? "\(topic.name) is answered by \(system.name): one model with the tools you connected."
            : "\(topic.name) is answered by \(system.name), with its own roles, context and budget. Its answers are said aloud."
    }

    private var answering: String? {
        let id = selected.isEmpty ? topics.selectedID : UUID(uuidString: selected)
        return available.first { $0.id == id }.flatMap { Self.answering($0, systems: systems) }
    }

    var body: some View {
        Form {
            Section {
                if available.isEmpty {
                    Label("No topic to talk with yet", systemImage: "waveform")
                        .font(.headline)
                        .accessibilityIdentifier("voiceSetup.empty")
                } else {
                    Picker("Topic", selection: selection) {
                        Text("Use current topic").tag("")
                        if savedUnavailable { Text("Unavailable topic").tag(selected) }
                        ForEach(available) { Text($0.name).tag($0.id.uuidString) }
                    }
                    .accessibilityIdentifier("voiceSetup.topic")
                    if selected.isEmpty, !available.contains(where: { $0.id == topics.selectedID }) {
                        Text("Your current topic cannot be talked with. Choose a topic above.")
                            .foregroundStyle(.secondary)
                    }
                    if let answering {
                        Text(answering).foregroundStyle(.secondary).accessibilityIdentifier("voiceSetup.answering")
                    }
                }
                Button("Create topic", systemImage: "plus") {
                    guard let system = creationSystem else { return }
                    var topic = Topic(name: "")
                    topic.system = system.id
                    draft = topic
                }
                .disabled(creationSystem == nil)
                .accessibilityIdentifier("voiceSetup.create")
                if creationSystem == nil {
                    Text("No system can run on this device. Check Topics → Systems.")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Talk with Listen") } footer: {
                Text("Used by Talk with Listen and your Action button shortcut. The topic's own system answers and nothing in it is changed. Saving selects the new topic; listening starts when you press Talk with Listen.")
            }
            if savedUnavailable {
                Section {
                    Label("Saved topic unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voiceSetup.unavailable")
                    Text("It may have been archived or deleted, or its system cannot run here. Choose another topic above.")
                        .foregroundStyle(.secondary)
                    Button("Clear saved choice") { selected = "" }
                        .accessibilityIdentifier("voiceSetup.reset")
                } footer: { Text("Your saved topic is never replaced automatically.") }
            }
            Section {
                Text("Connect a model under Settings → Connections. To use your iPhone's Action button, assign Talk with Listen in Shortcuts.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Voice quick start")
        .sheet(item: $draft) { topic in
            TopicEditor(topic: topic, isNew: true) {
                try AssistantLaunch.saveVoiceTopic($0, store: topics, systems: SystemStore())
            }
        }
    }
}
