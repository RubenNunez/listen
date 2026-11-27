import AVFoundation
import Foundation
import Testing
@testable import Listen

@Suite struct SoundMixing {
    private let frame = SoundMixer.frame

    private func ramp(_ count: Int, from start: Int, scale: Float = 1e-5) -> [Float] {
        (0..<count).map { Float(start + $0) * scale }
    }

    private func samples(_ frames: [SoundMixer.Frame]) -> [Float] { frames.flatMap { SoundMixer.samples(of: $0.pcm) } }

    @Test func bothSidesTogetherGoOutAtOnceAsTheirSum() {
        var mixer = SoundMixer()
        mixer.add(mine: [Float](repeating: 0.25, count: frame))
        #expect(mixer.frames().isEmpty, "waits for the other side, within the slack")
        mixer.add(theirs: [Float](repeating: 0.5, count: frame))
        let out = mixer.frames()
        #expect(out.count == 1)
        #expect(samples(out).allSatisfy { abs($0 - 0.75) < 0.001 })
        #expect(abs(out[0].mine - 0.25) < 0.001 && abs(out[0].theirs - 0.5) < 0.001)
    }

    @Test func aSilentAppHoldsTheMicrophoneUpByTheSlackOnlyAndLosesNothing() {
        var mixer = SoundMixer()
        var out: [SoundMixer.Frame] = []
        for step in 0..<10 {
            mixer.add(mine: ramp(frame, from: step * frame))
            out += mixer.frames()
        }
        // Ten frames in, all but the slack out.
        #expect(out.count == 10 - SoundMixer.slack / frame)
        out += mixer.flush()
        #expect(out.count == 10)
        let heard = samples(out)
        for (index, value) in heard.enumerated() { #expect(abs(value - Float(index) * 1e-5) < 1e-4) }
        #expect(out.allSatisfy { $0.theirs == 0 })
    }

    @Test func theAppInSmallPiecesAndTheMicrophoneInFramesStayInStep() {
        var mixer = SoundMixer()
        var out: [SoundMixer.Frame] = []
        var theirs = 0
        for step in 0..<20 {
            // The app's sound in pieces of 10 ms, a little ahead; the microphone every 100 ms.
            for _ in 0..<10 {
                mixer.add(theirs: [Float](repeating: 0, count: 160))
                theirs += 160
                out += mixer.frames()
            }
            mixer.add(mine: ramp(frame, from: step * frame))
            out += mixer.frames()
        }
        #expect(out.count == 20, "no frame waited for the slack")
        // The microphone came through without a gap of silence put into it.
        let heard = samples(out)
        for (index, value) in heard.enumerated() { #expect(abs(value - Float(index) * 1e-5) < 1e-4) }
    }

    @Test func loudSidesTogetherAreClippedNotWrapped() {
        var mixer = SoundMixer()
        mixer.add(mine: [Float](repeating: 0.8, count: frame))
        mixer.add(theirs: [Float](repeating: 0.8, count: frame))
        let heard = samples(mixer.frames())
        #expect(heard.allSatisfy { $0 > 0.99 })
    }

    @Test func soundOfAnyFormatBecomesSixteenKilohertzMono() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converter = SoundConverter()
        var total: [Float] = []
        // One second in pieces of 1024, as a stream of an app's sound comes.
        for piece in 0..<47 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            buffer.frameLength = 1024
            for channel in 0..<2 {
                for index in 0..<1024 {
                    buffer.floatChannelData![channel][index] = 0.5 * sin(2 * .pi * 440 * Float(piece * 1024 + index) / 48_000)
                }
            }
            total += converter.convert(buffer)
        }
        let expected = 47.0 * 1024 / 3
        #expect(abs(Double(total.count) - expected) < 100)
        let peak = total.dropFirst(200).map(abs).max() ?? 0
        #expect(peak > 0.3 && peak < 1.01)
    }
}

@Suite struct CallSideDecisions {
    private func sides(_ frames: [(Float, Float)], from first: Int = 0) -> CallSides {
        var sides = CallSides()
        for (offset, frame) in frames.enumerated() { sides.add(frame: first + offset, mine: frame.0, theirs: frame.1) }
        return sides
    }

    @Test func theMicrophoneAloneIsMineAndTheAppAloneIsTheirs() {
        let mine = sides(Array(repeating: (0.2, 0.001), count: 20))
        #expect(mine.side(from: 0, to: 2) == .mine)
        let theirs = sides(Array(repeating: (0.003, 0.3), count: 20))
        #expect(theirs.side(from: 0, to: 2) == .theirs)
    }

    @Test func bothSpeakingSilenceOrNoSidesDecideNothing() {
        #expect(sides(Array(repeating: (0.2, 0.2), count: 20)).side(from: 0, to: 2) == nil)
        #expect(sides(Array(repeating: (0.001, 0.001), count: 20)).side(from: 0, to: 2) == nil, "silence")
        #expect(CallSides().side(from: 0, to: 2) == nil, "the microphone alone has no sides")
        #expect(sides([(0.2, 0), (0.2, 0)]).side(from: 0, to: 0.2) == nil, "too short to tell")
    }

    @Test func aSentenceIsJudgedOnItsOwnFramesOnly() {
        // Two seconds of the app, then two of the microphone.
        let call = sides(Array(repeating: (0.001, 0.3), count: 20) + Array(repeating: (0.25, 0.002), count: 20))
        #expect(call.side(from: 0, to: 1.9) == .theirs)
        #expect(call.side(from: 2.1, to: 4) == .mine)
        // An echo of the others in the microphone, much quieter than their own sound, is still theirs.
        #expect(sides(Array(repeating: (0.05, 0.3), count: 20)).side(from: 0, to: 2) == .theirs)
    }

    @Test func forgottenFramesNoLongerCount() {
        var call = sides(Array(repeating: (0.2, 0.001), count: 40))
        call.forget(before: 30)
        #expect(call.side(from: 0, to: 2.9) == nil)
        #expect(call.side(from: 3, to: 4) == .mine)
    }
}
