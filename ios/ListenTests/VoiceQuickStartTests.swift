import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct VoiceQuickStart {
    private func preferences() throws -> (UserDefaults, String) {
        let name = "Listen-voice-setup-tests-" + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func everyActiveTopicWithARunnableSystemCanBeTalkedWithInStoredOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-voice-choices-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let topics = TopicStore(file: root.appending(path: "topics.json"))
        let systems = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        // The store's first topic names no system: it runs with the default one.
        let general = try #require(topics.topics.first)
        #expect(general.system == nil)
        var first = Topic(name: "Synthetic same name"); first.system = "voice-assistant"
        var archived = Topic(name: "Synthetic archived"); archived.system = "voice-assistant"; archived.archived = true
        var missing = Topic(name: "Synthetic unavailable system"); missing.system = "missing-system"
        var cards = Topic(name: "Synthetic same name"); cards.system = "expert-talk"
        for topic in [first, archived, missing, cards] { topics.upsert(topic) }
        #expect(AssistantLaunch.availableTopics(store: topics, systems: systems).map(\.id) == [general.id, first.id, cards.id])
        // Which system answers is said per topic, in its own name.
        #expect(VoiceQuickStartView.answering(first, systems: systems)?.contains("Voice assistant: one model with the tools") == true)
        #expect(VoiceQuickStartView.answering(cards, systems: systems)?.contains("Expert talk, with its own roles, context and budget") == true)
        #expect(VoiceQuickStartView.answering(general, systems: systems)?.contains("Interview") == true)
        #expect(VoiceQuickStartView.answering(missing, systems: systems) == nil)
    }

    @Test func aNewTopicStartsWithASystemWhoseOwnRolesAnswerNotWithTheToolAssistant() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-voice-creation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let systems = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        var expert = Topic(name: "Synthetic expert"); expert.system = "expert-talk"
        var assistant = Topic(name: "Synthetic assistant"); assistant.system = "voice-assistant"
        #expect(VoiceQuickStartView.creationSystem(in: systems, current: expert)?.id == "expert-talk", "the current topic's system")
        #expect(VoiceQuickStartView.creationSystem(in: systems, current: assistant)?.id == ListenSystem.defaultID)
        #expect(VoiceQuickStartView.creationSystem(in: systems, current: nil)?.id == ListenSystem.defaultID)
        // A system the owner set to speak its roles comes first.
        var meeting = try #require(systems.system("meeting"))
        var settings = VoiceAssistantConfiguration(enabled: true)
        settings.answerSource = .harness
        meeting.configuration?.conversation = settings
        systems.update(meeting)
        #expect(VoiceQuickStartView.creationSystem(in: systems, current: expert)?.id == "meeting")
    }

    @Test func invalidOrStaleSavedTargetsNeverFallBackToTheCurrentTopic() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-voice-targets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let topics = TopicStore(file: root.appending(path: "topics.json"))
        let systems = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        let (prefs, domain) = try preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        var current = Topic(name: "Synthetic current voice"); current.system = "voice-assistant"; topics.upsert(current)
        for saved in ["invalid-target", UUID().uuidString] {
            prefs.set(saved, forKey: AssistantLaunch.topicKey)
            #expect(throws: AssistantLaunchFailure.topic) { try AssistantLaunch.topic(store: topics, systems: systems, preferences: prefs) }
            #expect(prefs.string(forKey: AssistantLaunch.topicKey) == saved)
            #expect(try AssistantLaunch.topic(current.id, store: topics, systems: systems, preferences: prefs).id == current.id)
        }
        prefs.set(current.id.uuidString.lowercased(), forKey: AssistantLaunch.topicKey)
        #expect(try AssistantLaunch.topic(store: topics, systems: systems, preferences: prefs).id == current.id)
        prefs.set("", forKey: AssistantLaunch.topicKey)
        #expect(try AssistantLaunch.topic(store: topics, systems: systems, preferences: prefs).id == current.id)
    }

    @Test func theSameTalkEntryLaunchesTheExistingHarnessRolesWhenVoiceIsEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-harness-launch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let topics = TopicStore(file: root.appending(path: "topics.json"))
        let systems = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        let (prefs, domain) = try preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        var system = try #require(systems.system("interview"))
        let original = system.configuration ?? SystemConfig()
        var settings = original
        settings.conversation = VoiceAssistantConfiguration(enabled: true)
        settings.conversation?.answerSource = .harness
        system.configuration = settings
        systems.update(system)
        try #require(systems.lastError == nil)
        var topic = Topic(name: "Synthetic multi-role voice"); topic.system = system.id
        try AssistantLaunch.saveVoiceTopic(topic, store: topics, systems: systems, preferences: prefs)
        #expect(try AssistantLaunch.topic(store: topics, systems: systems, preferences: prefs).id == topic.id)
        let saved = try #require(systems.system(system.id))
        #expect(saved.speaksCards && saved.isOn(.writer))
        #expect(saved.configuration?.models == original.models)
        #expect(saved.configuration?.agents == original.agents)
    }

    @Test func savingAVoiceTopicPersistsItBeforeChoosingItForLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-voice-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "topics.json")
        let topics = TopicStore(file: file)
        let systems = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        let (prefs, domain) = try preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        var voice = Topic(name: "Synthetic configured voice"); voice.system = "voice-assistant"
        try AssistantLaunch.saveVoiceTopic(voice, store: topics, systems: systems, preferences: prefs)
        let restored = TopicStore(file: file)
        #expect(restored.selectedID == voice.id)
        #expect(restored.topics.contains { $0.id == voice.id && $0.system == "voice-assistant" })
        #expect(prefs.string(forKey: AssistantLaunch.topicKey) == voice.id.uuidString)
        #expect(try AssistantLaunch.topic(store: restored, systems: systems, preferences: prefs).id == voice.id)
    }

    @Test func anArchivedDraftOrOneWithoutItsSystemDoesNotChangeTopicsOrLaunchChoice() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-voice-invalid-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let topics = TopicStore(file: root.appending(path: "topics.json"))
        let systems = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        let (prefs, domain) = try preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        let previous = UUID().uuidString; prefs.set(previous, forKey: AssistantLaunch.topicKey)
        let original = topics.topics
        var archived = Topic(name: "Synthetic archived draft"); archived.system = "voice-assistant"; archived.archived = true
        var missing = Topic(name: "Synthetic topic of a removed system"); missing.system = "missing-system"
        for invalid in [missing, archived] {
            #expect(throws: AssistantLaunchFailure.system) { try AssistantLaunch.saveVoiceTopic(invalid, store: topics, systems: systems, preferences: prefs) }
        }
        #expect(topics.topics == original)
        #expect(prefs.string(forKey: AssistantLaunch.topicKey) == previous)
        // An ordinary topic is a valid target: its own system answers when it is talked with.
        let ordinary = Topic(name: "Synthetic normal topic")
        try AssistantLaunch.saveVoiceTopic(ordinary, store: topics, systems: systems, preferences: prefs)
        #expect(try AssistantLaunch.topic(store: topics, systems: systems, preferences: prefs).id == ordinary.id)
        #expect(systems.system(ListenSystem.defaultID)?.configuration?.conversation == nil, "saving the target changes no system")
    }

    @Test func failedSaveKeepsTheExistingLaunchChoiceAndTopicList() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-voice-failed-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let topics = TopicStore(file: blocked)
        let original = topics.topics
        let systems = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        let (prefs, domain) = try preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        let previous = UUID().uuidString; prefs.set(previous, forKey: AssistantLaunch.topicKey)
        var voice = Topic(name: "Synthetic unsaved voice"); voice.system = "voice-assistant"
        #expect(throws: (any Error).self) { try AssistantLaunch.saveVoiceTopic(voice, store: topics, systems: systems, preferences: prefs) }
        #expect(topics.topics == original)
        #expect(prefs.string(forKey: AssistantLaunch.topicKey) == previous)
    }
}
