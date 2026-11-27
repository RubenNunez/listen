import AVFAudio
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Listen

@MainActor @Suite struct NativeSupertonicProbe {
    /// Same installed model/style/steps/speed; only the documented phrase boundaries
    /// differ. Outputs files, never opens audio devices or grades naturalness itself.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_F2_PHRASE_PROBE"] == "1"), .timeLimit(.minutes(3)))
    func boundedPhraseComparisonWithoutPlayback() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        try #require(SupertonicVoiceFiles.complete() != nil)
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LISTEN_F2_PHRASE_OUT"]), isDirectory: true)
        try #require(root.path.contains("/runs/"))
        struct Fixture: Decodable { let text: String; let before: [String] }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appending(path: "fixtures.json")))
        try #require(fixtures.count == 2)
        await SupertonicVoice.shared.unload()
        let manager = Supertonic3Manager(directory: SupertonicVoiceFiles.base, computeUnits: .cpuAndNeuralEngine, vectorEstimator: .aneBucketed(.int4))
        try await manager.initialize()
        let style = try Supertonic3VoiceStyle.load(from: SupertonicVoiceFiles.folder().appending(path: "voice_styles/F2.json"))
        var rows: [[String: Any]] = []
        do {
            for round in 0..<2 {
                for (index, fixture) in fixtures.enumerated() {
                    let after = try SupertonicVoice.parts(fixture.text, language: .de)
                    for variant in round == 0 ? ["before", "after"] : ["after", "before"] {
                        let parts = variant == "before" ? fixture.before : after
                        try #require(parts.joined(separator: " ") == fixture.text)
                        let began = ProcessInfo.processInfo.systemUptime
                        var samples: [Float] = [], first: Double?, durations: [Double] = []
                        for (partIndex, part) in parts.enumerated() {
                            let text = SupertonicVoice.continuationInput(part, continues: partIndex < parts.count - 1)
                            try #require(text.decomposedStringWithCompatibilityMapping.unicodeScalars.count <= 70)
                            let audio = try await manager.synthesize(text: text, language: "de", style: style, totalSteps: 8, speed: 1.05)
                            try #require(!audio.samples.isEmpty && audio.samples.allSatisfy(\.isFinite))
                            let trimmed = SupertonicVoice.trimmingPadding(audio.samples, contextMilliseconds: 40, minimumTrimMilliseconds: 40)
                            if first == nil { first = ProcessInfo.processInfo.systemUptime - began }
                            durations.append(Double(trimmed.count) / 44_100); samples += trimmed
                        }
                        let file = "f2-\(index)-\(variant)-r\(round).wav"
                        try Self.wav(samples, to: root.appending(path: file))
                        rows.append(["fixture": index, "variant": variant, "round": round, "parts": parts, "file": file,
                                     "first_audio_s": try #require(first), "generation_s": ProcessInfo.processInfo.systemUptime - began,
                                     "audio_s": Double(samples.count) / 44_100, "part_durations_s": durations])
                    }
                }
            }
            await manager.cleanup()
            try JSONSerialization.data(withJSONObject: ["rows": rows, "measurement": "File-only same F2int4,8steps,speed1.05,40msedge context; counterbalanced two rounds, phrase boundaries differ. Unseeded model output. No auditory naturalness score or microphone."], options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "results.json"))
        } catch { await manager.cleanup(); throw error }
    }
    /// Explicitly requested, synthetic, file-only Core ML comparison. Never opens an
    /// input/output device, uses the owner's voice or downloads through the SDK.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_SUPERTONIC_PROBE"] == "1"),
          .timeLimit(.minutes(20)))
    func germanFemaleCoreML() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["LISTEN_SUPERTONIC_ROOT"]), isDirectory: true)
        try #require(root.path.contains("/runs/"))
        let assets = root.appending(path: "assets"), repo = assets.appending(path: "supertonic-3")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        try #require(manifest.revision == "2b5b939dfa1bca362c5212dcafeb8aadde90b1bc")
        for file in manifest.files {
            let data = try Data(contentsOf: repo.appending(path: file.path), options: .mappedIfSafe)
            try #require(data.count == file.bytes)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try #require(sha == file.sha256, "asset verification: \(file.path)")
        }
        let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf:
            URL(fileURLWithPath: try #require(env["LISTEN_SUPERTONIC_TEXTS"]))))
        try #require(texts.count == 3 && texts.allSatisfy { !$0.isEmpty && $0.count <= 300 })
        let style = try Supertonic3VoiceStyle.load(from: repo.appending(path: "voice_styles/F2.json"))
        var rows: [[String: Any]] = []
        // FP16 on GPU crashed inside MPSGraph on this Mac (dynamic-shape
        // expansion during vector estimation). Keep it out of the normal probe;
        // CPU is an explicit quality control, not a transparent GPU fallback.
        let variants = (env["LISTEN_SUPERTONIC_VARIANTS"] ?? "ane-int4,fp16-cpu")
            .split(separator: ",").map(String.init)
        try #require(!variants.isEmpty && variants.allSatisfy { ["ane-int4", "fp16-cpu"].contains($0) })
        for variant in variants {
            let bucketed = variant == "ane-int4"
            // These exact paths must exist before initialize(), otherwise the SDK
            // would silently fetch a moving revision. The manifest covers their files.
            let required = ModelNames.Supertonic3.requiredFiles(veVariant: bucketed ? "ane-int4" : nil)
            for path in required {
                try #require(FileManager.default.fileExists(atPath: repo.appending(path: path).path))
                try #require(manifest.files.contains { $0.path == path || $0.path.hasPrefix(path + "/") })
            }
            let manager = Supertonic3Manager(directory: assets,
                computeUnits: bucketed ? .cpuAndNeuralEngine : .cpuOnly,
                vectorEstimator: bucketed ? .aneBucketed(.int4) : .fp16Dynamic)
            let loading = ProcessInfo.processInfo.systemUptime
            try await manager.initialize()
            let loadSeconds = ProcessInfo.processInfo.systemUptime - loading
            for steps in (bucketed ? [8, 4] : [8]) {
                for round in 0..<2 {
                    for (index, text) in texts.enumerated() {
                        let start = ProcessInfo.processInfo.systemUptime
                        let audio = try await manager.synthesize(text: text, language: "de", style: style,
                                                                 totalSteps: steps, speed: 1.05)
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        try #require(!audio.samples.isEmpty && audio.samples.allSatisfy(\.isFinite))
                        let seconds = Double(audio.samples.count) / 44_100
                        let name = "\(variant)-s\(steps)-r\(round)-t\(index).wav"
                        try Self.wav(audio.samples, to: root.appending(path: name))
                        let row: [String: Any] = ["variant": variant, "steps": steps, "round": round,
                            "sample": index, "voice": "F2", "text": text, "file": name,
                            "sample_rate": 44_100, "load_s": loadSeconds,
                            "first_inference_for_variant": steps == 8 && round == 0 && index == 0,
                            "generation_s": elapsed, "first_deliverable_s": elapsed,
                            "delivery": "whole_utterance_not_streaming", "audio_s": seconds,
                            "real_time_factor": elapsed / seconds,
                            "peak": audio.samples.map(abs).max() ?? 0]
                        rows.append(row)
                        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                            .write(to: root.appending(path: "native-timings.json"), options: .atomic)
                        print("NATIVE_SUPERTONIC", String(decoding: try JSONSerialization.data(withJSONObject: row,
                            options: .sortedKeys), as: UTF8.self))
                    }
                }
            }
            await manager.cleanup()
        }
    }

    private struct Manifest: Decodable {
        let revision: String
        let files: [File]
        struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
    }

    fileprivate static func wav(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                               channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }
}

@MainActor @Suite struct NativeSupertonicAdapterProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_SUPERTONIC_ADAPTER_PROBE"] == "1"),
          .timeLimit(.minutes(10)))
    func theProductionAdapterUsesVerifiedFilesAndPreservesItsRate() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["LISTEN_SUPERTONIC_ROOT"]))
        try #require(LocalVoice.root.path.contains("/runs/") && root.path.contains("/runs/"))
        let staged = root.appending(path: "assets/supertonic-3")
        try await SupertonicVoiceFiles.download(fetch: { source, destination, _ in
            let prefix = "/\(SupertonicVoiceFiles.repository)/resolve/\(SupertonicVoiceFiles.revision)/"
            guard let range = source.path.range(of: prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            let path = String(source.path[range.upperBound...])
            try FileManager.default.copyItem(at: staged.appending(path: path), to: destination)
        }, progress: { _ in })
        try #require(LocalVoice.complete(TalkBack.supertonic) != nil)
        let engine = SupertonicVoice()
        try await engine.prepare(model: TalkBack.supertonic, voice: "F2")
        let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf:
            URL(fileURLWithPath: try #require(env["LISTEN_SUPERTONIC_TEXTS"]))))
        var rows: [[String: Any]] = []
        for (index, text) in texts.enumerated() {
            let start = ProcessInfo.processInfo.systemUptime
            var first: Double?, samples: [Float] = [], chunks = 0
            for try await chunk in try await engine.speech(text, model: TalkBack.supertonic, voice: "F2", language: .de) {
                first = first ?? ProcessInfo.processInfo.systemUptime - start
                try #require(chunk.sampleRate == 44_100 && chunk.samples.allSatisfy(\.isFinite))
                samples += chunk.samples
                chunks += 1
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            try #require(!samples.isEmpty)
            let file = "adapter-t\(index).wav"
            try NativeSupertonicProbe.wav(samples, to: root.appending(path: file))
            rows.append(["text": text, "file": file, "first_chunk_s": first ?? -1,
                "generation_s": elapsed, "sample_rate": 44_100, "chunks": chunks,
                "audio_s": Double(samples.count) / 44_100])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "adapter-timings.json"))

        // Interrupt a real queued generation, then replace it on the same manager.
        // Cancellation must not make that replacement reuse stale PCM or a cleaned
        // model. No hardware playback occurs here.
        let pending = try await engine.speech(String(repeating: texts[2] + " ", count: 20),
                                              model: TalkBack.supertonic, voice: "F2", language: .de)
        let consumer = Task { for try await _ in pending { try Task.checkCancellation() } }
        consumer.cancel()
        _ = await consumer.result
        var replacement: [Float] = []
        for try await chunk in try await engine.speech(texts[0], model: TalkBack.supertonic, voice: "F2", language: .de) {
            replacement += chunk.samples
        }
        try #require(!replacement.isEmpty)
        try NativeSupertonicProbe.wav(replacement, to: root.appending(path: "adapter-after-cancel.wav"))
        await engine.unload()
    }
}

@MainActor @Suite struct NativeSupertonicLifecycleProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_SUPERTONIC_LIFECYCLE_PROBE"] == "1"),
          .timeLimit(.minutes(5)))
    func removingAnActivePackCannotRestartAnImplicitDownload() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        try #require(LocalVoice.root.path.contains("/runs/") && SupertonicVoiceFiles.complete() != nil)
        let engine = SupertonicVoice()
        // Exercise cancellation while initialize() may still be loading. The
        // removal waits for both initialization and a queued inference to exit.
        let preparation = Task { try await engine.prepare(model: TalkBack.supertonic, voice: "F2") }
        try await Task.sleep(for: .milliseconds(10))
        await engine.removeFiles()
        _ = await preparation.result
        #expect(SupertonicVoiceFiles.complete() == nil)
        #expect(!FileManager.default.fileExists(atPath: SupertonicVoiceFiles.folder().path))
        do {
            _ = try await engine.speech("Nach dem Entfernen bleibt die Stimme still.",
                                        model: TalkBack.supertonic, voice: "F2", language: .de)
            Issue.record("removed model unexpectedly started speech")
        } catch { #expect(error is LocalVoiceUnavailable) }
        #expect(!FileManager.default.fileExists(atPath: SupertonicVoiceFiles.folder().path))
    }
}
