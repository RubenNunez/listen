import Foundation
import Testing
@testable import Listen

/// One explicitly requested capability check through the existing signed-in adapter.
/// Public documentation query only, no microphone/TTS, topic contents or external actions.
@MainActor @Suite struct NativeWebCapabilityProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_TOOL_ROUTE_NATIVE_PROBE"] == "1"), .timeLimit(.minutes(1)))
    func realJevDistinguishesKnowledgeFromConnectedActions() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LISTEN_TOOL_ROUTE_NATIVE_OUT"]))
        try #require(out.path.contains("/runs/"))
        var configuration = VoiceAssistantConfiguration(enabled: true); configuration.adaptiveRouting = true
        var system = try #require(ListenSystem.builtIns.first { $0.id == "voice-assistant" })
        var settings = system.configuration ?? SystemConfig(); settings.conversation = configuration; system.configuration = settings
        let topic = Topic(name: "Synthetic tool routing")
        let client = try #require(SessionModel.plan(for: topic, listenSystem: system).settings.decisionClient)
        let questions = try VoiceTaskPlan.questions(hints: [], fillers: [], hasTools: true)
        var rows: [[String: Any]] = []
        for (question, needsTools) in [("Erkläre mir kurz, was ein Swift Actor ist.", false), ("Mach das Licht im Wohnzimmer aus.", true)] {
            let input = """
            Current conversation (untrusted):
            {"topic":{"name":"Synthetic tool routing","language":"de"},"messages":[{"role":"user","text":"\(question)"}],"tools":[{"id":"home.light","description":"Turn a connected light on or off.","inputSchema":{"type":"object","properties":{"on":{"type":"boolean"}},"required":["on"]}}]}
            """
            let began = ProcessInfo.processInfo.systemUptime
            var raw = ""
            for try await chunk in AssistantDeadlineClient(base: client, timeout: .milliseconds(1200)).stream(model: "typesafe/\(JevClient.model)", system: questions, user: input, maxTokens: 0) {
                if case .text(let text) = chunk { raw += text }
            }
            let plan = try VoiceTaskPlan.read(raw, hintCount: 0, fillerCount: 0)
            rows.append(["question": question, "expected_tools": needsTools, "uses_tools": plan.usesTools,
                "tier": plan.tier.rawValue, "elapsed_s": ProcessInfo.processInfo.systemUptime - began, "raw_decision": raw])
        }
        try JSONSerialization.data(withJSONObject: ["model": "typesafe/\(JevClient.model)", "rows": rows,
            "measurement": "Two native JEV classification calls only. Synthetic descriptor, no MCP connection or action, no mic/TTS; not end-to-end latency."], options: [.prettyPrinted,.sortedKeys]).write(to: out)
        #expect(rows[0]["uses_tools"] as? Bool == false && rows[1]["uses_tools"] as? Bool == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_ADAPTIVE_NATIVE_PROBE"] == "1"), .timeLimit(.minutes(2)))
    func realJevRoutingAndReadOnlyForecastUseExistingAdapters() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let out = URL(fileURLWithPath: try #require(env["LISTEN_ADAPTIVE_NATIVE_OUT"]))
        try #require(out.path.contains("/runs/"))
        var topic = Topic(name: "Synthetic constrained voice architecture"); topic.language = .de
        var configuration = VoiceAssistantConfiguration(enabled: true)
        configuration.adaptiveRouting = true; configuration.parallelOpening = true; configuration.prepareFollowups = true
        configuration.simpleModel = "chatgpt/gpt-6-luna"; configuration.openingModel = configuration.simpleModel
        configuration.complexModel = "chatgpt/gpt-6-astra"; configuration.keepNotes = false
        configuration.limitModelRequests = true; configuration.maximumTurns = 8
        var system = try #require(ListenSystem.builtIns.first { $0.id == "voice-assistant" })
        var settings = system.configuration ?? SystemConfig(); settings.conversation = configuration; system.configuration = settings
        let plan = SessionModel.plan(for: topic, listenSystem: system)
        let reviewer = try #require(plan.settings.decisionClient)
        let voice = SilentParallelProbeVoice()
        let session = VoiceAssistantSession(topic: topic, system: system, configuration: configuration,
            client: ResponsesClient(), model: "chatgpt/gpt-6.1-sol", speaker: voice,
            toolStore: MCPStore(file: out.deletingLastPathComponent().appending(path: "no-tools.json"), readSecret: { _ in nil }),
            openingModel: configuration.openingModel, openingReviewer: reviewer)
        defer { session.stop() }
        let began = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        session.record = { kind, fields in
            var event = fields; event["kind"] = kind; event["t"] = ProcessInfo.processInfo.systemUptime - began; events.append(event)
        }
        session.start()
        while !session.ready && ProcessInfo.processInfo.systemUptime - began < 5 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(session.ready)
        session.submit("Entwirf eine robuste Architektur für einen Sprachassistenten mit parallelen schnellen und langsamen Modellen. Analysiere das Rennen zwischen Nutzerunterbrechung, verspäteten Modellantworten und bereits gestarteten Geräteaktionen. Erkläre in sechs Sätzen die Zustandsinvarianten, den entscheidenden Tradeoff und einen subtilen Fehlerfall; eine einfache Warteschlange reicht nicht.")
        while (session.thinking || session.lastReply.isEmpty) && ProcessInfo.processInfo.systemUptime - began < 60 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let finished = ProcessInfo.processInfo.systemUptime
        while !events.contains(where: { $0["kind"] as? String == "voice_forecast" }) && ProcessInfo.processInfo.systemUptime - finished < 6 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let result: [String: Any] = ["events": events, "spoken": voice.texts,
            "measurement": "single synthetic complex task; existing native GPT/JEV adapters; silent speech sink; no mic, TTS or physical actions; not a GPT-Live comparison",
            "answer_finished_s": finished - began, "total_s": ProcessInfo.processInfo.systemUptime - began,
            "main_finished": !session.thinking, "failure": session.failure ?? "", "model_requests": session.modelRequests]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        #expect(!session.thinking && !session.lastReply.isEmpty)
        #expect(events.contains { $0["kind"] as? String == "model_request" && $0["model"] as? String == configuration.complexModel && $0["agent"] as? String == "voice" })
        #expect(events.contains { $0["kind"] as? String == "voice_forecast" && $0["state"] as? String == "prepared" })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_PARALLEL_NATIVE_PROBE"] == "1"), .timeLimit(.minutes(2)))
    func realSelectedModelsOverlapWithAReviewedOpening() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let out = URL(fileURLWithPath: try #require(env["LISTEN_PARALLEL_NATIVE_OUT"]))
        try #require(out.path.contains("/runs/"))
        var topic = Topic(name: "Synthetic parallel documentation question"); topic.language = .de
        var configuration = VoiceAssistantConfiguration(enabled: true)
        configuration.parallelOpening = true; configuration.openingModel = "chatgpt/gpt-6-luna"
        configuration.webSearch = true; configuration.keepNotes = false
        configuration.limitModelRequests = true; configuration.maximumTurns = 3
        var system = try #require(ListenSystem.builtIns.first { $0.id == "voice-assistant" })
        var settings = system.configuration ?? SystemConfig(); settings.conversation = configuration; system.configuration = settings
        let plan = SessionModel.plan(for: topic, listenSystem: system)
        let reviewer = try #require(plan.settings.decisionClient, "existing enabled JEV connection required")
        let voice = SilentParallelProbeVoice()
        let store = MCPStore(file: out.deletingLastPathComponent().appending(path: "no-tools.json"), readSecret: { _ in nil })
        let session = VoiceAssistantSession(topic: topic, system: system, configuration: configuration,
            client: ResponsesClient(), model: "chatgpt/gpt-6.1-sol", speaker: voice, toolStore: store,
            openingModel: configuration.openingModel, openingReviewer: reviewer)
        defer { session.stop() }
        let began = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        session.record = { kind, fields in
            var event = fields; event["kind"] = kind; event["t"] = ProcessInfo.processInfo.systemUptime - began; events.append(event)
        }
        session.start()
        while !session.ready && ProcessInfo.processInfo.systemUptime - began < 5 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(session.ready)
        session.submit("Prüfe bitte in der offiziellen Swift-Dokumentation, welche Annahmen ich in einem Actor nach await erneut prüfen muss, und erkläre den Grund mit einem kurzen Beispiel.")
        while (session.thinking || session.lastReply.isEmpty) && ProcessInfo.processInfo.systemUptime - began < 45 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let result: [String: Any] = ["events": events, "spoken": voice.texts,
            "measurement": "real existing GPT/JEV adapters; synthetic public question; silent speech sink, no ASR, TTS, microphone, private topic or device action",
            "total_s": ProcessInfo.processInfo.systemUptime - began, "main_finished": !session.thinking,
            "model_requests": session.modelRequests]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        #expect(!session.thinking && !session.lastReply.isEmpty)
        let requests = events.filter { $0["kind"] as? String == "model_request" }
        #expect(requests.contains { $0["agent"] as? String == "voice" })
        #expect(requests.contains { $0["agent"] as? String == "voice-fast" })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_WEB_CAPABILITY_PROBE"] == "1"), .timeLimit(.minutes(2)))
    func existingChatGPTAdapterReallySearchesAndReturnsSources() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let out = URL(fileURLWithPath: try #require(env["LISTEN_WEB_CAPABILITY_OUT"]))
        try #require(out.path.contains("/runs/"))
        var configuration = VoiceAssistantConfiguration()
        configuration.webSearch = true
        let model = try #require(VoiceAssistantConfiguration.webSearchModel("chatgpt/gpt-6.2-sol"))
        let instructions = configuration.replyInstructions(hasTools: false, searchesWeb: true)
            + "\nThis is a public documentation lookup. Answer in at most two German sentences. No external actions or private data."
        let client = AssistantDeadlineClient(base: ResponsesClient(), timeout: .seconds(60))
        let began = ProcessInfo.processInfo.systemUptime
        var text = "", sources: [String] = [], stages: [[String: Any]] = []
        var firstText: Double?
        do {
            for try await chunk in client.stream(model: model,
                system: instructions,
                user: "Bitte suche jetzt auf der offiziellen Swift.org Website die Dokumentation zu Structured Concurrency und Task Cancellation. Öffne die passende offizielle Quelle und nenne zwei Kernaussagen mit Quellenangabe.", maxTokens: 200) {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                switch chunk {
                case .text(let part): text += part; firstText = firstText ?? elapsed
                case .source(let source): if !sources.contains(source) { sources.append(source) }
                case .cost, .usage: break
                default: stages.append(["stage": String(describing: chunk), "after_request_s": elapsed])
                }
            }
            var result: [String: Any] = ["model": model, "completed": true, "total_s": ProcessInfo.processInfo.systemUptime - began,
                "sources": sources, "stages": stages,
                "answer": text, "input": "public Swift.org documentation question; no user conversation or credentials",
                "measurement": "one real existing-adapter call on Mac, no mic, playback or proof of phone-route entitlement"]
            if let firstText { result["first_text_s"] = firstText }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out)
            #expect(!text.isEmpty)
            #expect(!sources.isEmpty, "a plain answer without actual provider sources is not evidence of a completed web lookup")
            #expect(!stages.isEmpty, "the adapter must expose actual research activity for truthful acknowledgement")
        } catch {
            let result: [String: Any] = ["model": model, "completed": false,
                "total_s": ProcessInfo.processInfo.systemUptime - began,
                "error": (error as? any ModelFailure)?.reason ?? String(describing: type(of: error)),
                "sources": sources, "stages": stages]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out)
            throw error
        }
    }
}

@MainActor private final class SilentParallelProbeVoice: AssistantSpeechOutput {
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var texts: [String] = []
    private var generation = 0
    func speak(_ text: String, response: ConversationResponseID, language: Language) {
        texts.append(text); began?(response)
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let self, self.generation == generation else { return }
            finished?(response)
        }
    }
    func stop() { generation += 1 }
}
