import Combine
import CoreMotion
import SwiftUI

/// The living element. One shader draws it, so it can flow between its forms:
/// blobs and a swarm of particles when it is quiet, strokes on the signal when someone speaks.
struct FluidOrb: View {
    /// 0 is spheres, 1 is signals: where the orb should be. `OrbTransition` takes it there.
    var morph: Double
    /// Microphone level, 0 to 1.
    var level: Double
    /// The captured sound itself, values from -1 to 1. The signal line is this shape.
    var waveform: [Float] = []
    /// Signal lines to draw when morphed, one per voice found.
    var speakers = 1
    /// Grey when the microphone is off or not allowed; it keeps moving.
    var isActive = true
    /// A covering settings sheet can suspend this decoration without changing capture.
    var isVisible = true

    @State private var motionOwner = UUID()
    @State private var appeared = false
    @State private var metalFailed = false
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var flow = WaveFlow()
    @State private var loudness = WaveFlow()
    @State private var voices = WaveFlow(rate: 7)
    @State private var transition = OrbTransition()
    @State private var body_ = OrbBody()
    @State private var touch: CGSize?
    /// When the microphone was last switched on or off; nil until it happens while the orb is shown.
    @State private var changed: Date?
    /// The change whose wake-up and colour have run out. Only kept when the orb is held at one
    /// moment (`fixedTime`), to know when nothing moves any more.
    @State private var settled: Date?
    /// Low Power Mode: the orb then draws half as often.
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// How long after a change of the microphone something still moves that does not depend on
    /// `time`: the shader follows `since` up to ten seconds.
    private static let wakeLasts = 10.0

    private var motionWanted: Bool { appeared && isVisible && scenePhase == .active && !reduceMotion && Self.fixedTime == nil && thermal != .critical }
    private var nativeEnabled: Bool {
        OrbMetalSurface.device != nil && !metalFailed
    }
    private var frameInterval: Double {
        if nativeEnabled {
            if thermal == .critical { return 1.0 / 15 }
            #if targetEnvironment(macCatalyst)
            return 1.0 / 30
            #else
            return lowPower || thermal == .serious || OrbGPUShare.shared.mode == .yielding ? 1.0 / 30 : 1.0 / 60
            #endif
        }
        if thermal == .critical { return 1.0 / 5 }
        return lowPower || thermal == .serious ? 1.0 / 15 : 1.0 / 30
    }

    /// `LISTEN_ORB_TIME` on a debug build holds the orb at one moment, to look at a form of it.
    private static let fixedTime: Float? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["LISTEN_ORB_TIME"].flatMap(Float.init)
        #else
        nil
        #endif
    }()

    /// `LISTEN_ORB_FORM=sphere` on a debug build keeps the orb gathered and quiet, to look at its wings.
    private static let heldAsSphere: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["LISTEN_ORB_FORM"] == "sphere"
        #else
        false
        #endif
    }()

    var body: some View {
        let frozen = Self.fixedTime != nil && (changed == nil || settled == changed)
        let paused = !isVisible || !appeared || reduceMotion || scenePhase != .active || frozen || OrbGPUShare.shared.mode == .still
        renderSurface(paused: paused)
        .background {
            // Reads where the pointer or a finger is, without taking taps away.
            GeometryReader { geometry in
                Color.clear
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): touch = Self.pull(towards: point, in: geometry.size)
                        case .ended: touch = nil
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { touch = Self.pull(towards: $0.location, in: geometry.size) }
                            .onEnded { _ in touch = nil })
            }
        }
        .onAppear { appeared = true; OrbMotion.shared.setActive(motionWanted, owner: motionOwner) }
        .onDisappear { appeared = false; OrbMotion.shared.setActive(false, owner: motionOwner) }
        .onChange(of: motionWanted) { _, wanted in OrbMotion.shared.setActive(wanted, owner: motionOwner) }
        .onReceive(OrbSystemState.thermalChanges()) { thermal = $0 }
        .onChange(of: isActive) { changed = .now }
        .onReceive(OrbSystemState.powerChanges()) { lowPower = $0 }
        // Held at one moment, the orb stands still again once a change has played out.
        .task(id: changed) {
            guard Self.fixedTime != nil, let stamp = changed else { return }
            try? await Task.sleep(for: .seconds(Self.wakeLasts))
            guard !Task.isCancelled else { return }
            settled = stamp
        }
        #if DEBUG
        // `LISTEN_ORB_WAKE=<seconds>`: plays the wake-up that long after launch, to look at it.
        .task {
            guard let delay = ProcessInfo.processInfo.environment["LISTEN_ORB_WAKE"].flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(delay))
            changed = .now
        }
        #endif
        .accessibilityHidden(true)
    }

    @ViewBuilder private func renderSurface(paused: Bool) -> some View {
        if nativeEnabled { nativeSurface(paused: paused) }
        else {
        #if targetEnvironment(macCatalyst)
            // Keep the fallback off the TimelineView callback that crashed in
            // the Catalyst runtime's executor check. Audio updates still redraw it.
            swiftUISurface(bleed: 0, time: Self.fixedTime ?? 0, morph: Float(morph),
                level: Float(level), speakers: Float(speakers), active: isActive ? 1 : 0,
                dark: colorScheme == .dark ? 1 : 0, lean: touch ?? .zero,
                since: 99, gain: 1, waveform: waveform)
        #else
            swiftUITimeline(paused: paused)
        #endif
        }
    }

    /// Targets change with audio/input, not on every display tick. The native
    /// coordinator owns its clock, smoothing and motion between those updates.
    private func nativeSurface(paused: Bool) -> some View {
        GeometryReader { geometry in
            let bleed = 0.75 * min(geometry.size.width, geometry.size.height)
            OrbMetalSurface(uniforms: OrbGPUUniforms(
                canvas: SIMD2(Float(geometry.size.width + bleed * 2), Float(geometry.size.height + bleed * 2)),
                lean: SIMD2(Float(touch?.width ?? 0), Float(touch?.height ?? 0)),
                time: Self.fixedTime ?? 0, morph: Self.heldAsSphere ? 0 : Float(morph),
                level: Self.heldAsSphere ? 0 : Float(level), speakers: Float(speakers), active: isActive ? 1 : 0,
                dark: colorScheme == .dark ? 1 : 0, gather: Self.heldAsSphere ? 1 : 0, since: 99, bleed: Float(bleed), gain: 1),
                waveform: waveform, isActive: isActive, changedAt: reduceMotion ? nil : changed,
                advancesTime: Self.fixedTime == nil, followsDeviceMotion: touch == nil,
                framesPerSecond: Int((1 / frameInterval).rounded()),
                pixelLimit: thermal == .critical || OrbGPUShare.shared.mode == .yielding ? 512 : (lowPower || thermal == .serious ? 768 : 1024),
                paused: paused, visible: isVisible && appeared && scenePhase == .active, failed: { metalFailed = true })
                .padding(-bleed)
                .allowsHitTesting(false)
        }
    }
    private func swiftUITimeline(paused: Bool) -> some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { context in
            let morph = transition.step(towards: Self.heldAsSphere ? 0 : Float(morph), at: context.date, snaps: paused)
            let level = Self.heldAsSphere ? 0 : Float(level)
            let target = waveform.isEmpty ? [Float](repeating: 0, count: Waveform.points) : waveform
            let sinceChange = Float(context.date.timeIntervalSince(changed ?? .distantPast))
            let since: Float = isActive && changed != nil ? sinceChange : 99
            let active: Float = isActive ? min(1, sinceChange / 0.8) : max(0, 1 - sinceChange / 0.5)
            let time = Self.fixedTime ?? Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            let waveform = flow.step(towards: target, at: context.date)
            let shownLevel = max(0, loudness.step(towards: [level], at: context.date)[0])
            let shownSpeakers = voices.step(towards: [Float(speakers)], at: context.date)[0]
            let peak = waveform.reduce(Float.zero) { max($0, abs($1)) }
            let gain: Float = 0.12 / max(peak, 0.10)
            let lean = body_.step(towards: touch ?? OrbMotion.shared.tilt, at: context.date)
            GeometryReader { geometry in
                swiftUISurface(bleed: 0.75 * min(geometry.size.width, geometry.size.height),
                    time: time, morph: morph, level: shownLevel, speakers: shownSpeakers, active: active,
                    dark: colorScheme == .dark ? 1 : 0, lean: lean, since: since, gain: gain, waveform: waveform)
            }
        }
    }

    private func swiftUISurface(bleed: CGFloat, time: Float, morph: Float, level: Float, speakers: Float, active: Float, dark: Float, lean: CGSize, since: Float, gain: Float, waveform: [Float]) -> some View {
        let gather: Float = Self.heldAsSphere ? 1 : 0
        return Rectangle().fill(.white)
            .visualEffect { content, proxy in
                content.colorEffect(ShaderLibrary.fluidOrb(
                    .float2(proxy.size), .float(time), .float(morph), .float(level), .float(speakers), .float(active), .float(dark),
                    .float2(lean.width, lean.height), .float(gather), .float(since),
                    .float(Float(bleed)), .float(gain), .floatArray(waveform)))
            }
            .padding(-bleed)
            .allowsHitTesting(false)
    }

    /// How far and which way a point pulls the body, from -1 to 1 on each axis.
    private static func pull(towards point: CGPoint, in size: CGSize) -> CGSize {
        let half = max(min(size.width, size.height) / 2, 1)
        let x = (point.x - size.width / 2) / half
        let y = (point.y - size.height / 2) / half
        let length = max(1, (x * x + y * y).squareRoot())
        return CGSize(width: x / length, height: y / length)
    }
}

/// The orb shares the GPU with the voice generated on this device, and on a phone that voice
/// only just keeps up with its own speech. While it is being generated the orb draws half as
/// often and at half the size: it keeps moving, without taking the time the voice needs.
@MainActor @Observable final class OrbGPUShare {
    enum Mode { case full, yielding, still }
    static let shared = OrbGPUShare()
    private var users = 0
    /// Set by a measurement instead (`TalkBackProbe`).
    var override: Mode?
    var mode: Mode { override ?? (users > 0 ? .yielding : .full) }
    func begin() { users += 1 }
    func end() { users = max(0, users - 1) }
}

/// NotificationCenter delivers on the posting thread. Hop before the first
/// main-actor closure, including Combine's map, rather than only before onReceive.
@MainActor enum OrbSystemState {
    static func thermalChanges(center: NotificationCenter = .default) -> AnyPublisher<ProcessInfo.ThermalState, Never> {
        center.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in ProcessInfo.processInfo.thermalState }
            .eraseToAnyPublisher()
    }

    static func powerChanges(center: NotificationCenter = .default) -> AnyPublisher<Bool, Never> {
        center.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .map { _ in ProcessInfo.processInfo.isLowPowerModeEnabled }
            .eraseToAnyPublisher()
    }
}

extension View {
    /// Semantic `primary` tint becomes white in dark mode; prominent buttons
    /// otherwise keep a white label. Resolve both sides of the monochrome action.
    func listenPrimaryAction() -> some View {
        modifier(ListenPrimaryAction())
    }

    /// A small floating glass row for status messages.
    func glassBanner() -> some View {
        self.font(.footnote)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct ListenPrimaryAction: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent)
            .tint(colorScheme == .dark ? Color.white : Color.black)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
    }
}

/// The orb's body has mass: it follows what pulls it on a spring, so it
/// overshoots, wobbles and settles instead of moving in straight lines.
@MainActor
final class OrbBody {
    private var position = CGSize.zero
    private var velocity = CGSize.zero
    private var last = Date.distantPast

    func step(towards target: CGSize, at date: Date) -> CGSize {
        let elapsed = max(0, min(date.timeIntervalSince(last), 0.1))
        last = date
        let stiffness = 42.0
        let damping = 5.5
        // Keep the spring's speed in real time at both 30 and 15 fps, with small,
        // stable integration steps rather than discarding half the elapsed time.
        let steps = max(1, Int(ceil(elapsed * 60)))
        let step = elapsed / Double(steps)
        for _ in 0..<steps {
            velocity.width += (stiffness * (target.width - position.width) - damping * velocity.width) * step
            velocity.height += (stiffness * (target.height - position.height) - damping * velocity.height) * step
            position.width += velocity.width * step
            position.height += velocity.height * step
        }
        return position
    }
}

/// How the device is being held and moved, as a pull on the orb. Stays zero
/// where there is no motion sensor, such as on a Mac.
@MainActor
final class OrbMotion {
    static let shared = OrbMotion()
    private(set) var tilt = CGSize.zero
    private let manager = CMMotionManager()
    private var owners = Set<UUID>()
    private var reading = OrbTilt()
    private var lastSample: TimeInterval?

    /// A transition may briefly show two orbs. One disappearing must not stop
    /// another visible orb; the last owner releases the sensor altogether.
    func setActive(_ active: Bool, owner: UUID) {
        if active { owners.insert(owner) } else { owners.remove(owner) }
        if owners.isEmpty {
            manager.stopDeviceMotionUpdates()
            tilt = .zero
            reading = OrbTilt()
            lastSample = nil
        } else { start() }
    }

    private func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = SIMD2(motion.gravity.x, motion.gravity.y)
            let shake = SIMD2(motion.userAcceleration.x, motion.userAcceleration.y)
            let stamp = motion.timestamp
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = self.lastSample.map { min(max(stamp - $0, 0), 0.5) } ?? 0
                self.lastSample = stamp
                self.tilt = self.reading.step(gravity: gravity, shake: shake, elapsed: elapsed)
            }
        }
    }
}
