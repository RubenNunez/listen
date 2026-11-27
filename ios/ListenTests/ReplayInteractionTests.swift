import AVFoundation
import SwiftUI
import Testing
import UIKit
@testable import Listen

@MainActor private final class ReplayTestAudio: ReplayAudio {
    var currentTime = 0.0
    var duration = 100.0
    var isPlaying = false
    var enableRate = false
    var rate: Float = 1
    var starts = 0
    @discardableResult func play() -> Bool { isPlaying = true; starts += 1; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; currentTime = 0 }
}

@MainActor @Suite struct ReplayInteraction {
    @Test func draggingOwnsTimeAndNeverReattachesFollow() {
        let replay = ReplayController(automaticTicks: false, clock: { 0 })
        replay.configure(length: 100)
        replay.seek(to: 20)
        replay.attachFollow()
        replay.togglePlayback()
        replay.beginScrub(.playhead)
        let generation = replay.seekGeneration
        replay.preview(25, source: .playhead)
        replay.tick(at: 5)
        #expect(replay.moment == 25 && !replay.follows && !replay.needsClock)
        replay.preview(22, source: .playhead)
        #expect(replay.seekGeneration == generation, "one interaction, not one card reset per pointer movement")
        replay.endScrub(.playhead)
        #expect(replay.playing && replay.needsClock && !replay.follows && replay.moment == 22)
    }

    @Test func sliderAndPlayheadCannotFightForTheSameInteraction() {
        let replay = ReplayController(automaticTicks: false)
        replay.configure(length: 100)
        replay.beginScrub(.playhead)
        replay.beginScrub(.slider)
        replay.preview(10, source: .slider)
        replay.endScrub(.slider)
        #expect(replay.scrubbing && replay.moment == 100)
        replay.preview(30, source: .playhead)
        replay.endScrub(.playhead)
        #expect(!replay.scrubbing && replay.moment == 30)
    }

    @Test func spaceDuringDragUpdatesIntentWithoutRestartingAudio() {
        let audio = ReplayTestAudio()
        let replay = ReplayController(automaticTicks: false)
        replay.configure(length: 100, audio: audio)
        replay.seek(to: 10)
        replay.togglePlayback()
        #expect(audio.isPlaying)
        let starts = audio.starts
        replay.beginScrub(.slider)
        replay.preview(35, source: .slider)
        replay.setSpeed(2)
        replay.setSound(false)
        replay.setSound(true)
        #expect(!audio.isPlaying && audio.starts == starts)
        replay.togglePlayback()
        replay.endScrub(.slider)
        #expect(!replay.playing && !audio.isPlaying && audio.starts == starts)
    }

    @Test func releaseSeeksAudioOnceAndKeepsItsRecordedOffset() {
        let audio = ReplayTestAudio()
        let replay = ReplayController(automaticTicks: false)
        replay.configure(length: 100, soundBegins: 5, audio: audio)
        replay.seek(to: 10)
        replay.togglePlayback()
        let starts = audio.starts
        replay.beginScrub(.playhead)
        for time in stride(from: 20.0, through: 40.0, by: 0.1) { replay.preview(time, source: .playhead) }
        #expect(audio.starts == starts)
        replay.endScrub(.playhead)
        #expect(audio.starts == starts + 1 && abs(audio.currentTime - 35) < 0.001)
    }

    @Test func delayedFramesUseElapsedTimeRatherThanAnAssumedTimerStep() {
        let replay = ReplayController(automaticTicks: false, clock: { 10 })
        replay.configure(length: 100)
        replay.seek(to: 20)
        replay.togglePlayback()
        replay.tick(at: 10.37)
        #expect(abs(replay.moment - 20.37) < 0.0001)
        replay.tick(at: 11.2)
        #expect(abs(replay.moment - 21.2) < 0.0001)
    }

    @Test func audioIsAuthoritativeAndSilentTailContinuesWithoutJumping() {
        let audio = ReplayTestAudio()
        audio.duration = 10
        let replay = ReplayController(automaticTicks: false, clock: { 0 })
        replay.configure(length: 100, soundBegins: 5, audio: audio)
        replay.seek(to: 8)
        replay.togglePlayback()
        audio.currentTime = 10
        replay.tick(at: 7)
        #expect(replay.moment == 15)
        audio.isPlaying = false
        replay.tick(at: 8)
        #expect(replay.moment == 16 && !audio.isPlaying)
    }

    @Test func cancellationRestoresTheStartAndInterruptionLeavesNoCapturedGesture() {
        let replay = ReplayController(automaticTicks: false)
        replay.configure(length: 100)
        replay.seek(to: 20)
        replay.beginScrub(.playhead)
        replay.preview(60, source: .playhead)
        replay.cancelScrub()
        #expect(replay.moment == 20 && !replay.scrubbing && !replay.follows)
        replay.togglePlayback()
        replay.beginScrub(.playhead)
        replay.preview(70, source: .playhead)
        replay.setActive(false)
        replay.setActive(true)
        #expect(replay.moment == 70 && !replay.scrubbing && !replay.playing && !replay.needsClock)
    }

    @Test func emptyRecordingsAndNonfiniteInputCannotRunAClockOrCorruptTime() {
        let replay = ReplayController(automaticTicks: false)
        replay.configure(length: 0)
        replay.togglePlayback()
        replay.seek(to: .nan)
        #expect(replay.moment == 0 && !replay.needsClock)
        replay.configure(length: 100)
        replay.seek(to: .infinity)
        #expect(replay.moment == 100)
        replay.seek(to: -1)
        #expect(replay.moment == 0)
        replay.seek(to: 1000)
        #expect(replay.moment == 100)
    }

    @Test func aPausedControllerHasNoDisplayLinkAndStopReleasesIt() {
        let replay = ReplayController()
        replay.configure(length: 100)
        #expect(!replay.hasDisplayLink)
        replay.togglePlayback()
        #expect(replay.hasDisplayLink)
        replay.beginScrub(.playhead)
        #expect(!replay.hasDisplayLink)
        replay.endScrub(.playhead)
        #expect(replay.hasDisplayLink)
        replay.stop()
        #expect(!replay.hasDisplayLink)
    }
}

@MainActor @Suite struct ReplayNativeTracking {
    private func mounted() -> (ReplayController, StripScroll, ReplayPlayheadControl) {
        let replay = ReplayController(automaticTicks: false)
        replay.configure(length: 1000)
        replay.seek(to: 20)
        replay.attachFollow()
        let scroll = StripScroll()
        scroll.record(TimelineViewport(offset: 500, width: 800, content: 46_000))
        let control = ReplayPlayheadControl(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        control.bind(replay, scroll: scroll, scale: 46, rulerHeight: 44)
        return (replay, scroll, control)
    }

    @Test func arbitraryGrabPointHasNoInitialJumpAndReversesImmediately() {
        let (replay, _, control) = mounted()
        // Keep the scroll alive: the control intentionally holds only weak references.
        let scroll = StripScroll()
        scroll.record(TimelineViewport(offset: 500, width: 800, content: 46_000))
        control.bind(replay, scroll: scroll, scale: 46, rulerHeight: 44)
        defer { control.disconnect() }
        let grab = CGPoint(x: 427, y: 22)
        #expect(control.begin(at: grab))
        control.move(to: grab)
        #expect(replay.moment == 20)
        control.move(to: CGPoint(x: 473, y: 22))
        #expect(abs(replay.moment - 21) < 0.0001)
        control.move(to: CGPoint(x: 404, y: 22))
        #expect(abs(replay.moment - 19.5) < 0.0001)
        control.finish(cancelled: false)
        #expect(!replay.follows && !replay.scrubbing)
    }

    @Test func edgeScrollKeepsTheGripUnderThePointer() {
        let (replay, scroll, control) = mounted()
        defer { control.disconnect() }
        #expect(control.begin(at: CGPoint(x: 427, y: 22)))
        scroll.record(TimelineViewport(offset: 600, width: 800, content: 46_000))
        #expect(abs(CGFloat(replay.moment) * 46 - scroll.offset - 420) < 0.01)
        #expect(control.frame.origin == .zero, "the gesture's coordinate space never moves with the thumb")
    }

    @Test func transparentAreaPassesThroughAndTouchTargetHasFullSizeAtTheEnds() {
        let (replay, scroll, control) = mounted()
        defer { control.disconnect() }
        #expect(control.point(inside: CGPoint(x: 427, y: 22), with: nil))
        #expect(!control.point(inside: CGPoint(x: 427, y: 80), with: nil))
        #expect(!control.point(inside: CGPoint(x: 100, y: 22), with: nil))
        replay.seek(to: 0)
        scroll.record(TimelineViewport(offset: 0, width: 800, content: 46_000))
        #expect(control.hitRect == CGRect(x: 0, y: 0, width: 44, height: 44))
    }

    @Test func cancellationAndDismantlingAlwaysReleaseTracking() {
        let (replay, scroll, control) = mounted()
        defer { withExtendedLifetime(scroll) {} }
        #expect(control.begin(at: CGPoint(x: 427, y: 22)))
        control.move(to: CGPoint(x: 600, y: 22))
        control.cancelInteraction()
        #expect(replay.moment == 20 && !control.dragging && !replay.scrubbing)
        #expect(control.begin(at: CGPoint(x: 427, y: 22)))
        control.disconnect()
        #expect(!control.dragging && !replay.scrubbing)
    }

    @Test func accessibilityUsesTheSameSeekPath() {
        let (replay, scroll, control) = mounted()
        defer { control.disconnect(); withExtendedLifetime(scroll) {} }
        control.accessibilityIncrement()
        #expect(replay.moment == 21 && !replay.follows)
        control.accessibilityDecrement()
        #expect(replay.moment == 20)
    }

    @Test func scrollingAwayDoesNotLeaveAFakeHandleClampedToTheEdge() {
        let (replay, scroll, control) = mounted()
        defer { control.disconnect() }
        replay.detachFollow()
        scroll.record(TimelineViewport(offset: 4000, width: 800, content: 46_000))
        #expect(!control.point(inside: CGPoint(x: 10, y: 22), with: nil))
        #expect(control.accessibilityElementsHidden)
        #expect(!control.begin(at: CGPoint(x: 10, y: 22)))
    }

    @Test func edgeSpeedIsBoundedAndStopsAwayFromTheEdge() {
        #expect(ReplayScrubGeometry.edgeVelocity(pointer: 400, width: 800) == 0)
        #expect(ReplayScrubGeometry.edgeVelocity(pointer: -1000, width: 800) == -2000)
        #expect(ReplayScrubGeometry.edgeVelocity(pointer: 1800, width: 800) == 2000)
        #expect(ReplayScrubGeometry.edgeVelocity(pointer: 10, width: 40) == 0)
        #expect(ReplayScrubGeometry.edgeVelocity(pointer: .nan, width: 800) == 0)
    }

    @Test func theStripComesAlongInABandThatStartsSoftly() {
        let width: CGFloat = 800, zone = ReplayScrubGeometry.edgeZone(width: width)
        #expect(abs(zone - width / 6) < 0.001)
        #expect(ReplayScrubGeometry.edgeZone(width: 300) == 56 && ReplayScrubGeometry.edgeZone(width: 2400) == 160)
        #expect(ReplayScrubGeometry.edgeVelocity(pointer: zone + 1, width: width) == 0)
        #expect(ReplayScrubGeometry.edgeVelocity(pointer: width - zone - 1, width: width) == 0)
        // Deeper into the band is faster; at the edge one strip width per second.
        let speeds = stride(from: zone - 1, through: 0, by: -10).map { -ReplayScrubGeometry.edgeVelocity(pointer: $0, width: width) }
        #expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0 < $1 })
        #expect(speeds.first! < 5, "it starts softly")
        #expect(abs(ReplayScrubGeometry.edgeVelocity(pointer: 0, width: width) + 800) < 0.01)
        #expect(abs(ReplayScrubGeometry.edgeVelocity(pointer: width, width: width) - 800) < 0.01)
    }

    @Test func holdingThePinInABandCarriesTheStripAndKeepsThePinUnderTheHand() {
        let (replay, scroll, control) = mounted()
        defer { control.disconnect() }
        #expect(control.begin(at: CGPoint(x: 427, y: 22)))
        control.move(to: CGPoint(x: 60, y: 22))
        let moment = replay.moment
        control.edgeFrame(1.0)
        control.edgeFrame(1.02)
        #expect(scroll.target < 500, "sent toward the start")
        control.edgeFrame(1.04)
        #expect(scroll.target < 500 - 2 * 0.02 * 200, "continues from where it was sent, not from a late report")
        // The strip reports the new offset: the time under the hand moves with it.
        scroll.record(TimelineViewport(offset: 480, width: 800, content: 46_000))
        #expect(abs(replay.moment - (moment - 20 / 46)) < 0.0001)
        #expect(abs(CGFloat(replay.moment) * 46 - scroll.offset - 53) < 0.01, "the pin stays where the hand holds it")
        control.finish(cancelled: false)
        #expect(!replay.follows && !replay.scrubbing)
    }

    @Test func theSoftStartOfABandAddsUpInsteadOfStalling() {
        let (replay, scroll, control) = mounted()
        defer { control.disconnect(); withExtendedLifetime(replay) {} }
        #expect(control.begin(at: CGPoint(x: 427, y: 22)))
        control.move(to: CGPoint(x: 120, y: 22))
        // About 8 points per second: a fifteenth of a point per frame, too little for one request.
        for frame in 0...12 { control.edgeFrame(1.0 + Double(frame) / 120) }
        #expect(scroll.target < 499.5)
        control.finish(cancelled: false)
    }

    @Test func aPinTakenNearAnEdgeDoesNotSetTheStripMovingUntilTheHandMovesTowardIt() {
        let (replay, scroll, control) = mounted()
        defer { control.disconnect() }
        replay.seek(to: 540.0 / 46)
        #expect(control.begin(at: CGPoint(x: 40, y: 22)))
        control.move(to: CGPoint(x: 44, y: 22))
        control.edgeFrame(1.0)
        control.edgeFrame(1.02)
        #expect(scroll.target == 500, "taking and steadying the pin leaves the strip")
        control.move(to: CGPoint(x: 30, y: 22))
        control.edgeFrame(1.04)
        control.edgeFrame(1.06)
        #expect(scroll.target < 500, "moving toward the edge does carry it")
        control.finish(cancelled: false)
    }

    @Test func keepingAMomentInViewMovesTheStripAsLittleAsPossible() {
        #expect(ReplayScrubGeometry.keepInView(900, shown: 500, width: 800, margin: 100) == 500)
        #expect(ReplayScrubGeometry.keepInView(1300, shown: 500, width: 800, margin: 100) == 600)
        #expect(ReplayScrubGeometry.keepInView(550, shown: 500, width: 800, margin: 100) == 450)
        #expect(ReplayScrubGeometry.keepInView(10_000, shown: 500, width: 800, margin: 100) == 9300)
        #expect(ReplayScrubGeometry.keepInView(.nan, shown: 500, width: 800, margin: 100) == 500)
    }
}

@Suite struct TimelineVisibleItems {
    @Test func longSpanningEventsAreKeptAndOffscreenEventsAreNotBuilt() {
        let intervals: [(CGFloat, CGFloat)] = [(0, 1000), (1100, 1150), (1200, 1250), (2000, 2100)]
        let visible = TimelineCulling.indices(count: intervals.count, lower: 900, upper: 1210,
                                              left: { intervals[$0].0 }, right: { intervals[$0].1 })
        #expect(visible == 0..<3)
        #expect(TimelineCulling.indices(count: intervals.count, lower: 1300, upper: 1900,
                                       left: { intervals[$0].0 }, right: { intervals[$0].1 }).isEmpty)
    }

    @Test func emptyRowsAndPositionsBeyondTheEndAreSafe() {
        #expect(TimelineCulling.indices(count: 0, lower: 0, upper: 800, left: { _ in 0 }, right: { _ in 0 }) == 0..<0)
        #expect(TimelineCulling.indices(count: 1, lower: 1000, upper: 2000, left: { _ in 0 }, right: { _ in 10 }) == 1..<1)
    }
}

/// The strip's clock while a run is recorded, read twice a second as the app does.
@Suite struct LiveStripClock {
    /// Readings every half second from `from` to `to`; the sound grows in real time up to
    /// `soundUntil` and stands still from there (a pause). Returns where the strip stood on
    /// every sixtieth of a second, as frames see it.
    private func run(_ clock: inout LiveClock, from: Double, to: Double, sound: (Double) -> Double) -> [Double] {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var shown: [Double] = []
        var reading = from
        for frame in stride(from: from, to: to, by: 1.0 / 60) {
            if frame >= reading {
                clock.keep(heard: sound(reading), at: start.addingTimeInterval(reading))
                reading += 0.5
            }
            shown.append(clock.time(at: start.addingTimeInterval(frame), heard: sound(reading - 0.5)))
        }
        return shown
    }

    /// Sound read with a little delay: what was spoken up to `t - 0.2` has been written and read.
    private func recorded(pausedFrom pause: Double = .infinity, until resume: Double = .infinity) -> (Double) -> Double {
        { t in
            let heard = max(0, t - 0.2)
            if heard <= pause { return heard }
            return t < resume ? pause : pause + max(0, heard - resume)
        }
    }

    @Test func aPausedRecordingHoldsTheStripStill() {
        var clock = LiveClock()
        let sound = recorded(pausedFrom: 20)
        let shown = run(&clock, from: 0, to: 40, sound: sound)
        // From when the strip reached the end of the sound until the end, it stands there.
        let held = shown.suffix(from: shown.firstIndex { $0 >= 20 - 0.0001 } ?? shown.endIndex)
        #expect(!held.isEmpty)
        #expect(held.allSatisfy { abs($0 - 20) < 0.0001 }, "it stood still, without jumping back: \(Set(held.map { ($0 * 100).rounded() / 100 }).sorted())")
    }

    @Test func soundAfterAPauseMovesTheStripOnWithoutThrowingItBack() {
        // Resumed between two readings: the readings during the pause must not have moved the
        // clock, or it runs ahead after the pause and sticks to the end of what was read.
        for resume in [34.6, 35.0, 35.3] {
            var clock = LiveClock()
            let shown = run(&clock, from: 0, to: 60, sound: recorded(pausedFrom: 20, until: resume))
            for (before, after) in zip(shown, shown.dropFirst()) {
                #expect(after >= before - 0.0001, "the strip never goes back: \(before) → \(after)")
            }
            // Moving again at the speed of the sound, frame by frame, the lag as before the pause.
            let frames = Array(shown.suffix(120))
            for (before, after) in zip(frames, frames.dropFirst()) {
                #expect(abs(after - before - 1.0 / 60) < 0.002, "a steady pace after resuming at \(resume): \(before) → \(after)")
            }
            let heard = 20 + (60 - 0.2 - resume)
            #expect(abs(shown.last! - (heard - LiveClock.lag)) < 0.05)
        }
    }

    @Test func whileRecordingTheStripRunsJustBehindTheSound() {
        var clock = LiveClock()
        let shown = run(&clock, from: 0, to: 20, sound: recorded())
        let frames = Array(shown.suffix(120))
        for (before, after) in zip(frames, frames.dropFirst()) {
            #expect(abs(after - before - 1.0 / 60) < 0.002, "a steady pace, frame by frame")
        }
        let now = 20 - 1.0 / 60
        #expect(abs(shown.last! - (now - LiveClock.lag)) < 0.05)
    }

    @Test func anotherRunStartsTheClockAnew() {
        var clock = LiveClock()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        // A run paused at 10 s and resumed: the strip waits at 10 until its clock catches up.
        clock.keep(heard: 10, at: start.addingTimeInterval(10))
        clock.keep(heard: 10, at: start.addingTimeInterval(20))
        clock.keep(heard: 10.5, at: start.addingTimeInterval(20.5))
        #expect(abs(clock.time(at: start.addingTimeInterval(20.6), heard: 10.5) - 10) < 0.0001)
        // Another run, with less sound: nothing of the first one holds it.
        clock.keep(heard: 1, at: start.addingTimeInterval(30))
        #expect(abs(clock.time(at: start.addingTimeInterval(30), heard: 1) - 0.1) < 0.0001)
    }
}
