import AVFoundation
import Speech

/// The session "backend" on the phone itself: audio frames go to Apple's
/// on-device `SpeechTranscriber`, and what it hears comes back as transcript
/// events. Nothing leaves the phone.
///
/// Listening has two stages. Apple's recogniser writes each sentence at once;
/// when a `SegmentRefiner` is given, it then hears the same sound again, corrects
/// the text and says which voice spoke. Until it has, a line's speaker is `unknown`.
///
/// What it cannot do: answer anything, because no model is connected yet.
///
/// Not verified on a device by the author: this compiles against the iOS 26
/// Speech API, but recognition quality, latency and German support on the
/// target phone are unobserved.
@MainActor
final class LocalTransport: Transport {
    var onEvent: ((TransportEvent) -> Void)?

    private let language: Language
    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: WireProtocol.sampleRate, channels: 1, interleaved: true)!
    private var seq: UInt64 = 0
    private var listening = false
    private var inputMuted = false
    private var inputEpoch = 0
    private var mutedAt: Double?
    private var captureGaps: [(after: Double, duration: Double)] = []
    private var acousticSupport: [UInt64: Bool] = [:]

    /// The recognizer's feed clock pauses with input; recorded replay time includes
    /// generated mute silence. Map timestamps without sending that silence to ASR.
    nonisolated static func recordingTime(_ seconds: Double, gaps: [(after: Double, duration: Double)]) -> Double {
        seconds + gaps.filter { seconds >= $0.after }.reduce(0) { $0 + $1.duration }
    }
    private var discardThrough = 0.0
    private var inputCancellation: Task<Void, Never>?
    /// The analyzer's converted feed clock, not the microphone's input sample count.
    private var analyzerInputEnd = CMTime.zero

    func setInputMuted(_ muted: Bool) {
        inputMuted = muted
        let now = ProcessInfo.processInfo.systemUptime
        if !muted {
            if let start = mutedAt {
                captureGaps.append((Double(hearingSamples) / WireProtocol.sampleRate, max(0, now - start)))
                mutedAt = nil
            }
            RunRecorder.assistantOutput?.log("voice_recognition", ["state": "input_resumed", "epoch": inputEpoch])
            return
        }
        if mutedAt == nil { mutedAt = now }
        inputEpoch += 1
        let cutoff = analyzerInputEnd
        discardThrough = cutoff.seconds
        committedSentences = 0
        sentenceSeen = .init()
        segment += 1
        revision = 0
        lastSentenceEnd = discardThrough
        converter = nil
        RunRecorder.assistantOutput?.log("voice_recognition", ["state": "input_muted", "epoch": inputEpoch, "discard_before_s": discardThrough])
        guard let analyzer else { return }
        inputCancellation?.cancel()
        let epoch = inputEpoch
        // Mute discards pending input. Finalizing an end-exclusive/future sample
        // while blocking all new input can wait forever. Cancellation never gates
        // resumed frames; late pre-mute results are still filtered below.
        inputCancellation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await analyzer.cancelAnalysis(before: cutoff)
            guard !Task.isCancelled, let self, self.inputEpoch == epoch else { return }
            RunRecorder.assistantOutput?.log("voice_recognition", ["state": "pending_input_discarded", "epoch": epoch])
        }
    }
    private var segment: UInt64 = 1
    private var revision = 0
    private var committedSentences = 0
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var work: Task<Void, Never>?

    /// Layer by layer, what happened to each sentence. For the debug overlay.
    var onTrace: ((LayerTrace) -> Void)?
    /// Model loading and similar news from the stages.
    var onStatus: ((String) -> Void)?
    /// Names the harness found for voices from what was said.
    var onNames: (([UInt32: String]) -> Void)?

    private let refiner: (any SegmentRefiner)?
    private var refinerReady = false
    private var refining: Task<Void, Never>?
    /// The sound fed to the recogniser, kept for the second stage only, in memory.
    private var history: [Float] = []
    /// Samples fed before `history[0]`.
    private var historyStart = 0
    private var hearingSamples = 0
    private var inputActivity = SpeechActivityWindow()

    func hasSpeech(_ segment: TranscriptSegment) -> Bool {
        acousticSupport[segment.segmentID] ?? inputActivity.supports(startMs: segment.startMs, endMs: segment.endMs)
    }
    private var fedSamples: Int { refiner == nil ? hearingSamples : historyStart + history.count }
    private var lastSentenceEnd = 0.0
    /// For each sentence of the recogniser's growing text: when it was first complete.
    private var sentenceSeen = TranscriptionSentenceBoundaries()
    private var mappingVersion = 0
    /// How much sound is kept, and how much of it the speaker model hears (from system.json).
    private let historySeconds: Double
    private let windowSeconds: Double
    /// Finished lines as last sent, so a later stage can send them again changed.
    private var sent: [UInt64: TranscriptSegment] = [:]
    /// The sentence whose voice is still the speaker model's first guess (`voicePending`).
    private var pendingVoice: UInt64?

    /// The output side: turns what was heard into cards. Nil means listening only.
    private let answers: AnswerEngine?
    private var traces: [UInt64: LayerTrace] = [:]
    private var meVoice: UInt32?
    /// In a call with an app's sound mixed in: who spoke in each frame, the side that decided a
    /// sentence's voice, and the voice the app's side spoke with last.
    private var sides = CallSides()
    private var sideOf: [UInt64: CallSides.Side] = [:]
    private var lastTheirs: UInt32?
    /// Sentences the decision service joined to an established voice.
    private var hinted: [UInt64: UInt32] = [:]

    /// Terms the topic's files name, given to Apple's recogniser as words to expect.
    private let expected: [String]

    init(language: Language, refiner: (any SegmentRefiner)? = nil, answers: AnswerEngine? = nil, speakerWindowSeconds: Double = 600,
         expected: [String] = []) {
        self.expected = expected
        windowSeconds = max(30, speakerWindowSeconds)
        historySeconds = max(30, speakerWindowSeconds) + 30
        self.language = language
        self.refiner = refiner
        self.answers = answers
        answers?.emit = { [weak self] event in self?.emit(event) }
        answers?.onNames = { [weak self] names, me in
            guard let self else { return }
            self.onNames?(names)
            // The talk gave away which voice is the user: mark it, unless they already did.
            if let me, self.meVoice == nil {
                self.meVoice = me
                self.mappingVersion += 1
                self.emit(.speakerMapping(version: self.mappingVersion, meVoice: me))
            }
        }
        answers?.onVoiceHint = { [weak self] sentence, voice in self?.hint(voice, for: sentence) }
        answers?.onStep = { [weak self] segment, step in
            guard let self, var trace = self.traces[segment] else { return }
            trace.steps.append(step)
            self.report(trace)
        }
    }

    private func report(_ trace: LayerTrace) {
        traces[trace.id] = trace
        if traces.count > 60, let oldest = traces.keys.min() { traces[oldest] = nil }
        onTrace?(trace)
    }

    func connect() {
        Task { self.onEvent?(.connected) }
    }

    func disconnect() {
        teardown()
        onEvent?(.disconnected)
    }

    func send(_ event: ClientEvent) {
        switch event {
        case .hello, .resumeFrom:
            break
        case .cardAction(let id, let action):
            if action == .dismiss {
                answers?.dismiss(id)
            } else if answers?.act(action, on: id) != true {
                emit(.error(.modelProvider))
            }
        case .mapSpeaker(let voice, let isMe):
            meVoice = isMe ? voice : nil
            mappingVersion += 1
            emit(.speakerMapping(version: mappingVersion, meVoice: isMe ? voice : nil))
        case .start:
            start()
        case .pause(let reason):
            listening = false
            emit(.state(.paused, reason: reason))
        case .resume:
            listening = true
            emit(.state(.listening, reason: nil))
        case .stop:
            settlePendingVoice()
            teardown()
            emit(.state(.stopped, reason: nil))
        case .helpNow:
            if let answers { answers.askNow() } else { emit(.error(.modelProvider)) }
        }
    }

    func sendAudio(_ frame: AudioFrame) {
        guard listening, !inputMuted, let input, let buffer = buffer(from: frame.pcm) else { return }
        inputActivity.receive(frame.pcm)
        let start = analyzerInputEnd
        let duration = CMTime(value: CMTimeValue(buffer.frameLength), timescale: CMTimeScale(buffer.format.sampleRate.rounded()))
        analyzerInputEnd = CMTimeAdd(start, duration)
        input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
        hearingSamples += frame.pcm.count / MemoryLayout<Int16>.size
        guard refiner != nil else { return }
        let frameSamples = WireProtocol.frameBytes / 2
        if let mine = frame.mine, let theirs = frame.theirs { sides.add(frame: fedSamples / frameSamples, mine: mine, theirs: theirs) }
        frame.pcm.withUnsafeBytes { raw in
            history.append(contentsOf: raw.bindMemory(to: Int16.self).map { Float($0) / 32_768 })
        }
        let limit = Int(historySeconds * WireProtocol.sampleRate)
        if history.count > limit {
            historyStart += history.count - limit
            history.removeFirst(history.count - limit)
            if !sides.isEmpty { sides.forget(before: historyStart / frameSamples) }
        }
    }

    func endUtterance() {
        guard listening, let analyzer else { return }
        // nil finalizes only audio already consumed. An input/output conversion
        // delay or an exclusive buffer end must never request future audio.
        Task { try? await analyzer.finalize(through: nil) }
    }

    // MARK: Recognition

    private func start() {
        if let refiner {
            // Sentences heard while the models load queue up behind this.
            refining = Task { [weak self] in
                await refiner.prepare { text in Task { @MainActor in self?.onStatus?(text) } }
                self?.refinerReady = true
            }
        }
        work = Task {
            do {
                guard let locale = await Self.locale(for: language) else {
                    print("[Listen] SpeechTranscriber supports no locale for \(language.rawValue) on this device")
                    throw CocoaError(.featureUnsupported)
                }
                let transcriber = SpeechTranscriber(
                    locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.audioTimeRange])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    print("[Listen] downloading speech model for \(locale.identifier)")
                    try await request.downloadAndInstall()
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                if !expected.isEmpty {
                    // Words the topic's files name: "SQL-Injection" rather than "Desqualinjection".
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = Array(expected.prefix(100))
                    try? await analyzer.setContext(context)
                }
                analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.start(inputSequence: stream)
                self.analyzer = analyzer
                input = continuation
                listening = true
                print("[Listen] transcribing \(locale.identifier), format \(String(describing: analyzerFormat))")
                emit(.state(.listening, reason: nil))
                for try await result in transcriber.results {
                    guard !inputMuted, result.range.start.seconds >= discardThrough else { continue }
                    heard(String(result.text.characters), isFinal: result.isFinal,
                          marks: Self.timeMarks(in: result.text), audioEnd: result.range.end.seconds)
                }
            } catch is CancellationError {
            } catch {
                print("[Listen] transcription failed: \(error)")
                emit(.error(.speechProvider))
                teardown()
                onEvent?(.disconnected)
            }
        }
    }

    /// Swiss locale first for German, then Germany; Apple decides what exists.
    private static func locale(for language: Language) async -> Locale? {
        let candidates = language == .de ? ["de-CH", "de-DE"] : ["en-US", "en-GB"]
        for identifier in candidates {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
                return match
            }
        }
        return nil
    }

    /// For each run of the recogniser's text: how many characters the text has
    /// up to its end, and when its sound ends, in seconds of fed audio.
    private static func timeMarks(in text: AttributedString) -> [(characters: Int, end: Double)] {
        var marks: [(Int, Double)] = []
        var characters = 0
        for run in text.runs {
            characters += text[run.range].characters.count
            if let range = run.audioTimeRange { marks.append((characters, range.end.seconds)) }
        }
        return marks
    }

    /// The recogniser reports one growing text until a long pause. Sentences
    /// that are complete are passed on as finished segments right away, so the
    /// feed shows one line per sentence and later stages can start early. The
    /// price: if the recogniser later revises a sentence already passed on,
    /// that revision is not shown.
    private func heard(_ text: String, isFinal: Bool, marks: [(characters: Int, end: Double)] = [], audioEnd: Double) {
        let (complete, rest) = Self.sentences(in: text)
        let ends = Self.sentenceEnds(in: text)
        // Word timings only come with the final result after a long pause. Until
        // then a sentence's end is taken from when its full stop first showed up,
        // moved back to the quietest moment just before.
        let analysed = min(audioEnd, Double(fedSamples) / WireProtocol.sampleRate)
        sentenceSeen.update(complete, committed: committedSentences, estimate: quietPoint(before: analysed))
        func endTime(_ index: Int) -> Double? {
            if isFinal, marks.count > 1, index < ends.count {
                return marks.first { $0.characters >= ends[index] }?.end ?? analysed
            }
            return sentenceSeen.end(at: index) ?? analysed
        }
        defer { if isFinal { sentenceSeen = .init() } }
        if isFinal {
            for (index, sentence) in complete.enumerated().dropFirst(committedSentences) {
                emitSegment(sentence, isFinal: true, endTime: endTime(index))
            }
            emitSegment(rest, isFinal: true, endTime: marks.last?.end ?? analysed)
            committedSentences = 0
            return
        }
        // The sentence at the very end is still being rewritten by the
        // recogniser; it only counts as finished once more words follow it.
        let settled = rest.isEmpty ? complete.dropLast() : complete[...]
        for (index, sentence) in settled.enumerated().dropFirst(committedSentences) {
            emitSegment(sentence, isFinal: true, endTime: endTime(index))
            committedSentences += 1
        }
        // A volatile result can arrive after its source audio, while our reply has
        // already started playing. Ending it at the current feed clock incorrectly
        // lends that later loudspeaker activity to an earlier silence-only guess.
        // Keep acoustic support on the recognizer result's own audio range.
        emitSegment(rest.isEmpty ? (complete.last ?? "") : rest, isFinal: false, endTime: analysed)
        // What is being said right now, before the sentence ends: ranked against prepared cards.
        let speaking = rest.isEmpty ? (complete.last ?? "") : rest
        // The ranker owns a separate allowance and must see revisions even while its final
        // allowed call is in flight, so it can discard a result for superseded words.
        if !speaking.isEmpty { answers?.partial(id: segment, text: speaking) }
        // A complete question the recogniser still holds back: its round may start now (it gets
        // the id it will be committed under), and waits for the commit before showing anything.
        if rest.isEmpty, let held = complete.last, answers?.routesEarlyText == true {
            answers?.provisional(id: segment, text: held)
        }
    }

    /// The quietest fifth of a second in the 1.6 s before `time`: most likely
    /// the gap between two sentences. Returns `time` when no sound is kept.
    private func quietPoint(before time: Double) -> Double {
        if refiner == nil { return inputActivity.quietPoint(before: time, after: lastSentenceEnd) }
        return Self.quietPoint(in: history, firstSample: historyStart, lastSentenceEnd: lastSentenceEnd, before: time)
    }

    /// Recognition time advances even when no refinement audio is retained. Window
    /// bounds come from the retained buffer, never from the full recognition clock.
    nonisolated static func quietPoint(in history: [Float], firstSample: Int, lastSentenceEnd: Double, before time: Double) -> Double {
        let rate = WireProtocol.sampleRate
        let frame = Int(0.2 * rate)
        let hop = Int(0.02 * rate)
        let to = min(history.count, max(0, Int(time * rate) - firstSample))
        let from = max(Int(max(time - 1.6, lastSentenceEnd + 0.3) * rate) - firstSample, 0)
        guard to - from > frame else { return time }
        var best = (energy: Float.infinity, at: to)
        var position = from
        while position + frame <= to {
            var energy: Float = 0
            for sample in history[position..<(position + frame)] { energy += sample * sample }
            if energy < best.energy { best = (energy, position + frame / 2) }
            position += hop
        }
        return Double(best.at + firstSample) / rate
    }

    private func emitSegment(_ text: String, isFinal: Bool, endTime: Double?) {
        // Punctuation on its own is noise, not speech.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        revision += 1
        let now = Double(fedSamples) / WireProtocol.sampleRate
        let end = min(endTime ?? now, now)
        let start = min(max(lastSentenceEnd, end - 20), end)
        let heard = TranscriptSegment(
            segmentID: segment, isFinal: isFinal, revision: revision, voice: nil, speaker: .unknown,
            text: text, startMs: UInt64(start * 1000), endMs: UInt64(end * 1000))
        emit(.transcript(heard))
        guard isFinal else { return }
        lastSentenceEnd = end
        var trace = LayerTrace(
            id: segment, text: text, audioSeconds: end - start,
            steps: [.init(name: "1 · Apple", detail: "heard live", seconds: max(0, now - end))])
        segment += 1
        revision = 0
        if refiner == nil {
            trace.steps.append(.init(name: "2 · Whisper", detail: "off", seconds: nil))
        } else if !refinerReady {
            trace.steps.append(.init(name: "2 · Whisper", detail: "waiting for the model to load", seconds: nil))
        }
        report(trace)
        // A directed session can prepare from committed first-pass text while
        // correction and anonymous speaker labels are computed in parallel.
        // The engine invalidates in-flight work on substantive text revisions.
        if refiner == nil || answers?.routesEarlyText == true { answers?.heard(heard, isMine: false) }
        refine(heard, trace: trace, start: start, end: end)
    }

    /// Second stage, one sentence after the other so the phone is never asked
    /// to run several models at once.
    private func refine(_ heard: TranscriptSegment, trace: LayerTrace, start: Double, end: Double) {
        guard let refiner else { return }
        let rate = WireProtocol.sampleRate
        let windowStart = max(historyStart, Int((end - windowSeconds) * rate))
        let from = max(windowStart, Int(start * rate))
        let to = min(fedSamples, Int(end * rate))
        guard to - from > Int(0.3 * rate) else { return }
        let request = RefineRequest(
            segmentID: heard.segmentID,
            window: Array(history[(windowStart - historyStart)..<(to - historyStart)]),
            windowStart: Double(windowStart) / rate,
            sentence: (from - windowStart)..<(to - windowStart), heard: heard.text)
        sent[heard.segmentID] = heard
        if sent.count > 200, let oldest = sent.keys.min() { sent[oldest] = nil }
        let previous = refining
        let epoch = inputEpoch
        refining = Task { [weak self] in
            await previous?.value
            let queued = Date()
            let result = await refiner.refine(request)
            guard let self, !Task.isCancelled, !self.inputMuted, self.inputEpoch == epoch else { return }
            var refined = self.sent[heard.segmentID] ?? heard
            if let text = result.text { refined.text = text }
            // Earlier sentences first, so the feed changes top to bottom.
            for (id, proposed) in result.voices.sorted(by: { $0.key < $1.key }) where id != heard.segmentID {
                guard var earlier = self.sent[id] else { continue }
                // In a call, the side that spoke decides what the sound model may not change.
                let voice = self.constrained(proposed, for: id)
                guard voice != earlier.voice else { continue }
                earlier.revision += 1
                earlier.voice = voice
                earlier.speaker = .speaker(Int(voice))
                earlier.voicePending = false
                self.sent[id] = earlier
                self.emit(.transcript(earlier))
                // The output side must know the corrected voice too.
                self.answers?.heard(earlier, isMine: voice == self.meVoice)
            }
            // This run heard more after the sentence that waited: its voice stands now, changed or not.
            if result.voicesHeard { self.settlePendingVoice(except: heard.segmentID) }
            var voice = result.voices[heard.segmentID]
            let side = self.sides.side(from: start, to: end)
            if let side {
                self.sideOf[heard.segmentID] = side
                if self.sideOf.count > 400, let oldest = self.sideOf.keys.min() { self.sideOf[oldest] = nil }
                voice = self.voice(for: side, acoustic: voice)
            }
            if let voice {
                refined.voice = voice
                refined.speaker = .speaker(Int(voice))
            }
            // A side heard in a call is not a guess.
            refined.voicePending = side == nil && result.voicesHeard
            if refined.voicePending { self.pendingVoice = heard.segmentID }
            refined.revision += 1
            self.sent[heard.segmentID] = refined
            self.emit(.transcript(refined))
            var trace = self.traces[heard.segmentID] ?? trace
            trace.steps.removeAll { $0.seconds == nil }
            let changed = result.text != nil && Correction.words(refined.text) != Correction.words(heard.text)
            trace.text = refined.text
            trace.steps.append(.init(
                name: "2 · Whisper", detail: result.text == nil ? (result.note ?? "no text") : (changed ? "corrected" : "same words"),
                seconds: result.textSeconds, changed: changed))
            if let dialect = result.dialect {
                trace.steps.append(.init(
                    name: "2b · Swiss German",
                    // The whole text, also when it was not taken: what the dialect model heard is
                    // what a measurement of Swiss German compares.
                    detail: result.dialectTaken ? "taken, the others struggled: \(dialect)"
                        : (result.dialectVoted ? "vote changed words: \(dialect)" : "not taken: \(dialect)"),
                    seconds: result.dialectSeconds, changed: result.dialectTaken || result.dialectVoted))
            }
            trace.steps.append(.init(
                name: "2 · Speaker",
                detail: (side.map { "voice \(voice.map(String.init) ?? "-"), by the \($0 == .mine ? "microphone" : "app's sound")" }
                    ?? voice.map { "voice \($0), first guess" } ?? (result.voicesHeard ? "waits for the next sentence" : "not found"))
                    + (result.voices.count > 1 ? ", \(result.voices.count - 1) earlier changed" : ""),
                seconds: result.voiceSeconds, changed: voice != nil))
            trace.steps.append(.init(name: "2 · total", detail: "", seconds: Date().timeIntervalSince(queued)))
            self.report(trace)
            self.answers?.heard(refined, isMine: voice != nil && voice == self.meVoice)
            // A voice heard in at most two sentences is asked about once more, from the conversation.
            if side == nil, let voice, self.hinted[heard.segmentID] == nil,
               self.sent.values.count(where: { $0.voice == voice }) <= 2 {
                self.answers?.checkSpeaker(heard.segmentID)
            }
        }
    }

    /// The voice the sides of a call allow for a sentence the sound model labelled again: a
    /// sentence the microphone spoke stays the user's, and one the app's sound spoke never becomes it.
    private func constrained(_ proposed: UInt32, for id: UInt64) -> UInt32 {
        // A joined sentence stays joined while the sound model still hears it as a rare voice;
        // an established voice it gives later is its own better answer.
        if let hint = hinted[id], sent.values.count(where: { $0.voice == proposed }) <= 2 { return hint }
        switch sideOf[id] {
        case .mine?: return meVoice ?? proposed
        case .theirs?: return proposed == meVoice ? (sent[id]?.voice ?? proposed) : proposed
        case nil: return proposed
        }
    }

    /// The voice of a sentence that one side of a call spoke. The microphone is the user, who
    /// chose to hear the app's sound with headphones on (Ruben, 17 November 2026): the first such
    /// sentence makes its voice theirs. The app's sound is the others, never the user.
    private func voice(for side: CallSides.Side, acoustic: UInt32?) -> UInt32 {
        switch side {
        case .mine:
            if let meVoice { return meVoice }
            let mine = acoustic ?? freshVoice()
            meVoice = mine
            mappingVersion += 1
            emit(.speakerMapping(version: mappingVersion, meVoice: mine))
            return mine
        case .theirs:
            let voice = acoustic.flatMap { $0 == meVoice ? nil : $0 } ?? lastTheirs ?? freshVoice()
            lastTheirs = voice
            return voice
        }
    }

    /// The decision service is sure whom a sentence with a new or rare voice belongs to. Taken
    /// unless the sides of a call decided the sentence, or its voice has become an established one.
    private func hint(_ voice: UInt32, for id: UInt64) {
        guard var segment = sent[id], sideOf[id] == nil, segment.voice != voice else { return }
        let rare = segment.voice.map { own in sent.values.count(where: { $0.voice == own }) <= 2 } ?? true
        guard rare else { return }
        let before = segment.voice
        hinted[id] = voice
        if hinted.count > 200, let oldest = hinted.keys.min() { hinted[oldest] = nil }
        segment.voice = voice
        segment.speaker = .speaker(Int(voice))
        segment.voicePending = false
        segment.revision += 1
        sent[id] = segment
        if pendingVoice == id { pendingVoice = nil }
        emit(.transcript(segment))
        answers?.heard(segment, isMine: voice == meVoice)
        if var trace = traces[id] {
            trace.steps.append(.init(name: "2 · Speaker", detail: "voice \(before.map(String.init) ?? "-") joined to voice \(voice) by the conversation",
                                     seconds: nil, changed: true))
            report(trace)
        }
    }

    private func freshVoice() -> UInt32 {
        (Set(sent.values.compactMap(\.voice)).union([meVoice, lastTheirs].compactMap { $0 }).max() ?? 0) + 1
    }

    /// Shows the waiting sentence's voice as settled, as it stands now. Its voice changes only
    /// when a run gives it another, which arrives as a voice for an earlier sentence.
    private func settlePendingVoice(except current: UInt64? = nil) {
        guard let id = pendingVoice, id != current else { return }
        pendingVoice = nil
        guard var waiting = sent[id], waiting.voicePending else { return }
        waiting.voicePending = false
        waiting.revision += 1
        sent[id] = waiting
        emit(.transcript(waiting))
    }

    /// Splits text into finished sentences and the unfinished remainder. A
    /// sentence ends at ".", "?" or "!" followed by a space or the end.
    nonisolated static func sentences(in text: String) -> (complete: [String], rest: String) {
        var complete: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let atEnd = index == characters.count - 1
            if ".?!".contains(character), atEnd || characters[index + 1].isWhitespace {
                complete.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        return (complete, current.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Character offsets just behind each finished sentence, matching `sentences(in:)`.
    nonisolated static func sentenceEnds(in text: String) -> [Int] {
        let characters = Array(text)
        return characters.indices.filter { index in
            ".?!".contains(characters[index]) && (index == characters.count - 1 || characters[index + 1].isWhitespace)
        }.map { $0 + 1 }
    }

    private func teardown() {
        inputCancellation?.cancel(); inputCancellation = nil
        analyzerInputEnd = .zero
        discardThrough = 0
        answers?.stop()
        refining?.cancel()
        refining = nil
        traces = [:]
        history = []
        sent = [:]
        listening = false
        input?.finish()
        input = nil
        work?.cancel()
        work = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        converter = nil
    }

    private func emit(_ event: ServerEvent) {
        var event = event
        if case .transcript(var segment) = event {
            guard !inputMuted else { return }
            acousticSupport[segment.segmentID] = inputActivity.supports(startMs: segment.startMs, endMs: segment.endMs)
            if acousticSupport.count > 256, let oldest = acousticSupport.keys.min() { acousticSupport[oldest] = nil }
            segment.startMs = UInt64(Self.recordingTime(Double(segment.startMs) / 1000, gaps: captureGaps) * 1000)
            segment.endMs = UInt64(Self.recordingTime(Double(segment.endMs) / 1000, gaps: captureGaps) * 1000)
            event = .transcript(segment)
        }
        seq += 1
        onEvent?(.envelope(Envelope(v: WireProtocol.version, seq: seq, event: event)))
    }

    // MARK: Audio

    /// Wraps one wire frame in a buffer, converted to the analyzer's format if it differs.
    private func buffer(from pcm: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: frames),
            let samples = source.int16ChannelData
        else { return nil }
        source.frameLength = frames
        pcm.withUnsafeBytes { raw in
            samples[0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        guard let target = analyzerFormat, target != wireFormat else { return source }

        if converter == nil { converter = AVAudioConverter(from: wireFormat, to: target) }
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / wireFormat.sampleRate) + 32
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        let pending = PendingBuffer(source)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// A volatile full stop is not a permanent audio boundary. If ASR grows that
/// sentence, its old timestamp can point into silence before the new words.
struct TranscriptionSentenceBoundaries {
    private var entries: [(text: String, end: Double)] = []

    mutating func update(_ sentences: [String], committed: Int, estimate: Double) {
        entries = Array(entries.prefix(sentences.count))
        for (index, text) in sentences.enumerated() {
            if index == entries.count { entries.append((text, estimate)) }
            else if index >= committed, entries[index].text != text { entries[index] = (text, estimate) }
        }
    }

    func end(at index: Int) -> Double? { entries.indices.contains(index) ? entries[index].end : nil }
}
