import Foundation
import CoreGraphics

/// A resting device supplies the neutral pose; changes of tilt and shaking pull the orb.
struct OrbTilt {
    /// Time constant, in seconds, for adopting a new resting pose.
    static let settle = 2.5
    private var rest: SIMD2<Double>?

    mutating func step(gravity: SIMD2<Double>, shake: SIMD2<Double>, elapsed: Double) -> CGSize {
        let rest = self.rest ?? gravity
        let x = (gravity.x - rest.x) * 0.9 + shake.x * 1.6
        let y = -(gravity.y - rest.y) * 0.9 - shake.y * 1.6
        self.rest = rest + (gravity - rest) * (1 - exp(-elapsed / Self.settle))
        return CGSize(width: max(-1.2, min(1.2, x)), height: max(-1.2, min(1.2, y)))
    }
}
