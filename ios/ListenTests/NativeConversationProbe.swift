import Foundation
import Testing
@testable import Listen

/// Explicit, bounded conversational measurement: synthetic on-device voice -> Apple's real
/// recognizer -> the existing GPT adapter -> chosen native voice -> timed silent player.
/// Input represents already echo-cancelled near-end audio. Hardware AEC is NOT simulated or
/// claimed. No microphone/device playback, owner topics, tool actions, or saved owner notes.
@MainActor @Suite struct NativeConversationProbe {
    private struct Scenario: Decodable {
        struct Turn: Decodable { var text: String; var startSeconds: Double? }
        var id: String
        var turns: [Turn]
        var finalNeedle: String
    }
    private final class Player: LocalVoicePlayback {
        var until = 0.0
        var epoch = 0
        var recordingOrigin: Double?
        private var recording: [Float] = []
        private let outputRate = 24_000
        func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws {
            let start = max(until, ProcessInfo.processInfo.systemUptime)
            until = start + Double(samples.count) / sampleRate
            if let origin = recordingOrigin {
                // Internal generated PCM only, never a microphone or another app.
                // Render the timed silent queue for later listening, including gaps.
                let offset = max(0, Int((start - origin) * Double(outputRate)))
                let count = Int(Double(samples.count) / sampleRate * Double(outputRate))
                let end = min(300 * outputRate, offset + count)
                if offset < end {
                    if recording.count < end { recording.append(contentsOf: repeatElement(0, count: end - recording.count)) }
                    for index in 0..<(end - offset) {
                        let at = Double(index) * sampleRate / Double(outputRate)
                        let lower = min(Int(at), samples.count - 1), upper = min(lower + 1, samples.count - 1)
                        recording[offset + index] = samples[lower] + Float(at - Double(lower)) * (samples[upper] - samples[lower])
                    }
                }
            }
            let delay = until - ProcessInfo.processInfo.systemUptime, token = epoch
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, epoch == token else { return }
                played()
            }
        }
        func stop() {
            epoch += 1; until = 0
            if let origin = recordingOrigin {
                let heard = max(0, Int((ProcessInfo.processInfo.systemUptime - origin) * Double(outputRate)))
                if recording.count > heard { recording.removeLast(recording.count - heard) }
            }
        }
        func save(to path: URL) throws {
            guard let origin = recordingOrigin else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - origin
            try #require(elapsed < 300, "the output recording must cover the entire bounded replay")
            let pcm = recording.map { Int16(max(-32767, min(32767, $0 * 32767))) }.withUnsafeBufferPointer { Data(buffer: $0) }
            var header = RunRecorder.header(dataBytes: pcm.count)
            var rate = UInt32(outputRate).littleEndian, bytesPerSecond = UInt32(outputRate * 2).littleEndian
            withUnsafeBytes(of: &rate) { header.replaceSubrange(24..<28, with: $0) }
            withUnsafeBytes(of: &bytesPerSecond) { header.replaceSubrange(28..<32, with: $0) }
            try (header + pcm).write(to: path)
        }
    }

    private final class Log {
        let began = ProcessInfo.processInfo.systemUptime
        var rows: [[String: Any]] = []
        let file: URL
        init(file: URL) { self.file = file; FileManager.default.createFile(atPath: file.path, contents: nil) }
        func note(_ kind: String, _ fields: [String: Any] = [:]) {
            let row = fields.merging(["kind": kind, "t": ProcessInfo.processInfo.systemUptime - began]) { $1 }
            rows.append(row)
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data("\n".utf8))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_CONVERSATION_PROBE"] == "1"), .timeLimit(.minutes(10)))
    func measuredSyntheticConversationsIncludingAnInterruption() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let root = try #require(env["LISTEN_TALKBACK_MODELS"])
        let out = URL(fileURLWithPath: try #require(env["LISTEN_CONVERSATION_OUT"]), isDirectory: true)
        try #require(root.contains("/runs/") && out.path.contains("/runs/"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = env["LISTEN_CONVERSATION_VOICE_MODEL"] ?? TalkBack.defaultModel
        let voice = env["LISTEN_CONVERSATION_VOICE"] ?? TalkBack.defaultVoice
        let answerModel = env["LISTEN_CONVERSATION_MODEL"] ?? "chatgpt/gpt-6.2-sol"
        try #require(["chatgpt/gpt-6.1-sol", "chatgpt/gpt-6.2-sol"].contains(answerModel))
        try #require(TalkBack.voices(for: model).contains(voice))
        let engine = TalkBack.synthesizer(for: model)
        try #require(LocalVoice.complete(model) != nil, "only use the already installed isolated model")
        try await engine.prepare(model: model, voice: voice)
        let duplex = env["LISTEN_CONVERSATION_DUPLEX"] != "0"
        var scenarios = [
            ("balu", "Ich habe eine Frage. Bei Käpt'n Balu, wie heißt der Architekturstil von Cape Suzette?",
             "Moment, ich meinte die Lage. Ist Cape Suzette in der Karibik? Und sag bitte nicht immer Hey Listen."),
            ("nvidia", "Schau bitte nach, wer aktuell der Chef von Nvidia ist.",
             "Moment, ich wollte wissen, warum der Verwaltungsrat diese Entscheidung getroffen hat. Erkläre es kurz."),
            ("swift", "Erklär mir kurz für ein iOS-Interview, ob ein Swift Actor Datenrennen verhindert.",
             "Moment, mir geht es um den Zustand nach await. Kann währenddessen ein anderer Aufruf den Actor verändern?")
        ].map { name, first, second in
            Scenario(id: name, turns: [.init(text: first), .init(text: second)],
                     finalNeedle: name == "balu" ? "Karibik" : name == "swift" ? "Zustand" : "Verwaltungsrat")
        }
        if let path = env["LISTEN_CONVERSATION_SCENARIOS"] {
            try #require(path.contains("/runs/"))
            scenarios = try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        scenarios = scenarios.filter { env["LISTEN_CONVERSATION_CASE"] == nil || $0.id == env["LISTEN_CONVERSATION_CASE"] }
        try #require(!scenarios.isEmpty)
        var results: [[String: Any]] = []
        for scenario in scenarios {
            let name = scenario.id
            try #require(name.wholeMatch(of: /[a-z0-9-]{1,40}/) != nil && (2...4).contains(scenario.turns.count))
            var clips: [Data] = []
            for (index, item) in scenario.turns.enumerated() {
                let text = item.text
                try #require(!text.isEmpty && text.count < 1600)
                if let source = env["LISTEN_CONVERSATION_INPUTS"] {
                    let url = URL(fileURLWithPath: source).appending(path: "\(name)-input-\(index).wav")
                    try #require(source.contains("/runs/"))
                    let bytes = try Data(contentsOf: url)
                    try #require(String(decoding: bytes.prefix(4), as: UTF8.self) == "RIFF")
                    try bytes.write(to: out.appending(path: "\(name)-input-\(index).wav"))
                    clips.append(Data(bytes.dropFirst(44)))
                    continue
                }
                var samples: [Float] = []
                var rate: Double?
                for try await chunk in try await engine.speech(text, model: model, voice: voice, language: .de) {
                    try #require(rate == nil || rate == chunk.sampleRate)
                    rate = chunk.sampleRate
                    samples += chunk.samples
                }
                try #require(!samples.isEmpty)
                // Deterministic test-only resampling; synthetic input, not a microphone or clone.
                let ratio = try #require(rate) / WireProtocol.sampleRate
                let count = Int(Double(samples.count) / ratio)
                let pcm = (0..<count).map { i -> Int16 in
                    let at = Double(i) * ratio, lo = min(Int(at), samples.count - 1), hi = min(lo + 1, samples.count - 1)
                    let value = samples[lo] + Float(at - Double(lo)) * (samples[hi] - samples[lo])
                    return Int16(max(-32767, min(32767, value * 32767)))
                }.withUnsafeBufferPointer { Data(buffer: $0) }
                try (RunRecorder.header(dataBytes: pcm.count) + pcm).write(to: out.appending(path: "\(name)-input-\(index).wav"))
                clips.append(pcm)
            }
            if env["LISTEN_CONVERSATION_FIXTURES_ONLY"] == "1" { continue }
            let log = Log(file: out.appending(path: "\(name)-events.jsonl")), player = Player()
            if env["LISTEN_CONVERSATION_CAPTURE_OUTPUT"] == "1" { player.recordingOrigin = log.began }
            let speaker = LocalVoiceSpeaker(model: model, voice: voice, synthesizer: engine, playback: player, status: LocalVoice())
            var topic = Topic(name: "Synthetic \(name) conversation")
            topic.language = .de
            var configuration = VoiceAssistantConfiguration(enabled: true)
            configuration.webSearch = true
            configuration.keepNotes = false
            configuration.limitModelRequests = true
            configuration.maximumTurns = 6
            configuration.talkBackEngine = .local
            configuration.talkBackModel = model
            configuration.talkBackVoice = voice
            let adaptive = env["LISTEN_CONVERSATION_ADAPTIVE"] == "1"
            if adaptive {
                configuration.adaptiveRouting = true; configuration.parallelOpening = true; configuration.prepareFollowups = true
                configuration.simpleModel = "chatgpt/gpt-6-luna"; configuration.openingModel = configuration.simpleModel
                configuration.complexModel = "chatgpt/gpt-6-astra"; configuration.maximumTurns = 32
            }
            var system = try #require(ListenSystem.builtIns.first { $0.id == "voice-assistant" })
            var settings = system.configuration ?? SystemConfig(); settings.conversation = configuration; system.configuration = settings
            let reviewer = adaptive ? SessionModel.plan(for: topic, listenSystem: system).settings.decisionClient : nil
            if adaptive { try #require(reviewer != nil, "real configured JEV is required; no fake adaptive benchmark") }
            let noTools = MCPStore(file: out.appending(path: "no-tools.json"), readSecret: { _ in nil },
                                   writeSecret: { _, _ in }, deleteSecret: { _ in })
            let legacyInput = env["LISTEN_CONVERSATION_LEGACY_INPUT"] == "1"
            let inputEncoder: (HarnessValue) throws -> String
            if legacyInput {
                inputEncoder = { value in String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
            } else {
                inputEncoder = { value in try VoiceTurnInput.encode(value) }
            }
            let session = VoiceAssistantSession(topic: topic, system: system, configuration: configuration,
                client: ResponsesClient(), model: answerModel, speaker: speaker, toolStore: noTools,
                reactionDelay: env["LISTEN_CONVERSATION_REACTIONS"] == "1" ? ConversationReaction.delay : nil,
                context: AssistantContext(earlier: "Historical quote, not an active instruction: the user once tested saying Hey Listen before each sentence. This preference was removed."),
                openingModel: adaptive ? configuration.openingModel : nil, openingReviewer: reviewer, inputEncoder: inputEncoder)
            let transport = LocalTransport(language: .de)
            session.record = { kind, fields in
                log.note(kind, fields)
                if kind == "voice_playback" || kind == "voice_barge_in" {
                    log.note("player_metrics", ["gap_s": speaker.playout.gapSeconds,
                        "longest_gap_s": speaker.playout.longestGap, "stalls": speaker.stalls,
                        "first_audio_s": speaker.firstAudioAfter ?? -1])
                }
            }
            var ready = false
            transport.onEvent = { [weak transport, weak session] event in
                guard let transport, let session else { return }
                guard case .envelope(let envelope) = event else { return }
                if case .state(.listening, _) = envelope.event { ready = true }
                if case .transcript(let segment) = envelope.event {
                    let supported = !duplex || transport.hasSpeech(segment)
                    log.note("recognizer", ["segment": segment.segmentID, "final": segment.isFinal,
                        "text": segment.text, "start_ms": segment.startMs, "end_ms": segment.endMs,
                        "acoustic_support": supported])
                    session.receive(segment, hasAcousticSupport: supported)
                }
                if case .error = envelope.event { log.note("recognizer_error") }
            }
            session.onTurnPause = { transport.endUtterance() }
            session.start(store: noTools)
            session.setDuplexListening(duplex) // capability-controlled comparison, not hardware evidence
            transport.send(.start(language: .de, contextVersion: 1))
            defer { session.stop(); transport.disconnect() }
            let setupLimit = ProcessInfo.processInfo.systemUptime + 45
            while (!ready || !session.ready) && ProcessInfo.processInfo.systemUptime < setupLimit {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(ready && session.ready)
            var pending = clips[0], inputIndex = 0, currentInput = 0, sequence: UInt32 = 0
            var activity = ConversationActivity()
            var bargeAt: Double?, secondFed = false, firstFrame = true
            var endLogged = false
            let began = ProcessInfo.processInfo.systemUptime
            let duration = min(180, max(30, Double(env["LISTEN_CONVERSATION_SECONDS"] ?? "100") ?? 100))
            let limit = began + duration
            var lastInputAt = began
            while ProcessInfo.processInfo.systemUptime < limit {
                let now = ProcessInfo.processInfo.systemUptime
                if firstFrame { log.note("input_begin", ["case": name, "input": 0, "text": scenario.turns[0].text]); firstFrame = false }
                let nextInput = currentInput + 1
                if nextInput < clips.count, let fixed = scenario.turns[nextInput].startSeconds {
                    try #require(fixed.isFinite && fixed > 0 && fixed < duration - 10)
                    bargeAt = began + fixed
                } else if nextInput < clips.count, session.audible,
                   env["LISTEN_CONVERSATION_BARGE_ON_ACK"] == "1" || !session.acknowledging {
                    bargeAt = bargeAt ?? now + 1
                }
                if nextInput < clips.count, let due = bargeAt, now >= due {
                    currentInput = nextInput
                    log.note("input_begin", ["case": name, "input": currentInput, "text": scenario.turns[currentInput].text,
                                              "overlap": session.audible, "scheduled_s": due - began])
                    pending = clips[currentInput]; inputIndex = 0; secondFed = true
                    bargeAt = nil; lastInputAt = now
                    endLogged = false
                }
                let end = min(inputIndex + WireProtocol.frameBytes, pending.count)
                var frame = inputIndex < pending.count ? pending.subdata(in: inputIndex..<end) : Data()
                inputIndex = end
                if !endLogged, inputIndex == pending.count {
                    log.note("input_clip_end", ["input": currentInput])
                    endLogged = true
                }
                if frame.count < WireProtocol.frameBytes { frame.append(Data(count: WireProtocol.frameBytes - frame.count)) }
                let withheld = session.blocksRecognition
                if withheld { activity.reset() } else { activity.receive(frame) }
                if duplex { session.microphoneActivity(speechSeconds: activity.speechSeconds, quietSeconds: activity.quietSeconds) }
                session.heardQuiet(for: activity.quietSeconds)
                sequence += 1
                transport.sendAudio(.init(seq: sequence, captureMs: UInt64(now * 1000), pcm: withheld ? Data(count: frame.count) : frame))
                if currentInput == clips.count - 1, inputIndex == pending.count, !session.thinking, !session.speaking,
                   !session.hearing, now > lastInputAt + Double(pending.count) / 32_000 + 3 { break }
                let due = began + Double(sequence) * 0.1
                let wait = due - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            }
            session.stop(); transport.disconnect()
            try player.save(to: out.appending(path: "returned-audio.wav"))
            let requests = log.rows.filter { $0["kind"] as? String == "model_request" }
            let usages = log.rows.filter { $0["kind"] as? String == "usage" }
            let needle = scenario.finalNeedle
            let secondReached = requests.contains {
                guard let raw = $0["input"] as? String,
                      let payload = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let messages = payload["messages"] as? [[String: Any]],
                      let user = messages.last(where: { $0["role"] as? String == "user" }) else { return false }
                return (user["text"] as? String)?.localizedCaseInsensitiveContains(needle) == true
            }
            let result: [String: Any] = ["duplex_enabled": duplex, "followup_reached_model": secondReached, "case": name, "elapsed_s": ProcessInfo.processInfo.systemUptime - began,
                "model": answerModel, "tts_model": model, "tts_voice": voice, "adaptive_routing": adaptive,
                "prompt_encoding": legacyInput ? "legacy_dictionary" : "stable_prefix",
                "model_requests": requests.count, "cancelled": usages.filter { $0["outcome"] as? String == "cancelled" }.count,
                "barge_in_events": log.rows.filter { $0["kind"] as? String == "voice_barge_in" }.count,
                "second_input_fed": secondFed, "input_turns_fed": currentInput + 1, "expected_input_turns": clips.count, "last_reply": session.lastReply,
                "hardware_aec_verified": false, "native_asr_and_tts": true,
                "measurement": "Synthetic post-AEC input, real native ASR/GPT adapter/TTS, timed silent output on Mac; not phone/acoustic latency."]
            results.append(result)
            let data = try log.rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data("\n".utf8) }.reduce(Data(), +)
            try data.write(to: out.appending(path: "\(name)-events.jsonl"))
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]).write(to: out.appending(path: "results.json"))
            #expect(currentInput == clips.count - 1 && !session.lastReply.isEmpty)
            #expect(!duplex || secondReached, "the complete overlapping question must reach the model when input stays live")
            #expect(!log.rows.contains { $0["kind"] as? String == "voice_operation" }, "no actions in a replay")
        }
    }
}
