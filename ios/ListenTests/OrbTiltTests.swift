import Foundation
import CoreGraphics
import Testing
@testable import Listen

/// The orb stays round wherever the device rests, and a change of tilt still pulls it.
@Suite struct OrbTiltTests {
    /// Feeds the same gravity at 30 samples a second and returns the last pull.
    private func hold(_ reading: inout OrbTilt, gravity: SIMD2<Double>, seconds: Double) -> CGSize {
        var pull = CGSize.zero
        for _ in 0..<Int((seconds * 30).rounded()) {
            pull = reading.step(gravity: gravity, shake: .zero, elapsed: 1.0 / 30)
        }
        return pull
    }

    private func length(_ pull: CGSize) -> Double { (pull.width * pull.width + pull.height * pull.height).squareRoot() }

    @Test func lyingFlatPullsNothing() {
        var reading = OrbTilt()
        // Flat on a table: gravity points straight down through the screen, x and y are zero.
        // The previous absolute reference produced a constant pull of 0.54 here.
        #expect(hold(&reading, gravity: SIMD2(0, 0), seconds: 5) == .zero)
    }

    @Test func anyHeldPoseSettlesRound() {
        for gravity in [SIMD2(0.0, -1.0), SIMD2(0.0, -0.6), SIMD2(0.5, -0.7), SIMD2(-0.3, 0.2)] {
            var reading = OrbTilt()
            #expect(hold(&reading, gravity: gravity, seconds: 5) == .zero)
        }
    }

    @Test func layingItDownPullsAndThenFades() {
        var reading = OrbTilt()
        _ = hold(&reading, gravity: SIMD2(0, -0.8), seconds: 5)  // held in the hand
        let first = reading.step(gravity: SIMD2(0, 0), shake: .zero, elapsed: 1.0 / 30)  // laid down
        #expect(first.height < -0.7)  // the body swings with the move
        #expect(length(hold(&reading, gravity: SIMD2(0, 0), seconds: 10)) < 0.02)  // and comes back round
    }

    @Test func tiltingSidewaysLeansThatWay() {
        var reading = OrbTilt()
        _ = hold(&reading, gravity: SIMD2(0, -0.8), seconds: 3)
        #expect(reading.step(gravity: SIMD2(0.4, -0.7), shake: .zero, elapsed: 1.0 / 30).width > 0.3)
    }

    @Test func shakePullsAtOnceAndIsBounded() {
        var reading = OrbTilt()
        _ = hold(&reading, gravity: SIMD2(0, 0), seconds: 1)
        let shaken = reading.step(gravity: SIMD2(0, 0), shake: SIMD2(0.2, 0), elapsed: 1.0 / 30)
        #expect(abs(shaken.width - 0.32) < 1e-9)
        let hard = reading.step(gravity: SIMD2(0, 0), shake: SIMD2(5, -5), elapsed: 1.0 / 30)
        #expect(hard.width == 1.2 && hard.height == 1.2)
    }
}
