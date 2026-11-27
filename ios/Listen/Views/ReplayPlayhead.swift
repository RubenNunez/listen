import QuartzCore
import SwiftUI
import UIKit
import os

/// All positions are in the fixed viewport, never in a thumb or moving content view.
enum ReplayScrubGeometry {
    static func time(pointer: CGFloat, offset: CGFloat, grab: CGFloat, scale: CGFloat, length: Double) -> Double {
        guard pointer.isFinite, offset.isFinite, grab.isFinite, scale > 0, scale.isFinite else { return 0 }
        return min(max(0, Double((pointer + offset - grab) / scale)), max(0, length))
    }

    /// The band along each side of the strip where a held pin carries the strip along:
    /// a sixth of the strip, at least a fingertip wide, never more than 160 points.
    static func edgeZone(width: CGFloat) -> CGFloat { min(160, max(56, width / 6)) }

    /// How fast the strip comes along with a held pin, in points per second, negative toward
    /// the start. Zero in the middle. It starts softly where a band begins, reaches one strip
    /// width per second at the edge, and keeps rising, bounded, for a hand beyond the strip.
    static func edgeVelocity(pointer: CGFloat, width: CGFloat) -> CGFloat {
        let zone = edgeZone(width: width)
        guard pointer.isFinite, width > zone * 2 else { return 0 }
        let into = pointer < zone ? pointer - zone : pointer > width - zone ? pointer - (width - zone) : 0
        guard into != 0 else { return 0 }
        // 0 where the band begins, 1 at the strip's edge, at most 2 beyond it.
        let depth = min(2, abs(into) / zone)
        let fastest = max(600, width)
        let speed = depth <= 1 ? fastest * depth * depth : fastest * (1 + (depth - 1) * 1.5)
        return into < 0 ? -speed : speed
    }

    /// The scroll offset that keeps `x` (a point on the strip) at least `margin` inside the
    /// shown part, moving as little as possible; `shown` when it already is.
    static func keepInView(_ x: CGFloat, shown: CGFloat, width: CGFloat, margin: CGFloat) -> CGFloat {
        guard x.isFinite, shown.isFinite, width > 0 else { return shown }
        let margin = min(max(0, margin), width / 2)
        if x < shown + margin { return x - margin }
        if x > shown + width - margin { return x - width + margin }
        return shown
    }
}

/// Native tracking delivers begin/update/end/cancel synchronously. Transparent areas
/// pass through to the timeline's normal scrolling and event buttons.
struct ReplayPlayhead: UIViewRepresentable {
    let replay: ReplayController
    let scroll: StripScroll
    let scale: CGFloat
    let rulerHeight: CGFloat

    func makeUIView(context: Context) -> ReplayPlayheadControl {
        let view = ReplayPlayheadControl()
        view.bind(replay, scroll: scroll, scale: scale, rulerHeight: rulerHeight)
        return view
    }

    func updateUIView(_ view: ReplayPlayheadControl, context: Context) {
        view.bind(replay, scroll: scroll, scale: scale, rulerHeight: rulerHeight)
    }

    static func dismantleUIView(_ view: ReplayPlayheadControl, coordinator: ()) { view.disconnect() }
}

@MainActor final class ReplayPlayheadControl: UIControl, UIPointerInteractionDelegate {
    private weak var replay: ReplayController?
    private weak var scroll: StripScroll?
    private var timeObserver: UUID?
    private var viewportObserver: UUID?
    private var scale: CGFloat = 46
    private var rulerHeight: CGFloat = 44
    private let line = CAShapeLayer()
    private let thumb = UIView()
    private let timeLabel = UILabel()
    private(set) var dragging = false
    private var grab: CGFloat = 0
    private var pointer: CGFloat = 0
    /// Where the hand took the pin, and which bands may carry the strip. A band starts carrying
    /// only once the hand moved toward it, so taking a pin that already stands near an edge
    /// does not set the strip moving.
    private var origin: CGFloat = 0
    private var carriesLeading = false
    private var carriesTrailing = false
    /// Where the band is carrying the strip to. Kept here, with its fractions: at the soft start
    /// of a band a frame moves the strip by less than a request is worth, and those steps add up.
    private var edgeTarget: CGFloat?
    private var edgeLink: CADisplayLink?
    private var edgeTimestamp: CFTimeInterval?
    private let signposter = OSSignposter(subsystem: "com.meowop.listen", category: "Replay")
    private var scrubInterval: OSSignpostIntervalState?
    private var begins = 0
    private var updates = 0
    private var cancels = 0
    private static let inputDiagnostics = ProcessInfo.processInfo.environment["LISTEN_REPLAY_INPUT_DIAGNOSTICS"] == "1"
    private lazy var trackingGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(track(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isExclusiveTouch = true
        isAccessibilityElement = true
        accessibilityLabel = "Timeline playhead"
        accessibilityIdentifier = "replay.playhead"
        accessibilityTraits = [.adjustable]
        accessibilityHint = "Adjust the replay position. The replay slider also supports keyboard control."
        line.strokeColor = UIColor.white.cgColor
        line.lineWidth = 2
        layer.addSublayer(line)
        thumb.backgroundColor = .white
        thumb.layer.cornerRadius = 4
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.backgroundColor = UIColor(white: 0.15, alpha: 1)
        timeLabel.layer.cornerRadius = 4
        timeLabel.clipsToBounds = true
        timeLabel.textAlignment = .center
        timeLabel.isHidden = true
        timeLabel.isUserInteractionEnabled = false
        addSubview(timeLabel)
        addInteraction(UIPointerInteraction(delegate: self))
        // Recognizers receive the initial contact before a UIScrollView's delayed
        // delivery to controls. Claim the grip immediately, before its pan can begin.
        addGestureRecognizer(trackingGesture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(_ replay: ReplayController, scroll: StripScroll, scale: CGFloat, rulerHeight: CGFloat) {
        self.scale = scale
        self.rulerHeight = rulerHeight
        if self.replay !== replay || self.scroll !== scroll {
            disconnect()
            self.replay = replay
            self.scroll = scroll
            timeObserver = replay.observeTime { [weak self] _, _ in self?.render() }
            viewportObserver = scroll.observeViewport { [weak self] in
                guard let self else { return }
                if self.dragging { self.updatePreview() }
                self.render()
            }
        }
        // An interruption can finish the controller's interaction before UIKit cancels tracking.
        if dragging, !replay.scrubbing { finish(cancelled: false) }
        render()
    }

    func disconnect() {
        finish(cancelled: false)
        if let timeObserver { replay?.removeTimeObserver(timeObserver) }
        if let viewportObserver { scroll?.removeViewportObserver(viewportObserver) }
        timeObserver = nil
        viewportObserver = nil
        replay = nil
        scroll = nil
    }

    private var pinX: CGFloat { CGFloat(replay?.moment ?? 0) * scale - (scroll?.offset ?? 0) }
    private var pinVisible: Bool { pinX >= 0 && pinX <= bounds.width }
    var hitRect: CGRect {
        let side = rulerHeight
        return CGRect(x: min(max(0, pinX - side / 2), max(0, bounds.width - side)), y: 0, width: side, height: side)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        replay != nil && pinVisible && (replay?.length ?? 0) > 0 && hitRect.contains(point)
    }

    override var accessibilityFrame: CGRect {
        get { pinVisible ? UIAccessibility.convertToScreenCoordinates(hitRect, in: self) : .zero }
        set { }
    }

    override var accessibilityValue: String? {
        get {
            guard let replay else { return nil }
            var value = String(format: "%.1f seconds", replay.moment)
            #if DEBUG
            if Self.inputDiagnostics {
                value += " bounds=\(bounds) offset=\(scroll?.offset ?? 0) content=\(scroll?.contentWidth ?? 0) scale=\(scale) pin=\(pinX) visible=\(pinVisible) begins=\(begins) updates=\(updates) cancels=\(cancels) following=\(replay.follows) reason=\(replay.followDiagnostic) follow=\(scroll?.followDiagnostic ?? "")"
            }
            #endif
            return value
        }
        set { }
    }

    override func layoutSubviews() { super.layoutSubviews(); render() }

    private func render() {
        guard let replay else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: pinX, y: rulerHeight))
        path.addLine(to: CGPoint(x: pinX, y: bounds.height))
        line.path = path
        line.isHidden = !pinVisible
        thumb.isHidden = !pinVisible
        isAccessibilityElement = pinVisible
        accessibilityElementsHidden = !pinVisible
        thumb.frame = CGRect(x: min(max(0, pinX - 6), max(0, bounds.width - 12)), y: (rulerHeight - 20) / 2, width: 12, height: 20)
        thumb.backgroundColor = dragging ? .systemYellow : .white
        let label = String(format: "%d:%04.1f", Int(replay.moment) / 60, replay.moment.truncatingRemainder(dividingBy: 60))
        if timeLabel.text != label { timeLabel.text = label }
        timeLabel.frame = CGRect(x: min(max(0, pinX + 12), max(0, bounds.width - 74)), y: rulerHeight + 2, width: 74, height: 22)
        timeLabel.isHidden = !dragging || !pinVisible
        CATransaction.commit()
    }

    @discardableResult func begin(at point: CGPoint) -> Bool {
        guard let replay, !replay.scrubbing, pinVisible, hitRect.contains(point), replay.length > 0 else { return false }
        pointer = point.x
        grab = pointer + (scroll?.offset ?? 0) - CGFloat(replay.moment) * scale
        origin = pointer
        let zone = ReplayScrubGeometry.edgeZone(width: bounds.width)
        carriesLeading = origin > zone
        carriesTrailing = origin < bounds.width - zone
        dragging = true
        begins += 1
        scrubInterval = signposter.beginInterval("Scrub")
        scroll?.glide = nil
        replay.beginScrub(.playhead)
        // Claiming first responder here makes ancestor scroll views reveal this
        // whole overlay and shifts the ruler underneath the captured pointer.
        render()
        return true
    }

    func move(to point: CGPoint) {
        guard dragging else { return }
        let interval = signposter.beginInterval("PlayheadUpdate")
        defer { signposter.endInterval("PlayheadUpdate", interval) }
        pointer = point.x
        if pointer < origin - 8 { carriesLeading = true }
        if pointer > origin + 8 { carriesTrailing = true }
        updates += 1
        updatePreview()
        updateEdgeClock()
    }

    private func updatePreview() {
        guard let replay, dragging else { return }
        let boundedPointer = min(max(grab, pointer), bounds.width + grab)
        replay.preview(ReplayScrubGeometry.time(pointer: boundedPointer, offset: scroll?.offset ?? 0,
            grab: grab, scale: scale, length: replay.length), source: .playhead)
    }

    func finish(cancelled: Bool) {
        guard dragging else { return }
        dragging = false
        if cancelled { cancels += 1 }
        if let scrubInterval { signposter.endInterval("Scrub", scrubInterval); self.scrubInterval = nil }
        edgeLink?.invalidate()
        edgeLink = nil
        edgeTimestamp = nil
        edgeTarget = nil
        replay?.endScrub(.playhead, cancelled: cancelled)
        render()
    }

    @objc private func track(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began: _ = begin(at: point)
        case .changed: move(to: point)
        case .ended: move(to: point); finish(cancelled: false)
        case .cancelled, .failed: finish(cancelled: true)
        default: break
        }
    }

    func cancelInteraction() {
        finish(cancelled: true)
        trackingGesture.isEnabled = false
        trackingGesture.isEnabled = true
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finish(cancelled: false) }
    }

    /// How fast the held pin carries the strip along right now.
    private var edgeVelocity: CGFloat {
        let velocity = ReplayScrubGeometry.edgeVelocity(pointer: pointer, width: bounds.width)
        return (velocity < 0 && carriesLeading) || (velocity > 0 && carriesTrailing) ? velocity : 0
    }

    private func updateEdgeClock() {
        let velocity = edgeVelocity
        guard dragging, velocity != 0 else {
            edgeLink?.invalidate(); edgeLink = nil; edgeTimestamp = nil; edgeTarget = nil
            return
        }
        guard edgeLink == nil else { return }
        let target = ReplayDisplayTarget { [weak self] link in
            guard let self else { link.invalidate(); return }
            self.edgeFrame(link.timestamp)
        }
        let link = CADisplayLink(target: target, selector: #selector(ReplayDisplayTarget.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        edgeLink = link
    }

    func edgeFrame(_ timestamp: CFTimeInterval) {
        guard dragging, let scroll, replay?.scrubbing == true else { finish(cancelled: false); return }
        defer { edgeTimestamp = timestamp }
        guard let previous = edgeTimestamp else { return }
        // Continue from where the strip was sent, not from the last offset it reported: a report
        // can be a frame late, and the strip would then move only every other frame.
        let from = edgeTarget.flatMap { abs($0 - scroll.offset) < bounds.width ? $0 : nil } ?? scroll.target
        let target = min(max(0, from + edgeVelocity * min(0.05, max(0, timestamp - previous))),
                         max(0, scroll.contentWidth - bounds.width))
        edgeTarget = target
        scroll.request(target)
    }

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(step(_:))),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(step(_:))),
         UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .alternate, action: #selector(step(_:))),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .alternate, action: #selector(step(_:))),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelDrag))]
    }
    @objc private func step(_ command: UIKeyCommand) {
        guard let replay else { return }
        let amount = command.modifierFlags.contains(.alternate) ? 0.1 : 1.0
        replay.seek(to: replay.moment + (command.input == UIKeyCommand.inputRightArrow ? amount : -amount))
    }
    @objc private func cancelDrag() { cancelInteraction() }
    override func accessibilityIncrement() { if let replay { replay.seek(to: replay.moment + 1) } }
    override func accessibilityDecrement() { if let replay { replay.seek(to: replay.moment - 1) } }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        hitRect.contains(request.location) ? UIPointerRegion(rect: hitRect, identifier: "playhead" as NSString) : nil
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: thumb)))
    }
}

/// Playback drives following through its own clock. Paused replay has no follow timer.
struct ReplayFollowUpdates: View {
    let replay: ReplayController
    let scroll: StripScroll
    let scale: CGFloat
    let width: CGFloat
    let contentWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func update() {
        #if DEBUG
        scroll.followDiagnostic = "width=\(width) expected=\(contentWidth) actual=\(scroll.contentWidth) active=\(replay.active) follows=\(replay.follows) scrubbing=\(replay.scrubbing)"
        #endif
        guard width > 0, scroll.contentWidth >= contentWidth - 1, replay.active else { return }
        if replay.scrubbing {
            // The slider is held: the strip comes along, so the moment stays in sight. A held
            // pin carries the strip itself, at the edges.
            if replay.scrubSource == .slider {
                scroll.request(ReplayScrubGeometry.keepInView(CGFloat(replay.moment) * scale, shown: scroll.target,
                    width: width, margin: ReplayScrubGeometry.edgeZone(width: width)))
            }
            return
        }
        guard replay.follows else { return }
        var target = min(max(0, CGFloat(replay.moment) * scale - width / 2), max(0, contentWidth - width))
        if let glide = scroll.glide, replay.playing, !reduceMotion {
            let t = min(1, Date().timeIntervalSince(glide.start) / 0.25)
            target = glide.from + (target - glide.from) * t * t * (3 - 2 * t)
            if t >= 1 { scroll.glide = nil }
        } else { scroll.glide = nil }
        scroll.request(target)
    }

    /// A moment chosen in one step (arrow keys, a click on the ruler, VoiceOver) stays in sight
    /// while detached; the strip moves only as far as needed.
    private func reveal() {
        guard width > 0, replay.active, !replay.scrubbing, !replay.follows else { return }
        scroll.request(ReplayScrubGeometry.keepInView(CGFloat(replay.moment) * scale, shown: scroll.target,
                                                      width: width, margin: 24))
    }

    var body: some View {
        Color.clear
            .onChange(of: replay.moment, initial: true) { update() }
            .onChange(of: replay.seekGeneration) { reveal() }
            .onChange(of: replay.follows) { update() }
            .onChange(of: replay.active) { update() }
            .onChange(of: width) { update() }
            .onChange(of: contentWidth) { update() }
            .onChange(of: scroll.contentWidth, initial: true) { update() }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
