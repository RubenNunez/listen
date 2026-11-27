import Foundation
@preconcurrency import SpeakerKit
@preconcurrency import WhisperKit

/// Second listening stage with open models from Argmax (MIT): Whisper writes
/// the sentence again, primed with the topic's words, and Pyannote says which
/// voice it was. Models are downloaded from Hugging Face on first use
/// (about 500 MB) and run on the device afterwards.
///
/// Measured only on a Mac with synthetic voices so far.
actor WhisperRefiner: SegmentRefiner {
    /// Which stages run and with what, from system.json.
    private let voice: SystemConfig.Voice
    private var model: String { voice.whisperModel }
    private let language: Language
    private let glossary: String
    private var whisper: WhisperKit?
    /// A Whisper trained on Swiss German that writes Standard German, as an
    /// extra layer. Used only when its model lies in `dialectFolder`.
    private var dialect: WhisperKit?

    /// Where the converted dialect model is expected (see `Tools/swiss-german`).
    static var dialectFolder: URL {
        URL.documentsDirectory.appending(path: "huggingface/models/listen/swiss-german", directoryHint: .isDirectory)
    }

    static var hasDialectModel: Bool {
        FileManager.default.fileExists(atPath: dialectFolder.appending(path: "AudioEncoder.mlmodelc").path)
    }
    private var speakers: SpeakerKit?
    private var promptTokens: [Int]?
    private struct Span {
        var segment: UInt64
        var start: Double
        var end: Double
        var voice: UInt32?
    }
    /// Sentences of the last ten minutes with the voice given to them so far.
    private var spans: [Span] = []

    init(language: Language, glossary: String, voice: SystemConfig.Voice = .init()) {
        self.voice = voice
        self.language = language
        self.glossary = glossary
    }

    func prepare(report: @escaping @Sendable (String) -> Void) async {
        let began = Date()
        if voice.speakers {
            do {
                report("Speaker model: loading")
                let kit = try await SpeakerKit()
                try await kit.ensureModelsLoaded()
                speakers = kit
                report(String(format: "Speaker model: ready after %.1f s", Date().timeIntervalSince(began)))
            } catch {
                report("Speaker model: failed (\(error.localizedDescription))")
            }
        } else {
            report("Speaker model: switched off in system.json")
        }
        let whisperBegan = Date()
        if !voice.whisper {
            report("Whisper: switched off in system.json")
        } else {
          do {
            report("Whisper \(model): loading, first time downloads about 500 MB")
            let kit = try await WhisperKit(WhisperKitConfig(model: model, verbose: false, logLevel: .error))
            // The first run compiles the model for this chip; do it before the first sentence.
            _ = try? await kit.transcribe(
                audioArray: [Float](repeating: 0, count: 16_000),
                decodeOptions: DecodingOptions(language: language.rawValue, withoutTimestamps: true))
            // The tokenizer exists only once the model is loaded, which the run above did.
            if !glossary.isEmpty, let tokenizer = kit.tokenizer {
                promptTokens = tokenizer.encode(text: " " + glossary)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                    .suffix(200).map { $0 }
            }
            report("Whisper \(model): glossary of \(promptTokens?.count ?? 0) tokens")
            whisper = kit
            report(String(format: "Whisper \(model): ready after %.1f s", Date().timeIntervalSince(whisperBegan)))
          } catch {
            report("Whisper \(model): failed (\(error.localizedDescription))")
          }
        }
        guard language == .de else { return }
        guard voice.swissGerman else {
            report("Swiss German: switched off in system.json")
            return
        }
        guard Self.hasDialectModel else {
            report("Swiss German: no model on this device")
            return
        }
        // In the background: the first load compiles a large model for this chip
        // and can take minutes. The other layers must not wait for it.
        report("Swiss German: loading in the background")
        Task { await self.loadDialect(report: report) }
    }

    private func loadDialect(report: @escaping @Sendable (String) -> Void) async {
        let began = Date()
        do {
            let kit = try await WhisperKit(WhisperKitConfig(
                modelFolder: Self.dialectFolder.path, verbose: false, logLevel: .error, download: false))
            _ = try? await kit.transcribe(
                audioArray: [Float](repeating: 0, count: 16_000),
                decodeOptions: DecodingOptions(language: "de", withoutTimestamps: true))
            dialect = kit
            report(String(format: "Swiss German: ready after %.0f s", Date().timeIntervalSince(began)))
        } catch {
            report("Swiss German: failed (\(error.localizedDescription))")
        }
    }

    func refine(_ request: RefineRequest) async -> Refinement {
        var result = Refinement()
        async let voices = voices(for: request)
        let began = Date()
        let margin = 3200  // 0.2 s on both sides, so no word is cut
        let from = max(0, request.sentence.lowerBound - margin)
        let to = min(request.window.count, request.sentence.upperBound + margin)
        var second: String?
        if let whisper {
            var options = DecodingOptions(
                language: language.rawValue, skipSpecialTokens: true, withoutTimestamps: true)
            options.promptTokens = promptTokens
            if let results = try? await whisper.transcribe(
                audioArray: Array(request.window[from..<to]), decodeOptions: options)
            {
                let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                second = text.isEmpty ? nil : text
                if Correction.isPlausible(text, for: request.heard) {
                    // Word by word: an invented word does not replace a real one the first stage heard.
                    let language = language
                    let glossary = glossary
                    let settled = await MainActor.run {
                        Correction.arbitrate(heard: request.heard, candidate: text, glossary: glossary) {
                            WordCheck.isWord($0, in: language)
                        }
                    }
                    if settled != text { result.note = "kept first-stage words over: \(text.prefix(60))" }
                    result.text = settled
                } else if !text.isEmpty {
                    result.note = "dropped: \(text.prefix(60))"
                }
            }
            result.textSeconds = Date().timeIntervalSince(began)
        }
        if let dialect {
            let dialectBegan = Date()
            let options = DecodingOptions(language: "de", skipSpecialTokens: true, withoutTimestamps: true)
            if let results = try? await dialect.transcribe(audioArray: Array(request.window[from..<to]), decodeOptions: options) {
                let whole = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let text = Correction.trimDialect(whole, to: request.heard)
                if !text.isEmpty {
                    result.dialect = text
                    let language = language
                    let settled = result.text ?? request.heard
                    let heard = request.heard
                    let whisperText = second
                    result.dialectTaken = await MainActor.run {
                        Correction.prefersDialect(text, over: settled, first: heard, second: whisperText) {
                            WordCheck.isWord($0, in: language)
                        }
                    }
                    if result.dialectTaken {
                        result.text = text
                    } else if Correction.similarity(text, settled) >= 0.6 {
                        // The same sentence heard a third time, by the largest model: a vote.
                        let voted = Correction.vote(first: heard, second: settled, strongest: text, glossary: glossary)
                        if Correction.words(voted) != Correction.words(settled) { result.dialectVoted = true }
                        result.text = voted
                    }
                }
            }
            result.dialectSeconds = Date().timeIntervalSince(dialectBegan)
        }
        let found = await voices
        result.voices = found.found
        result.voiceSeconds = found.seconds
        result.voicesHeard = found.heard
        return result
    }

    /// Diarizes everything heard so far (at most the last ten minutes) and gives
    /// every sentence in it the voice that fills most of it. The model's speaker
    /// numbers are only valid within one run, so they are matched to this
    /// session's voices through the sentences already labelled: a model speaker
    /// keeps the voice most of its sentences had.
    ///
    /// A model speaker that matches no voice is judged by its voice print: far
    /// from every known speaker of this run it is a new person, close to one it
    /// is that person, split in two by the model. On eleven recorded runs,
    /// different people were 0.79 to 0.98 apart and halves of one voice 0.16 to
    /// 0.36 (cosine distance between the centroids of one run).
    ///
    /// The newest sentence lies at the end of what was heard, where the model has the least to
    /// go on: it often gives the newest words a speaker of their own and takes it back on the
    /// next run. So someone new is only counted once heard long enough before the newest
    /// sentence, and the newest sentence is never given a voice by guessing; it waits for the
    /// next run instead. On a conversation recorded on 17 November 2026 a person who never spoke
    /// was shown for 14 sentences; with this, sentences shown in a wrong voice went from 25 of
    /// 78 to 15, and 14 waited one sentence for theirs (`check voices`).
    ///
    /// The sound goes in as it was recorded. Cutting the silences out was tried
    /// against one speaker heard as two, and it made two real voices one: with
    /// a minute of sound the model lost them, with the whole recording and its
    /// silences it kept both (runs of 15 November 2026).
    /// Not private: the check tool runs it over a recording to measure it against the true speakers.
    func voices(for request: RefineRequest) async -> (found: [UInt64: UInt32], seconds: Double, heard: Bool) {
        guard let speakers else { return ([:], 0, false) }
        let began = Date()
        guard let diarization = try? await speakers.diarize(audioArray: request.window) else {
            return ([:], Date().timeIntervalSince(began), false)
        }
        let windowEnd = request.windowStart + Double(request.window.count) / WireProtocol.sampleRate
        spans.removeAll { $0.end <= request.windowStart }
        spans.append(Span(
            segment: request.segmentID,
            start: request.windowStart + Double(request.sentence.lowerBound) / WireProtocol.sampleRate,
            end: min(windowEnd, request.windowStart + Double(request.sentence.upperBound) / WireProtocol.sampleRate),
            voice: nil))

        // A speaker heard only briefly is a cough, a click or a laugh, not a person: in a run
        // with one speaker the model found two more, 3 and 4 seconds long in short pieces,
        // and the voices on screen kept changing (15 November 2026).
        var heardFor: [Int: Double] = [:]
        for segment in diarization.segments {
            guard let id = segment.speaker.speakerId else { continue }
            heardFor[id, default: 0] += Double(segment.endTime - segment.startTime)
        }
        let real = Set(heardFor.filter { $0.value >= voice.shortestVoiceSeconds }.keys)
        // How long each model speaker was heard before the newest sentence began.
        let newestStart = Double(request.sentence.lowerBound) / WireProtocol.sampleRate
        var heardBefore: [Int: Double] = [:]
        for segment in diarization.segments {
            guard let id = segment.speaker.speakerId else { continue }
            heardBefore[id, default: 0] += max(0, min(Double(segment.endTime), newestStart) - Double(segment.startTime))
        }

        // Which model speaker fills most of each sentence.
        var local: [Int: Int] = [:]  // index into spans -> model speaker
        for (index, span) in spans.enumerated() {
            var overlap: [Int: Double] = [:]
            let from = span.start - request.windowStart
            let to = span.end - request.windowStart
            for segment in diarization.segments {
                guard let id = segment.speaker.speakerId, real.contains(id) else { continue }
                let shared = min(to, Double(segment.endTime)) - max(from, Double(segment.startTime))
                if shared > 0 { overlap[id, default: 0] += shared }
            }
            if let best = overlap.max(by: { $0.value < $1.value })?.key { local[index] = best }
        }
        if ProcessInfo.processInfo.environment["LISTEN_TRACE_VOICES"] != nil {
            let heard = heardFor.sorted { $0.key < $1.key }.map { "\($0.key): " + String(format: "%.0f s", $0.value) }
            print("[voices] model", heard.joined(separator: ", "), "| sentences", spans.enumerated().map { "#\($1.segment)→\(local[$0].map(String.init) ?? "?")" }.joined(separator: " "))
        }
        // Votes: how many already-labelled sentences each model speaker shares with each voice.
        var votes: [Int: [UInt32: Int]] = [:]
        for (index, speaker) in local {
            guard let voice = spans[index].voice else { continue }
            votes[speaker, default: [:]][voice, default: 0] += 1
        }
        var mapping: [Int: UInt32] = [:]
        // Most shared sentences first; on a tie the older voice, so numbers stay put.
        var ranked: [(speaker: Int, voice: UInt32, shared: Int)] = []
        for (speaker, byVoice) in votes {
            for (voice, shared) in byVoice { ranked.append((speaker, voice, shared)) }
        }
        ranked.sort { first, second in
            if first.shared != second.shared { return first.shared > second.shared }
            if first.voice != second.voice { return first.voice < second.voice }
            return first.speaker < second.speaker
        }
        for (speaker, voice, _) in ranked where mapping[speaker] == nil && !mapping.values.contains(voice) {
            mapping[speaker] = voice
        }
        // The rest, longest heard first: the same person as a known speaker, or someone new.
        let unknown = Set(local.values).filter { mapping[$0] == nil }.sorted { (heardFor[$0] ?? 0) > (heardFor[$1] ?? 0) }
        for speaker in unknown {
            let nearest = mapping.keys
                .compactMap { known in diarization.centroidCosineDistance(between: speaker, and: known).map { (known, $0) } }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 < Float(voice.sameVoiceDistance), let known = mapping[nearest.0] {
                mapping[speaker] = known
            } else if !mapping.isEmpty, (heardBefore[speaker] ?? 0) < voice.shortestVoiceSeconds {
                // Not someone new yet: heard mostly in the newest sentence. Its sentences wait.
                continue
            } else {
                // The lowest number nobody has: a voice that came and went leaves no gap.
                let taken = Set(spans.compactMap(\.voice)).union(mapping.values)
                mapping[speaker] = (1...).first { !taken.contains($0) } ?? 1
            }
        }
        let usual = spans.compactMap(\.voice).min() ?? mapping.values.min()
        var found: [UInt64: UInt32] = [:]
        for (index, span) in spans.enumerated() {
            // No model speaker for this sentence: keep the voice, or take the first one. Not for
            // the newest sentence: there that guess was mostly wrong, and the next run knows more.
            let newest = span.segment == request.segmentID
            guard let voice = local[index].flatMap({ mapping[$0] }) ?? span.voice ?? (newest ? nil : usual),
                  span.voice != voice else { continue }
            spans[index].voice = voice
            found[span.segment] = voice
        }
        return (found, Date().timeIntervalSince(began), true)
    }

    /// Sound with its silences cut out, and a way to find where a moment of the
    /// original landed in it.
    struct Speech {
        var samples: [Float]
        /// For each 20 ms frame of the original: how many frames were kept before it.
        var keptBefore: [Int]
        static let frame = 320

        func position(of seconds: Double) -> Double {
            guard !keptBefore.isEmpty else { return 0 }
            let index = min(max(Int(seconds * WireProtocol.sampleRate) / Self.frame, 0), keptBefore.count - 1)
            return Double(keptBefore[index] * Self.frame) / WireProtocol.sampleRate
        }
    }

    /// Keeps every frame within 0.3 s of sound that is clearly above the quietest level.
    static func withoutSilence(_ samples: [Float]) -> Speech {
        let frame = Speech.frame
        let count = samples.count / frame
        guard count > 0 else { return Speech(samples: samples, keptBefore: []) }
        var energy = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var sum: Float = 0
            for sample in samples[(index * frame)..<((index + 1) * frame)] { sum += sample * sample }
            energy[index] = sum / Float(frame)
        }
        let threshold = max((energy.max() ?? 0) * 0.002, 1e-7)
        let reach = 15
        var active = [Bool](repeating: false, count: count)
        for index in 0..<count where energy[index] > threshold {
            for near in max(0, index - reach)...min(count - 1, index + reach) { active[near] = true }
        }
        var kept: [Float] = []
        kept.reserveCapacity(samples.count)
        var keptBefore = [Int](repeating: 0, count: count)
        var total = 0
        for index in 0..<count {
            keptBefore[index] = total
            if active[index] {
                kept.append(contentsOf: samples[(index * frame)..<((index + 1) * frame)])
                total += 1
            }
        }
        return Speech(samples: kept, keptBefore: keptBefore)
    }
}
