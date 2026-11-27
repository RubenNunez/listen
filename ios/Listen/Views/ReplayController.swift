import AVFoundation
import Observation
import QuartzCore
import SwiftUI

@MainActor
protocol ReplayAudio: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: ReplayAudio {}

/// One owner for replay time, transport and manual interaction. Only the lightweight
/// controls observe `moment`; the table projects recorded changes via `observeTime`.
@MainActor @Observable
final class ReplayController {
    enum ScrubSource { case playhead, slider }
    private(set) var moment = 0.0
    private(set) var length = 0.0
    private(set) var playing = false
    private(set) var scrubbing = false
    private(set) var follows = true
    private(set) var speed = 1.0
    private(set) var sound = true
    private(set) var seekGeneration = 0
    private(set) var manualChange = false
    private(set) var active = true

    @ObservationIgnored private var source: ScrubSource?
    @ObservationIgnored private var startMoment = 0.0
    @ObservationIgnored private var audio: (any ReplayAudio)?
    @ObservationIgnored private var soundBegins = 0.0
    @ObservationIgnored private var anchor = 0.0
    @ObservationIgnored private var hostTime = 0.0
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private let automaticTicks: Bool
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var listeners: [UUID: (Double, Bool) -> Void] = [:]
    @ObservationIgnored private(set) var followDiagnostic = "initial"

    init(automaticTicks: Bool = true, clock: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.automaticTicks = automaticTicks
        self.clock = clock
    }

    /// What holds the moment while scrubbing: the pin on the strip or the slider.
    var scrubSource: ScrubSource? { source }
    var seeking: Bool { scrubbing || manualChange }
    var audible: Bool { sound && speed <= 2 && audio != nil }
    var needsClock: Bool { active && playing && !scrubbing && length > 0 }
    var hasDisplayLink: Bool { link != nil }

    func configure(length: Double, soundBegins: Double = 0, audio: (any ReplayAudio)? = nil) {
        stop()
        self.length = length.isFinite ? max(0, length) : 0
        self.soundBegins = soundBegins.isFinite ? soundBegins : 0
        self.audio = audio
        follows = true
        setTime(self.length, manual: true)
    }

    @discardableResult
    func observeTime(_ listener: @escaping (Double, Bool) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        listener(moment, seeking)
        return id
    }

    func removeTimeObserver(_ id: UUID) { listeners[id] = nil }

    func togglePlayback() {
        guard length > 0 else { return }
        if !playing, moment >= length { setTime(0, manual: false) }
        playing.toggle()
        synchronizeTransport()
    }

    /// Starts exactly once, before any preview write or scroll callback.
    func beginScrub(_ source: ScrubSource) {
        guard self.source == nil else { return }
        self.source = source
        startMoment = moment
        scrubbing = true
        follows = false
        followDiagnostic = "scrub"
        manualChange = true
        seekGeneration &+= 1
        audio?.pause()
        updateClock()
    }

    func preview(_ time: Double, source: ScrubSource) {
        guard self.source == source else { return }
        setTime(time, manual: true)
    }

    func endScrub(_ source: ScrubSource, cancelled: Bool = false) {
        guard self.source == source else { return }
        if cancelled { setTime(startMoment, manual: true) }
        self.source = nil
        scrubbing = false
        // Follow deliberately stays detached after both commit and cancellation.
        synchronizeTransport()
    }

    func cancelScrub() {
        if let source { endScrub(source, cancelled: true) }
    }

    func seek(to time: Double) {
        guard !scrubbing else { return }
        follows = false
        seekGeneration &+= 1
        setTime(time, manual: true)
        synchronizeTransport()
    }

    func detachFollow(_ reason: String = "manual scroll") { follows = false; followDiagnostic = reason }
    func toggleFollow() { if !scrubbing { follows.toggle(); followDiagnostic = "button toggle: \(follows)" } }
    func attachFollow() { if !scrubbing { follows = true; followDiagnostic = "attach" } }

    func setSpeed(_ value: Double) {
        guard [1.0, 2.0, 5.0].contains(value), value != speed else { return }
        if needsClock { tick(at: clock()) }
        speed = value
        synchronizeTransport()
    }

    func setSound(_ value: Bool) {
        guard sound != value else { return }
        if needsClock { tick(at: clock()) }
        sound = value
        synchronizeTransport()
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value {
            // Losing the window must not leave a captured drag or restart sound later.
            source = nil
            scrubbing = false
            playing = false
        }
        synchronizeTransport()
    }

    func stop() {
        playing = false
        source = nil
        scrubbing = false
        audio?.stop()
        link?.invalidate()
        link = nil
    }

    /// Audio is authoritative while it plays. Silent intervals advance by actual
    /// monotonic elapsed time, including delayed frames and rate changes.
    func tick(at now: TimeInterval) {
        guard needsClock, now.isFinite else { return }
        let time: Double
        if let audio, audio.isPlaying { time = audio.currentTime + soundBegins }
        else { time = anchor + max(0, now - hostTime) * speed }
        setTime(time, manual: false, at: now)
        if moment >= length {
            playing = false
            audio?.pause()
            updateClock()
        } else if audible, let audio, !audio.isPlaying,
                  moment >= soundBegins, moment - soundBegins < audio.duration {
            startSound()
        }
    }

    private func setTime(_ value: Double, manual: Bool, at now: TimeInterval? = nil) {
        guard value.isFinite else { return }
        let chosen = min(length, max(0, value))
        anchor = chosen
        hostTime = now ?? clock()
        let changed = chosen != moment || manualChange != manual
        withTransaction(.withoutAnyAnimation) {
            manualChange = manual
            moment = chosen
        }
        if changed { for listener in Array(listeners.values) { listener(chosen, manual || scrubbing) } }
    }

    private func synchronizeTransport() {
        audio?.pause()
        anchor = moment
        hostTime = clock()
        if needsClock { startSound() }
        updateClock()
    }

    private func startSound() {
        guard needsClock, audible, let audio else { return }
        let at = moment - soundBegins
        guard at >= 0, at < audio.duration else { return }
        audio.enableRate = true
        audio.rate = Float(speed)
        audio.currentTime = at
        audio.play()
    }

    private func updateClock() {
        guard needsClock, automaticTicks else {
            link?.invalidate()
            link = nil
            return
        }
        guard link == nil else { return }
        let target = ReplayDisplayTarget { [weak self] link in
            guard let self else { link.invalidate(); return }
            self.tick(at: link.timestamp)
        }
        let display = CADisplayLink(target: target, selector: #selector(ReplayDisplayTarget.frame(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        display.add(to: .main, forMode: .common)
        link = display
    }
}

/// Display links retain their target. The callback's owner is always weak.
@MainActor final class ReplayDisplayTarget: NSObject {
    let callback: (CADisplayLink) -> Void
    init(_ callback: @escaping (CADisplayLink) -> Void) { self.callback = callback }
    @objc func frame(_ link: CADisplayLink) { callback(link) }
}

/// Expensive replay projection changes only at a recorded checkpoint. It never calls models.
@MainActor @Observable
final class ReplayProjection {
    private(set) var timeline = RunTimeline(folder: URL(fileURLWithPath: "/dev/null"))
    private(set) var blocks: [CardBlocks.Block] = []
    private(set) var heard: [RunTimeline.Sentence] = []
    @ObservationIgnored private var cardCheckpoint = -1
    @ObservationIgnored private var transcriptCheckpoint = -1
    @ObservationIgnored private(set) var cardUpdates = 0
    @ObservationIgnored private(set) var transcriptUpdates = 0

    func configure(_ timeline: RunTimeline) {
        self.timeline = timeline
        cardCheckpoint = -1
        transcriptCheckpoint = -1
    }

    func move(to time: Double, manual: Bool) {
        let cards = timeline.cardCheckpoint(at: time), transcript = timeline.transcriptCheckpoint(at: time)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = manual
        withTransaction(transaction) {
            if cards != cardCheckpoint {
                blocks = timeline.blocks(at: time)
                cardCheckpoint = cards
                cardUpdates += 1
            }
            if transcript != transcriptCheckpoint {
                heard = timeline.heard(by: time)
                transcriptCheckpoint = transcript
                transcriptUpdates += 1
            }
        }
    }
}

/// Content which depends on frame time lives in this small view, never in the lane/table parent.
struct ReplayMomentContent<Content: View>: View {
    var replay: ReplayController?
    var fallback: Double
    @ViewBuilder var content: (Double) -> Content
    var body: some View { content(replay?.moment ?? fallback) }
}
