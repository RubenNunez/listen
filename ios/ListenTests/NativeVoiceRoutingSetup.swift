import Foundation
import Testing
@testable import Listen

/// Opt-in owner setup using existing native model adapters. Connectivity requests contain
/// synthetic text only, no topic data or tools. Provider credentials never leave adapters.
@MainActor @Suite struct NativeVoiceRoutingSetup {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_CONFIGURE_VOICE_ROUTING"] == "1"), .timeLimit(.minutes(2)))
    func verifyModelsAndEnableRoutingForTheSelectedVoiceTopic() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let topics = TopicStore(), systems = SystemStore()
        let topic = topics.selected
        var system = systems.chosen(for: topic)
        try #require(system.isVoiceAssistant && systems.storageProblem == nil)
        var configuration = system.configuration ?? SystemConfig()
        var voice = configuration.conversation ?? VoiceAssistantConfiguration(enabled: true)
        voice.adaptiveRouting = true
        configuration.conversation = voice; system.configuration = configuration
        let plan = SessionModel.plan(for: topic, listenSystem: system)
        let reviewer = try #require(plan.settings.decisionClient)
        let client = RoutedClient(local: nil, remote: plan.key.map { OpenRouterClient(key: $0) }, direct: plan.direct)
        let chosen = UserDefaults.standard.stringArray(forKey: ChatGPT.alsoAskedKey) ?? []
        let fast = chosen.first { $0.contains("luna") }.map { "chatgpt/" + $0 }
        try #require(fast != nil, "Choose an available fast model in Account first")
        var rows: [[String: Any]] = []
        func available(_ model: String) async -> Bool {
            let began = ProcessInfo.processInfo.systemUptime
            var text = "", first: Double?
            do {
                for try await chunk in AssistantDeadlineClient(base: client, timeout: .seconds(15)).stream(
                    model: model, system: "Synthetic connection check. Reply only READY. No tools or actions.",
                    user: "Reply READY.", maxTokens: 16) {
                    if case .text(let part) = chunk { if first == nil { first = ProcessInfo.processInfo.systemUptime - began }; text += part }
                }
                let ready = text.trimmingCharacters(in: .whitespacesAndNewlines) == "READY"
                rows.append(["model": model, "available": ready, "first_text_s": first ?? -1])
                return ready
            } catch {
                rows.append(["model": model, "available": false, "outcome": "connection_check_failed"])
                return false
            }
        }
        let fastModel = try #require(fast)
        try #require(await available(fastModel))
        var complex = ""
        for candidate in ["chatgpt/gpt-6.2-astra", "chatgpt/gpt-6-astra"] {
            if await available(candidate) { complex = candidate; break }
        }
        let questions = try VoiceTaskPlan.questions(hints: [], fillers: [], hasTools: false)
        var raw = ""
        let began = ProcessInfo.processInfo.systemUptime
        for try await chunk in AssistantDeadlineClient(base: reviewer, timeout: .milliseconds(1200)).stream(
            model: "typesafe/\(JevClient.model)", system: questions,
            user: #"{"messages":[{"role":"user","text":"Was ist zwei plus zwei?"}],"tools":[]}"#, maxTokens: 0) {
            if case .text(let text) = chunk { raw += text }
        }
        _ = try VoiceTaskPlan.read(raw, hintCount: 0, fillerCount: 0)
        let routeSeconds = ProcessInfo.processInfo.systemUptime - began
        voice.simpleModel = fastModel; voice.openingModel = fastModel
        voice.complexModel = complex; voice.parallelOpening = true; voice.prepareFollowups = true
        try voice.validate()
        configuration.conversation = voice; system.configuration = configuration
        systems.update(system)
        try #require(systems.lastError == nil)
        let result: [String: Any] = ["state": "configured", "synthetic_model_checks": rows,
            "routing_check_s": routeSeconds, "simple_model": fastModel, "complex_model": complex,
            "adaptive_routing": true, "parallel_opening": true, "preparation": true, "actions_sent": 0,
            "scope": "Connection checks only, not conversation quality or end-to-end latency"]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL.cachesDirectory.appending(path: "listen-owner-routing-status.json"), options: .atomic)
    }
}
