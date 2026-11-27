import Foundation
import Testing
@testable import Listen

/// When the orb walks the way between its calm forms and the signal.
@MainActor @Suite struct OrbTransitionTiming {
    /// Steps at 30 frames a second with the flag held, and returns the last value.
    private func run(_ transition: OrbTransition, speaking: Bool, from start: Double, seconds: Double) -> Float {
        var value: Float = 0
        for frame in 1...Int((seconds * 30).rounded()) {
            value = transition.step(towards: speaking ? 1 : 0, at: Date(timeIntervalSinceReferenceDate: start + Double(frame) / 30))
        }
        return value
    }
    private func resting(_ speaking: Bool) -> OrbTransition {
        let transition = OrbTransition()
        _ = transition.step(towards: speaking ? 1 : 0, at: Date(timeIntervalSinceReferenceDate: 0))
        return transition
    }

    @Test func theFirstFrameTakesTheFormItIsGiven() {
        #expect(OrbTransition().step(towards: 1, at: .now) == 1)
        #expect(OrbTransition().step(towards: 0, at: .now) == 0)
    }
    @Test func speechStartsTheWayAtOnceAndArrivesExactly() {
        let transition = resting(false)
        let early = run(transition, speaking: true, from: 0, seconds: 0.2)
        #expect(early > 0 && early < 0.3)
        #expect(run(transition, speaking: true, from: 0.2, seconds: 1.5) == 1)
    }
    @Test func aShortNoiseDoesNotChangeTheForm() {
        let transition = resting(false)
        let peak = run(transition, speaking: true, from: 0, seconds: 0.3)
        #expect(peak < 0.5)
        // Below the commit point the way back starts after a moment's patience.
        let turned = run(transition, speaking: false, from: 0.3, seconds: 0.5)
        #expect(turned < 0.3)
        #expect(run(transition, speaking: false, from: 0.8, seconds: 1.0) == 0)
    }
    @Test func aFlickeringFlagDoesNotTurnTheOrbRoundEveryTenthOfASecond() {
        // A quiet voice at the threshold: on for a tenth of a second, off for the next.
        let transition = resting(false)
        var before: Float = 0, reversals = 0
        for tenth in 0..<12 {
            let now = run(transition, speaking: tenth % 2 == 0, from: Double(tenth) / 10, seconds: 0.1)
            if now < before { reversals += 1 }
            before = now
        }
        #expect(reversals == 0 && before > 0.4)
    }
    @Test func aPauseBetweenWordsLeavesTheSignalStanding() {
        let transition = resting(true)
        #expect(run(transition, speaking: false, from: 0, seconds: 0.4) == 1)
        #expect(run(transition, speaking: true, from: 0.4, seconds: 0.5) == 1)
        // Lasting quiet takes it all the way back, to exactly the calm form.
        #expect(run(transition, speaking: false, from: 0.9, seconds: 0.8) < 1)
        #expect(run(transition, speaking: false, from: 1.7, seconds: 2.0) == 0)
    }
    @Test func aStillSurfaceTakesTheFormAtOnce() {
        let transition = resting(false)
        #expect(transition.step(towards: 1, at: Date(timeIntervalSinceReferenceDate: 0.03), snaps: true) == 1)
        #expect(transition.step(towards: 0, at: Date(timeIntervalSinceReferenceDate: 0.06), snaps: true) == 0)
    }
    @Test func aValueGlidesToItsTargetWithoutABeatAtEveryArrival() {
        // Targets arrive ten times a second, frames are drawn sixty times. The largest step
        // between frames must not stand out from the typical one, as it did when each
        // arrival was answered with a jump that then died away.
        let flow = WaveFlow()
        _ = flow.step(towards: [0], at: Date(timeIntervalSinceReferenceDate: 0))
        var steps: [Float] = [], shown: Float = 0
        for frame in 1...120 {
            let target = Float((frame - 1) / 6 + 1) * 0.05  // rises by 0.05 every tenth of a second
            let next = flow.step(towards: [target], at: Date(timeIntervalSinceReferenceDate: Double(frame) / 60))[0]
            if frame > 30 { steps.append(next - shown) }
            shown = next
        }
        let typical = steps.reduce(0, +) / Float(steps.count)
        #expect(steps.allSatisfy { $0 > 0 })
        #expect(steps.max()! < typical * 1.25 && steps.min()! > typical * 0.75)
        // And it arrives: held, the target is reached exactly enough.
        var held: Float = 0
        for frame in 121...240 { held = flow.step(towards: [6.0], at: Date(timeIntervalSinceReferenceDate: Double(frame) / 60))[0] }
        #expect(abs(held - 6.0) < 0.001)
    }
    @Test func aNewVoiceIsMadeRoomForGradually() {
        let animation = OrbFrameAnimator(), began = Date(timeIntervalSinceReferenceDate: 100)
        var target = OrbGPUUniforms(canvas: SIMD2(850, 850), lean: .zero, time: 40, morph: 1,
            level: 0, speakers: 1, active: 1, dark: 1, gather: 0, since: 99, bleed: 255, gain: 1)
        _ = animation.frame(target: target, waveform: [], at: began, isActive: true, changedAt: nil, advancesTime: true, lean: .zero)
        target.speakers = 2
        let first = animation.frame(target: target, waveform: [], at: began.addingTimeInterval(1.0 / 30), isActive: true, changedAt: nil, advancesTime: true, lean: .zero)
        var last = first
        for frame in 2...60 { last = animation.frame(target: target, waveform: [], at: began.addingTimeInterval(Double(frame) / 30), isActive: true, changedAt: nil, advancesTime: true, lean: .zero) }
        #expect(first.uniforms.speakers > 1 && first.uniforms.speakers < 1.2)
        #expect(abs(last.uniforms.speakers - 2) < 0.001)
    }
    @Test func theNativeAnimatorWalksTheSameWay() {
        let animation = OrbFrameAnimator(), began = Date(timeIntervalSinceReferenceDate: 100)
        var target = OrbGPUUniforms(canvas: SIMD2(850, 850), lean: .zero, time: 40, morph: 0,
            level: 0, speakers: 1, active: 1, dark: 1, gather: 0, since: 99, bleed: 255, gain: 1)
        _ = animation.frame(target: target, waveform: [], at: began, isActive: true, changedAt: nil, advancesTime: true, lean: .zero)
        target.morph = 1
        let first = animation.frame(target: target, waveform: [], at: began.addingTimeInterval(0.1), isActive: true, changedAt: nil, advancesTime: true, lean: .zero)
        #expect(first.uniforms.morph > 0 && first.uniforms.morph < 0.2)
    }
}
