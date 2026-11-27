import AVFoundation

/// Puts the microphone and the sound one app plays (the other people in a call, on a Mac)
/// together into the 100 ms frames of 16 kHz mono that every listening stage reads.
///
/// The two sides arrive in pieces of their own sizes and with their own delays. They are laid
/// next to each other as they come and nothing is dropped. A side that delivers nothing (an
/// app that plays nothing sends nothing) holds the other up by at most `slack`.
struct SoundMixer {
    struct Frame: Equatable {
        var pcm: Data
        /// How loud each side was in this frame, as RMS from 0 to 1: which side spoke.
        var mine: Float
        var theirs: Float
    }

    static let frame = WireProtocol.frameBytes / 2
    /// How far one side may run ahead before frames go out without the other: 200 ms, more
    /// than the microphone's own steps of 100 ms, so its ordinary jitter is not taken for silence.
    static let slack = frame * 2

    private var mine: [Float] = []
    private var theirs: [Float] = []

    mutating func add(mine samples: [Float]) { mine += samples }
    mutating func add(theirs samples: [Float]) { theirs += samples }

    /// The frames that are ready: as soon as both sides have one, or when one side runs ahead
    /// by `slack` (the other then adds what it has, the rest is silence).
    mutating func frames() -> [Frame] {
        var ready: [Frame] = []
        while (mine.count >= Self.frame && theirs.count >= Self.frame)
            || max(mine.count, theirs.count) >= Self.frame + Self.slack {
            ready.append(take())
        }
        return ready
    }

    /// Everything still held, in frames; the last one filled up with silence.
    mutating func flush() -> [Frame] {
        var rest = frames()
        while !mine.isEmpty || !theirs.isEmpty { rest.append(take()) }
        return rest
    }

    private mutating func take() -> Frame {
        let a = Array(mine.prefix(Self.frame)), b = Array(theirs.prefix(Self.frame))
        mine.removeFirst(a.count)
        theirs.removeFirst(b.count)
        var pcm = [Int16](repeating: 0, count: Self.frame)
        for index in pcm.indices {
            let sum = (index < a.count ? a[index] : 0) + (index < b.count ? b[index] : 0)
            pcm[index] = Int16(max(-1, min(1, sum)) * 32_767)
        }
        return Frame(pcm: pcm.withUnsafeBufferPointer { Data(buffer: $0) }, mine: Self.rms(a), theirs: Self.rms(b))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot()
    }

    static func samples(of pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32_768 } }
    }
}

/// Turns sound of any format into 16 kHz mono samples, as the stages hear it. One per source;
/// it keeps the converter's state between pieces, so a stream is resampled without seams.
final class SoundConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var input: AVAudioFormat?
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WireProtocol.sampleRate, channels: 1, interleaved: false)!

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if input != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            // Both channels of a call, not only the left one.
            converter?.downmix = true
            input = buffer.format
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
    }
}

/// Which side of a call spoke, frame by frame: the microphone (the user, wearing headphones)
/// or the app (the others). Known only while an app's sound is mixed in; otherwise empty.
struct CallSides {
    enum Side: String, Equatable { case mine, theirs }

    /// Frames of 100 ms, by their place in the fed sound.
    private var frames: [Int: (mine: Float, theirs: Float)] = [:]
    /// Quieter than this on both sides is no one speaking (RMS).
    static let silence: Float = 0.004

    var isEmpty: Bool { frames.isEmpty }

    mutating func add(frame index: Int, mine: Float, theirs: Float) { frames[index] = (mine, theirs) }

    mutating func forget(before index: Int) {
        guard frames.keys.contains(where: { $0 < index }) else { return }
        frames = frames.filter { $0.key >= index }
    }

    /// Who spoke between two moments, in seconds of fed sound: the side carrying at least
    /// `dominance` of the sound energy. Nil when both spoke, too little was heard, or the
    /// frames have no sides (the microphone alone).
    func side(from start: Double, to end: Double, dominance: Float = 0.8) -> Side? {
        let first = Int((start * 10).rounded(.down)), last = Int((end * 10).rounded(.up))
        guard last > first else { return nil }
        var mine: Float = 0, theirs: Float = 0, heard = 0
        for index in first..<last {
            guard let frame = frames[index], max(frame.mine, frame.theirs) >= Self.silence else { continue }
            mine += frame.mine * frame.mine
            theirs += frame.theirs * frame.theirs
            heard += 1
        }
        guard heard >= 3, mine + theirs > 0 else { return nil }
        let share = mine / (mine + theirs)
        if share >= dominance { return .mine }
        if share <= 1 - dominance { return .theirs }
        return nil
    }
}
