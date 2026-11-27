import QuartzCore
import UIKit

#if DEBUG
/// `LISTEN_FRAME_PROBE=1` on a debug build: counts the display frames the main thread got to,
/// so a stutter can be measured instead of guessed. Every five seconds it prints how many
/// frames came, how many arrived more than 25 ms after the one before (at least one frame
/// missed at 60 Hz), the longest gap, and how often the timeline's body was worked out.
/// This is main-thread pacing, not GPU time and not what reached the glass.
@MainActor
final class FrameProbe: NSObject {
    static let shared = FrameProbe()
    static var isOn: Bool { ProcessInfo.processInfo.environment["LISTEN_FRAME_PROBE"] == "1" }

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var slow = 0
    private var worst: CFTimeInterval = 0
    private let began = Date()
    /// Raised by the view being watched each time its body is worked out.
    var bodies = 0

    func start() {
        guard Self.isOn, link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if last > 0 {
            let gap = now - last
            frames += 1
            if gap > 0.025 { slow += 1 }
            worst = max(worst, gap)
        } else {
            windowStart = now
        }
        last = now
        guard now - windowStart >= 5 else { return }
        print(String(format: "[FrameProbe] t=%.1f frames=%d over25ms=%d worst=%.1fms bodies=%d",
                     Date().timeIntervalSince(began), frames, slow, worst * 1000, bodies))
        windowStart = now
        frames = 0
        slow = 0
        worst = 0
        bodies = 0
    }
}
#endif
