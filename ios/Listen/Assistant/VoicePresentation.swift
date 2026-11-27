import Foundation

/// Talk with Listen over a topic's own system: the system answers with its roles, context and
/// budget as it does on screen, and the answers are also said.
///
/// A presentation never changes a system. A system that has voice settings of its own keeps
/// them and is spoken with them. For a system without any, the voice chosen while talking is
/// remembered here, per system, in the app's preferences: the system's file stays as it was,
/// and started the usual way the topic is a conversation of cards as before.
enum VoicePresentation {
    struct Plan: Equatable {
        var configuration: VoiceAssistantConfiguration
        /// The system has conversation settings of its own; a voice change is saved there.
        var savedInSystem: Bool
    }

    private struct Remembered: Codable { var engine: TalkBackEngine; var model: String; var voice: String }

    static func key(_ system: String) -> String { "voicePresentation.voice." + system }

    /// How a conversation with this system is spoken, or nil when it is not: a system with one
    /// model and tools speaks for itself (`VoiceAssistantSession`), and a system of cards is
    /// spoken only when `requested` (Talk with Listen).
    static func plan(for system: ListenSystem, requested: Bool, preferences: UserDefaults = .standard) -> Plan? {
        let own = system.configuration?.conversation
        if system.isVoiceAssistant { return nil }
        if let own, system.speaksCards { return Plan(configuration: own, savedInSystem: true) }
        guard requested else { return nil }
        // Voice settings the owner once made and switched off keep their voice.
        var configuration = own ?? VoiceAssistantConfiguration()
        if own == nil, let data = preferences.data(forKey: key(system.id)),
           let remembered = try? JSONDecoder().decode(Remembered.self, from: data),
           let chosen = try? AssistantVoiceChoice(engine: remembered.engine, model: remembered.model, voice: remembered.voice)
               .applying(to: configuration) {
            configuration = chosen
        }
        configuration.enabled = true
        configuration.answerSource = .harness
        configuration.speakReplies = true
        // A conversation of this system is recorded when Account's switch is on; said aloud,
        // it is the same conversation.
        if own == nil { configuration.recordAudio = true }
        return Plan(configuration: configuration, savedInSystem: own != nil)
    }

    /// Remembers the voice for a system that has no voice settings. The system is not touched.
    static func remember(_ choice: AssistantVoiceChoice, system: String, preferences: UserDefaults = .standard) throws {
        _ = try choice.applying(to: VoiceAssistantConfiguration())
        preferences.set(try JSONEncoder().encode(Remembered(engine: choice.engine, model: choice.model, voice: choice.voice)),
                        forKey: key(system))
    }

    /// What answers in a spoken conversation of this system, for the person talking to it.
    /// It names what is attached and may be used, not what is running at the moment:
    /// `decisions`: the decision service is attached and the system uses it. `deepens`: a main
    /// model can add to the fast answer. `research`: a model that can search is attached; it is
    /// asked only for the moments that need it.
    static func summary(of system: ListenSystem, decisions: Bool, deepens: Bool, research: Bool, material: Bool) -> String {
        var parts = [decisions ? "its decisions choose what to answer" : nil,
                     deepens ? "a fast model answers first and its main model can add to that" : "its models write the answer",
                     research ? "web research is used when a question needs it" : nil].compactMap { $0 }
        if material { parts.append("with this topic's notes and files") }
        return "\(system.name) answers: " + parts.joined(separator: ", ") + "."
    }
}
