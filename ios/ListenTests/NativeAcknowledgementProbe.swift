import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct NativeAcknowledgementProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_NATIVE_ACK_PROBE"] == "1"), .timeLimit(.minutes(3)))
    func fixedResearchWordsAreReusedOnlyInTheirOwnVoice() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let out = URL(fileURLWithPath: try #require(env["LISTEN_NATIVE_ACK_OUT"]))
        try #require(out.path.contains("/runs/") && (env["LISTEN_TALKBACK_MODELS"] ?? "").contains("/runs/"))
        var rows: [[String: Any]] = [], outputs: [[Float]] = []
        for voice in ["Serena", "Serena", "Sohee"] {
            var samples: [Float] = [], first: Double?
            let began = ProcessInfo.processInfo.systemUptime
            for try await chunk in try await QwenVoice.shared.speech("Ich schaue das nach.", model: TalkBack.defaultModel, voice: voice, language: .de) {
                first = first ?? ProcessInfo.processInfo.systemUptime - began
                samples += chunk.samples
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            try #require(samples.count > 12_000 && samples.allSatisfy(\.isFinite))
            outputs.append(samples)
            rows.append(["voice": voice, "first_chunk_s": first ?? -1, "elapsed_s": elapsed,
                         "audio_s": Double(samples.count) / 24_000,
                         "generated_segments": await QwenVoice.shared.trace?.segments ?? -1])
        }
        #expect(rows[1]["generated_segments"] as? Int == 0)
        #expect(outputs[0] == outputs[1], "reuse the generated fixed phrase; do not regenerate a different delivery")
        #expect(outputs[0] != outputs[2], "changing voice cannot reuse the previous speaker")
        try JSONSerialization.data(withJSONObject: ["rows": rows, "hardware_or_phone_latency": false], options: [.prettyPrinted,.sortedKeys]).write(to: out)
    }
}
