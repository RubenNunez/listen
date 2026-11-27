import CryptoKit
import Foundation
import Testing

@testable import Listen

// Normal checks use synthetic fixtures: no network, model loading or sound output.
// The explicitly gated native probe below requires already installed models and muted I/O.

/// Stands in for the network: writes what it was told to, and counts.
private actor FetchDouble {
    private let contents: [String: Data]
    private(set) var fetched: [String] = []
    private var stallsAt: String?

    init(_ contents: [String: Data], stallsAt: String? = nil) {
        self.contents = contents
        self.stallsAt = stallsAt
    }

    func fetch(_ source: URL, _ destination: URL, _ written: @Sendable (Int64) -> Void) async throws {
        let path = source.path.components(separatedBy: PocketVoiceFiles.pack + "/").last ?? ""
        fetched.append(path)
        if path == stallsAt { try await Task.sleep(for: .seconds(30)) }
        guard let data = contents[path] else { throw URLError(.fileDoesNotExist) }
        try data.write(to: destination)
        written(Int64(data.count))
    }
}

private func catalogue(_ contents: [String: Data]) -> [PocketVoiceFiles.File] {
    contents.keys.sorted().map { path in
        let data = contents[path]!
        return .init(path: path, bytes: Int64(data.count),
                     sha256: path.hasSuffix(".json") ? nil : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not reached")
}

/// A sink for progress values reported from the download's own task.
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [Double] = []
    func note(_ value: Double) { lock.withLock { reported.append(value) } }
    var values: [Double] { lock.withLock { reported } }
}

@Suite struct PocketVoiceCatalogueTests {
    private let pocket = TalkBack.pocketGerman

    @Test func theCatalogueNamesItsEnginesAndRoutesEachModelToItsOwnSynthesizer() {
        #expect(TalkBack.model(pocket)?.family == .pocket)
        #expect(TalkBack.models.filter { $0.family == .qwen }.count == 3)
        #expect(TalkBack.synthesizer(for: pocket) is PocketVoice)
        for model in TalkBack.models where model.family == .qwen { #expect(TalkBack.synthesizer(for: model.id) is QwenVoice) }
        #expect(Set(TalkBack.models.map(\.slug)).count == TalkBack.models.count && !TalkBack.models.contains { $0.slug.isEmpty || $0.short.isEmpty })
        // The default stays what earlier systems were saved with.
        #expect(TalkBack.defaultModel == "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit" && TalkBack.defaultVoice == "Serena")
    }

    @MainActor @Test func aPocketChoiceSpeaksThroughTheLocalSpeakerAndTheDeviceVoiceDoesNot() {
        var configuration = VoiceAssistantConfiguration(enabled: true)
        configuration.talkBackEngine = .local
        configuration.talkBackModel = pocket
        configuration.talkBackVoice = "alba"
        // A double, so making the speaker loads nothing.
        let speaker = TalkBack.speaker(for: configuration, synthesizer: RefusingVoice())
        #expect(speaker is LocalVoiceSpeaker)
        speaker.retire()
        configuration.talkBackEngine = .system
        #expect(TalkBack.speaker(for: configuration, synthesizer: RefusingVoice()) is AssistantSpeaker)
    }

    @Test func aVoiceIsOnlyValidUnderItsOwnModel() throws {
        var configuration = VoiceAssistantConfiguration(enabled: true)
        configuration.talkBackEngine = .local
        configuration.talkBackModel = pocket
        for voice in ["alba", "cosette", "fantine", "eponine"] {
            configuration.talkBackVoice = voice
            try configuration.validate()
            let again = try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: JSONEncoder().encode(configuration))
            #expect(again == configuration)
        }
        // A Qwen speaker under Pocket TTS, a Pocket voice under Qwen, and a voice the pack
        // has but this app does not fetch.
        for (model, voice) in [(pocket, "Serena"), (TalkBack.defaultModel, "alba"), (pocket, "javert"), (pocket, "Alba")] {
            configuration.talkBackModel = model
            configuration.talkBackVoice = voice
            #expect(throws: (any Error).self) { try configuration.validate() }
        }
    }

    @Test func configurationsSavedBeforePocketStillDecodeUnchanged() throws {
        // As written by earlier builds: a male Qwen speaker, and the device voice.
        for (json, engine, voice) in [
            (#"{"enabled":true,"talkBackEngine":"local","talkBackModel":"mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit","talkBackVoice":"Ryan"}"#, TalkBackEngine.local, "Ryan"),
            (#"{"enabled":true,"talkBackEngine":"system","talkBackModel":"mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit","talkBackVoice":"Uncle_Fu"}"#, .system, "Uncle_Fu"),
        ] {
            let old = try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: Data(json.utf8))
            try old.validate()
            #expect(old.talkBackEngine == engine && old.talkBackVoice == voice)
            let again = try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: JSONEncoder().encode(old))
            #expect(again == old, "reading and writing an old choice does not rewrite it")
        }
        // No new stored field: what an older build reads has the keys it knows.
        let keys = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceAssistantConfiguration())) as? [String: Any]).keys
        #expect(keys.filter { $0.hasPrefix("talkBack") }.sorted() == ["talkBackEngine", "talkBackModel", "talkBackVoice"])
    }

    @Test func aSystemWithAPocketVoiceExportsAndImportsAndAMismatchedOneIsRefused() throws {
        var voice = ListenSystem.builtIns.first { $0.id == "voice-assistant" }!
        voice.configuration?.conversation?.talkBackEngine = .local
        voice.configuration?.conversation?.talkBackModel = pocket
        voice.configuration?.conversation?.talkBackVoice = "fantine"
        let data = try SystemPackage(system: voice, defaults: SystemConfig()).data()
        let restored = try SystemPackage.read(data).system.configuration?.conversation
        #expect(restored?.talkBackModel == pocket && restored?.talkBackVoice == "fantine" && restored?.talkBackEngine == .local)

        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var definition = raw["system"] as! [String: Any]
        var settings = definition["settings"] as! [String: Any]
        var conversation = settings["conversation"] as! [String: Any]
        conversation["talkBackVoice"] = "Serena"
        settings["conversation"] = conversation; definition["settings"] = settings; raw["system"] = definition
        #expect(throws: (any Error).self) { try SystemPackage.read(JSONSerialization.data(withJSONObject: raw)) }
    }

    @Test func pocketSpeaksGermanOnlyAndSaysSo() {
        #expect(TalkBack.unsupported(pocket, language: .de) == nil)
        #expect(TalkBack.unsupported(pocket, language: .en) != nil)
        #expect(TalkBack.unsupported(TalkBack.defaultModel, language: .en) == nil)
    }

    @Test func phononIsNamedAsUnavailableAndCanBeNeitherChosenNorSaved() {
        #expect(TalkBack.unavailable.map(\.title) == ["Phonon 40M-DE"])
        #expect(!TalkBack.models.contains { $0.title.localizedCaseInsensitiveContains("phonon") || $0.id.localizedCaseInsensitiveContains("phonon") })
        var configuration = VoiceAssistantConfiguration(enabled: true)
        configuration.talkBackModel = "Phonon 40M-DE"
        #expect(throws: (any Error).self) { try configuration.validate() }
    }

    @Test func theRealSynthesizersRefuseWhatIsNotTheirsWithoutLoadingAnything() async {
        // Each of these is turned away before any file is read.
        await #expect(throws: LocalVoiceUnavailable.self) {
            _ = try await PocketVoice().speech("Hello.", model: TalkBack.pocketGerman, voice: "alba", language: .en)
        }
        await #expect(throws: LocalVoiceUnavailable.self) {
            _ = try await PocketVoice().speech("Hallo.", model: TalkBack.pocketGerman, voice: "Serena", language: .de)
        }
        await #expect(throws: LocalVoiceUnavailable.self) {
            _ = try await PocketVoice().speech("Hallo.", model: TalkBack.defaultModel, voice: "Serena", language: .de)
        }
        await #expect(throws: LocalVoiceUnavailable.self) {
            try await QwenVoice().prepare(model: TalkBack.pocketGerman, voice: "alba")
        }
    }
}

@MainActor @Suite struct NativePocketProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_POCKET_NATIVE_PROBE"] == "1"), .timeLimit(.minutes(3)))
    func installedFemaleVoicesAndCancellationStayUsableWithoutAudioDevices() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        try #require(PocketVoiceFiles.complete() != nil, "No automatic model download in a benchmark.")
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LISTEN_POCKET_NATIVE_OUT"]), isDirectory: true)
        try #require(root.path.contains("/runs/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = PocketVoice(), model = TalkBack.pocketGerman
        var rows: [[String: Any]] = []
        func measure(_ voice: String, phase: String) async throws {
            let began = ProcessInfo.processInfo.systemUptime
            let stream = try await engine.speech("Ja, ich kann auch sprechen. Du kannst einfach mit mir reden.", model: model, voice: voice, language: .de)
            var samples: [Float] = [], first: Double?, rate = 0.0
            for try await chunk in stream {
                try #require(chunk.samples.allSatisfy(\.isFinite) && chunk.sampleRate == 24_000)
                if first == nil { first = ProcessInfo.processInfo.systemUptime - began }
                samples += chunk.samples; rate = chunk.sampleRate
            }
            try #require(!samples.isEmpty && rate > 0)
            let elapsed = ProcessInfo.processInfo.systemUptime - began, seconds = Double(samples.count) / rate
            try samples.withUnsafeBytes { try Data($0).write(to: root.appending(path: "\(phase)-\(voice).f32")) }
            rows.append(["voice": voice, "phase": phase, "first_audio_s": try #require(first), "generation_s": elapsed,
                         "audio_s": seconds, "real_time_factor": elapsed / seconds, "samples": samples.count, "sample_rate": rate])
        }
        do {
            for voice in TalkBack.pocketVoices { try await measure(voice, phase: "initial") }
            let (signal, started) = AsyncStream.makeStream(of: Void.self)
            let cancelled = Task {
                defer { started.finish() }
                let stream = try await engine.speech(String(repeating: "Diese synthetische Antwort wird absichtlich unterbrochen. ", count: 12), model: model, voice: "alba", language: .de)
                for try await _ in stream { started.yield(()); try Task.checkCancellation() }
            }
            var received = false
            for await _ in signal { received = true; break }
            cancelled.cancel()
            do { try await cancelled.value } catch is CancellationError {} // Other errors fail the probe.
            try #require(received)
            await engine.unload()
            try await measure("cosette", phase: "after-cancel-unload")
            await engine.unload()
            let receipt: [String: Any] = ["rows": rows, "cancel_after_first_frame": true, "reload_completed": true,
                "measurement": "Synthetic installed native Pocket TTS, file-only PCM; no microphone, playback, network, acoustic echo or naturalness grade."]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "results.json"))
        } catch { await engine.unload(); throw error }
    }
}

/// A synthesizer that never speaks, for checks that only need a speaker to exist.
private struct RefusingVoice: LocalVoiceSynthesizing {
    func prepare(model: String, voice: String) async throws { throw LocalVoiceUnavailable(message: "Synthetic refusal.") }
    func speech(_ text: String, model: String, voice: String, language: Language) async throws
        -> AsyncThrowingStream<LocalVoiceChunk, any Error>
    {
        throw LocalVoiceUnavailable(message: "Synthetic refusal.")
    }
}

@Suite struct PocketVoiceFilesTests {
    private let contents: [String: Data] = [
        "manifest.json": Data(#"{"synthetic":true}"#.utf8),
        "cond_prefill.mlmodelc/weights/weight.bin": Data(repeating: 1, count: 4096),
        "flowlm_step.mlmodelc/weights/weight.bin": Data(repeating: 2, count: 8192),
        "constants_bin/alba.safetensors": Data(repeating: 3, count: 1024),
    ]

    private func base() -> URL { URL.temporaryDirectory.appending(path: "pocket-voice-\(UUID())", directoryHint: .isDirectory) }

    @Test func everyFileComesFromOnePinnedRevisionOfTheOfficialRepository() throws {
        let hexadecimal = Set("0123456789abcdef")
        #expect(PocketVoiceFiles.revision.count == 40 && PocketVoiceFiles.revision.allSatisfy(hexadecimal.contains), "a commit, not a branch")
        #expect(PocketVoiceFiles.libraryPack == PocketVoiceFiles.pack, "the linked FluidAudio looks where these files are put")
        let prefix = "https://huggingface.co/FluidInference/pocket-tts-coreml/resolve/\(PocketVoiceFiles.revision)/v2.1/german/"
        for file in PocketVoiceFiles.files {
            #expect(PocketVoiceFiles.source(file).absoluteString == prefix + file.path)
            #expect(file.bytes > 0 && !file.path.hasPrefix("/") && !file.path.contains("..") && !file.path.contains("//"))
            #expect(file.sha256.map { $0.count == 64 && $0.allSatisfy(hexadecimal.contains) } ?? true)
            // Only small text files go without a hash.
            #expect(file.sha256 != nil || file.bytes < 1_000_000)
        }
        let paths = Set(PocketVoiceFiles.files.map(\.path))
        #expect(paths.count == PocketVoiceFiles.files.count)
        // What FluidAudio 0.18.4 needs on disk for the default placement, so it fetches nothing itself.
        for model in ["cond_prefill", "flowlm_step", "flow_decoder_fused", "mimi_decoder"] {
            for part in ["coremldata.bin", "model.mil", "weights/weight.bin"] { #expect(paths.contains("\(model).mlmodelc/\(part)")) }
        }
        for constant in ["bos_emb.bin", "text_embed_table.bin", "tokenizer.model", "bos_before_voice.bin"] {
            #expect(paths.contains("constants_bin/" + constant))
        }
        // The voices on offer are exactly the voices fetched: none is left for a later, silent download.
        let voices = paths.filter { $0.hasSuffix(".safetensors") }.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".safetensors", with: "") }
        #expect(Set(voices) == Set(TalkBack.pocketVoices) && TalkBack.comparedVoices(for: TalkBack.pocketGerman) == TalkBack.pocketVoices)
        let gigabytes = Double(PocketVoiceFiles.files.reduce(0) { $0 + $1.bytes }) / 1_000_000_000
        #expect(abs(gigabytes - (TalkBack.model(TalkBack.pocketGerman)?.gigabytes ?? 0)) < 0.05, "the size shown is the size fetched")
    }

    @Test func aDownloadIsCompleteOnlyAfterEveryFileWasCheckedAndIsThenReusedOffline() async throws {
        let base = base(), files = catalogue(contents), network = FetchDouble(contents), progress = Progress()
        defer { PocketVoiceFiles.remove(base: base) }
        #expect(PocketVoiceFiles.complete(files, base: base) == nil)
        try await PocketVoiceFiles.download(files, base: base, fetch: { try await network.fetch($0, $1, $2) }, progress: { progress.note($0) })
        let folder = try #require(PocketVoiceFiles.complete(files, base: base))
        #expect(Array(folder.standardizedFileURL.pathComponents.suffix(4)) == ["Models", "pocket-tts", "v2.1", "german"],
                "the layout FluidAudio 0.18.4 reads")
        for (path, data) in contents { #expect(try Data(contentsOf: folder.appending(path: path)) == data) }
        #expect(await network.fetched.count == files.count)
        #expect(progress.values.last == 1 && progress.values == progress.values.sorted())
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "Staging").path))

        // Again, with a network that has nothing: no request is made.
        let offline = FetchDouble([:])
        try await PocketVoiceFiles.download(files, base: base, fetch: { try await offline.fetch($0, $1, $2) }, progress: { _ in })
        #expect(await offline.fetched.isEmpty && PocketVoiceFiles.complete(files, base: base) != nil)

        // A file that went missing is noticed, not papered over by the marker.
        try FileManager.default.removeItem(at: folder.appending(path: "constants_bin/alba.safetensors"))
        #expect(PocketVoiceFiles.complete(files, base: base) == nil)
        PocketVoiceFiles.remove(base: base)
        #expect(PocketVoiceFiles.complete(files, base: base) == nil && !FileManager.default.fileExists(atPath: base.path))
    }

    @Test func aFileThatDiffersFromThePublishedOneIsRejectedAndNotKept() async throws {
        let base = base(), files = catalogue(contents)
        defer { PocketVoiceFiles.remove(base: base) }
        var tampered = contents
        tampered["flowlm_step.mlmodelc/weights/weight.bin"] = Data(repeating: 9, count: 8192)
        let network = FetchDouble(tampered)
        await #expect(throws: LocalVoiceUnavailable.self) {
            try await PocketVoiceFiles.download(files, base: base, fetch: { try await network.fetch($0, $1, $2) }, progress: { _ in })
        }
        #expect(PocketVoiceFiles.complete(files, base: base) == nil)
        let folder = PocketVoiceFiles.folder(in: base)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "flowlm_step.mlmodelc/weights/weight.bin").path))
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "Staging").path))

        // A wrong size is caught as well, for the files without a hash.
        var short = contents
        short["manifest.json"] = Data("{}".utf8)
        let other = FetchDouble(short)
        await #expect(throws: LocalVoiceUnavailable.self) {
            try await PocketVoiceFiles.download(files, base: base, fetch: { try await other.fetch($0, $1, $2) }, progress: { _ in })
        }
        #expect(PocketVoiceFiles.complete(files, base: base) == nil)
    }

    @Test func aCancelledDownloadIsNotReadyAndGoesOnFromItsLastWholeFile() async throws {
        let base = base(), files = catalogue(contents)
        defer { PocketVoiceFiles.remove(base: base) }
        let stalled = files[2].path
        let network = FetchDouble(contents, stallsAt: stalled)
        let download = Task {
            try await PocketVoiceFiles.download(files, base: base, fetch: { try await network.fetch($0, $1, $2) }, progress: { _ in })
        }
        try await eventually { await network.fetched.count == 3 }
        #expect(await network.fetched.last == stalled)
        download.cancel()
        await #expect(throws: (any Error).self) { try await download.value }
        #expect(PocketVoiceFiles.complete(files, base: base) == nil, "a cancelled download never counts as ready")
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "Staging").path))

        let again = FetchDouble(contents)
        try await PocketVoiceFiles.download(files, base: base, fetch: { try await again.fetch($0, $1, $2) }, progress: { _ in })
        #expect(await again.fetched == Array(files.map(\.path)[2...]), "the files already checked are not fetched again")
        #expect(PocketVoiceFiles.complete(files, base: base) != nil)
    }
}

// MARK: A retired voice

/// A synthesizer whose loading the test holds open.
private actor GatedVoice: LocalVoiceSynthesizing {
    private var gate: CheckedContinuation<Void, Never>?
    private var stream: AsyncThrowingStream<LocalVoiceChunk, any Error>.Continuation?
    private(set) var preparing = false
    private(set) var streams = 0

    func prepare(model: String, voice: String) async throws {
        preparing = true
        await withCheckedContinuation { gate = $0 }
        throw LocalVoiceUnavailable(message: "A late failure of the replaced voice.")
    }

    func open() {
        gate?.resume()
        gate = nil
    }

    func speech(_ text: String, model: String, voice: String, language: Language) async throws
        -> AsyncThrowingStream<LocalVoiceChunk, any Error>
    {
        streams += 1
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LocalVoiceChunk.self)
        self.stream = continuation
        return stream
    }

    func speakLate() {
        stream?.yield(LocalVoiceChunk(samples: Array(repeating: 0.03, count: 3000), sampleRate: 1000))
        stream?.finish()
    }
}

@MainActor private final class SilentPlayback: LocalVoicePlayback {
    var scheduled = 0
    func schedule(_ samples: [Float], sampleRate: Double, played: @escaping @MainActor @Sendable () -> Void) throws { scheduled += 1 }
    func stop() {}
}

@MainActor @Suite struct RetiredVoiceTests {
    @Test func aReplacedVoiceIsNotHeardAndReportsNeitherItsLoadingNorItsFailure() async throws {
        let voice = GatedVoice(), playback = SilentPlayback(), status = LocalVoice()
        let speaker = LocalVoiceSpeaker(model: TalkBack.pocketGerman, voice: "alba", synthesizer: voice, playback: playback, status: status)
        var events = 0
        speaker.began = { _ in events += 1 }; speaker.finished = { _ in events += 1 }; speaker.cancelled = { _ in events += 1 }
        try await eventually { await voice.preparing }
        #expect(status.notice == "Loading the local voice…")
        speaker.speak("Diese Antwort gehört der alten Stimme.", response: .init("old"), language: .de)
        try await eventually { await voice.streams == 1 }

        speaker.retire()
        #expect(status.notice == nil, "its loading notice does not outlive it")
        status.notice = "The next voice's own notice."
        await voice.open()
        await voice.speakLate()
        try await Task.sleep(for: .milliseconds(80))
        #expect(events == 0 && playback.scheduled == 0, "late audio and callbacks of the old voice go nowhere")
        #expect(status.notice == "The next voice's own notice.", "its late failure does not overwrite the next voice's state")
    }
}
