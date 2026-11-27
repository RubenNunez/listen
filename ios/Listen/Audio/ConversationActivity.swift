import Foundation

/// Energy relative to the quiet part of the recent microphone signal. A fixed speech
/// level misses a softly spoken question and repeatedly finalizes it in the middle of a
/// word. The low decile of three seconds follows room noise without following every word.
/// This is a pause aid, not a speech recognizer or an echo canceller.
struct ConversationActivity {
    private var levels: [Double] = []
    private(set) var quietSeconds = 0.0
    private(set) var threshold = 80.0 / 32_768
    private(set) var speechSeconds = 0.0
    private(set) var isSpeech = false

    mutating func reset() { self = Self() }

    mutating func receive(_ pcm: Data) {
        let rms = pcm.withUnsafeBytes { bytes -> Double in
            let samples = bytes.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            return (sum / Double(samples.count)).squareRoot() / 32_768
        }
        levels.append(rms)
        if levels.count > 30 { levels.removeFirst(levels.count - 30) }
        // Until a second of evidence exists, err towards letting the person finish.
        let floor = levels.count >= 10 ? levels.sorted()[levels.count / 10] : 0
        threshold = max(80.0 / 32_768, floor * 1.6)
        isSpeech = rms > threshold
        let seconds = Double(pcm.count / 2) / WireProtocol.sampleRate
        quietSeconds = isSpeech ? 0 : quietSeconds + seconds
        speechSeconds = isSpeech ? speechSeconds + seconds : 0
    }
}

/// Bounded acoustic evidence on the recognizer's sample clock. No audio or words kept.
/// An ASR fragment over silence must not restart inference (observed "you", "B.", "M.").
/// This does not blacklist short words: even one voiced 100 ms frame can support "ja".
struct SpeechActivityWindow {
    private var activity = ConversationActivity()
    private var time = 0.0
    private var voiced: [Range<Double>] = []

    mutating func receive(_ pcm: Data) {
        let start = time
        time += Double(pcm.count / 2) / WireProtocol.sampleRate
        activity.receive(pcm)
        if activity.isSpeech {
            if let last = voiced.last, abs(last.upperBound - start) < 0.001 {
                voiced[voiced.count - 1] = last.lowerBound..<time
            } else { voiced.append(start..<time) }
        }
        voiced.removeAll { $0.upperBound < time - 60 }
    }

    func supports(startMs: UInt64, endMs: UInt64) -> Bool {
        let start = Double(startMs) / 1000, end = Double(endMs) / 1000
        // Allow one capture frame of timing rounding at word boundaries.
        return voiced.contains { min($0.upperBound, end + 0.1) - max($0.lowerBound, max(0, start - 0.1)) >= 0.08 - 0.000_001 }
    }

    /// First-pass punctuation can arrive after the next sentence was already spoken.
    /// Use the actual quiet gap for that boundary even when no refinement audio is kept.
    /// Only activity ranges are retained, never microphone samples or words.
    func quietPoint(before end: Double, after previousEnd: Double) -> Double {
        let upper = min(end, time), lower = max(end - 1.6, previousEnd + 0.3)
        guard upper - lower >= 0.2,
              voiced.contains(where: { $0.upperBound > lower && $0.lowerBound < upper }) else { return end }
        var cursor = lower
        var best = (length: 0.2 - 0.000_001, middle: end)
        func consider(_ start: Double, _ finish: Double) {
            if finish - start > best.length { best = (finish - start, (start + finish) / 2) }
        }
        for range in voiced where range.upperBound > lower && range.lowerBound < upper {
            consider(cursor, max(lower, range.lowerBound))
            cursor = max(cursor, min(upper, range.upperBound))
        }
        consider(cursor, upper)
        return best.middle
    }
}
