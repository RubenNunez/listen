import CoreML
import FluidAudio
import Foundation

/// Native Supertonic 3. Files come only from Listen's verified pinned download;
/// FluidAudio never receives a partial pack that could trigger its own downloader.
enum SupertonicVoiceFiles {
    typealias File = PocketVoiceFiles.File
    static let repository = "FluidInference/supertonic-3-coreml"
    static let revision = "2b5b939dfa1bca362c5212dcafeb8aadde90b1bc"
    static var base: URL { LocalVoice.root.appending(path: "supertonic-3", directoryHint: .isDirectory) }
    static func folder(in base: URL = SupertonicVoiceFiles.base) -> URL { base.appending(path: Repo.supertonic3.folderName, directoryHint: .isDirectory) }
    private static func marker(_ base: URL) -> URL { base.appending(path: ".listen-complete") }

    // Manifest below is generated from the pinned HF file tree, with local SHA-256
    // also recorded for text files. V2 bundles fix the old chunk-tail padding leak.
    static let files: [File] = [
        File(path: "DurationPredictor_v2.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "d8bfa7996e1b4c0e26c9c1edc3861f28726bbd30f74d4a7519e69ef78c1b2d1c"),
        File(path: "DurationPredictor_v2.mlmodelc/coremldata.bin", bytes: 426, sha256: "f4f1630670632dd149787fb6ea4f934ab915c390a88d87a4e825ca58f041b4b2"),
        File(path: "DurationPredictor_v2.mlmodelc/model.mil", bytes: 105229, sha256: "0c9c67236d575b2b8f0077815e0b57a30cc7d770dead3ad068fc060c68e33920"),
        File(path: "DurationPredictor_v2.mlmodelc/weights/weight.bin", bytes: 1797952, sha256: "7f709c544087966d6b2538ac50b7a4014d6e1049e21d713cf3bc71c4c5b9307c"),
        File(path: "LICENSE", bytes: 15007, sha256: "0d944a9110fed9a9602d60e0423a272903e7bd21ab060490774efc77c2275e9f"),
        File(path: "TextEncoder_v2.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "973b90afda5d837c037cef2dcbbda275f005eeeb55f2712ca6fbcfa68220f5b5"),
        File(path: "TextEncoder_v2.mlmodelc/coremldata.bin", bytes: 432, sha256: "c1177e3e03cc4130e5dca18eb007f20573bf95d3938abf62ab2d3470b04cbe7f"),
        File(path: "TextEncoder_v2.mlmodelc/model.mil", bytes: 158547, sha256: "b0fd5d9a34a301221194a90aa2ba9133b34ed981209f5e6c7b89733c1491074b"),
        File(path: "TextEncoder_v2.mlmodelc/weights/weight.bin", bytes: 18022016, sha256: "7c7afa5d02426a8a363c9cef0e27ce64a5c57a67d1a59f60aac0ac58ffb9877f"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L128_int4.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "d86b6a6763b342d1e4921ea055e6dfbad082f76643d1a403cce66d2aa2974a2c"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L128_int4.mlmodelc/coremldata.bin", bytes: 553, sha256: "2e3b78de95e365609e870fe6af76c5f5e87c1a6787871cf3954d445af085f85f"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L128_int4.mlmodelc/model.mil", bytes: 373376, sha256: "889e69177fea30c276cbff98e752275fddb2a80085a5b30db128b20cad8773a7"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L128_int4.mlmodelc/weights/weight.bin", bytes: 32166112, sha256: "c6173731642fd2eb40f759a970d4cdea459c0368cc37a29d0b4c1d19fd1ca90a"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L256_int4.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "80775fe9f4b06a17dd7ac9454daf62181ac260df24f4e197bd1a9914d0ba24db"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L256_int4.mlmodelc/coremldata.bin", bytes: 553, sha256: "7cb6db0a28a0efa6e50248f9ecdb07b4ae8a7e078873eadb2a87f476a310d758"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L256_int4.mlmodelc/model.mil", bytes: 373595, sha256: "750a25ff6939e27506348a62b8ef14e34495356fb73ba4925f1f7be8d6b953fe"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L256_int4.mlmodelc/weights/weight.bin", bytes: 32167200, sha256: "e9574dcce25fd7d3f4a68b2257f74fea5227ccd9e6843d53f0e9f5476aa8dc87"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L512_int4.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "439f6850aff99365baae7651e0859e65fde08280fbb6ddb18a7d6fc5cc905d31"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L512_int4.mlmodelc/coremldata.bin", bytes: 553, sha256: "d8f370e473dafa80fdb00ba827eb87b46b123e5fab8c7c41f7e014140c4d9fce"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L512_int4.mlmodelc/model.mil", bytes: 373595, sha256: "9173a49f4489ac5317e750cc565a4919786052375031284c4216a55fc523c621"),
        File(path: "VectorEstimatorVariants/VectorEstimator_v2_L512_int4.mlmodelc/weights/weight.bin", bytes: 32168224, sha256: "75621d8dcab2fb486fcf7424bf44f472c84f55fdabe5b9b9a5fa781447c7a860"),
        File(path: "Vocoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "4fe1b825137629a96dc58a1339bc4ece32041b755f99d638f21a153f2e7faed6"),
        File(path: "Vocoder.mlmodelc/coremldata.bin", bytes: 388, sha256: "dbf54fc98879ee1c9a213452e16d09367f3c34ad489b175bcae7ef5f74f8d121"),
        File(path: "Vocoder.mlmodelc/model.mil", bytes: 75626, sha256: "5f57d6b16a4ee7237e046a423c265aa2c487857eb0003bba1c89fa66e577353f"),
        File(path: "Vocoder.mlmodelc/weights/weight.bin", bytes: 50672512, sha256: "b45e4c17a45cc4de30dcedae9f662548aa35f8f9763632c342b8bbef3089fcee"),
        File(path: "tts.json", bytes: 8253, sha256: "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"),
        File(path: "unicode_indexer.json", bytes: 277676, sha256: "9bf7346e43883a81f8645c81224f786d43c5b57f3641f6e7671a7d6c493cb24f"),
        File(path: "voice_styles/F2.json", bytes: 292423, sha256: "7c722c6a72707b1a77f035d67f0d1351ba187738e06f7683e8c72b1df3477fc6"),
    ]

    static func source(_ file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }

    static func complete(_ files: [File] = SupertonicVoiceFiles.files, base: URL = SupertonicVoiceFiles.base) -> URL? {
        guard (try? Data(contentsOf: marker(base))) == Data(revision.utf8) else { return nil }
        let directory = folder(in: base)
        return files.allSatisfy { file in
            (try? directory.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes)
        } ? directory : nil
    }

    static func download(_ files: [File] = SupertonicVoiceFiles.files, base: URL = SupertonicVoiceFiles.base,
        fetch: PocketVoiceFiles.Fetch = { try await PocketFileFetch(destination: $1, written: $2).run($0) },
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default, directory = folder(in: base)
        let staging = base.appending(path: "Staging", directoryHint: .isDirectory)
        try? fm.removeItem(at: marker(base))
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let total = Double(max(files.reduce(Int64(0)) { $0 + $1.bytes }, 1))
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appending(path: file.path)
            // Verify existing files too: a cancelled pack cannot gain a completion
            // marker merely because a corrupt file happens to have the right size.
            if (try? PocketVoiceFiles.verify(destination, file)) == nil {
                let partial = staging.appending(path: UUID().uuidString), before = done
                try await fetch(source(file), partial) { progress(Double(before + min($0, file.bytes)) / total) }
                try Task.checkCancellation()
                try PocketVoiceFiles.verify(partial, file)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: partial, to: destination)
            }
            done += file.bytes
            progress(Double(done) / total)
        }
        try Task.checkCancellation()
        var url = base, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try Data(revision.utf8).write(to: marker(base), options: .atomic)
    }

    static func remove(base: URL = SupertonicVoiceFiles.base) {
        try? FileManager.default.removeItem(at: marker(base))
        try? FileManager.default.removeItem(at: base)
    }
}

/// One fixed female stock voice, eight denoising steps. Fixed-shape Int4 + CPU/ANE
/// only: the dynamic FP16 GPU build crashed in MPSGraph during our Mac probe.
actor SupertonicVoice: LocalVoiceSynthesizing {
    static let shared = SupertonicVoice()
    private var manager: Supertonic3Manager?
    private var loading: Task<Supertonic3Manager, any Error>?
    private var last: Task<Void, Never>?
    private var epoch = 0
    private var warmed = false
    private var removing = false

    func prepare(model: String, voice: String) async throws {
        _ = try await load(model, voice: voice)
        guard !warmed else { return }
        let started = epoch
        // First inference also loads the lazily selected latent bucket. No playback.
        for try await _ in try await speech("Hallo.", model: model, voice: voice, language: .de) {}
        try Task.checkCancellation()
        if epoch == started { warmed = true }
    }

    func speech(_ text: String, model: String, voice: String, language: Language) async throws
        -> AsyncThrowingStream<LocalVoiceChunk, any Error>
    {
        let manager = try await load(model, voice: voice)
        let style = try Supertonic3VoiceStyle.load(from: SupertonicVoiceFiles.folder().appending(path: "voice_styles/\(voice).json"))
        let parts = try Self.parts(text, language: language)
        let previous = last, started = epoch
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LocalVoiceChunk.self)
        let job = Task {
            // SDK synthesis does not check task cancellation internally. Wait until
            // the preceding bounded call exits before starting another on its models.
            await previous?.value
            do {
                for (index, part) in parts.enumerated() {
                    try Task.checkCancellation()
                    guard epoch == started else { throw CancellationError() }
                    let input = Self.continuationInput(part, continues: index < parts.count - 1)
                    let audio = try await manager.synthesize(text: input, language: language.rawValue, style: style,
                                                             totalSteps: 8, speed: 1.05)
                    try Task.checkCancellation()
                    guard epoch == started else { throw CancellationError() }
                    guard !audio.samples.isEmpty, audio.samples.allSatisfy(\.isFinite) else {
                        throw LocalVoiceUnavailable(message: "Supertonic could not generate this speech.")
                    }
                    // The model already supplies breathing room. Stacking another
                    // fixed pad at every bounded call makes clause joins sound broken.
                    let samples = Self.trimmingPadding(audio.samples, contextMilliseconds: 40, minimumTrimMilliseconds: 40)
                    continuation.yield(LocalVoiceChunk(samples: samples, sampleRate: 44_100))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { if case .cancelled = $0 { job.cancel() } }
        last = job
        return stream
    }

    /// Each bounded SDK call includes near-silent edges. Concatenating those edges
    /// created roughly one-second breaks even with a full player queue. Keep 80 ms
    /// around audible material and only remove long outer padding, never an internal
    /// pause or a whole quiet result. The low threshold preserves soft consonants.
    nonisolated static func trimmingPadding(_ samples: [Float], sampleRate: Int = 44_100,
                                            contextMilliseconds: Int = 80, minimumTrimMilliseconds: Int = 120) -> [Float] {
        guard sampleRate > 0, !samples.isEmpty else { return samples }
        let block = max(1, sampleRate / 100)
        var first: Int?, last = 0
        for start in stride(from: 0, to: samples.count, by: block) {
            let end = min(samples.count, start + block)
            let power = samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(end - start)
            if power > 0.000_2 * 0.000_2 { first = first ?? start; last = end }
        }
        guard let first else { return samples }
        let keep = sampleRate * max(0, contextMilliseconds) / 1000
        let minimum = sampleRate * max(0, minimumTrimMilliseconds) / 1000
        let leading = max(0, first - keep)
        let trailing = max(0, samples.count - last - keep)
        let start = leading >= minimum ? leading : 0
        let end = trailing >= minimum ? samples.count - trailing : samples.count
        return Array(samples[start..<end])
    }

    func unload() async {
        epoch += 1
        let initializing = loading
        initializing?.cancel()
        loading = nil
        warmed = false
        let previous = manager, pending = last
        manager = nil
        pending?.cancel()
        await pending?.value
        // initialize() can be in flight across actor awaits. Deleting its assets
        // before it exits could make the SDK's missing-file path download anew.
        _ = await initializing?.result
        await previous?.cleanup()
    }

    func removeFiles() async {
        guard !removing else { return }
        removing = true
        defer { removing = false }
        await unload()
        SupertonicVoiceFiles.remove()
    }

    private func load(_ model: String, voice: String) async throws -> Supertonic3Manager {
        guard model == TalkBack.supertonic, TalkBack.voices(for: model).contains(voice) else {
            throw LocalVoiceUnavailable(message: "The system names a local voice this app does not offer.")
        }
        if let reason = LocalVoice.cannotRun(model) { throw LocalVoiceUnavailable(message: reason) }
        guard !removing else { throw CancellationError() }
        guard SupertonicVoiceFiles.complete() != nil else {
            throw LocalVoiceUnavailable(message: "The Supertonic voice is not downloaded.")
        }
        try Task.checkCancellation()
        if let manager { return manager }
        let started = epoch
        let task: Task<Supertonic3Manager, any Error>
        if let loading { task = loading } else {
            let base = SupertonicVoiceFiles.base
            task = Task.detached {
                try Task.checkCancellation()
                let manager = Supertonic3Manager(directory: base, computeUnits: .cpuAndNeuralEngine,
                                                 vectorEstimator: .aneBucketed(.int4))
                try await manager.initialize()
                if Task.isCancelled { await manager.cleanup(); throw CancellationError() }
                return manager
            }
            loading = task
        }
        do {
            let loaded = try await task.value
            guard epoch == started else { await loaded.cleanup(); throw CancellationError() }
            loading = nil
            manager = loaded
            try Task.checkCancellation()
            return loaded
        } catch {
            if epoch == started { loading = nil }
            throw error
        }
    }

    /// Expose bounded utterances as chunks: the SDK otherwise returns a complete
    /// paragraph at once. Preserve every word, including an unusually long token;
    /// splitting that token also prevents the SDK's fixed 128-scalar truncation.
    static func parts(_ text: String, language: Language) throws -> [String] {
        let text = SpokenReply.spelledOut(text, language: language)
        // Count compatibility decompositions and the SDK's expanding substitutions
        // before packing. 70 source graphemes alone is unsafe for repeated umlauts
        // or @ signs in a long identifier.
        func cost(_ value: String) -> Int {
            value.decomposedStringWithCompatibilityMapping
                .replacingOccurrences(of: "@", with: " at ")
                .replacingOccurrences(of: "e.g.,", with: "for example, ")
                .replacingOccurrences(of: "i.e.,", with: "that is, ").unicodeScalars.count
        }
        var result: [String] = []
        // Leave room for one continuation comma within the SDK's clean 70-scalar cap.
        let limit = 69
        let linkedWords: Set<String> = language == .de
            ? ["kein", "keine", "keinen", "keinem", "keiner", "keines", "nicht", "ein", "eine", "einen", "einem", "einer", "eines", "der", "die", "das", "dem", "den", "des", "im", "in", "am", "an", "auf", "aus", "mit", "ohne", "von", "vom", "zum", "zur", "für", "über", "unter", "und", "oder", "aber", "dass"]
            : ["no", "not", "a", "an", "the", "of", "to", "for", "with", "without", "from", "in", "on", "at", "by", "and", "or", "but", "that", "this", "these", "those"]
        let clauseStarts: Set<String> = language == .de
            ? ["das", "der", "die", "den", "dem", "welche", "welcher", "welches", "weil", "wenn", "obwohl", "während", "damit", "dass", "aber", "sondern"]
            : ["which", "who", "whose", "because", "although", "while", "if", "but", "whereas"]
        func phrased(_ sentence: String) -> [String]? {
            let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count > 1, words.allSatisfy({ cost($0) <= limit }) else { return nil }
            var scores = [Int](repeating: Int.max, count: words.count + 1)
            var next = [Int](repeating: words.count, count: words.count)
            scores[words.count] = 0
            for start in words.indices.reversed() {
                var part = ""
                for end in (start + 1)...words.count {
                    part += (part.isEmpty ? "" : " ") + words[end - 1]
                    let length = cost(part)
                    guard length <= limit else { break }
                    guard scores[end] != Int.max else { continue }
                    let last = words[end - 1]
                    let punctuation = last.last.map { ",;:".contains($0) } == true
                    let clause = end < words.count && punctuation && clauseStarts.contains(words[end].lowercased())
                    let dangling = linkedWords.contains(last.lowercased())
                    // Minimize model calls while preferring actual clause boundaries
                    // over arbitrary maximum-length cuts. Never strand "keine"/"the".
                    let boundary = end == words.count ? 0 : clause ? -35 : punctuation ? 0 : 90
                    let score = scores[end] + 120 + max(0, 24 - length) * 4 + abs(54 - length) / 4
                        + boundary + (dangling ? 500 : 0)
                    if score < scores[start] { scores[start] = score; next[start] = end }
                }
            }
            guard scores[0] != Int.max else { return nil }
            var parts: [String] = [], at = 0
            while at < words.count {
                let end = next[at]
                guard end > at else { return nil }
                parts.append(words[at..<end].joined(separator: " ")); at = end
            }
            return parts
        }
        for sentence in SpokenReply.sentences(text) {
            if let parts = phrased(sentence) {
                result += parts
                continue
            }
            let start = result.count
            var current = ""
            for word in sentence.split(whereSeparator: \.isWhitespace).map(String.init) {
                var remainder = word
                while cost(remainder) > limit {
                    if !current.isEmpty { result.append(current); current = "" }
                    var cut = remainder.startIndex, next = cut
                    while next < remainder.endIndex {
                        next = remainder.index(after: next)
                        if cost(String(remainder[..<next])) > limit { break }
                        cut = next
                    }
                    // One pathological grapheme cannot be split safely. Refuse it
                    // as a part rather than silently dropping following words.
                    guard cut != remainder.startIndex else {
                        throw LocalVoiceUnavailable(message: "Supertonic cannot speak this text safely. Shorten the unusual character sequence.")
                    }
                    result.append(String(remainder[..<cut]))
                    remainder = String(remainder[cut...])
                }
                if cost(current) + cost(remainder) + (current.isEmpty ? 0 : 1) > limit {
                    result.append(current); current = ""
                }
                current = current.isEmpty ? remainder : current + " " + remainder
            }
            if !current.isEmpty { result.append(current) }
            guard result.count > start + 1 else { continue }
            // Rebalance a dangling function word or a tiny final fragment, within this
            // sentence only. Keep every word and the same bounded model input size.
            for index in stride(from: result.count - 2, through: start, by: -1) {
                let left = result[index], right = result[index + 1]
                let last = left.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                guard linkedWords.contains(last.lowercased()) || cost(right) < 22 else { continue }
                let words = (left + " " + right).split(whereSeparator: \.isWhitespace).map(String.init)
                var best: (left: String, right: String, score: Int)?
                for cut in 1..<words.count {
                    guard !linkedWords.contains(words[cut - 1].lowercased()) else { continue }
                    let a = words[..<cut].joined(separator: " "), b = words[cut...].joined(separator: " ")
                    guard cost(a) <= limit, cost(b) <= limit else { continue }
                    let punctuation = words[cut - 1].last.map { ",;:".contains($0) } == true
                    let score = abs(cost(a) - cost(b)) + (punctuation ? 0 : 20)
                    if best == nil || score < best!.score { best = (a, b, score) }
                }
                if let best { result[index] = best.left; result[index + 1] = best.right }
            }
        }
        return result
    }

    /// The SDK otherwise adds a full stop to every unpunctuated chunk. A bounded
    /// mid-sentence continuation should not acquire sentence-final intonation.
    static func continuationInput(_ part: String, continues: Bool) -> String {
        guard continues, let last = part.last, last.isLetter || last.isNumber else { return part }
        return part + ","
    }
}
