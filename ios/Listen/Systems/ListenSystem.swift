import Foundation

/// A named way for Listen to work through a conversation: an arrangement of building blocks the
/// app runs, chosen per topic. Interview, a working conversation and a meeting are different
/// systems over the same blocks; a system says which blocks run and so what it needs, such as
/// the decision service. See docs/OPEN_HARNESS_PLAN.md (profiles) for where this is heading:
/// today a system switches the engine's existing blocks on and off; free graphs come later.
struct ListenSystem: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var summary: String
    /// An SF Symbol for the system.
    var symbol: String
    var blocks: [Block]
    /// Shipped with the app; it can be reset, not deleted.
    var builtIn = false
    /// The complete settings owned by this system. Nil only for migration from older files.
    var configuration: SystemConfig? = nil

    struct Block: Codable, Equatable, Sendable {
        var kind: Kind
        var on: Bool
    }

    /// What a system can be made of. Each block is something the engine does, or will do.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case hearing, secondHearing, swissGerman, speakers
        case decisions, writer, quotes, research, researchRejected
        case forecast, forecastWhileSpeaking
        case names, summary
        case meetingItems, meetingMinutes, repositories
    }

    /// What a block needs from outside the app.
    enum Requirement: String, CaseIterable, Sendable {
        case decisionService, models, gitHub, dialectModel
    }

    func isOn(_ kind: Kind) -> Bool { blocks.first { $0.kind == kind }?.on ?? false }
    /// One model with tools answers by voice. A system whose own roles are spoken is not
    /// one: its blocks, requirements and decisions stay those of its cards (`speaksCards`).
    var isVoiceAssistant: Bool { configuration?.conversation.map { $0.enabled && $0.answerSource == .assistant } == true }
    /// The system's cards are said aloud while its roles run as always.
    var speaksCards: Bool { configuration?.conversation.map { $0.enabled && $0.answerSource == .harness } == true }
    var hasSpokenConversation: Bool { isVoiceAssistant || speaksCards }
    func requires(_ kind: Kind) -> Bool { kind == .hearing || (kind == .writer && !isVoiceAssistant) }

    mutating func set(_ kind: Kind, _ on: Bool) {
        if let index = blocks.firstIndex(where: { $0.kind == kind }) { blocks[index].on = on }
        else { blocks.append(Block(kind: kind, on: on)) }
        if !on {
            for child in Kind.allCases where child.dependsOn == kind { set(child, false) }
        }
    }

    /// Blocks that are on and that this build cannot run yet.
    var missingBlocks: [Kind] { isVoiceAssistant ? [] : blocks.filter { $0.on && !$0.kind.isBuilt }.map(\.kind) }

    /// A system can run a conversation once every block it switches on exists.
    var isRunnable: Bool { missingBlocks.isEmpty }

    /// What the blocks that are on need, in a stable order.
    var requirements: [Requirement] {
        if isVoiceAssistant { return [.models] }
        let needed = Set(blocks.filter(\.on).flatMap(\.kind.requirements))
        return Requirement.allCases.filter(needed.contains)
    }

    /// Sets the engine's switches for this system. Blocks the engine has no switch for (hearing,
    /// the writer) always run; the decision service is chosen in `usesDecisions`.
    func apply(to config: inout SystemConfig) {
        if let configuration { config = configuration }
        config.voice.whisper = isOn(.secondHearing)
        config.voice.swissGerman = isOn(.secondHearing) && isOn(.swissGerman)
        config.voice.speakers = isOn(.speakers)
        config.agents.evidenceAnswers = isOn(.quotes)
        config.agents.web = isOn(.research)
        config.agents.researchRejectedDrafts = isOn(.research) && isOn(.researchRejected)
        config.agents.forecast = isOn(.forecast)
        config.agents.forecastWhileSpeaking = isOn(.forecast) && isOn(.forecastWhileSpeaking)
        config.agents.names = isOn(.names)
        config.agents.summary = isOn(.summary)
        config.agents.meetingItems = isOn(.meetingItems)
        config.agents.meetingMinutes = isOn(.meetingMinutes)
    }

    /// Typed decisions run only when the system has them and the decision service is attached.
    var usesDecisions: Bool {
        if isVoiceAssistant { return configuration?.conversation.map { $0.parallelOpening || $0.adaptiveRouting } == true }
        return isOn(.decisions) || isOn(.meetingItems) || isOn(.meetingMinutes)
    }

    func effectiveConfiguration(over defaults: SystemConfig) -> SystemConfig {
        var result = defaults
        apply(to: &result)
        return result
    }

    static let defaultID = "interview"
}

extension ListenSystem.Kind {
    var title: String {
        switch self {
        case .hearing: "Live hearing"
        case .secondHearing: "Second hearing"
        case .swissGerman: "Swiss German"
        case .speakers: "Who speaks"
        case .decisions: "Decisions"
        case .writer: "Writer"
        case .quotes: "Quoted answers"
        case .research: "Web research"
        case .researchRejected: "Research weak drafts"
        case .forecast: "Forecast"
        case .forecastWhileSpeaking: "Forecast while speaking"
        case .names: "Names"
        case .summary: "Summary at the end"
        case .meetingItems: "Meeting items"
        case .meetingMinutes: "Minutes at the end"
        case .repositories: "Repositories"
        }
    }

    var detail: String {
        switch self {
        case .hearing: "Apple's on-device text while people speak."
        case .secondHearing: "Whisper hears each sentence again and corrects words."
        case .swissGerman: "A Whisper trained on Swiss German joins the second hearing."
        case .speakers: "Voices are told apart; in a call the microphone is you."
        case .decisions: "The decision service judges each moment: useful, research, which card."
        case .writer: "A fast model writes the card."
        case .quotes: "A short answer that was said is shown as a quote, without a writer."
        case .research: "A model with web search checks and adds sources."
        case .researchRejected: "A useful moment whose quick draft was rejected is looked up instead."
        case .forecast: "Cards for the likely next moments are prepared in advance."
        case .forecastWhileSpeaking: "What is still being said is matched against the prepared cards."
        case .names: "Names are read from introductions."
        case .summary: "A short summary goes into the topic's memory."
        case .meetingItems: "Decisions, tasks and open points land on a protocol."
        case .meetingMinutes: "Minutes with owners and due dates at the end."
        case .repositories: "Files from GitHub repositories as material."
        }
    }

    var symbol: String {
        switch self {
        case .hearing: "waveform"
        case .secondHearing: "ear"
        case .swissGerman: "character.bubble"
        case .speakers: "person.2"
        case .decisions: "arrow.triangle.branch"
        case .writer: "square.and.pencil"
        case .quotes: "quote.opening"
        case .research: "globe"
        case .researchRejected: "arrow.uturn.right"
        case .forecast: "sparkles"
        case .forecastWhileSpeaking: "bolt"
        case .names: "person.text.rectangle"
        case .summary: "text.badge.checkmark"
        case .meetingItems: "checklist"
        case .meetingMinutes: "doc.text"
        case .repositories: "shippingbox"
        }
    }

    var requirements: [ListenSystem.Requirement] {
        switch self {
        case .decisions, .quotes, .forecastWhileSpeaking, .meetingItems: [.decisionService]
        case .meetingMinutes: [.decisionService, .models]
        case .writer, .research, .researchRejected, .forecast, .summary: [.models]
        case .swissGerman: [.dialectModel]
        case .repositories: [.gitHub]
        case .hearing, .secondHearing, .speakers, .names: []
        }
    }

    /// Blocks this build of the app can run.
    var isBuilt: Bool {
        switch self {
        case .repositories: false
        default: true
        }
    }

    /// Always on: the app has no way to run a conversation without them yet.
    var isFixed: Bool { self == .hearing || self == .writer }

    /// A block that only works when another is on.
    var dependsOn: ListenSystem.Kind? {
        switch self {
        case .swissGerman: .secondHearing
        case .quotes, .forecast: .decisions
        case .forecastWhileSpeaking: .forecast
        case .researchRejected: .research
        default: nil
        }
    }
}

extension ListenSystem.Requirement {
    var title: String {
        switch self {
        case .decisionService: "Decision service (Jev)"
        case .models: "A model account"
        case .gitHub: "GitHub"
        case .dialectModel: "Swiss German model on this Mac"
        }
    }

    var hint: String {
        switch self {
        case .decisionService: "Connect Jev under Account and switch decisions on."
        case .models: "Connect ChatGPT, OpenRouter or another provider under Account."
        case .gitHub: "Connect GitHub under Account."
        case .dialectModel: "Convert the model with ios/Tools/swiss-german/convert.sh."
        }
    }
}

extension ListenSystem {
    private static func blocks(_ on: [Kind]) -> [Block] {
        Kind.allCases.map { Block(kind: $0, on: on.contains($0)) }
    }

    /// The systems the app ships with. Interview is how Listen worked until now.
    static let builtIns: [ListenSystem] = [
        ListenSystem(
            id: "interview", name: "Interview", summary: "Answers to questions, fast.", symbol: "person.crop.rectangle",
            blocks: blocks([.hearing, .secondHearing, .swissGerman, .speakers, .decisions, .writer, .quotes, .research,
                            .forecast, .names, .summary]),
            builtIn: true),
        ListenSystem(
            id: "expert-talk", name: "Expert talk", summary: "Terms, distinctions and checked claims.", symbol: "lightbulb",
            blocks: blocks([.hearing, .secondHearing, .swissGerman, .speakers, .decisions, .writer, .research,
                            .researchRejected, .forecast, .names, .summary]),
            builtIn: true),
        ListenSystem(
            id: "meeting", name: "Meeting", summary: "Decisions, tasks and open points; minutes at the end.", symbol: "person.3",
            blocks: blocks([.hearing, .secondHearing, .swissGerman, .speakers, .decisions, .writer, .names,
                            .meetingItems, .meetingMinutes]),
            builtIn: true),
        ListenSystem(
            id: "voice-assistant", name: "Voice assistant", summary: "Talk to this topic; use the tools you connected.", symbol: "waveform",
            blocks: blocks([.hearing]), builtIn: true,
            configuration: SystemConfig(conversation: VoiceAssistantConfiguration(enabled: true))),
    ]
}
