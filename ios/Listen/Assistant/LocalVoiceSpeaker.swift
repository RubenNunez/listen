import AVFoundation

struct LocalVoiceChunk: Sendable {
    var samples: [Float]
    var sampleRate: Double
}

/// The local voice cannot speak, and why. The message is shown as it is.
struct LocalVoiceUnavailable: Error, Equatable {
    let message: String
}

/// Turns text into streamed speech. `QwenVoice` is the real one.
protocol LocalVoiceSynthesizing: Sendable {
    /// Loads the model and runs it once, so the first reply does not pay for it.
    func prepare(model: String, voice: String) async throws
    func speech(_ text: String, model: String, voice: String, language: Language) async throws
        -> AsyncThrowingStream<LocalVoiceChunk, Error>
}

/// Plays buffers in the order given. `played` is called when a buffer has been played out;
/// after `stop` it may still be called for dropped buffers.
@MainActor protocol LocalVoicePlayback: AnyObject {
    func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws
    func stop()
    func retire()
}

extension LocalVoicePlayback { func retire() { stop() } }

/// Speaks replies with a model on this device: generated chunks are levelled and streamed
/// into a player.
///
/// - `began` fires when the first buffer goes to the player, `finished` when the last one
///   was played out, `cancelled` on `stop()`. Failures have their own callback when
///   the consumer supports it; legacy consumers receive `cancelled` for failures too.
/// - Every reply has a token. A chunk or player callback that carries an older token does
///   nothing, so a stopped reply stays silent and reports nothing.
/// - By default a sentence plays once the rest of it will be generated in time
///   (`startsEarly`); on a device slower than twice real time, only once it is complete.
///   The next sentence can generate while the previous one plays. This avoids gaps inside
///   words on a slower device without waiting for whole sentences on a faster one.
/// - A generator slower than real time cannot keep the player fed across sentences. Buffer
///   estimates and unexpected slow frames can also leave gaps inside a part. `Playout` says
///   which silences a reply had; the end of generation after the last audio is not one.
/// - While a reply is generated the orb draws less (`OrbGPUShare`): both use the GPU.
/// - There is no other voice behind this one. If it cannot speak, the reason is in
///   `LocalVoice.notice` and the reply stays on screen as text.
@MainActor final class LocalVoiceSpeaker: AssistantSentenceSpeechOutput, AssistantPlaybackReporting, AssistantSpeechFailureReporting {
    enum Buffering { case sentences, streamed }
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var failed: ((ConversationResponseID) -> Void)?
    var reached: ((ConversationResponseID, Int) -> Void)?
    var playoutChanged: ((ConversationResponseID, Bool) -> Void)?

    /// Seconds from `speak` to the first buffer at the player, for the reply last started.
    private(set) var firstAudioAfter: Double?
    /// Numbers about the reply last started, as this class saw them: no words and no audio.
    /// Times are those of the player's callbacks, not of the loudspeaker.
    struct Playout: Equatable, Sendable {
        var receivedSeconds = 0.0
        var generationEnded = false
        /// The player ran dry and audio followed: a silence inside the reply.
        var underruns = 0
        /// Those of them inside a sentence. The others fell between two sentences.
        var underrunsInSentence = 0
        /// Those silences together and the longest one, from the callback for the last
        /// buffer to the next buffer handed to the player.
        var gapSeconds = 0.0
        var longestGap = 0.0
        /// The player had played everything and generation then ended without more audio:
        /// the seconds between the two. The model's own ending, not a silence in the reply.
        var tailSeconds = 0.0
        /// The longest a frame came later than its sentence's pace until then predicted.
        var lateSeconds = 0.0
    }
    private(set) var playout = Playout()
    /// How often the reply last started fell silent and went on (`Playout.underruns`).
    var stalls: Int { playout.underruns }

    private let model: String
    private let voice: String
    private let synthesizer: any LocalVoiceSynthesizing
    private let playback: any LocalVoicePlayback
    private let status: LocalVoice
    private let now: () -> Double
    private let bufferingMode: Buffering

    private var token = 0
    private var current: ConversationResponseID?
    private var task: Task<Void, Never>?
    private var input: AsyncStream<(index: Int, text: String)>.Continuation?
    /// Texts appended to the reply so far, the one being generated, the one each waiting
    /// chunk and each buffer at the player belongs to, and the last one the player began.
    private var appended = 0
    private var generating = 0
    private var waitingParts: [Int] = []
    private var bufferParts: [Int] = []
    private var lastReached = -1
    private var warmUp: Task<Void, Never>?
    private var retired = false
    private var leveler = LoudnessLeveler()
    private var waiting: [LocalVoiceChunk] = []
    private var waitingSeconds = 0.0
    private var receivedSeconds = 0.0
    private var startedAt = 0.0
    private var buffering = true
    private var generationEnded = false
    /// Seconds from `speak` until the model had generated the whole reply.
    private var generatedAfter: Double?
    private var scheduled = 0
    private var played = 0
    /// Seconds of audio at the player whose callback has not come yet.
    private var queuedSeconds = 0.0
    /// When the player will have played what it was given, by the clock. A callback comes
    /// after its buffer was played, so `queuedSeconds` alone counts audio that is gone.
    private var playsUntil = 0.0
    /// The sentence being generated: its expected length, when it began, how much of it
    /// arrived, and whether it already plays while the rest is generated.
    private var partExpected = 0.0
    private var partStartedAt = 0.0
    private var partReceived = 0.0
    private var partReleased = false
    /// Its first frame (when, how long) and when its latest frame came.
    private var partFirstAt = 0.0
    private var partFirstSeconds = 0.0
    private var partLastAt = 0.0
    /// Sentences begun in this reply; the one the first waiting chunk and the last buffer at
    /// the player belong to.
    private var partSerial = 0
    private var waitingSerial = 0
    private var scheduledSerial = 0
    /// The player ran dry while generation went on: when, and in which sentence.
    private var dry: (at: Double, serial: Int)?
    /// The longest a frame came late (`Playout.lateSeconds`), halved with every new reply:
    /// a generator that hesitated is given more room, and gets its trust back over time.
    private var late = 0.0

    init(
        model: String, voice: String, synthesizer: any LocalVoiceSynthesizing = QwenVoice.shared,
        playback: (any LocalVoicePlayback)? = nil, status: LocalVoice = .shared,
        buffering: Buffering = .sentences,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.model = model
        self.voice = voice
        self.synthesizer = synthesizer
        self.playback = playback ?? LocalVoicePlayer()
        self.status = status
        self.now = now
        bufferingMode = buffering
        status.notice = Self.loading
        warmUp = Task { [weak self] in
            do {
                try await synthesizer.prepare(model: model, voice: voice)
                guard let self, !self.retired else { return }
                self.status.notice = nil
            } catch {
                guard let self, !self.retired else { return }
                self.status.notice = Self.message(error)
            }
        }
    }

    /// Replaced by another voice: its loading must not report into the next voice's notice.
    func retire() {
        retired = true
        began = nil
        finished = nil
        cancelled = nil
        failed = nil
        reached = nil
        playoutChanged = nil
        warmUp?.cancel()
        warmUp = nil
        // Its own "loading" would otherwise stay on screen for good.
        if status.notice == Self.loading { status.notice = nil }
        _ = reset()
        playback.retire()
    }

    private static let loading = "Loading the local voice…"

    func speak(_ text: String, response: ConversationResponseID, language: Language) {
        begin(response: response, language: language)
        append(text, response: response)
        complete(response: response)
    }

    func begin(response: ConversationResponseID, language: Language) {
        stop()
        token += 1
        let token = token
        current = response
        firstAudioAfter = nil
        playout = Playout()
        // What came late in earlier replies counts for less with each new one.
        late *= 0.5
        startedAt = now()
        leveler.beginReply()
        appended = 0
        let (sentences, input) = AsyncStream.makeStream(of: (index: Int, text: String).self)
        self.input = input
        let bufferingMode = bufferingMode
        task = Task { [weak self, synthesizer, model, voice] in
            // Until the last sentence is generated, the orb leaves the GPU to the voice.
            OrbGPUShare.shared.begin()
            defer { OrbGPUShare.shared.end() }
            do {
                for await (index, text) in sentences {
                    try Task.checkCancellation()
                    guard self?.token == token else { return }
                    self?.generating = index
                    // Qwen's short comma fragments avoid its long-output failures. Pocket
                    // and Supertonic own their chunk boundaries; another split here can
                    // turn a continuing clause into a new utterance with broken prosody.
                    let parts: [String]
                    let family = TalkBack.model(model)?.family
                    if family == .supertonic {
                        // Supertonic selects the output language before expanding numbers.
                        // Pre-expanding here would turn Spanish digits into German words.
                        parts = [text]
                    } else if bufferingMode == .sentences, family == .pocket {
                        parts = [SpokenReply.spelledOut(text, language: language)]
                    } else {
                        parts = bufferingMode == .sentences ? SpokenReply.segments(text, language: language).map(\.text) : [text]
                    }
                    for part in parts {
                        try Task.checkCancellation()
                        guard self?.token == token else { return }
                        self?.beginPart(part)
                        let fixed = ConversationReaction.isFixed(part)
                        let cached = fixed && LocalVoice.complete(model) != nil
                            ? await ConversationReactionAudio.shared.get(part, model: model, voice: voice, language: language) : nil
                        let stream: AsyncThrowingStream<LocalVoiceChunk, any Error>
                        if let cached {
                            stream = AsyncThrowingStream { continuation in
                                cached.forEach { continuation.yield($0) }
                                continuation.finish()
                            }
                        } else {
                            stream = try await synthesizer.speech(part, model: model, voice: voice, language: language)
                        }
                        var collected: [LocalVoiceChunk] = []
                        var seconds = 0.0
                        for try await chunk in stream {
                            guard let self, self.token == token else { return }
                            try Task.checkCancellation()
                            if fixed && cached == nil {
                                seconds += Double(chunk.samples.count) / max(1, chunk.sampleRate)
                                if seconds <= 4 { collected.append(chunk) } else { collected.removeAll() }
                            }
                            try self.receive(chunk)
                        }
                        guard let self, self.token == token else { return }
                        try Task.checkCancellation()
                        if fixed && cached == nil && seconds <= 4 {
                            await ConversationReactionAudio.shared.keep(collected, text: part, model: model, voice: voice, language: language)
                        }
                        if bufferingMode == .sentences { try self.flush() }
                    }
                }
                try self?.endGeneration(token)
            } catch {
                self?.fail(token, error)
            }
        }
    }

    func append(_ text: String, response: ConversationResponseID) {
        guard current == response, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input?.yield((appended, text))
        appended += 1
    }

    func complete(response: ConversationResponseID) {
        guard current == response else { return }
        input?.finish()
        input = nil
    }

    func stop() {
        guard let response = reset() else { return }
        cancelled?(response)
    }

    /// Ends the current reply without a callback and returns it.
    private func reset() -> ConversationResponseID? {
        token += 1
        task?.cancel()
        task = nil
        input?.finish()
        input = nil
        guard let response = current else { return nil }
        playoutChanged?(response, false)
        VoiceTiming.note("voice_audio", ["response": response.rawValue, "first_audio_s": firstAudioAfter ?? -1, "stalls": stalls,
                                         "audio_s": receivedSeconds, "generation_s": generatedAfter ?? -1,
                                         "stalls_in_sentence": playout.underrunsInSentence, "gap_s": playout.gapSeconds,
                                         "longest_gap_s": playout.longestGap, "tail_s": playout.tailSeconds,
                                         "late_s": playout.lateSeconds])
        generatedAfter = nil
        playsUntil = 0
        partSerial = 0
        dry = nil
        current = nil
        playback.stop()
        waiting = []
        waitingParts = []
        bufferParts = []
        lastReached = -1
        waitingSeconds = 0
        receivedSeconds = 0
        buffering = true
        generationEnded = false
        scheduled = 0
        played = 0
        queuedSeconds = 0
        partReleased = false
        return response
    }

    private func receive(_ chunk: LocalVoiceChunk) throws {
        guard !chunk.samples.isEmpty, chunk.sampleRate > 0 else { return }
        let seconds = Double(chunk.samples.count) / chunk.sampleRate, time = now()
        if partReceived == 0 {
            partFirstAt = time
            partFirstSeconds = seconds
        } else if let steadyPace {
            let lateness = time - partLastAt - seconds * steadyPace
            playout.lateSeconds = max(playout.lateSeconds, lateness)
            late = max(late, min(lateness, 1))
        }
        partLastAt = time
        if waiting.isEmpty { waitingSerial = partSerial }
        waiting.append(LocalVoiceChunk(samples: leveler.level(chunk.samples), sampleRate: chunk.sampleRate))
        waitingParts.append(generating)
        waitingSeconds += seconds
        receivedSeconds += seconds
        partReceived += seconds
        playout.receivedSeconds += seconds
        switch bufferingMode {
        case .streamed: if !buffering || waitingSeconds >= neededSeconds { try flush() }
        case .sentences: if partReleased || startsEarly { partReleased = true; try flush() }
        }
    }

    private func beginPart(_ text: String) {
        partExpected = Self.expectedSeconds(text)
        partStartedAt = now()
        partReceived = 0
        partReleased = false
        partSerial += 1
    }

    /// Spoken German and English run at about 13 characters a second; a little more is
    /// assumed, so a longer sentence is not cut short by the estimate.
    static func expectedSeconds(_ text: String) -> Double { Double(text.count) / 13 * 1.15 }

    /// Seconds the generator needs for a second of this sentence's audio, measured from its
    /// first frame to its latest. The wait for the first frame happens once a sentence and
    /// says nothing about the rest. Nil until 0.4 s of audio followed the first frame.
    private var steadyPace: Double? {
        let after = partReceived - partFirstSeconds
        return after >= 0.4 ? (partLastAt - partFirstAt) / after : nil
    }

    /// Audio the player still has: the smaller of what its callbacks leave and what the
    /// clock leaves. The callbacks lag; the clock runs from the hand-over, before the
    /// player has started. Each errs towards more audio than there is, never both at once.
    private var ahead: Double { min(queuedSeconds, max(0, playsUntil - now())) }

    /// Whether the sentence being generated can start before it is complete. It can once
    /// generating the rest, at this sentence's pace and 10 % slower, ends before the player
    /// reaches it: before what it still has, what is waiting and the rest have played, less
    /// 0.3 s or the longest a frame came late.
    ///
    /// The rest is the estimate less what arrived, and at least a quarter of the estimate:
    /// a sentence that turns out longer than estimated is covered too. Until the pace can be
    /// measured without the wait for the first frame, that wait counts as pace, as it did
    /// before; it made a sentence that follows another wait for far more audio than it
    /// needed, while the player was already silent.
    private var startsEarly: Bool {
        guard partReceived > 0, partReceived < partExpected else { return false }
        let pace = steadyPace ?? (now() - partStartedAt) / partReceived
        guard pace <= 2 else { return false }
        let rest = max(partExpected - partReceived, 0.25 * partExpected)
        return rest * pace * 1.1 + max(0.3, late) <= ahead + waitingSeconds + rest
    }

    /// How much audio must wait before playback starts or resumes. Slow generation needs a
    /// longer lead, or the player catches up with it mid-sentence.
    private var neededSeconds: Double {
        if scheduled > 0 { return 1 }
        let pace = (now() - startedAt) / max(receivedSeconds, 0.01)
        return pace <= 0.6 ? 0.3 : pace <= 0.9 ? 1 : 2
    }

    private func flush() throws {
        guard let response = current, !waiting.isEmpty else { return }
        let token = token
        let first = scheduled == 0
        if let dry {
            // Audio follows a silence: only now is it one inside the reply.
            let gap = max(0, now() - dry.at)
            playout.underruns += 1
            if dry.serial == waitingSerial { playout.underrunsInSentence += 1 }
            playout.gapSeconds += gap
            playout.longestGap = max(playout.longestGap, gap)
            self.dry = nil
        }
        scheduledSerial = partSerial
        for (chunk, part) in zip(waiting, waitingParts) {
            scheduled += 1
            bufferParts.append(part)
            let seconds = Double(chunk.samples.count) / chunk.sampleRate
            queuedSeconds += seconds
            playsUntil = max(playsUntil, now()) + seconds
            try playback.schedule(chunk.samples, sampleRate: chunk.sampleRate) { [weak self] in
                self?.playedOne(token, seconds: seconds)
            }
        }
        waiting = []
        waitingParts = []
        waitingSeconds = 0
        buffering = false
        playoutChanged?(response, true)
        if first {
            firstAudioAfter = now() - startedAt
            status.notice = nil
            began?(response)
        }
        noteReached(token)
    }

    /// The buffer the player is at belongs to a later appended text than the last one
    /// reported: the listener has got that far.
    private func noteReached(_ token: Int) {
        guard token == self.token, let response = current, played < bufferParts.count else { return }
        let part = bufferParts[played]
        guard part > lastReached else { return }
        lastReached = part
        reached?(response, part)
    }

    private func playedOne(_ token: Int, seconds: Double) {
        guard token == self.token, current != nil else { return }
        played += 1
        queuedSeconds = max(0, queuedSeconds - seconds)
        noteReached(token)
        // A listener to `reached` may have stopped the reply.
        guard token == self.token, current != nil, played == scheduled else { return }
        if generationEnded {
            finish()
        } else {
            buffering = true
            if let response = current { playoutChanged?(response, false) }
            // Ran dry while generation goes on: what follows waits until it can play through
            // again. Whether this is a silence in the reply or just its end shows when audio
            // follows (`flush`) or generation ends without any (`endGeneration`).
            partReleased = false
            dry = (now(), scheduledSerial)
        }
    }

    private func endGeneration(_ token: Int) throws {
        guard token == self.token, current != nil else { return }
        generationEnded = true
        playout.generationEnded = true
        generatedAfter = now() - startedAt
        try flush()
        if let dry {
            playout.tailSeconds = max(0, now() - dry.at)
            self.dry = nil
        }
        guard scheduled > 0 else { throw LocalVoiceUnavailable(message: "The local voice produced no audio.") }
        if played == scheduled { finish() }
    }

    private func finish() {
        guard let response = reset() else { return }
        finished?(response)
    }

    private func fail(_ token: Int, _ error: any Error) {
        guard token == self.token, !retired, !(error is CancellationError) else { return }
        status.notice = Self.message(error)
        VoiceTiming.note("voice_failure", ["state": Self.message(error)])
        guard let response = reset() else { return }
        if let failed { failed(response) } else { cancelled?(response) }
    }

    private static func message(_ error: any Error) -> String {
        let reason = (error as? LocalVoiceUnavailable)?.message ?? "The local voice failed: \(error.localizedDescription)"
        return reason + " Replies are shown as text."
    }
}

/// An audio engine with one player node. The engine is started with the first buffer and
/// then left running for the session.
@MainActor final class LocalVoicePlayer: LocalVoicePlayback {
    private let recordingID = UUID().uuidString
    private var generation = 0
    private weak var outputRun: RunRecorder?
    private let standalone = AVAudioEngine()
    private var engine: AVAudioEngine?
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// 0 keeps the whole path running without sound, for measurements.
    var volume: Float = TalkBack.muted ? 0 : 1 { didSet { node.volume = volume } }

    func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws {
        let engine = VoiceAudioIO.engine ?? standalone
        if self.engine !== engine || node.engine !== engine {
            stop()
            if let previous = node.engine { VoiceAudioIO.retire(node, from: previous) }
            engine.attach(node)
            self.engine = engine
            format = nil
        }
        if format?.sampleRate != sampleRate {
            guard let new = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw LocalVoiceUnavailable(message: "The local voice has an unusable audio format.")
            }
            if format != nil { engine.disconnectNodeOutput(node) }
            engine.connect(node, to: engine.mainMixerNode, format: new)
            node.volume = volume
            format = new
        }
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { throw LocalVoiceUnavailable(message: "The local voice could not buffer its audio.") }
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !engine.isRunning { try engine.start() }
        let recorder = RunRecorder.assistantOutput
        outputRun = recorder
        let captured = recorder?.output(samples, sampleRate: sampleRate, player: recordingID)
        let generation = generation, recordingID = recordingID
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self, weak recorder] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if let captured { recorder?.log("voice_output_played", ["buffer": captured, "player": recordingID]) }
                played()
            }
        }
        if !node.isPlaying { node.play() }
    }

    func stop() {
        generation += 1
        outputRun?.log("voice_output_stopped", ["player": recordingID])
        guard format != nil else { return }
        node.stop()
    }

    func retire() {
        generation += 1
        outputRun?.log("voice_output_stopped", ["player": recordingID])
        node.stop()
        if let engine { VoiceAudioIO.retire(node, from: engine) }
        engine = nil
        format = nil
        standalone.stop()
    }
}
