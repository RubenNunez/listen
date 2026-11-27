import AppIntents
import Foundation
import Observation
import SwiftUI

enum AssistantLaunchFailure: Error, LocalizedError, Equatable {
    case topic, system
    var errorDescription: String? {
        switch self {
        case .topic: "Choose an active topic in Settings → Voice quick start."
        case .system: "This topic is archived or its system cannot run on this device. Choose another system before saving it."
        }
    }
}

@MainActor @Observable
final class AssistantLaunch {
    static let shared = AssistantLaunch()
    static let topicKey = "assistant.quickStartTopic"
    struct Request: Equatable { let id = UUID(); let topic: UUID; let created = Date() }
    private(set) var request: Request?

    static func topic(_ id: UUID? = nil, store: TopicStore, systems: SystemStore,
                      preferences: UserDefaults = .standard) throws -> Topic {
        let chosen: UUID
        if let id { chosen = id }
        else if let saved = preferences.string(forKey: topicKey), !saved.isEmpty {
            // An invalid saved target must never silently select another tool context.
            guard let id = UUID(uuidString: saved) else { throw AssistantLaunchFailure.topic }
            chosen = id
        } else { chosen = store.selectedID }
        guard let topic = store.topics.first(where: { $0.id == chosen }), isVoiceTopic(topic, systems: systems) else {
            throw AssistantLaunchFailure.topic
        }
        return topic
    }

    static func availableTopics(store: TopicStore, systems: SystemStore) -> [Topic] {
        store.topics.filter { isVoiceTopic($0, systems: systems) }
    }

    /// Every active topic can be talked with: its own system answers, with its roles, context
    /// and budget, and the answers are said (`VoicePresentation`). A system with one model and
    /// tools speaks as it always did. Nothing is changed in a system to make it a voice topic.
    private static func isVoiceTopic(_ topic: Topic, systems: SystemStore) -> Bool {
        // A topic that names no system runs with the default one; a system that no longer
        // exists is not replaced by another behind the person's back.
        !topic.archived && systems.system(topic.system ?? ListenSystem.defaultID)?.isRunnable == true
    }

    /// The explicit setup Save commits the topic before changing its launch target.
    static func saveVoiceTopic(_ topic: Topic, store: TopicStore, systems: SystemStore,
                               preferences: UserDefaults = .standard) throws {
        guard isVoiceTopic(topic, systems: systems) else { throw AssistantLaunchFailure.system }
        try store.saveTopic(topic)
        preferences.set(topic.id.uuidString, forKey: topicKey)
    }
    func launch(topic: UUID) { request = .init(topic: topic) }
    func take() -> Request? {
        defer { request = nil }
        guard let request, Date().timeIntervalSince(request.created) < 30 else { return nil }
        return request
    }
}

struct ListenVoiceTopic: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listen topic")
    static let defaultQuery = Query()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    struct Query: EntityQuery {
        @MainActor func entities(for identifiers: [UUID]) async throws -> [ListenVoiceTopic] {
            let topics = TopicStore(), systems = SystemStore()
            return identifiers.compactMap { id in
                guard let topic = try? AssistantLaunch.topic(id, store: topics, systems: systems) else { return nil }
                return .init(id: topic.id, name: topic.name)
            }
        }
        @MainActor func suggestedEntities() async throws -> [ListenVoiceTopic] {
            let topics = TopicStore(), systems = SystemStore()
            return AssistantLaunch.availableTopics(store: topics, systems: systems).map {
                .init(id: $0.id, name: $0.name)
            }
        }
    }
}

struct TalkWithListenIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk with Listen"
    static let description = IntentDescription("Open a topic and talk with it: its own system answers, by voice.")
    static var supportedModes: IntentModes { [.foreground(.immediate)] }
    @Parameter(title: "Topic") var topic: ListenVoiceTopic?

    @MainActor func perform() async throws -> some IntentResult {
        let chosen = try AssistantLaunch.topic(topic?.id, store: TopicStore(), systems: SystemStore())
        AssistantLaunch.shared.launch(topic: chosen.id)
        return .result()
    }
}

struct ListenVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkWithListenIntent(), phrases: ["Talk with \(.applicationName)"], shortTitle: "Talk with Listen", systemImageName: "waveform")
    }
}
