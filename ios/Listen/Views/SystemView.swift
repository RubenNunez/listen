import SwiftUI

/// The defaults for new systems, read from system.json: the agents with the prompt
/// each one is given and the model it is routed to, the listening stages, the
/// rules code decides by, and the file all of it comes from. Nothing here is
/// written by hand for display: the texts are the ones that are sent.
struct SystemView: View {
    let model: SessionModel
    let topic: Topic
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = SystemConfig.load()
    @State private var plan: SessionModel.Plan?

    /// One prompt given to one kind of model for one job.
    struct Agent: Identifiable {
        var id: String
        var name: String
        var when: String
        var models: [String]
        var isOn: Bool
        /// Why it does not run, when it does not.
        var note: String?
        /// The system prompt as it is sent.
        var prompt: String
        /// What the request carries besides the prompt.
        var carries: [String]
    }

    static func agents(_ plan: SessionModel.Plan) -> [Agent] {
        let settings = plan.settings
        let system = settings.system
        let language = settings.language
        func text(_ prompt: String) -> String { SystemConfig.filled(prompt, language: language) }
        func short(_ model: String) -> String { model.split(separator: "/").last.map(String.init) ?? model }
        var rules = text(system.prompts.cardRules)
        if !settings.instructions.isEmpty { rules += "\n\n" + text(system.prompts.yourInstructions) + "\n" + settings.instructions }
        var firstCard = text(system.prompts.firstCard)
        if !settings.instructions.isEmpty { firstCard += "\n\n" + text(system.prompts.yourInstructions) + "\n" + settings.instructions }
        let context = [
            "a fixed snapshot: six recent sentences, their last question and up to two retrieved earlier lines",
            "the relevant numbered blocks; Jev selects a subject when enabled:\n" + text(system.prompts.blocks),
            "the topic's briefing", "the notes of earlier conversations in the topic", "the text of the topic's linked pages",
        ]
        let drafters = settings.drafters.map(short)
        let main = short(settings.merger)
        let schema = (try? JSONSerialization.data(withJSONObject: JevClient.questions(
            for: DirectedContext(revision: 0, trigger: 0, evidence: [], blocks: []), prompts: system.prompts),
            options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let web = settings.researcher.map { short($0.replacingOccurrences(of: ResponsesClient.web, with: "")) + " with web search" }
        let gated = settings.gated.map(short)
        return [
            Agent(
                id: "decision", name: "Context decisions", when: "Before drafting: answer need, existing subject and research need in one request",
                models: settings.decisionClient == nil ? [] : [JevClient.model], isOn: settings.decisionClient != nil,
                note: settings.decisionClient == nil ? "Optional. Enable Jev in Account; the normal path works without it." : "One fast drafter; a fallback when it is empty. Model decisions can be wrong.",
                prompt: String(decoding: schema, as: UTF8.self),
                carries: ["committed first-pass text; refinement and speaker labels continue in parallel", "recent evidence and corrections, text only", "up to 3,000 characters of the captured topic briefing and earlier material", "up to eight candidate blocks; target options are generated from their IDs"]),
            Agent(
                id: "review", name: "Card review", when: "Before publication: usefulness, destination, external claims and represented evidence",
                models: settings.decisionClient == nil ? [] : [JevClient.model], isOn: settings.decisionClient != nil,
                note: "Reviews are model judgments, not proof of truth. External claims may trigger research.",
                prompt: [system.prompts.reviewUseful, "Verbatim numerical answers:\n" + system.prompts.reviewEvidence,
                         system.prompts.reviewResearch, system.prompts.reviewTarget].joined(separator: "\n\n"),
                carries: ["the proposed card", "the same fixed conversation context", "candidate subjects and pending evidence IDs"]),
            Agent(
                id: "gate", name: "Gate", when: "Before a small model may write a card",
                models: gated, isOn: system.agents.gate && !gated.isEmpty,
                note: !system.agents.gate ? "Switched off in system.json." : gated.isEmpty ? "Not needed: no small model drafts in this setup." : nil,
                prompt: text(system.prompts.gate), carries: ["the latest sentences", "the newest sentence once more"]),
            Agent(
                id: "evidence", name: "Conversation quote", when: "Before writing: a short numerical answer from supplied evidence",
                models: [], isOn: settings.decisionClient != nil && system.agents.evidenceAnswers,
                note: "No generated wording. Requires typed relevance and candidate review; rejected quotes use the normal writer.",
                prompt: "A numerical utterance of at most \(system.scheduler.evidenceWords) words; routing usefulness at least \(system.scheduler.evidenceUsefulness); a nearby question or selected existing subject. No question-only, code, link or markup input.",
                carries: ["the exact recognised utterance", "its question or existing subject", "verbatim-answer relevance, coverage and destination review"]),
            Agent(
                id: "prepared", name: "Prepared answers", when: "Select a supplied answer before asking a writer",
                models: settings.decisionClient == nil ? [] : [JevClient.model], isOn: settings.decisionClient != nil,
                note: "Requires prepared topic references. Selection and relevance review run before publication; otherwise the writer answers. References are not live verification.",
                prompt: text(system.prompts.routePreparedHint),
                carries: ["up to four matching reference cards", "their source references", "the active question, recent evidence and existing cards"]),
            Agent(
                id: "draft", name: "Draft", when: (settings.decisionClient == nil ? "Every round: models in parallel" : "After routing: one fast model, fallback on clear demand; full cards reviewed before publication") + (system.agents.streamDrafts && settings.decisionClient == nil ? "; useful complete lines stream" : ""),
                models: drafters, isOn: !drafters.isEmpty, note: drafters.isEmpty ? "No model is connected." : nil,
                prompt: settings.decisionClient == nil ? rules + (web != nil ? "\n\n" + text(system.prompts.besideTheWeb) : "") : firstCard, carries: context),
            Agent(
                id: "web", name: "Web look-up", when: settings.decisionClient == nil ? "Checks the same fixed context as its draft" : "Only when Jev selects external research; uses the same fixed evidence",
                models: web.map { [$0] } ?? [], isOn: web != nil,
                note: !system.agents.web ? "Switched off in system.json." : web == nil ? "Needs a ChatGPT plan: no other connected account can search the web." : nil,
                prompt: rules + "\n\n" + text(system.prompts.web), carries: context),
            Agent(
                id: "merge", name: "Merge", when: "When more than one draft came back",
                models: [main], isOn: system.agents.merge && drafters.count > 1,
                note: !system.agents.merge ? "Switched off in system.json." : drafters.count > 1 ? nil : "Not needed: one model drafts in this setup.",
                prompt: text(system.prompts.merge), carries: ["the drafts", "the latest sentences"]),
            Agent(
                id: "action", name: "Card action", when: "You tap Shorter, Explain or Go deeper",
                models: [main], isOn: !drafters.isEmpty, note: nil,
                prompt: [system.prompts.actionShorter, system.prompts.actionExplain, system.prompts.actionDeeper]
                    .enumerated().map { "\(["Shorter", "Explain", "Go deeper"][$0.offset]): \($0.element)" }.joined(separator: "\n")
                    + "\n\n" + text(system.prompts.actionForm),
                carries: ["the card", "the latest sentences"]),
            Agent(
                id: "names", name: "Names", when: "Every \(system.scheduler.namesEverySentences) sentences, once two voices are heard",
                models: settings.namer.map { [short($0)] } ?? [], isOn: settings.namer != nil,
                note: !system.agents.names ? "Switched off in system.json." : settings.namer == nil ? "No model is connected." : nil,
                prompt: text(system.prompts.names), carries: ["the latest 24 sentences with their voice numbers"]),
            Agent(
                id: "summary", name: "Summary", when: "When a conversation of 25 words or more ends",
                models: [main], isOn: system.agents.summary && !drafters.isEmpty,
                note: system.agents.summary ? nil : "Switched off in system.json.",
                prompt: text(system.prompts.summary), carries: ["the transcript, at most its last 8000 characters"]),
        ]
    }

    var body: some View {
        let config = loaded.config
        NavigationStack {
            Form {
                if let problem = loaded.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach(plan.map(Self.agents) ?? []) { agent in
                        NavigationLink {
                            AgentDetail(agent: agent)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(agent.name).font(.body.weight(.semibold))
                                    if !agent.isOn { Text("off").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(agent.models.isEmpty ? "–" : agent.models.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(agent.note ?? agent.when).font(.caption).foregroundStyle(.secondary)
                            }
                            .opacity(agent.isOn ? 1 : 0.6)
                        }
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Each agent is one prompt given to one kind of model for one job. The models are the ones a conversation in “\(topic.name)” would use right now. Open an agent to read its prompt exactly as it is sent.")
                }
                Section {
                    LabeledContent("1 · Hears live", value: "Apple, on device")
                    LabeledContent("2 · Writes it again", value: config.voice.whisper ? "Whisper \(config.voice.whisperModel)" : "off")
                    LabeledContent(
                        "2b · Swiss German",
                        value: !config.voice.swissGerman ? "off" : WhisperRefiner.hasDialectModel ? "Whisper large-v3-turbo, Swiss German" : "no model on this device")
                    LabeledContent("Tells voices apart", value: config.voice.speakers ? "Pyannote" : "off")
                    LabeledContent("Speaker model hears", value: "the last \(Int(config.voice.speakerWindowSeconds / 60)) min")
                    LabeledContent("A voice counts from", value: String(format: "%.1f s", config.voice.shortestVoiceSeconds))
                    LabeledContent("Same person below", value: String(format: "%.2f distance", config.voice.sameVoiceDistance))
                } header: {
                    Text("Voice pipeline")
                } footer: {
                    Text("Sound never leaves this device. Three listeners hear every sentence; where they differ, two of three win, and a word from the topic's glossary wins over both.")
                }
                Section {
                    LabeledContent("Waits for a pause", value: String(format: "%.2f s", config.scheduler.pauseSeconds))
                    LabeledContent("A question starts after", value: String(format: "%.2f s", config.scheduler.questionPauseSeconds))
                    LabeledContent("New words needed", value: "\(config.scheduler.minimumWords)")
                    LabeledContent("At a time", value: "one round, one web look-up")
                    LabeledContent("Same question: titles share", value: String(format: "%.0f %%", config.landing.sameTitle * 100))
                    LabeledContent("Same question: texts share", value: String(format: "%.0f %%", config.landing.sameText * 100))
                    LabeledContent("Dropped as a repeat from", value: String(format: "%.0f %% alike", config.landing.sameAsShown * 100))
                    LabeledContent("Batch subject additions", value: "\(config.landing.minimumUpdateIntervalSeconds.formatted()) s")
                    LabeledContent("Retain leading points", value: "\(config.landing.retainedLeadingPoints)")
                    LabeledContent("Show latest addition alone", value: config.landing.focusOnLatestAddition ? "Yes" : "No")
                    LabeledContent("Draft over a checked card needs", value: String(format: "%.0f %% new", config.landing.newOverChecked * 100))
                    LabeledContent("Budget per conversation", value: String(format: "%.2f USD", config.scheduler.budgetUSD))
                } header: {
                    Text("Rules in code")
                } footer: {
                    Text("These decide without a model: when to ask, and in which block a reply lands.")
                }
                Section {
                    #if targetEnvironment(macCatalyst)
                    Button("Open system.json") { UIApplication.shared.open(SystemConfig.file) }
                    Button("Open cards.md") {
                        _ = Instructions.load(topic: nil)
                        UIApplication.shared.open(Instructions.file)
                    }
                    #endif
                    NavigationLink("Show the whole file") { ConfigText(text: config.json) }
                    Button("Timeline of recorded runs") {
                        dismiss()
                        model.showsTimeline = true
                    }
                    Button("Reset to built-in", role: .destructive) {
                        SystemConfig.reset()
                        reload()
                    }
                    .disabled(!loaded.edited)
                } header: {
                    Text("Configuration")
                } footer: {
                    Text(loaded.edited
                        ? "system.json supplies these defaults when a new system is created. Existing systems keep their own settings. New keys of later versions are added from the built-in values."
                        : "system.json holds the defaults above. New systems copy them; existing systems keep their own prompts and settings.")
                }
            }
            .navigationTitle("Defaults for new systems")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Reload", action: reload) }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        loaded = SystemConfig.load()
        plan = SessionModel.plan(for: topic, system: loaded)
    }
}

private struct AgentDetail: View {
    let agent: SystemView.Agent

    var body: some View {
        Form {
            Section("When") {
                Text(agent.when)
                if let note = agent.note { Text(note).foregroundStyle(.secondary) }
            }
            Section("Asked") {
                if agent.models.isEmpty {
                    Text("No model").foregroundStyle(.secondary)
                } else {
                    ForEach(agent.models, id: \.self) { Text($0) }
                }
            }
            Section {
                Text(agent.prompt).font(.footnote.monospaced()).textSelection(.enabled)
            } header: {
                Text("System prompt, as sent")
            }
            Section("The request also carries") {
                ForEach(agent.carries, id: \.self) { Text($0).font(.footnote) }
            }
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConfigText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle("system.json")
        .navigationBarTitleDisplayMode(.inline)
    }
}
