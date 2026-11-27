import Foundation

/// Debug builds only: when each step of a voice reply happened, for finding where a reply
/// spends its time on a real phone. One JSON line per event in the app's caches
/// (`voice-timing.jsonl`), with times in seconds since the device started. No words, no
/// audio and no account data: only the event, its state, the model's name and lengths.
/// A run fed from a synthetic recording (`-audioFile`) keeps its words, to check what was
/// recognised and answered.
enum VoiceTiming {
    static let file = URL.cachesDirectory.appending(path: "voice-timing.jsonl")

    static func note(_ kind: String, _ fields: [String: Any]) {
        #if DEBUG
        var line: [String: Any] = ["t": ProcessInfo.processInfo.systemUptime, "kind": kind]
        for key in ["state", "outcome", "model", "agent", "request_id", "response", "first_audio_s", "stalls", "audio_s", "generation_s",
                    "stalls_in_sentence", "gap_s", "longest_gap_s", "tail_s", "late_s", "web_searches", "source_count",
                    "card", "block", "version", "sentence", "card_kind", "update", "chars", "reason", "engine", "tts_model", "tts_voice",
                    "since_card_s", "since_voice_s", "since_sentence_s", "part", "joined", "sentences",
                    "heard_sentences", "prepared_sentences", "heard", "quiet_s", "audio",
                    "queue_priority", "card_ready_uptime_s", "since_ready_s", "queue_wait_s",
                    "queue_position", "queue_ahead", "plan_sentences", "covered_sentences", "speech_s"] {
            if let value = fields[key] { line[key] = value }
        }
        // Words are only counted: what was said, and the model's answer in `usage`.
        for key in kind == "usage" ? ["text", "response"] : ["text"] {
            guard let text = fields[key] as? String else { continue }
            line[key + "_chars"] = text.count
            if AudioCapture.scriptedFile != nil { line[key] = text } else { line.removeValue(forKey: key) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: .sortedKeys) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: file)
        }
        #endif
    }
}
