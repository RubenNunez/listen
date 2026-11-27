import Foundation
import AVFoundation
import AudioToolbox
import Darwin
import Testing

@testable import Listen

/// The offline engine/buffer are used by one detached render task, then stopped
/// by their owner only after that task returns. No physical I/O is enabled.
private final class OffThreadAudioRender: @unchecked Sendable {
    let engine: AVAudioEngine
    let buffer: AVAudioPCMBuffer
    init(engine: AVAudioEngine, buffer: AVAudioPCMBuffer) { self.engine = engine; self.buffer = buffer }
    func silent() throws -> Bool {
        guard try engine.renderOffline(256, to: buffer) == .success,
              buffer.frameLength == 256, let data = buffer.floatChannelData else { return false }
        for index in 0..<256 where data[0][index] != 0 { return false }
        return true
    }
}

@MainActor @Suite struct VoiceAudioGraphLifecycle {
    @Test func silentOutputReferenceRendersOutsideTheMainActor() async throws {
        let engine = AVAudioEngine(), source = AudioCapture.silentSource()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        let worker = OffThreadAudioRender(engine: engine, buffer: buffer)
        #expect(try await Task.detached { try worker.silent() }.value)
    }

    @Test func microphoneConversionKeepsChannelZeroAndRejectsAuxiliaryChannels() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        func converted(microphone: Float, auxiliary: Float) throws -> [Int16] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<9 {
                channels[channel].initialize(repeating: channel == 0 ? microphone : auxiliary, count: 4800)
            }
            let chunker = try #require(PCMChunker(inputFormat: format))
            var pcm = Data()
            for _ in 0..<3 {
                for item in chunker.append(buffer) { if case .frame(let data) = item { pcm.append(data) } }
            }
            return pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        let speech = try converted(microphone: 0.2, auxiliary: -0.2)
        #expect(!speech.isEmpty && speech.contains { $0 > 5000 }, "auxiliary/reference channels must not cancel the microphone")
        let auxiliaryOnly = try converted(microphone: 0, auxiliary: 0.4)
        #expect(!auxiliaryOnly.isEmpty && auxiliaryOnly.allSatisfy { abs(Int($0)) < 2 }, "reference audio must not become user speech")
    }

    @Test func retiredVoiceNodesWaitUntilSharedRenderingStops() throws {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        // Offline rendering cannot open the microphone or play through the device.
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        VoiceAudioIO.began(engine)
        VoiceAudioIO.retire(node, from: engine)
        #expect(node.engine === engine, "voice replacement must not detach from the live shared graph")
        VoiceAudioIO.reuse(node)
        VoiceAudioIO.retire(node, from: engine)
        engine.stop()
        VoiceAudioIO.ended(engine)
        #expect(node.engine == nil && VoiceAudioIO.engine == nil)
    }
}

// Synthetic fixtures only. Nothing here loads a model, except the probe at the end, which
// runs only when asked for by an environment variable.

/// A synthesizer whose streams the test feeds by hand.
private actor VoiceDouble: LocalVoiceSynthesizing {
    private var streams: [AsyncThrowingStream<LocalVoiceChunk, any Error>.Continuation] = []
    private var refusal: LocalVoiceUnavailable?
    private(set) var prepared = 0
    private(set) var ended = 0

    init(refusal: LocalVoiceUnavailable? = nil) { self.refusal = refusal }

    var count: Int { streams.count }

    func prepare(model: String, voice: String) async throws {
        prepared += 1
        if let refusal { throw refusal }
    }

    func speech(_ text: String, model: String, voice: String, language: Language) async throws
        -> AsyncThrowingStream<LocalVoiceChunk, any Error>
    {
        if let refusal { throw refusal }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LocalVoiceChunk.self)
        continuation.onTermination = { _ in Task { await self.noteEnd() } }
        streams.append(continuation)
        return stream
    }

    private func noteEnd() { ended += 1 }

    /// `seconds` of audio at 1000 samples per second.
    func yield(_ stream: Int, seconds: Double) {
        streams[stream].yield(LocalVoiceChunk(samples: Array(repeating: 0.03, count: Int(seconds * 1000)), sampleRate: 1000))
    }

    func finish(_ stream: Int, throwing error: (any Error)? = nil) {
        streams[stream].finish(throwing: error)
    }
}

@MainActor private final class PlaybackDouble: LocalVoicePlayback {
    var scheduled: [(seconds: Double, played: @MainActor @Sendable () -> Void)] = []
    var stops = 0
    var refuses = false

    func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws {
        if refuses { throw LocalVoiceUnavailable(message: "No output.") }
        scheduled.append((Double(samples.count) / sampleRate, played))
    }

    func stop() { stops += 1 }

    func play(_ range: Range<Int>) {
        for index in range { scheduled[index].played() }
    }
}

@MainActor private final class Stage {
    let voice: VoiceDouble
    let playback = PlaybackDouble()
    let status = LocalVoice()
    let speaker: LocalVoiceSpeaker
    var clock = 0.0
    var events: [String] = []

    init(refusal: LocalVoiceUnavailable? = nil) {
        voice = VoiceDouble(refusal: refusal)
        var read: () -> Double = { 0 }
        speaker = LocalVoiceSpeaker(
            model: TalkBack.defaultModel, voice: TalkBack.defaultVoice, synthesizer: voice, playback: playback,
            status: status, buffering: .streamed, now: { read() })
        read = { [unowned self] in self.clock }
        speaker.began = { [unowned self] in self.events.append("began \($0.rawValue)") }
        speaker.finished = { [unowned self] in self.events.append("finished \($0.rawValue)") }
        speaker.cancelled = { [unowned self] in self.events.append("cancelled \($0.rawValue)") }
    }

    /// Starts a reply and waits until its stream is open.
    func speak(_ id: String) async throws {
        let before = await voice.count
        speaker.speak("synthetic reply", response: ConversationResponseID(id), language: .en)
        try await until { await self.voice.count == before + 1 }
    }
}

@MainActor private func until(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not reached")
}

/// Lets queued main-actor work run, for checks that nothing happened.
@MainActor private func settle() async throws {
    try await Task.sleep(for: .milliseconds(60))
}

@Suite struct TalkBackConfigurationTests {
    @Test func theLocalVoiceIsTheDefaultWhereTheDeviceCanRunIt() {
        #expect(VoiceAssistantConfiguration().talkBackEngine == TalkBackEngine.preferred)
        #if targetEnvironment(simulator)
        #expect(TalkBackEngine.preferred == .system)
        #else
        #expect(TalkBackEngine.preferred == (LocalVoice.unsupported == nil ? .local : .system))
        #endif
    }

    @Test func aConfigurationWithoutTalkBackFieldsDecodesToThePreferredVoice() throws {
        let legacy = try JSONDecoder().decode(
            VoiceAssistantConfiguration.self, from: Data(#"{"enabled":true,"speakReplies":true}"#.utf8))
        #expect(legacy.talkBackEngine == TalkBackEngine.preferred)
        #expect(legacy.talkBackModel == "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit")
        #expect(legacy.talkBackVoice == "Serena")
        try legacy.validate()

        var local = legacy
        local.talkBackEngine = .local
        local.talkBackModel = TalkBack.models[0].id
        local.talkBackVoice = "Aiden"
        let again = try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: JSONEncoder().encode(local))
        #expect(again == local)
        try again.validate()
    }

    @Test func onlyCatalogueModelsVoicesAndEnginesAreAccepted() throws {
        var other = VoiceAssistantConfiguration(enabled: true)
        other.talkBackModel = "someone/another-model"
        #expect(throws: (any Error).self) { try other.validate() }
        other.talkBackModel = TalkBack.defaultModel
        other.talkBackVoice = "Nobody"
        #expect(throws: (any Error).self) { try other.validate() }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: Data(#"{"talkBackEngine":"cloud"}"#.utf8))
        }
    }

    @Test func aSystemPackageFromBeforeTalkBackStillImportsAndAnUnknownModelDoesNot() throws {
        var voice = ListenSystem.builtIns.first { $0.id == "voice-assistant" }!
        voice.configuration?.conversation?.talkBackEngine = .local
        let package = SystemPackage(system: voice, defaults: SystemConfig())
        #expect(try SystemPackage.read(package.data()).system.configuration?.conversation?.talkBackEngine == .local)

        func rewritten(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var raw = try JSONSerialization.jsonObject(with: package.data()) as! [String: Any]
            var definition = raw["system"] as! [String: Any]
            var settings = definition["settings"] as! [String: Any]
            var conversation = settings["conversation"] as! [String: Any]
            change(&conversation)
            settings["conversation"] = conversation; definition["settings"] = settings; raw["system"] = definition
            return try JSONSerialization.data(withJSONObject: raw)
        }
        let old = try rewritten { $0["talkBackEngine"] = nil; $0["talkBackModel"] = nil; $0["talkBackVoice"] = nil }
        let restored = try SystemPackage.read(old).system.configuration?.conversation
        #expect(restored?.talkBackEngine == TalkBackEngine.preferred)
        #expect(restored?.talkBackModel == TalkBack.defaultModel && restored?.talkBackVoice == TalkBack.defaultVoice)

        #expect(throws: (any Error).self) {
            try SystemPackage.read(rewritten { $0["talkBackModel"] = "someone/another-model" })
        }
    }

    @MainActor @Test func theConfigurationSelectsTheEngine() {
        let voice = VoiceDouble()
        var configuration = VoiceAssistantConfiguration(enabled: true)
        configuration.talkBackEngine = .system
        #expect(TalkBack.speaker(for: configuration, synthesizer: voice) is AssistantSpeaker)
        configuration.talkBackEngine = .local
        #expect(TalkBack.speaker(for: configuration, synthesizer: voice) is LocalVoiceSpeaker)
        // Text-only sessions load no voice.
        configuration.speakReplies = false
        #expect(TalkBack.speaker(for: configuration, synthesizer: voice) is AssistantSpeaker)
    }
}

@MainActor @Suite struct LocalVoiceSpeakerTests {
    @Test func replyPresentationFollowsThePlayingSentenceAndIgnoresLateRetiredCues() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let local = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        let wrapper = AssistantReplySpeech(output: local), response = ConversationResponseID("presentation")
        let first = "The first complete sentence is being played."
        let second = "The second complete sentence is prepared but not yet playing."
        var ends: [Int] = []
        wrapper.presentationReached = { id, end in if id == response { ends.append(end) } }
        defer { wrapper.stop() }
        wrapper.begin(response: response, language: .en)
        wrapper.append(first, response: response)
        try await until { await voice.count == 1 }
        clock = 1.8
        await voice.yield(0, seconds: 0.6); await voice.finish(0)
        try await until { playback.scheduled.count == 1 }
        #expect(ends == [first.count])
        wrapper.append(second, response: response)
        try await until { await voice.count == 2 }
        clock = 3.6
        await voice.yield(1, seconds: 0.6); await voice.finish(1)
        try await until { playback.scheduled.count == 2 }
        #expect(ends == [first.count], "a generated or queued future sentence is not a presentation cue")
        playback.play(0..<1)
        #expect(ends == [first.count, first.count + 1 + second.count])
        let late = local.reached
        wrapper.stop()
        late?(response, 0)
        #expect(ends.count == 2)
    }
    @Test func theNextSentenceGeneratesWhileTheFirstOneIsStillPlaying() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let local = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        let speaker = AssistantReplySpeech(output: local), response = ConversationResponseID("pipelined")
        var events: [String] = []
        speaker.began = { _ in events.append("began") }
        speaker.finished = { _ in events.append("finished") }
        defer { speaker.stop() }
        speaker.begin(response: response, language: .en)
        speaker.append("The first sentence has enough words to stand alone.", response: response)
        speaker.append("The next sentence can already generate in the background.", response: response)
        speaker.complete(response: response)
        try await until { await voice.count == 1 }
        // Three times slower than real time: the sentence waits until it is complete.
        clock = 1.8
        await voice.yield(0, seconds: 0.6)
        try await settle()
        #expect(playback.scheduled.isEmpty)
        await voice.finish(0)
        try await until { await voice.count == 2 && playback.scheduled.count == 1 }
        #expect(events == ["began"], "generation continues without waiting for the first playback callback")
        clock = 3.6
        await voice.yield(1, seconds: 0.6)
        await voice.finish(1)
        try await until { playback.scheduled.count == 2 }
        playback.play(0..<1)
        #expect(events == ["began"])
        playback.play(1..<2)
        #expect(events == ["began", "finished"])
    }

    /// A sentence whose audio is already at the player is prepared, not heard: `reached`
    /// names the sentence the player has actually begun.
    @Test func theSpeakerSaysWhichAppendedSentenceThePlayerHasBegun() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let speaker = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        let response = ConversationResponseID("sentences")
        var reached: [Int] = [], finished = false
        speaker.reached = { id, index in if id == response { reached.append(index) } }
        speaker.finished = { _ in finished = true }
        defer { speaker.stop() }
        speaker.begin(response: response, language: .en)
        speaker.append("The first sentence has enough words to stand alone.", response: response)
        try await until { await voice.count == 1 }
        clock = 1.8
        await voice.yield(0, seconds: 0.6)
        await voice.finish(0)
        try await until { playback.scheduled.count == 1 }
        #expect(reached == [0], "the player begins the first sentence as soon as it has its audio")
        // The second sentence is appended and generated while the first one plays.
        speaker.append("The next sentence can already generate in the background.", response: response)
        try await until { await voice.count == 2 }
        clock = 3.6
        await voice.yield(1, seconds: 0.6)
        await voice.finish(1)
        try await until { playback.scheduled.count == 2 }
        #expect(reached == [0], "audio waiting at the player is not a sentence the listener has begun")
        playback.play(0..<1)
        #expect(reached == [0, 1] && !finished)
        speaker.complete(response: response)
        try await settle()
        playback.play(1..<2)
        #expect(finished && reached == [0, 1])
        // A report for a reply that was stopped names nothing.
        speaker.begin(response: ConversationResponseID("next"), language: .en)
        speaker.stop()
        playback.play(0..<2)
        #expect(reached == [0, 1])
    }

    @Test func stoppingADefaultBufferedReplyDiscardsUnplayedWords() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let speaker = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        var began = false, finished = false, cancelled = false
        speaker.began = { _ in began = true }; speaker.finished = { _ in finished = true }
        speaker.cancelled = { _ in cancelled = true }
        speaker.speak("This sentence must not begin after it was stopped.", response: .init("old"), language: .en)
        try await until { await voice.count == 1 }
        clock = 9
        await voice.yield(0, seconds: 3)
        try await settle()
        #expect(playback.scheduled.isEmpty)
        speaker.stop()
        await voice.finish(0)
        try await settle()
        #expect(!began && !finished && cancelled && playback.scheduled.isEmpty)
    }

    @Test func phonePaceDoesNotReleaseHalfASentenceIntoAnEmptyPlayer() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let speaker = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        defer { speaker.stop() }
        speaker.speak("This is one complete synthetic sentence.", response: .init("slow"), language: .en)
        try await until { await voice.count == 1 }
        // The phone trace generated roughly eleven seconds of audio in thirty seconds.
        for index in 1...7 {
            clock = Double(index) * 0.9
            await voice.yield(0, seconds: 0.32)
        }
        try await settle()
        #expect(playback.scheduled.isEmpty, "an incomplete sentence must not start and repeatedly run dry")
        await voice.finish(0)
        try await until { playback.scheduled.count == 7 }
        playback.play(0..<7)
    }

    @Test func aSentenceStartsOnceItsRestWillArriveInTime() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let speaker = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        defer { speaker.stop() }
        // 52 characters: about 4.6 seconds expected. Generated 1.15 times slower than real time.
        speaker.speak("Alles klar, ich habe das Licht im Wohnzimmer gelöscht.", response: .init("near"), language: .de)
        try await until { await voice.count == 1 }
        clock = 0.368
        await voice.yield(0, seconds: 0.32)
        try await settle()
        #expect(playback.scheduled.isEmpty, "too little is ready for the rest to keep up")
        for index in 2...5 {
            clock = Double(index) * 0.368
            await voice.yield(0, seconds: 0.32)
        }
        try await until { playback.scheduled.count == 5 }
        clock += 0.368
        await voice.yield(0, seconds: 0.32)
        try await until { playback.scheduled.count == 6 }
        await voice.finish(0)
        try await settle()
        playback.play(0..<playback.scheduled.count)
        #expect(speaker.stalls == 0)
    }

    @Test func aSentenceThatRanDryWaitsAgainBeforeItGoesOn() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let speaker = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        defer { speaker.stop() }
        speaker.speak("Alles klar, ich habe das Licht im Wohnzimmer gelöscht.", response: .init("dry"), language: .de)
        try await until { await voice.count == 1 }
        for index in 1...5 {
            clock = Double(index) * 0.368
            await voice.yield(0, seconds: 0.32)
        }
        try await until { playback.scheduled.count == 5 }
        playback.play(0..<5)
        #expect(speaker.stalls == 0, "a silence counts once audio follows it")
        // Now much slower: the next chunk waits instead of playing into an empty player.
        clock += 2
        await voice.yield(0, seconds: 0.32)
        try await settle()
        #expect(playback.scheduled.count == 5)
        await voice.finish(0)
        try await until { playback.scheduled.count == 6 }
        #expect(speaker.playout.underruns == 1 && speaker.playout.underrunsInSentence == 1)
        #expect(abs(speaker.playout.gapSeconds - 2) < 0.001 && speaker.playout.lateSeconds > 1.5)
        playback.play(5..<6)
    }

    @Test func theModelIsWarmedWhenTheSpeakerIsMadeAndBeganWaitsForAudio() async throws {
        let stage = Stage()
        try await until { await stage.voice.prepared == 1 && stage.status.notice == nil }

        try await stage.speak("r1")
        try await settle()
        #expect(stage.events.isEmpty, "speaking has not begun before audio exists")

        // A chunk that arrived three times faster than it plays: start at once.
        stage.clock = 0.1
        await stage.voice.yield(0, seconds: 0.32)
        try await until { stage.events == ["began r1"] }
        #expect(stage.playback.scheduled.count == 1)
        #expect(stage.speaker.firstAudioAfter == 0.1)

        await stage.voice.yield(0, seconds: 0.32)
        try await until { stage.playback.scheduled.count == 2 }
        stage.playback.play(0..<1)
        await stage.voice.finish(0)
        try await settle()
        #expect(stage.events == ["began r1"], "not finished while a buffer is still playing")
        stage.playback.play(1..<2)
        #expect(stage.events == ["began r1", "finished r1"])
        #expect(stage.speaker.stalls == 0)
    }

    @Test func slowGenerationIsBufferedLongerBeforePlaybackStarts() async throws {
        let stage = Stage()
        try await stage.speak("r1")
        // 0.32 s of audio took 0.5 s: the player would overtake the model.
        stage.clock = 0.5
        await stage.voice.yield(0, seconds: 0.32)
        stage.clock = 1.0
        await stage.voice.yield(0, seconds: 0.32)
        try await settle()
        #expect(stage.playback.scheduled.isEmpty && stage.events.isEmpty)

        // The end of the reply releases what is waiting, however little.
        await stage.voice.finish(0)
        try await until { stage.events == ["began r1"] }
        #expect(stage.playback.scheduled.count == 2)
        stage.playback.play(0..<2)
        #expect(stage.events == ["began r1", "finished r1"])
    }

    @Test func aPlayerThatRunsDryBuffersAgainAndCountsTheStall() async throws {
        let stage = Stage()
        try await stage.speak("r1")
        stage.clock = 0.1
        await stage.voice.yield(0, seconds: 0.32)
        try await until { stage.playback.scheduled.count == 1 }
        stage.playback.play(0..<1)
        #expect(stage.speaker.stalls == 0, "a silence counts once audio follows it")
        #expect(stage.events == ["began r1"], "running dry is not the end of the reply")

        await stage.voice.yield(0, seconds: 0.4)
        try await settle()
        #expect(stage.playback.scheduled.count == 1, "it waits for a second of audio before going on")
        await stage.voice.yield(0, seconds: 0.7)
        try await until { stage.playback.scheduled.count == 3 }
        #expect(stage.speaker.stalls == 1 && stage.speaker.playout.underrunsInSentence == 1)
        await stage.voice.finish(0)
        try await settle()
        stage.playback.play(1..<3)
        #expect(stage.events == ["began r1", "finished r1"])
    }

    @Test func stopCancelsAtOnceAndNothingLateIsReported() async throws {
        let stage = Stage()
        try await stage.speak("r1")
        stage.clock = 0.1
        await stage.voice.yield(0, seconds: 0.32)
        try await until { stage.playback.scheduled.count == 1 }

        stage.speaker.stop()
        #expect(stage.events == ["began r1", "cancelled r1"])
        #expect(stage.playback.stops == 1)
        try await until { await stage.voice.ended == 1 }

        // Audio and player callbacks that were already on their way.
        await stage.voice.yield(0, seconds: 0.32)
        await stage.voice.finish(0)
        stage.playback.play(0..<1)
        try await settle()
        #expect(stage.events == ["began r1", "cancelled r1"])
        #expect(stage.playback.scheduled.count == 1)

        // A second stop has nothing to cancel.
        stage.speaker.stop()
        #expect(stage.events.count == 2)
    }

    @Test func aNewReplyReplacesTheOldOneAndIgnoresItsCallbacks() async throws {
        let stage = Stage()
        try await stage.speak("r1")
        stage.clock = 0.1
        await stage.voice.yield(0, seconds: 0.32)
        try await until { stage.playback.scheduled.count == 1 }

        try await stage.speak("r2")
        #expect(stage.events == ["began r1", "cancelled r1"])
        stage.playback.play(0..<1)
        await stage.voice.yield(0, seconds: 0.32)
        try await settle()
        #expect(stage.events == ["began r1", "cancelled r1"])

        stage.clock = 0.2
        await stage.voice.yield(1, seconds: 0.32)
        try await until { stage.playback.scheduled.count == 2 }
        await stage.voice.finish(1)
        try await settle()
        // The old reply's buffer reporting again must not finish the new one.
        stage.playback.play(0..<1)
        #expect(stage.events == ["began r1", "cancelled r1", "began r2"])
        stage.playback.play(1..<2)
        #expect(stage.events.last == "finished r2")
    }

    @Test func aVoiceThatIsNotReadySaysWhyAndSpeaksNothing() async throws {
        let stage = Stage(refusal: LocalVoiceUnavailable(message: "The local voice model is not downloaded."))
        try await until { stage.status.notice?.hasPrefix("The local voice model is not downloaded.") == true }
        #expect(stage.status.notice == "The local voice model is not downloaded. Replies are shown as text.")

        stage.speaker.speak("synthetic reply", response: ConversationResponseID("r1"), language: .de)
        try await until { !stage.events.isEmpty }
        #expect(stage.events == ["cancelled r1"])
        #expect(stage.playback.scheduled.isEmpty)
        #expect(stage.status.notice?.hasPrefix("The local voice model is not downloaded.") == true)
    }

    @Test func failureAwareConsumersReceiveFailureWithoutLosingIntentionalCancellation() async throws {
        struct Broken: Error {}
        let stage = Stage()
        defer { stage.speaker.retire() }
        stage.speaker.failed = { stage.events.append("failed \($0.rawValue)") }
        try await stage.speak("r1")
        await stage.voice.finish(0, throwing: Broken())
        try await until { stage.events == ["failed r1"] }
        #expect(stage.status.notice?.hasSuffix("Replies are shown as text.") == true)
        try await stage.speak("r2")
        stage.speaker.stop()
        #expect(stage.events == ["failed r1", "cancelled r2"])
    }

    @Test func aFailureInTheMiddleEndsTheReplyWithANotice() async throws {
        struct Broken: Error {}
        let stage = Stage()
        try await stage.speak("r1")
        stage.clock = 0.1
        await stage.voice.yield(0, seconds: 0.32)
        try await until { stage.events == ["began r1"] }
        await stage.voice.finish(0, throwing: Broken())
        try await until { stage.events.count == 2 }
        #expect(stage.events == ["began r1", "cancelled r1"])
        #expect(stage.playback.stops == 1)
        #expect(stage.status.notice?.hasSuffix("Replies are shown as text.") == true)

        // A reply without any audio is a failure too, not a silent success.
        try await stage.speak("r2")
        await stage.voice.finish(1)
        try await until { stage.events.count == 3 }
        #expect(stage.events.last == "cancelled r2")
    }

    @Test func aPlayerThatRefusesIsAFailureNotASilentReply() async throws {
        let stage = Stage()
        stage.playback.refuses = true
        try await stage.speak("r1")
        stage.clock = 0.1
        await stage.voice.yield(0, seconds: 0.32)
        try await until { !stage.events.isEmpty }
        #expect(stage.events == ["cancelled r1"])
        #expect(stage.status.notice == "No output. Replies are shown as text.")
    }
}

/// A player on the test's clock. It plays what it is given in simulated time, reports each
/// buffer `lag` seconds after its last sample, and notes every silence that audio followed:
/// what a listener would have heard as a gap. Nothing is played and no audio engine exists.
@MainActor private final class ClockedPlayback: LocalVoicePlayback {
    struct Gap: Equatable { var at: Double, seconds: Double, buffer: Int }
    private var queue: [(ends: Double, played: @MainActor @Sendable () -> Void)] = []
    /// When the audio handed over so far has played.
    private(set) var end = 0.0
    private(set) var firstAudioAt: Double?
    private(set) var gaps: [Gap] = []
    private(set) var buffers = 0
    var lag = 0.0
    var clock = 0.0

    func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws {
        if firstAudioAt == nil {
            firstAudioAt = clock
            end = clock
        } else if end < clock - 1e-9 {
            gaps.append(Gap(at: end, seconds: clock - end, buffer: buffers))
            end = clock
        }
        end += Double(samples.count) / sampleRate
        buffers += 1
        queue.append((end, played))
    }

    func stop() { queue = [] }

    /// Moves the clock on and delivers the callbacks that fall due, each at its own time.
    func advance(to time: Double) {
        while let first = queue.first, first.ends + lag <= time + 1e-9 {
            queue.removeFirst()
            clock = max(clock, first.ends + lag)
            first.played()
        }
        clock = max(clock, time)
    }
}

/// How a synthetic generator delivers one sentence: 80 ms frames, the first after `startup`,
/// then one every `interval` seconds, single frames later by `late`, and `tail` seconds
/// between its last frame and the end of its stream.
private struct SentenceCadence {
    var text: String
    var frames: Int
    var startup = 0.35
    var interval = 0.086
    var late: [Int: Double] = [:]
    var tail = 0.2
}

/// The real `LocalVoiceSpeaker` fed by a scripted generator and a clocked player. The same
/// cadence gives the same result every time; it is synthetic, not a phone's trace.
@MainActor private func playout(_ sentences: [SentenceCadence], callbackLag: Double = 0) async throws
    -> (speaker: LocalVoiceSpeaker, player: ClockedPlayback, events: [String])
{
    let voice = VoiceDouble(), player = ClockedPlayback()
    player.lag = callbackLag
    let speaker = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
        synthesizer: voice, playback: player, status: LocalVoice(), now: { [unowned player] in player.clock })
    var events: [String] = []
    speaker.began = { _ in events.append("began") }
    speaker.finished = { _ in events.append("finished") }
    speaker.cancelled = { _ in events.append("cancelled") }
    let response = ConversationResponseID("cadence")
    speaker.begin(response: response, language: .de)
    for sentence in sentences { speaker.append(sentence.text, response: response) }
    speaker.complete(response: response)
    var time = 0.0, received = 0.0
    for (index, sentence) in sentences.enumerated() {
        try await until { await voice.count == index + 1 }
        time += sentence.startup
        for frame in 0..<sentence.frames {
            time += (frame == 0 ? 0 : sentence.interval) + (sentence.late[frame] ?? 0)
            player.advance(to: time)
            await voice.yield(index, seconds: 0.08)
            received += 0.08
            try await until { abs(speaker.playout.receivedSeconds - received) < 0.001 || events.contains("cancelled") }
        }
        time += sentence.tail
        player.advance(to: time)
        await voice.finish(index)
        if index + 1 < sentences.count { try await until { await voice.count == index + 2 } }
    }
    try await until { speaker.playout.generationEnded || events.contains("cancelled") }
    player.advance(to: player.end + callbackLag + 0.01)
    return (speaker, player, events)
}

@MainActor @Suite struct VoicePlayoutTests {
    private static let opener = SentenceCadence(text: "Alles klar.", frames: 7, interval: 0.042)
    private static let sentence = SentenceCadence(text: "Ich habe das Licht im Wohnzimmer jetzt gelöscht.", frames: 36)

    private func summary(_ name: String, _ speaker: LocalVoiceSpeaker, _ player: ClockedPlayback) {
        let gaps = player.gaps.map { String(format: "%.3f s before buffer %d", $0.seconds, $0.buffer) }
        print(String(format: "PLAYOUT %@: first audio %.3f s, end %.3f s, counted %d (%d in a sentence), tail %.3f s, late %.3f s",
                     name, player.firstAudioAt ?? -1, player.end, speaker.playout.underruns,
                     speaker.playout.underrunsInSentence, speaker.playout.tailSeconds, speaker.playout.lateSeconds)
            + ", silences \(gaps)")
    }

    /// A short first sentence, then one generated 7.5 % slower than it plays, each with
    /// 0.35 s before its first frame. The wait for the first frame used to count as pace:
    /// the second sentence then waited for 1.5 s of audio it did not need, and the player
    /// was silent for 1.494 s after the first one. The generator stays slower than the
    /// player, so a pause remains; it is the lead the sentence needs and no more.
    @Test func aSentenceAfterAShortOneWaitsOnlyForTheLeadItNeeds() async throws {
        let (speaker, player, events) = try await playout([Self.opener, Self.sentence])
        summary("opener and sentence", speaker, player)
        #expect(events == ["began", "finished"])
        #expect(abs((player.firstAudioAt ?? 0) - 0.56) < 0.001, "the first sentence is heard as early as before")
        let gap = try #require(player.gaps.first)
        #expect(player.gaps.count == 1 && gap.buffer == 7, "one pause, between the two sentences")
        #expect(gap.seconds < 1.0)
        #expect(speaker.playout.underruns == 1 && speaker.playout.underrunsInSentence == 0)
        #expect(abs(speaker.playout.gapSeconds - gap.seconds) < 0.001)
    }

    /// Three long sentences at 1.05 times real time, each with one frame 0.6 s late. No
    /// sentence is cut by it, and the lateness seen in the first one is allowed for after.
    @Test func aLateFrameDoesNotCutTheSentenceItIsIn() async throws {
        var long = SentenceCadence(text: "Morgen wird es in Zürich zuerst sonnig, am Nachmittag ziehen dann Wolken auf.", frames: 60, interval: 0.084)
        long.late = [30: 0.6]
        let (speaker, player, events) = try await playout([long, long, long])
        summary("late frames", speaker, player)
        #expect(events == ["began", "finished"])
        #expect(player.gaps.map(\.buffer) == [60, 120], "silences fall between sentences only")
        #expect(speaker.playout.underruns == 2 && speaker.playout.underrunsInSentence == 0)
        #expect(abs(speaker.playout.lateSeconds - 0.6) < 0.001)
    }

    /// The model goes on for a while after its last audio. The player has played everything
    /// by then; that used to be counted as a stall although nothing followed it.
    @Test func theEndOfGenerationAfterTheLastAudioIsNotAStall() async throws {
        var short = SentenceCadence(text: "Gern.", frames: 8, interval: 0.04)
        short.tail = 0.9
        let (speaker, player, events) = try await playout([short])
        summary("tail", speaker, player)
        #expect(events == ["began", "finished"])
        #expect(player.gaps.isEmpty && speaker.stalls == 0)
        #expect(speaker.playout.tailSeconds > 0.3)
    }

    /// The player's callbacks come after the sound. Audio whose callback is late has been
    /// played all the same and cannot cover the next sentence.
    @Test func audioAlreadyPlayedDoesNotCoverTheNextSentenceWhileItsCallbackIsLate() async throws {
        let voice = VoiceDouble(), playback = PlaybackDouble()
        var clock = 0.0
        let speaker = LocalVoiceSpeaker(model: TalkBack.defaultModel, voice: TalkBack.defaultVoice,
            synthesizer: voice, playback: playback, status: LocalVoice(), now: { clock })
        let response = ConversationResponseID("late callbacks")
        defer { speaker.stop() }
        speaker.begin(response: response, language: .de)
        speaker.append("Alles klar.", response: response)
        speaker.append("Alles klar, ich habe das Licht im Wohnzimmer gelöscht.", response: response)
        speaker.complete(response: response)
        try await until { await voice.count == 1 }
        await voice.yield(0, seconds: 1)
        clock = 1.5
        await voice.finish(0)
        try await until { await voice.count == 2 && playback.scheduled.count == 1 }
        // That second of audio plays until 2.5 by the clock, and no callback comes for it.
        for index in 1...3 {
            clock = 1.5 + Double(index) * 0.368
            await voice.yield(1, seconds: 0.32)
            try await until { abs(speaker.playout.receivedSeconds - 1 - Double(index) * 0.32) < 0.001 }
        }
        #expect(playback.scheduled.count == 1, "a second that is gone must not stand in for a lead")
        clock += 0.368
        await voice.yield(1, seconds: 0.32)
        try await until { playback.scheduled.count == 5 }
    }
}

@Suite struct LoudnessLevelerTests {
    private func tone(_ amplitude: Float, count: Int = 7680) -> [Float] {
        (0..<count).map { amplitude * sin(Float($0) * 0.05) }
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test func aQuietVoiceIsRaisedToTheTargetAndALoudOneLowered() {
        var quiet = LoudnessLeveler()
        quiet.beginReply()
        _ = quiet.level(tone(0.05))
        #expect(abs(rms(quiet.level(tone(0.05))) - 0.09) < 0.01)

        var loud = LoudnessLeveler()
        loud.beginReply()
        _ = loud.level(tone(0.2))
        #expect(abs(rms(loud.level(tone(0.2))) - 0.09) < 0.01)
    }

    @Test func peaksAreRoundedOffBelowFullScaleAndSilenceKeepsTheGain() {
        var leveler = LoudnessLeveler()
        leveler.beginReply()
        // Mostly quiet with a burst: the gain is high when the burst arrives.
        _ = leveler.level(tone(0.02))
        let burst = leveler.level(tone(0.02, count: 2000) + tone(0.9, count: 200))
        #expect(burst.allSatisfy { abs($0) < 1 })

        let before = leveler.gain
        leveler.beginReply()
        #expect(leveler.level(Array(repeating: 0, count: 100)).allSatisfy { $0 == 0 })
        #expect(leveler.gain == before, "the gain carries into the next reply")
        #expect((0.5...4).contains(leveler.gain))
    }
}

// MARK: Probe

/// Collects what the speaker hands to playback. Without a player it lets each buffer take
/// its real duration and makes no sound; with one, the real audio engine runs muted.
@MainActor private final class ProbePlayback: LocalVoicePlayback {
    private let player: LocalVoicePlayer?
    private(set) var samples: [Float] = []
    private var endsAt = 0.0
    private var run = 0

    init(player: LocalVoicePlayer?) {
        self.player = player
        player?.volume = 0
    }

    func take() -> [Float] {
        defer { samples = [] }
        return samples
    }

    func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws {
        self.samples += samples
        if let player { return try player.schedule(samples, sampleRate: sampleRate, played: played) }
        let now = ProcessInfo.processInfo.systemUptime
        endsAt = max(now, endsAt) + Double(samples.count) / sampleRate
        let wait = endsAt - now
        let run = run
        Task {
            try? await Task.sleep(for: .seconds(wait))
            if run == self.run { played() }
        }
    }

    func stop() {
        run += 1
        endsAt = 0
        player?.stop()
    }
}

/// Measures the real path on the Mac or a phone: `TEST_RUNNER_LISTEN_TALKBACK_PROBE=1`, with
/// `TEST_RUNNER_LISTEN_TALKBACK_MODELS` (model folder) and `TEST_RUNNER_LISTEN_TALKBACK_OUT`
/// (where wavs and timings go). On a phone both may start with `~`, the app's home; naming
/// the app's own model folder there reads the downloaded model and downloads nothing. `TEST_RUNNER_LISTEN_TALKBACK_PLAYER=1` runs the real audio
/// engine at volume 0 instead of the timed stand-in. Nothing is audible either way.
@MainActor @Suite struct TalkBackProbe {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    private static let sentences: [(Language, [String])] = [
        (.de, [
            "Alles klar, ich habe das Licht im Wohnzimmer eingeschaltet.",
            "Morgen wird es in Zürich bewölkt, mit Höchstwerten um zwölf Grad und am Nachmittag etwas Regen.",
            "Kurz zusammengefasst: Der Pull Request ist bereit, aber zwei Tests schlagen noch fehl. Soll ich sie mir genauer anschauen?",
            "Hmm, da bin ich mir nicht ganz sicher. Meinst du den Termin am Dienstag oder den am Donnerstag?",
        ]),
        (.en, [
            "Sure, I've turned on the living room lights.",
            "Tomorrow in Zurich it'll be cloudy, with highs around twelve degrees and some rain in the afternoon.",
            "Quick summary: the pull request is ready, but two tests are still failing. Want me to take a closer look?",
            "Hmm, I'm not totally sure. Do you mean the meeting on Tuesday or the one on Thursday?",
        ]),
    ]

    @Test(.enabled(if: environment["LISTEN_TALKBACK_PROBE"] == "1"), .timeLimit(.minutes(60)))
    func firstAudioAndStallsInTheRealPath() async throws {
        let out = URL(fileURLWithPath: (try #require(Self.environment["LISTEN_TALKBACK_OUT"]) as NSString).expandingTildeInPath, isDirectory: true)
        try #require(Self.environment["LISTEN_TALKBACK_MODELS"] != nil, "the probe must not use the user's own model folder")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = Self.environment["LISTEN_TALKBACK_MODEL"] ?? TalkBack.defaultModel
        let rounds = Int(Self.environment["LISTEN_TALKBACK_ROUNDS"] ?? "") ?? 2

        let store = LocalVoice()
        if LocalVoice.complete(model) == nil {
            store.download(model)
            while case .downloading = store.state(model) { try await Task.sleep(for: .seconds(1)) }
        }
        try #require(store.state(model) == .ready)

        let playback = ProbePlayback(player: Self.environment["LISTEN_TALKBACK_PLAYER"] == "1" ? LocalVoicePlayer() : nil)
        let status = LocalVoice()
        var outcome: String?
        let created = ProcessInfo.processInfo.systemUptime
        let speaker = LocalVoiceSpeaker(model: model, voice: TalkBack.defaultVoice, playback: playback, status: status)
        speaker.finished = { _ in outcome = "finished" }
        speaker.cancelled = { _ in outcome = "cancelled" }

        var rows: [[String: Any]] = []
        func say(_ text: String, _ language: Language, label: String) async throws {
            outcome = nil
            let started = ProcessInfo.processInfo.systemUptime
            speaker.speak(text, response: ConversationResponseID(label), language: language)
            while outcome == nil { try await Task.sleep(for: .milliseconds(10)) }
            let samples = playback.take()
            let seconds = Double(samples.count) / 24_000
            let level = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
            let row: [String: Any] = [
                "label": label, "outcome": outcome ?? "", "first_audio_s": speaker.firstAudioAfter ?? -1,
                "stalls": speaker.stalls, "until_finished_s": ProcessInfo.processInfo.systemUptime - started,
                "audio_s": seconds, "rms": level, "peak": Double(samples.map(abs).max() ?? 0), "notice": status.notice ?? "",
            ]
            rows.append(row)
            print("PROBE", String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
            try Self.wav(samples, to: out.appending(path: label + ".wav"))
            #expect(outcome == "finished")
        }

        // Cold: the first reply is asked for while the model is still loading.
        try await say(Self.sentences[0].1[0], .de, label: "cold-de-1")
        print("PROBE cold_until_first_reply_finished_s", ProcessInfo.processInfo.systemUptime - created)
        for round in 1...rounds {
            for (language, texts) in Self.sentences {
                for (index, text) in texts.enumerated() {
                    try await say(text, language, label: "warm\(round)-\(language.rawValue)-\(index + 1)")
                }
            }
        }
        // Generation alone, without playback: seconds of work per second of audio. Above 1
        // the device cannot keep up with its own voice.
        for (index, text) in Self.sentences[0].1.enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            var count = 0
            for try await chunk in try await QwenVoice.shared.speech(text, model: model, voice: TalkBack.defaultVoice, language: .de) {
                count += chunk.samples.count
            }
            let seconds = ProcessInfo.processInfo.systemUptime - started, audio = Double(count) / 24_000
            let row: [String: Any] = ["label": "generate-de-\(index + 1)", "generation_s": seconds, "audio_s": audio,
                                      "pace": seconds / max(audio, 0.01), "retries": await QwenVoice.shared.trace?.retries ?? 0]
            rows.append(row)
            print("PROBE", String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
        }
        try JSONSerialization.data(withJSONObject: ["model": model, "player": Self.environment["LISTEN_TALKBACK_PLAYER"] == "1", "rows": rows],
            options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "timings.json"))
    }

    /// The orb and the voice share the GPU. Generation alone, while the app's orb draws at full
    /// rate, gives way (`OrbGPUShare`) or stands still, taken in turns so a phone warming up
    /// weighs on all three alike. `TEST_RUNNER_LISTEN_TALKBACK_ORB=1`, with the phone unlocked:
    /// the orb only draws while the app is in front. Its `[OrbGPU]` lines show that it did.
    @Test(.enabled(if: environment["LISTEN_TALKBACK_ORB"] == "1"), .timeLimit(.minutes(30)))
    func generationPaceWithTheOrbAtEachRate() async throws {
        try #require(Self.environment["LISTEN_TALKBACK_MODELS"] != nil, "the probe must not use the user's own model folder")
        let model = Self.environment["LISTEN_TALKBACK_MODEL"] ?? TalkBack.defaultModel
        try #require(LocalVoice.complete(model) != nil, "the model must already be downloaded")
        let rounds = Int(Self.environment["LISTEN_TALKBACK_ROUNDS"] ?? "") ?? 2
        defer { OrbGPUShare.shared.override = nil }
        try await QwenVoice.shared.prepare(model: model, voice: TalkBack.defaultVoice)
        let modes: [OrbGPUShare.Mode] = [.full, .yielding, .still]
        var rows: [[String: Any]] = []
        for round in 0..<rounds {
            for (index, text) in Self.sentences[0].1.enumerated() {
                for step in modes.indices {
                    let mode = modes[(step + index + round) % modes.count]
                    OrbGPUShare.shared.override = mode
                    try await Task.sleep(for: .milliseconds(500))
                    let started = ProcessInfo.processInfo.systemUptime
                    var count = 0
                    for try await chunk in try await QwenVoice.shared.speech(text, model: model, voice: TalkBack.defaultVoice, language: .de) {
                        count += chunk.samples.count
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime - started, audio = Double(count) / 24_000
                    let row: [String: Any] = ["orb": "\(mode)", "round": round + 1, "sentence": index + 1, "generation_s": seconds,
                                              "audio_s": audio, "pace": seconds / max(audio, 0.01),
                                              "thermal": ProcessInfo.processInfo.thermalState.rawValue]
                    rows.append(row)
                    print("PROBE", String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
                }
            }
        }
        for mode in modes {
            let paces = rows.filter { $0["orb"] as? String == "\(mode)" }.compactMap { $0["pace"] as? Double }
            print("PROBE orb=\(mode) mean_pace=\(paces.reduce(0, +) / Double(max(paces.count, 1))) n=\(paces.count)")
        }
        if let path = Self.environment["LISTEN_TALKBACK_OUT"] {
            let out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["model": model, "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appending(path: "orb-timings.json"))
        }
    }

    /// Seconds of audio decoded per step (`QwenVoice.streamingInterval`): fewer, larger steps
    /// may cost less per second of audio but delay the first sound. Generation alone, with
    /// the orb giving way as it does while a reply is generated, intervals taken in turns.
    /// `TEST_RUNNER_LISTEN_TALKBACK_INTERVALS=0.32,0.64,1.0`, with the phone unlocked.
    @Test(.enabled(if: environment["LISTEN_TALKBACK_INTERVALS"] != nil), .timeLimit(.minutes(30)))
    func generationPaceAtEachInterval() async throws {
        try #require(Self.environment["LISTEN_TALKBACK_MODELS"] != nil, "the probe must not use the user's own model folder")
        let model = Self.environment["LISTEN_TALKBACK_MODEL"] ?? TalkBack.defaultModel
        try #require(LocalVoice.complete(model) != nil, "the model must already be downloaded")
        let intervals = (Self.environment["LISTEN_TALKBACK_INTERVALS"] ?? "").split(separator: ",").compactMap { Double($0) }
        try #require(!intervals.isEmpty)
        let rounds = Int(Self.environment["LISTEN_TALKBACK_ROUNDS"] ?? "") ?? 2
        let before = QwenVoice.streamingInterval
        defer { OrbGPUShare.shared.override = nil; QwenVoice.streamingInterval = before }
        OrbGPUShare.shared.override = .yielding
        try await QwenVoice.shared.prepare(model: model, voice: TalkBack.defaultVoice)
        var rows: [[String: Any]] = []
        for round in 0..<rounds {
            for (index, text) in Self.sentences[0].1.enumerated() {
                for step in intervals.indices {
                    let interval = intervals[(step + index + round) % intervals.count]
                    QwenVoice.streamingInterval = interval
                    let started = ProcessInfo.processInfo.systemUptime
                    var first: Double?, count = 0
                    for try await chunk in try await QwenVoice.shared.speech(text, model: model, voice: TalkBack.defaultVoice, language: .de) {
                        if first == nil { first = ProcessInfo.processInfo.systemUptime - started }
                        count += chunk.samples.count
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime - started, audio = Double(count) / 24_000
                    let row: [String: Any] = ["interval": interval, "round": round + 1, "sentence": index + 1, "first_s": first ?? -1,
                                              "generation_s": seconds, "audio_s": audio, "pace": seconds / max(audio, 0.01),
                                              "thermal": ProcessInfo.processInfo.thermalState.rawValue]
                    rows.append(row)
                    print("PROBE", String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
                }
            }
        }
        for interval in intervals {
            let picked = rows.filter { $0["interval"] as? Double == interval }
            let paces = picked.compactMap { $0["pace"] as? Double }, firsts = picked.compactMap { $0["first_s"] as? Double }
            print("PROBE interval=\(interval) mean_pace=\(paces.reduce(0, +) / Double(max(paces.count, 1))) mean_first_s=\(firsts.reduce(0, +) / Double(max(firsts.count, 1))) n=\(paces.count)")
        }
    }

    private static func wav(_ samples: [Float], to file: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32767)) }
        try data.write(to: file)
    }
}

// MARK: Corpus

/// Synthetic assistant replies of four kinds, for checking what the voice actually says.
enum TalkBackCorpus {
    static let texts: [(Language, String, [String])] = [
        (.de, "word", ["Ja.", "Nein.", "Okay.", "Erledigt.", "Gerne.", "Moment.", "Alles klar.", "Verstanden."]),
        (.de, "sentence", [
            "Alles klar, ich habe das Licht im Wohnzimmer eingeschaltet.",
            "Die Heizung im Büro läuft jetzt auf zwanzig Grad.",
            "Ich habe die Notiz gespeichert und den Titel angepasst.",
            "Der Bericht ist fertig und liegt im Ordner für diese Woche.",
            "Das habe ich leider nicht verstanden, kannst du es wiederholen?",
            "Soll ich die Rollläden im Schlafzimmer auch gleich herunterlassen?",
            "Die Verbindung zum Dienst ist gerade unterbrochen.",
            "Morgen früh erinnere ich dich an den Anruf.",
        ]),
        (.de, "three", [
            "Das Licht ist an. Die Rollläden sind unten. Soll ich auch die Musik starten?",
            "Kurz zusammengefasst: Der Pull Request ist bereit, aber zwei Tests schlagen noch fehl. Soll ich sie mir genauer anschauen?",
            "Hmm, da bin ich mir nicht ganz sicher. Meinst du den Termin am Dienstag oder den am Donnerstag? Sag mir einfach, welchen du meinst.",
            "Ich habe drei Dinge gefunden. Zwei davon sind schon erledigt. Das dritte braucht noch deine Entscheidung.",
            "Der Dienst hat einen Fehler gemeldet. Ich habe nichts verändert. Möchtest du es noch einmal versuchen?",
            "Die Besprechung wurde verschoben. Der neue Raum ist im zweiten Stock. Ich habe den Eintrag im Kalender angepasst.",
            "Gute Frage. Dafür brauche ich etwas mehr Kontext. Um welches Projekt geht es genau?",
        ]),
        (.de, "numbers", [
            "Morgen wird es in Zürich bewölkt, mit Höchstwerten um zwölf Grad und am Nachmittag etwas Regen.",
            "Der Zug nach Bern fährt um 14 Uhr 32 auf Gleis 7.",
            "Dein nächster Termin ist am 3. Dezember um 9 Uhr 15 mit Frau Keller.",
            "Das macht zusammen 48 Franken und 50 Rappen.",
            "Die Messung ergab 0,38 Sekunden im Mittel und 1,4 Sekunden im schlechtesten Fall.",
            "Herr Baumann und Frau Aebischer treffen sich um halb fünf in Winterthur.",
            "Es sind noch 27 Prozent Akku, das reicht für ungefähr zwei Stunden.",
        ]),
        (.en, "word", ["Yes.", "No.", "Okay.", "Done.", "Sure.", "One moment.", "All right.", "Got it."]),
        (.en, "sentence", [
            "Sure, I've turned on the living room lights.",
            "The heating in the office is now set to twenty degrees.",
            "I saved the note and adjusted its title.",
            "The report is finished and sits in this week's folder.",
            "Sorry, I didn't catch that, could you say it again?",
            "Should I lower the bedroom blinds as well?",
            "The connection to the service is down at the moment.",
            "I'll remind you about the call tomorrow morning.",
        ]),
        (.en, "three", [
            "The light is on. The blinds are down. Should I start the music as well?",
            "Quick summary: the pull request is ready, but two tests are still failing. Want me to take a closer look?",
            "Hmm, I'm not totally sure. Do you mean the meeting on Tuesday or the one on Thursday? Just tell me which one.",
            "I found three things. Two of them are already done. The third still needs your decision.",
            "The service reported an error. I did not change anything. Would you like to try again?",
            "The meeting was moved. The new room is on the second floor. I updated the calendar entry.",
            "Good question. I need a bit more context for that. Which project is it about?",
        ]),
        (.en, "numbers", [
            "Tomorrow in Zurich it'll be cloudy, with highs around twelve degrees and some rain in the afternoon.",
            "The train to Bern leaves at 2:32 pm from platform 7.",
            "Your next appointment is on December 3rd at 9:15 with Ms. Keller.",
            "That comes to 48 francs and 50 cents in total.",
            "The measurement gave 0.38 seconds on average and 1.4 seconds in the worst case.",
            "Mr. Baumann and Ms. Fischer are meeting at half past four in Winterthur.",
            "There is 27 percent battery left, enough for about two hours.",
        ]),
    ]
}

extension TalkBackProbe {
    /// Explicit native, silent comparison. Isolated model folder; saves generated PCM and
    /// measurements without opening an audio device or recording a microphone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_NATIVE_VOICE_PROBE"] == "1"), .timeLimit(.minutes(30)))
    func nativeFemaleVoiceComparisonWithoutPlayback() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let root = try #require(env["LISTEN_TALKBACK_MODELS"])
        try #require(root.contains("/runs/"), "use an isolated review folder")
        let out = URL(fileURLWithPath: try #require(env["LISTEN_TALKBACK_OUT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = env["LISTEN_TALKBACK_MODEL"] ?? TalkBack.pocketGerman
        let voices = (env["LISTEN_TALKBACK_VOICES"] ?? (TalkBack.model(model)?.family == .pocket ? "alba,cosette,fantine,eponine" : "Serena,Vivian"))
            .split(separator: ",").map(String.init)
        try #require(voices.allSatisfy { TalkBack.voices(for: model).contains($0) })
        let store = LocalVoice()
        if LocalVoice.complete(model) == nil {
            store.download(model)
            while case .downloading = store.state(model) { try await Task.sleep(for: .milliseconds(200)) }
        }
        try #require(store.state(model) == .ready, "native model download must finish: \(store.state(model))")
        let engine = TalkBack.synthesizer(for: model)
        var texts = ["Hallo. Ich höre dir zu und erkläre dir das Schritt für Schritt.",
                     "Ein Actor schützt seinen veränderlichen Zustand. Nach einem await kann trotzdem anderer Code im Actor weiterlaufen.",
                     "Für die genaue Antwort prüfe ich gerade noch die Quellen. Zunächst können wir die beiden Möglichkeiten anhand ihrer Vor- und Nachteile vergleichen."]
        if let fixture = env["LISTEN_NATIVE_VOICE_TEXTS"] {
            try #require(fixture.contains("/runs/"), "synthetic comparison input belongs in the ignored experiment folder")
            texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
            try #require((1...5).contains(texts.count) && texts.allSatisfy { !$0.isEmpty && $0.count <= 300 })
        }
        var rows: [[String: Any]] = []
        for voice in voices {
            for (i, text) in texts.enumerated() {
                let began = ProcessInfo.processInfo.systemUptime
                var first: Double?
                var samples: [Float] = []
                var gaps: [Double] = []
                var previous = began
                for try await chunk in try await engine.speech(text, model: model, voice: voice, language: .de) {
                    let now = ProcessInfo.processInfo.systemUptime
                    first = first ?? now - began
                    if !samples.isEmpty { gaps.append(now - previous) }
                    previous = now
                    try #require(chunk.sampleRate == 24_000 && chunk.samples.allSatisfy(\.isFinite))
                    samples += chunk.samples
                }
                let generation = ProcessInfo.processInfo.systemUptime - began
                try #require(!samples.isEmpty)
                let audio = Double(samples.count) / 24_000
                var row: [String: Any] = ["model":model,"voice":voice,"sample":i,"text":text,"cold":rows.isEmpty,
                    "first_chunk_s":first ?? -1,"generation_s":generation,"audio_s":audio,
                    "real_time_factor":generation / audio,"max_chunk_gap_s":gaps.max() ?? 0,
                    "peak":samples.map(abs).max() ?? 0]
                if i == 0 {
                    // Include the production buffering/leveling path, with a timed silent
                    // player. This is scheduling, not an acoustic hardware measurement.
                    try await engine.prepare(model: model, voice: voice)
                    let playback = ProbePlayback(player: nil)
                    let speaker = LocalVoiceSpeaker(model: model, voice: voice, synthesizer: engine,
                                                   playback: playback, status: LocalVoice())
                    var ended = false
                    speaker.finished = { _ in ended = true }
                    speaker.cancelled = { _ in ended = true }
                    speaker.speak(text, response: .init("native-\(voice)"), language: .de)
                    let deadline = ProcessInfo.processInfo.systemUptime + 30
                    while !ended && ProcessInfo.processInfo.systemUptime < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try #require(ended && speaker.firstAudioAfter != nil)
                    row["warm_player_first_schedule_s"] = speaker.firstAudioAfter
                    row["player_stalls"] = speaker.stalls
                    speaker.retire()
                }
                rows.append(row)
                try Self.wav(samples, to: out.appending(path: "\(voice)-\(i).wav"))
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys])
                    .write(to: out.appending(path: "native-timings.json"))
                print("NATIVE_VOICE", String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
            }
        }
    }

    /// Speaks the corpus through the speaker with a player that takes no time, and saves each
    /// reply with what the engine reported. `TEST_RUNNER_LISTEN_TALKBACK_CORPUS=1`, plus
    /// `..._MODELS`, `..._OUT`, and optionally `..._MODEL` and `..._ROUNDS` (default 2).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_TALKBACK_CORPUS"] == "1"), .timeLimit(.minutes(60)))
    func whatTheVoiceSays() async throws {
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(environment["LISTEN_TALKBACK_OUT"]), isDirectory: true)
        try #require(environment["LISTEN_TALKBACK_MODELS"] != nil)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = environment["LISTEN_TALKBACK_MODEL"] ?? TalkBack.defaultModel
        let rounds = Int(environment["LISTEN_TALKBACK_ROUNDS"] ?? "") ?? 2
        let store = LocalVoice()
        if LocalVoice.complete(model) == nil {
            store.download(model)
            while case .downloading = store.state(model) { try await Task.sleep(for: .seconds(1)) }
        }
        try #require(store.state(model) == .ready)

        let playback = InstantPlayback()
        let status = LocalVoice()
        var outcome: String?
        let speaker = LocalVoiceSpeaker(model: model, voice: TalkBack.defaultVoice, playback: playback, status: status)
        speaker.finished = { _ in outcome = "finished" }
        speaker.cancelled = { _ in outcome = "cancelled" }

        var rows: [[String: Any]] = []
        var number = 0
        // `..._TEXTS` names a file with one "de|text" or "en|text" per line, to speak instead.
        var corpus = TalkBackCorpus.texts
        if let file = environment["LISTEN_TALKBACK_TEXTS"] {
            corpus = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n").enumerated().map { index, line in
                let parts = line.split(separator: "|", maxSplits: 1)
                return (parts[0] == "en" ? .en : .de, "extra\(index + 1)", [String(parts[1])])
            }
        }
        for round in 1...rounds {
            for (language, kind, texts) in corpus {
                for (index, text) in texts.enumerated() {
                    number += 1
                    let label = String(format: "r%d-%@-%@-%02d", round, language.rawValue, kind, index + 1)
                    outcome = nil
                    await QwenVoice.shared.seedNext(UInt64(1000 * round + number))
                    let started = ProcessInfo.processInfo.systemUptime
                    speaker.speak(text, response: ConversationResponseID(label), language: language)
                    while outcome == nil { try await Task.sleep(for: .milliseconds(5)) }
                    let samples = playback.take()
                    let trace = await QwenVoice.shared.trace
                    rows.append([
                        "label": label, "language": language.rawValue, "kind": kind, "text": text, "outcome": outcome ?? "",
                        "audio_s": Double(samples.count) / 24_000, "tokens": (trace?.samples ?? 0) / 1920,
                        "reached_limit": (trace?.cut ?? 0) > 0, "segments": trace?.segments ?? 0,
                        "retries": trace?.retries ?? 0, "first_audio_s": speaker.firstAudioAfter ?? -1,
                        "generation_s": ProcessInfo.processInfo.systemUptime - started, "notice": status.notice ?? "",
                    ])
                    try Self.wav(samples, to: out.appending(path: label + ".wav"))
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["model": model, "rows": rows], options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appending(path: "corpus.json"))
    }
}

/// Every buffer counts as played at once. For content runs, where pace does not matter.
@MainActor private final class InstantPlayback: LocalVoicePlayback {
    private var samples: [Float] = []

    func take() -> [Float] {
        defer { samples = [] }
        return samples
    }

    func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws {
        self.samples += samples
        Task { played() }
    }

    func stop() {}
}

// MARK: Spoken text

@Suite struct SpokenReplyTests {
    /// Text, language, what the voice is given.
    private static let spelling: [(String, Language, String)] = [
        // Years
        ("Das war 1998.", .de, "Das war neunzehnhundertachtundneunzig."),
        ("Seit 1291 gibt es das.", .de, "Seit zwölfhunderteinundneunzig gibt es das."),
        ("Im Jahr 2026 kommt es.", .de, "Im Jahr zweitausendsechsundzwanzig kommt es."),
        ("It was built in 1998.", .en, "It was built in nineteen ninety-eight."),
        ("Since 1905 and until 1900.", .en, "Since nineteen oh five and until nineteen hundred."),
        ("In 2005 and in 2026.", .en, "In two thousand five and in twenty twenty-six."),
        ("We have 2048 items here.", .en, "We have two thousand forty-eight items here."),
        ("Es sind 1500 Stück im Lager.", .de, "Es sind eintausendfünfhundert Stück im Lager."),
        // Dates in digits
        ("Abgabe am 2026-11-21.", .de, "Abgabe am einundzwanzigsten November zweitausendsechsundzwanzig."),
        ("Due on 2026-11-21.", .en, "Due on November twenty-first, twenty twenty-six."),
        ("Am 21.11.2026 ist es so weit.", .de, "Am einundzwanzigsten November zweitausendsechsundzwanzig ist es so weit."),
        // Money
        ("Das kostet CHF 12.50.", .de, "Das kostet zwölf Franken fünfzig."),
        ("Nur €3,20 pro Stück.", .de, "Nur drei Euro zwanzig pro Stück."),
        ("It costs $4.99 today.", .en, "It costs four dollars ninety-nine today."),
        ("Das macht 12 Fr.", .de, "Das macht zwölf Franken."),
        ("Das macht 12 Fr. pro Tag.", .de, "Das macht zwölf Franken pro Tag."),
        ("Zusammen 1'250.00 CHF.", .de, "Zusammen eintausendzweihundertfünfzig Franken."),
        ("Noch 0,50 € offen.", .de, "Noch fünfzig Cent offen."),
        ("Fr. 20.– bitte.", .de, "zwanzig Franken bitte."),
        ("That is 1 USD or 3 EUR.", .en, "That is one dollar or three euros."),
        ("About 1,250 dollars, so $1 each.", .en, "About one thousand two hundred fifty dollars, so one dollar each."),
        // Ranges
        ("Das dauert 3–5 Tage.", .de, "Das dauert drei bis fünf Tage."),
        ("Geöffnet 10-12 Uhr.", .de, "Geöffnet zehn bis zwölf Uhr."),
        ("See pages 3-5.", .en, "See pages three to five."),
        ("Open 9:00–17:00.", .en, "Open nine to seventeen."),
        ("Es sind -5 Grad.", .de, "Es sind minus fünf Grad."),
        ("It dropped to -12 from 3.", .en, "It dropped to minus twelve from three."),
        // Phone numbers and long digit groups
        ("Ruf +41 79 123 45 67 an.", .de, "Ruf plus vier eins, sieben neun, eins zwei drei, vier fünf, sechs sieben an."),
        ("Call 044 123 45 67.", .en, "Call zero four four, one two three, four five, six seven."),
        ("Die Nummer ist 12345678901234567890.", .de,
         "Die Nummer ist eins zwei drei vier fünf sechs sieben acht neun null eins zwei drei vier fünf sechs sieben acht neun null."),
        ("Code 007.", .en, "Code zero zero seven."),
        // German days of the month
        ("3. Dezember passt.", .de, "dritter Dezember passt."),
        ("Der 3. Dezember passt.", .de, "Der dritte Dezember passt."),
        ("Vom 1. Mai bis zum 31. Mai.", .de, "Vom ersten Mai bis zum einunddreißigsten Mai."),
        // German "1"
        ("Das dauert 1 Stunde.", .de, "Das dauert eine Stunde."),
        ("Noch 1 Tag und 1 Minute.", .de, "Noch ein Tag und eine Minute."),
        ("Um 1 Uhr auf Gleis 1.", .de, "Um ein Uhr auf Gleis eins."),
        ("Es bleibt 1% übrig.", .de, "Es bleibt ein Prozent übrig."),
        // Unchanged, and forms handled before
        ("Installiert ist v1.2.3.", .de, "Installiert ist v1.2.3."),
        ("Version 2.10.4 or v2 is fine.", .en, "Version 2.10.4 or v2 is fine."),
        ("Nichts zu ändern.", .de, "Nichts zu ändern."),
        ("Der Zug fährt um 14 Uhr 32 auf Gleis 7.", .de, "Der Zug fährt um vierzehn Uhr zweiunddreißig auf Gleis sieben."),
        ("At 2:32 pm from platform 7, or at 9:05.", .en, "At two thirty-two pm from platform seven, or at nine oh five."),
        ("0,38 Sekunden, 27% Akku, 48 Franken.", .de, "null Komma drei acht Sekunden, siebenundzwanzig Prozent Akku, achtundvierzig Franken."),
        ("On December 3rd it took 0.38 seconds, 27% less.", .en, "On December third it took zero point three eight seconds, twenty-seven percent less."),
    ]

    @Test func numbersAreWrittenOutInTheReplysLanguage() {
        #expect(Self.spelling.count >= 30)
        for (text, language, spoken) in Self.spelling {
            #expect(SpokenReply.spelledOut(text, language: language) == spoken, "\(text)")
        }
    }

    @Test func aNumberOfAnyLengthIsReadAndNeverBecomesZero() {
        let long = String(repeating: "9", count: 40)
        #expect(SpokenReply.spelledOut(long, language: .en) == Array(repeating: "nine", count: 40).joined(separator: " "))
        #expect(!SpokenReply.spelledOut("CHF " + long, language: .de).contains("null"))
    }

    @Test func aReplyIsCutIntoSentencesAndShortOnesJoinANeighbour() {
        let three = SpokenReply.segments(
            "Gute Frage. Dafür brauche ich etwas mehr Kontext. Um welches Projekt geht es genau?", language: .de)
        #expect(three.map(\.text) == ["Gute Frage. Dafür brauche ich etwas mehr Kontext.", "Um welches Projekt geht es genau?"])

        // A short last sentence joins the one before; a title is not a sentence end.
        let last = SpokenReply.segments(
            "I moved the appointment with Dr. Keller to the afternoon as you asked. Is that fine?", language: .en)
        #expect(last.count == 1)

        let long = SpokenReply.segments(
            "Kurz zusammengefasst: Der Pull Request ist bereit, aber zwei Tests schlagen noch fehl, und ausserdem "
                + "fehlt noch die Freigabe der zweiten Person, die erst am Montag wieder im Büro ist.", language: .de)
        #expect(long.count == 2)
        #expect(long.allSatisfy { $0.text.count <= SpokenReply.longest })
        #expect(long.map(\.text).joined(separator: " ").hasPrefix("Kurz zusammengefasst: Der Pull Request"))

        #expect(SpokenReply.segments("  ", language: .de).isEmpty)
    }

    @Test func onlyAFirstSegmentOfSomeLengthIsStreamedAndLimitsFollowTheLength() {
        let short = SpokenReply.segments("Ja.", language: .de)
        #expect(short.count == 1 && !short[0].streamed, "a one-word reply is checked before it plays")
        let reply = SpokenReply.segments(
            "Alles klar, ich habe das Licht im Wohnzimmer eingeschaltet. Soll ich auch die Musik im Wohnzimmer starten?",
            language: .de)
        #expect(reply.map(\.streamed) == [true, false])
        #expect(short[0].limit < reply[1].limit && reply[1].limit < reply[0].limit)
        // About two seconds for one word, far below the six the model would otherwise take.
        #expect(short[0].limit <= 30)
    }
}

/// Generations scripted per call: the audio pieces and whether the run hit its limit.
private final class GenerationScript: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [(pieces: Int, reachedLimit: Bool, hangs: Bool)]
    private var _calls: [(text: String, limit: Int)] = []
    private var _clock = 0.0
    /// Seconds one piece of audio takes to generate. A piece is one second long.
    var secondsPerPiece = 0.1

    init(_ plans: [(pieces: Int, reachedLimit: Bool, hangs: Bool)]) { self.plans = plans }

    var calls: [(text: String, limit: Int)] { lock.withLock { _calls } }
    var clock: Double { lock.withLock { _clock } }

    func generate(_ text: String, _ limit: Int) -> AsyncThrowingStream<SpokenVoice.Piece, any Error> {
        let (index, plan): (Int, (pieces: Int, reachedLimit: Bool, hangs: Bool)) = lock.withLock {
            _calls.append((text, limit))
            return (_calls.count, plans.isEmpty ? (pieces: 1, reachedLimit: false, hangs: false) : plans.removeFirst())
        }
        return AsyncThrowingStream { continuation in
            for piece in 0..<plan.pieces {
                self.lock.withLock { self._clock += self.secondsPerPiece }
                continuation.yield(.audio(Array(repeating: Float(index), count: 10 + piece)))
            }
            guard !plan.hangs else { return }
            continuation.yield(.ended(reachedLimit: plan.reachedLimit))
            continuation.finish()
        }
    }
}

@Suite struct SpokenVoiceTests {
    private let streamedFirst = [
        SpokenSegment(text: "one", limit: 50, streamed: true), SpokenSegment(text: "two", limit: 40, streamed: false),
    ]

    /// Runs the segments and returns the first sample of every piece handed on: the number of
    /// the generation it came from.
    private func run(_ segments: [SpokenSegment], _ script: GenerationScript) async throws -> (SpokenVoice.Outcome, [Int]) {
        let heard = Heard()
        let outcome = try await SpokenVoice.run(
            segments, sampleRate: 10, generate: script.generate, now: { script.clock }, yield: { heard.add(Int($0[0])) })
        return (outcome, heard.values)
    }

    @Test func aSegmentThatRanIntoItsLimitIsMadeAgainAndOnlyTheGoodAttemptIsHeard() async throws {
        let script = GenerationScript([(2, false, false), (3, true, false), (2, false, false)])
        let (outcome, heard) = try await run(streamedFirst, script)
        #expect(heard == [1, 1, 3, 3], "nothing of the second generation is handed on")
        #expect(outcome == .init(segments: 2, retries: 1, cut: 0, samples: 42))
        #expect(script.calls.map(\.text) == ["one", "two", "two"])
        #expect(script.calls.map(\.limit) == [50, 40, 40])
    }

    @Test func afterThreeAttemptsTheLastIsUsedAndCounted() async throws {
        let script = GenerationScript([(1, false, false), (1, true, false), (1, true, false), (1, true, false)])
        let (outcome, heard) = try await run(streamedFirst, script)
        #expect(heard == [1, 4])
        #expect(outcome.retries == 2 && outcome.cut == 1)
    }

    @Test func aStreamedFirstSegmentIsNeverRepeatedAndAShortOneIsCheckedFirst() async throws {
        // Streamed: it was heard, so running into the limit only cuts it.
        var script = GenerationScript([(2, true, false), (1, false, false)])
        var (outcome, heard) = try await run(streamedFirst, script)
        #expect(heard == [1, 1, 2] && outcome.retries == 0 && outcome.cut == 1)

        // Not streamed: a failed first attempt is thrown away unheard.
        script = GenerationScript([(4, true, false), (1, false, false)])
        (outcome, heard) = try await run([SpokenSegment(text: "yes", limit: 20, streamed: false)], script)
        #expect(heard == [2] && outcome.retries == 1 && outcome.cut == 0)
    }

    @Test func aSegmentThatCannotBeReadyInTimeIsStreamedUnchecked() async throws {
        // One second of audio takes one second: no lead over playback.
        var script = GenerationScript([(2, false, false), (2, true, false)])
        script.secondsPerPiece = 1
        var (outcome, heard) = try await run(streamedFirst, script)
        #expect(heard == [1, 1, 2, 2])
        #expect(outcome.retries == 0 && outcome.cut == 1)
        #expect(script.calls.count == 2)

        // A fast model, but a long sentence after a short one: its generation would outlast
        // the audio that is still playing.
        script = GenerationScript([(1, false, false), (2, true, false)])
        let long = [streamedFirst[0], SpokenSegment(text: "a much longer sentence", limit: 400, streamed: false)]
        (outcome, heard) = try await run(long, script)
        #expect(heard == [1, 2, 2] && outcome.retries == 0 && outcome.cut == 1)
    }

    @Test func stoppingDuringTheLookAheadHandsOnNothingOfIt() async throws {
        let script = GenerationScript([(2, false, false), (3, false, true)])
        let heard = Heard()
        let segments = streamedFirst
        let task = Task {
            try await SpokenVoice.run(
                segments, sampleRate: 10, generate: script.generate, now: { script.clock }, yield: { heard.add(Int($0[0])) })
        }
        for _ in 0..<400 where script.calls.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(heard.values == [1, 1])
    }
}

private actor VoiceLoadProbe {
    var events: [String] = []
    private var finish: CheckedContinuation<Void, Never>?
    func initialize() async {
        events.append("loading old voice")
        // A non-cooperative SDK load does not finish merely because its caller cancels.
        await withCheckedContinuation { finish = $0 }
        events.append("old initializer exited")
    }
    func release() { finish?.resume(); finish = nil }
    func next() { events.append("loading next voice") }
}

@Suite struct VoicePreparationTests {
    @Test func aVoiceSwitchWaitsForCancelledSDKInitializationToActuallyExit() async throws {
        let gate = VoicePreparationGate(), probe = VoiceLoadProbe()
        let old = Task { try await gate.run { await probe.initialize() } }
        for _ in 0..<1000 {
            if !(await probe.events).isEmpty { break }
            await Task.yield()
        }
        #expect(await probe.events == ["loading old voice"])
        old.cancel()
        let next = Task { try await gate.run { await probe.next() } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.events == ["loading old voice"], "The next model cannot allocate during cancelled SDK work")
        await probe.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        try await next.value
        #expect(await probe.events == ["loading old voice", "old initializer exited", "loading next voice"])
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
@Suite struct PhoneVoiceMemoryProbe {
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_QWEN_MEMORY_PROBE"] == "1"))
    func boundedQwenPreparationAndReleaseWithoutMicrophoneOrPlayback() async throws {
        #expect(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let model = TalkBack.defaultModel
        try #require(LocalVoice.complete(model) != nil, "Existing local Qwen files are required; never downloaded by this probe")
        let before = footprint()
        let sampler = Task {
            var peak = footprint()
            while !Task.isCancelled {
                peak = max(peak, footprint())
                try? await Task.sleep(for: .milliseconds(50))
            }
            return peak
        }
        do {
            try await TalkBack.synthesizer(for: model).prepare(model: model, voice: "Serena")
        } catch { sampler.cancel(); _ = await sampler.value; throw error }
        sampler.cancel()
        let peak = await sampler.value
        try await VoicePreparationGate.shared.run { await TalkBack.releaseUnused(except: TalkBack.supertonic) }
        let after = footprint()
        let fields: [String: Any] = ["before_bytes": before, "peak_bytes": peak, "after_release_bytes": after,
            "physical_audio": false, "qwen_prepared": true, "released_before_next_family": true]
        try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
            .write(to: URL.cachesDirectory.appending(path: "voice-memory-probe.json"), options: .atomic)
        #expect(before > 0 && peak > 0)
        #expect(peak < 3_000_000_000, "Stay below the observed3.60GB process kill")
    }
}
#endif

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] { lock.withLock { _values } }
    func add(_ value: Int) { lock.withLock { _values.append(value) } }
}
