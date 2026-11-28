import Foundation
import Testing
@testable import Listen

/// Explicitly file-fed real SpeechAnalyzer regression. No microphone, model,
/// assistant, tool executor or audio player is constructed. Recognized text is data.
@MainActor @Suite struct LiveRecognitionMuteProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_ASR_MUTE_PROBE"] == "1"), .timeLimit(.minutes(2)))
    func realRecognitionContinuesAfterMuteAndRapidToggles() async throws {
        try #require(AudioCapture.physicalInputDisabled)
        let path = try #require(ProcessInfo.processInfo.environment["LISTEN_ASR_MUTE_AUDIO"])
        let output = try #require(ProcessInfo.processInfo.environment["LISTEN_ASR_MUTE_OUT"])
        try #require(path.contains("/runs/") && output.contains("/runs/"))
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        try #require(wav.count >= 44 + WireProtocol.frameBytes * 60 && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        let pcm = wav.subdata(in: 44..<(44 + WireProtocol.frameBytes * 60))
        let transport = LocalTransport(language: .de)
        var ready = false, failure = false, phase = 0
        var segments: [(phase: Int, id: UInt64, start: UInt64, end: UInt64)] = []
        transport.onEvent = { event in
            guard case .envelope(let envelope) = event else { return }
            switch envelope.event {
            case .state(.listening, _): ready = true
            case .transcript(let segment) where segment.text.contains(where: \.isLetter):
                segments.append((phase, segment.segmentID, segment.startMs, segment.endMs))
            case .error: failure = true
            default: break
            }
        }
        transport.connect(); transport.send(.start(language: .de, contextVersion: 0))
        defer { transport.disconnect() }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Timed out waiting for file-fed SpeechAnalyzer progress")
        }
        var sequence: UInt32 = 0
        func feed() async throws {
            for index in 0..<60 {
                sequence += 1
                transport.sendAudio(.init(seq: sequence, captureMs: UInt64(sequence) * 100,
                    pcm: pcm.subdata(in: (index * WireProtocol.frameBytes)..<((index + 1) * WireProtocol.frameBytes))))
                try await Task.sleep(for: .milliseconds(20))
            }
            transport.endUtterance()
        }
        try await wait { ready || failure }
        try #require(ready && !failure)
        try await feed(); try await wait { segments.contains { $0.phase == 0 } }
        let before = segments.map(\.id).max() ?? 0
        let mutedCount = segments.count
        transport.setInputMuted(true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(segments.count == mutedCount)
        transport.setInputMuted(false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(segments.count == mutedCount, "late old recognition must not become a new post-mute turn")
        phase = 1
        try await feed(); try await wait { segments.contains { $0.phase == 1 && $0.id > before } }
        let after = segments.map(\.id).max() ?? 0
        for _ in 0..<5 {
            transport.setInputMuted(true)
            try await Task.sleep(for: .milliseconds(20))
            transport.setInputMuted(false)
        }
        phase = 2
        try await feed(); try await wait { segments.contains { $0.phase == 2 && $0.id > after } }
        let counts = (0...2).map { index in segments.filter { $0.phase == index }.count }
        #expect(!failure && counts.allSatisfy { $0 > 0 })
        let receipt: [String: Any] = ["measurement": "File-fed real on-device SpeechAnalyzer, accelerated input repeated across one mute and five rapid toggles. No mic, playback, model or tool calls; no acoustic latency claim.", "recognized_events_per_phase": counts, "last_segment_id": segments.map(\.id).max() ?? 0]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
