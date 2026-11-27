import Foundation
import Testing
@testable import Listen

/// An opt-in measurement runner, not a correctness/count score. Replays selected PCM through
/// the real on-device recognizer, saved Topic/System, provider adapters and native TTS.
/// Uses a timed silent player, no microphone, no owner settings/notes/recordings are written.
@MainActor @Suite struct SystemPerformanceProbe {
    private struct Input: Decodable {
        var id: String
        var input: String
        var topic_id: UUID
        var pcm_active_end_s: Double
    }

    private final class Built {
        var engine: AnswerEngine?
        var transport: LocalTransport?
        var speaker: LocalVoiceSpeaker?
        var profile: [String: Any] = [:]
    }

    private final class SilentPlayer: LocalVoicePlayback {
        private var end = 0.0
        private var epoch = 0
        func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws {
            let now = ProcessInfo.processInfo.systemUptime
            end = max(end, now) + Double(samples.count) / sampleRate
            let delay = end - now, epoch = epoch
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.epoch == epoch else { return }
                played()
            }
        }
        func stop() { epoch += 1; end = 0 }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_SYSTEM_PERF_PROBE"] == "1"), .timeLimit(.minutes(15)))
    func measuredRecordedInputThroughTheSavedSystem() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let inputFile = URL(fileURLWithPath: try #require(env["LISTEN_SYSTEM_PERF_CASES"]))
        let out = URL(fileURLWithPath: try #require(env["LISTEN_SYSTEM_PERF_OUT"]), isDirectory: true)
        try #require(out.path.contains("/runs/"), "keep private measurements in the ignored run folder")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: inputFile))
        let topics = TopicStore(), systems = SystemStore()
        let mode = env["LISTEN_SYSTEM_PERF_MODE"] ?? "staged"
        var results: [[String: Any]] = []

        for item in inputs {
            let topic = try #require(topics.topics.first { $0.id == item.topic_id })
            var chosen = systems.chosen(for: topic)
            try #require(!chosen.isVoiceAssistant, "measure the selected system's roles, not a direct-model substitute")
            // Explicit candidate voice in this isolated replay only. The selected
            // role models/context/budget stay intact; nothing is saved to the owner.
            if let voiceModel = env["LISTEN_SYSTEM_PERF_VOICE_MODEL"], let voice = env["LISTEN_SYSTEM_PERF_VOICE"] {
                try #require(TalkBack.voices(for: voiceModel).contains(voice) && LocalVoice.complete(voiceModel) != nil)
                var settings = chosen.configuration ?? SystemConfig()
                var conversation = settings.conversation ?? VoiceAssistantConfiguration(enabled: true)
                conversation.enabled = true
                conversation.speakReplies = true
                conversation.answerSource = .harness
                conversation.talkBackEngine = .local
                conversation.talkBackModel = voiceModel
                conversation.talkBackVoice = voice
                settings.conversation = conversation
                chosen.configuration = settings
            }
            var loaded = SystemConfig.load()
            chosen.apply(to: &loaded.config)
            let material = TopicMaterial(topic: topic.id).index
            let terms = Array(material.terms.prefix(24))
            let glossary = ([topic.glossary] + (terms.isEmpty ? [] : [terms.joined(separator: ", ")])).filter { !$0.isEmpty }.joined(separator: ". ")
            let built = Built()
            let run = try #require(RunRecorder(topic: topic.name, language: topic.language.rawValue, root: out,
                                               topicID: topic.id, input: "recorded-file", evaluation: true))
            let began = ProcessInfo.processInfo.systemUptime
            var firstAudio: Double?, deepAudio: Double?, firstCommit: Double?, firstReaction: Double?
            var requests = Set<String>(), failures = 0, cancellations = 0
            var milestones: [String: Double] = [:]
            var requestStarts: [String: (time: Double, agent: String)] = [:]
            var providerTimes: [[String: Any]] = []
            var readyCards: [UInt64: Double] = [:]
            var spokenCards = Set<UInt64>()
            var voiceCards: [[String: Any]] = []
            var voiceResponses: [[String: Any]] = []
            var lastFinished = 0.0
            var setupFailure: String?
            let parts = SessionModel.Parts(
                system: { _ in (loaded, chosen) },
                answers: { topic, system, selected, spoken in
                    var form = spoken
                    if mode == "fast-only" { form?.deepens = false }
                    let plan = SessionModel.plan(for: topic, system: system, listenSystem: selected)
                    built.profile = ["system":selected.id, "drafters":plan.settings.drafters,
                        "main":plan.settings.merger, "researcher":plan.settings.researcher ?? "",
                        "jev_attached":plan.settings.decisionClient != nil, "material_passages":material.passages.count,
                        "budget_usd":plan.settings.limitUSD]
                    let engine = SessionModel.answers(for: topic, system: system, listenSystem: selected, spoken: form)
                    built.engine = engine
                    return engine
                },
                transport: { topic, answers in
                    let transport = LocalTransport(language: topic.language,
                        refiner: WhisperRefiner(language: topic.language, glossary: glossary, voice: loaded.config.voice),
                        answers: answers, speakerWindowSeconds: loaded.config.voice.speakerWindowSeconds, expected: terms)
                    transport.onTrace = { run.log($0) }
                    built.transport = transport
                    return transport
                },
                speaker: { configuration in
                    guard configuration.talkBackEngine == .local else {
                        setupFailure = "The selected voice is not a native model"
                        return AssistantSpeaker()
                    }
                    built.profile["tts_model"] = configuration.talkBackModel
                    built.profile["tts_voice"] = configuration.talkBackVoice
                    let speaker = LocalVoiceSpeaker(model: configuration.talkBackModel, voice: configuration.talkBackVoice,
                        synthesizer: TalkBack.synthesizer(for: configuration.talkBackModel), playback: SilentPlayer(), status: LocalVoice())
                    built.speaker = speaker
                    return speaker
                })
            let model = SessionModel(parts: parts)
            model.onEvent = { event in
                run.log(event)
                if case .transcript(let segment) = event, segment.isFinal, firstCommit == nil {
                    firstCommit = ProcessInfo.processInfo.systemUptime
                    milestones["recognition_committed"] = firstCommit
                }
            }
            model.start(topic, spoken: true)
            try #require(model.startFailure == nil && setupFailure == nil)
            built.engine?.onLog = { kind, fields in
                run.logModelEventIfNeeded(kind, fields)
                let now = ProcessInfo.processInfo.systemUptime
                if kind == "model_request", let id = fields["request_id"] as? String {
                    requests.insert(id)
                    let agent = fields["agent"] as? String ?? "unknown"
                    requestStarts[id] = (now, agent)
                    if milestones[agent + "_requested"] == nil { milestones[agent + "_requested"] = now }
                }
                if kind == "usage", let outcome = fields["outcome"] as? String {
                    if outcome == "failed" { failures += 1 }
                    if outcome == "cancelled" { cancellations += 1 }
                    if let id = fields["request_id"] as? String, let start = requestStarts[id] {
                        var timing: [String: Any] = ["request_id": id, "agent": start.agent,
                            "model": fields["model"] ?? "", "outcome": outcome, "total_s": now - start.time]
                        if let first = fields["first_text_seconds"] as? Double {
                            timing["first_text_s"] = first
                            let key = start.agent + "_first_text"
                            milestones[key] = min(milestones[key] ?? .infinity, start.time + first)
                        }
                        providerTimes.append(timing)
                    }
                }
            }
            model.spoken?.record = { kind, fields in
                run.log(kind, fields)
                let now = ProcessInfo.processInfo.systemUptime
                let card = (fields["card"] as? NSNumber)?.uint64Value
                let part = fields["part"] as? String ?? "answer"
                if kind == "voice_acknowledgement", fields["state"] as? String == "scheduled" {
                    firstReaction = firstReaction ?? now
                }
                // A queued speech is complete, accepted content. This is not a model's
                // first token and does not claim that its claims were checked on the web.
                if kind == "voice_speech", fields["state"] as? String == "queued", let card {
                    readyCards[card] = readyCards[card] ?? now
                    let key = part == "answer" ? "first_answer_ready" : "first_deep_ready"
                    milestones[key] = milestones[key] ?? now
                }
                if kind == "voice_playback", fields["state"] as? String == "scheduled" {
                    firstAudio = firstAudio ?? now
                    milestones["first_voice"] = firstAudio
                    if part != "answer" {
                        deepAudio = deepAudio ?? now
                        milestones["first_deep_voice"] = deepAudio
                    }
                    if let card, spokenCards.insert(card).inserted {
                        var timing: [String: Any] = ["card": card, "part": part, "player_at_s": now - began]
                        if let ready = readyCards[card] { timing["ready_to_player_s"] = now - ready }
                        voiceCards.append(timing)
                    }
                }
                if kind == "voice_playback", fields["state"] as? String == "finished" { lastFinished = now }
                if kind == "voice_playback", let state = fields["state"] as? String,
                   state == "finished" || state == "cancelled", let speaker = built.speaker {
                    var response: [String: Any] = ["response": fields["response"] ?? "", "state": state,
                        "player_stalls": speaker.stalls]
                    if let first = speaker.firstAudioAfter { response["native_first_buffer_s"] = first }
                    voiceResponses.append(response)
                }
            }
            let readinessDeadline = began + 60
            while model.core.phase != .listening && ProcessInfo.processInfo.systemUptime < readinessDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(model.core.phase == .listening, "file recognizer must be ready; no microphone fallback")
            let bytes = try Data(contentsOf: URL(fileURLWithPath: item.input))
            try #require(bytes.count >= 44 && String(decoding: bytes.prefix(4), as: UTF8.self) == "RIFF")
            let pcm = Data(bytes.dropFirst(44))
            let feedBegan = ProcessInfo.processInfo.systemUptime
            let activeEnd = feedBegan + item.pcm_active_end_s
            run.log("performance_input", ["case":item.id,"mode":mode,"source":"recorded PCM, no live capture",
                "active_end_after_run_s":activeEnd - began,"endpoint":"20 ms RMS threshold, approximate",
                "profile":built.profile,"setup_s":feedBegan - began])
            let deadline = feedBegan + Double(pcm.count) / 32_000 + 55
            var index = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                let from = index * WireProtocol.frameBytes
                var frame = from < pcm.count ? Data(pcm[from..<min(pcm.count, from + WireProtocol.frameBytes)]) : Data()
                if frame.count < WireProtocol.frameBytes { frame.append(Data(count: WireProtocol.frameBytes - frame.count)) }
                let due = feedBegan + Double(index) * 0.1
                let delay = due - ProcessInfo.processInfo.systemUptime
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                run.audio(frame)
                model.captured(frame)
                index += 1
                if firstAudio != nil, lastFinished > activeEnd, model.spoken?.thinking == false,
                   model.spoken?.speaking == false, ProcessInfo.processInfo.systemUptime - lastFinished > 2 { break }
            }
            let unfinishedAtLimit = model.spoken?.speaking == true || model.spoken?.thinking == true
            model.stopAndSave()
            await Task.yield()
            var result: [String: Any] = ["case":item.id,"mode":mode,"run":run.directory.path,"profile":built.profile,
                "model_requests":requests.count,"model_failures":failures,"model_cancellations":cancellations,
                "requests_without_final_usage":max(0, requests.count - providerTimes.count),
                "voice_or_round_unfinished_at_limit":unfinishedAtLimit,
                "answered":firstAudio != nil,"deep_addition":deepAudio != nil,
                "measurement":"recorded PCM -> real recognizer/refinement -> saved system/providers -> native TTS -> silent timed player; no acoustic output",
                "endpoint":"approximate recorded-PCM activity end; not independently annotated word end"]
            if let firstAudio { result["active_end_to_first_voice_s"] = firstAudio - activeEnd }
            if let firstReaction { result["active_end_to_first_reaction_s"] = firstReaction - activeEnd }
            if let deepAudio { result["active_end_to_deep_voice_s"] = deepAudio - activeEnd }
            if let firstAudio, let firstCommit { result["commit_to_first_voice_s"] = firstAudio - firstCommit }
            result["milestones_after_activity_end_s"] = milestones.mapValues { $0 - activeEnd }
            result["provider_timings"] = providerTimes
            result["spoken_cards"] = voiceCards
            result["voice_responses"] = voiceResponses
            result["voice_ready_not_begun_cards"] = readyCards.keys.filter { !spokenCards.contains($0) }.sorted()
            if let first = voiceCards.first(where: { $0["part"] as? String != "answer" }),
               let wait = first["ready_to_player_s"] as? Double { result["deep_ready_to_player_s"] = wait }
            result["premature_voice_overlap"] = firstAudio.map { $0 < activeEnd } ?? false
            run.log("performance_result", result)
            run.finish()
            results.append(result)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]).write(to: out.appending(path:"performance.json"))
            print("SYSTEM_PERFORMANCE", String(decoding: try JSONSerialization.data(withJSONObject: result, options:.sortedKeys), as:UTF8.self))
        }
    }
}

private extension RunRecorder {
    func logModelEventIfNeeded(_ kind: String, _ fields: [String: Any]) {
        if kind == "model_request" || kind == "usage" { logModelEvent(kind, fields) }
        else { log(kind, fields) }
    }
}
