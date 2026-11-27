import Foundation
import Metal
import QuartzCore
import SwiftUI

/// Matches ListenOrbUniforms in FluidOrb.metal, including its eight-byte alignment.
struct OrbGPUUniforms: Sendable {
    var canvas: SIMD2<Float>
    var pixels = SIMD2<Float>.zero
    var lean: SIMD2<Float>
    var time: Float
    var morph: Float
    var level: Float
    var speakers: Float
    var active: Float
    var dark: Float
    var gather: Float
    var since: Float
    var bleed: Float
    var gain: Float
    var waveCount: UInt32 = 0
    var padding: UInt32 = 0
}

/// Sound arrives ten times a second, the orb draws thirty or sixty times. Two things keep
/// what is shown moving evenly in between. A new target is not jumped to but approached in
/// a straight line over the time one arrival takes, so the motion does not pause between
/// arrivals; and the shown value follows that on a critically damped spring, so its speed
/// has no step. A plain exponential glide towards the newest target moves furthest in the
/// first frame after every arrival and then stalls: a beat ten times a second in the line
/// and the body. The price is about a tenth of a second by which the drawing trails the sound.
@MainActor final class WaveFlow {
    private var shown: [Float] = []
    private var speed: [Float] = []
    private var from: [Float] = []
    private var to: [Float] = []
    private var arrived = Date.distantPast
    private var interval = 0.1
    private var last = Date.distantPast
    private let rate: Float

    /// `rate` is how tightly the spring follows: it trails by about 2 / rate seconds.
    init(rate: Float = 24) { self.rate = rate }

    func step(towards target: [Float], at date: Date) -> [Float] {
        let elapsed = max(0, min(date.timeIntervalSince(last), 0.1))
        last = date
        guard shown.count == target.count else {
            shown = target; from = target; to = target
            speed = [Float](repeating: 0, count: target.count)
            arrived = date
            return shown
        }
        if target != to {
            // It arrived at some moment since the last frame; the approach starts there, from
            // wherever the last approach had got to.
            let reached = Float(min(1, max(0, date.timeIntervalSince(arrived) - elapsed) / interval))
            for index in from.indices { from[index] += (to[index] - from[index]) * reached }
            interval = min(0.25, max(0.05, date.timeIntervalSince(arrived) - elapsed))
            to = target
            arrived = date.addingTimeInterval(-elapsed)
        }
        let along = Float(min(1, max(0, date.timeIntervalSince(arrived)) / interval))
        // The exact solution over the elapsed time, so it is the same motion at any frame rate.
        let time = Float(elapsed), decay = exp(-rate * time)
        for index in shown.indices {
            let aim = from[index] + (to[index] - from[index]) * along
            let offset = shown[index] - aim
            let push = (speed[index] + rate * offset) * time
            shown[index] = aim + (offset + push) * decay
            speed[index] = (speed[index] - rate * push) * decay
        }
        return shown
    }
}

/// How far the orb is on its way from its calm forms (0) to the signal (1). The shader
/// lays the way out (FluidOrb.metal); this decides when it is walked, from the raw
/// "someone is probably speaking" flag, which flickers between syllables and at noises.
/// The way there starts at once, so speech is answered without delay, but takes
/// `rise` seconds. Nothing shows on its first tenth, so a single loud frame passes unseen,
/// and the stretch after that only folds the wings: a short noise makes the orb flinch and
/// return, not change form. A flag that flickers, as it does when a quiet voice hovers at
/// the threshold, does not turn the orb round every tenth of a second: the way back starts
/// only after `patience` seconds of quiet, and once past `commit` only after `hold`, so
/// pauses between words leave the signal standing.
@MainActor final class OrbTransition {
    static let rise = 0.9, fall = 1.3, hold = 0.5, commit = 0.75, patience = 0.22
    private var progress = 0.0
    private var shown = 0.0
    private var quiet = 0.0
    private var last: Date?

    /// `snaps`: nothing is animating (paused, reduced motion), so the form is taken at once.
    func step(towards target: Float, at date: Date, snaps: Bool = false) -> Float {
        let speaking = target >= 0.5
        guard let before = last, !snaps else {
            last = date
            progress = speaking ? 1 : 0; shown = progress; quiet = speaking ? 0 : Self.hold
            return Float(shown)
        }
        let elapsed = max(0, min(date.timeIntervalSince(before), 0.1))
        last = date
        if speaking {
            quiet = 0
            progress = min(1, progress + elapsed / Self.rise)
        } else {
            quiet += elapsed
            if quiet >= (progress < Self.commit ? Self.patience : Self.hold) { progress = max(0, progress - elapsed / Self.fall) }
        }
        // Rounds the corners where the way is taken up, left or turned round.
        shown += (progress - shown) * (1 - exp(-elapsed * 14))
        if abs(shown - progress) < 0.0005 { shown = progress }
        return Float(shown)
    }
}

#if canImport(UIKit)
import UIKit

/// The phone renders the same orb into a bounded texture instead of shading the
/// entire 3x Retina canvas. SwiftUI still owns layout, motion and interaction.
@MainActor struct OrbMetalSurface: UIViewRepresentable {
    static let device = MTLCreateSystemDefaultDevice()
    var uniforms: OrbGPUUniforms
    var waveform: [Float]
    var isActive: Bool
    var changedAt: Date?
    var advancesTime: Bool
    var followsDeviceMotion: Bool
    var framesPerSecond: Int
    var pixelLimit: Int
    var paused: Bool
    var visible: Bool
    var failed: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> OrbMetalView {
        let view = OrbMetalView(frame: .zero)
        view.isOpaque = false; view.backgroundColor = .clear
        let layer = view.metal
        layer.isOpaque = false
        layer.device = Self.device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        // One displayed, one retained by the compositor, one available to draw.
        // The renderer still permits only one queued/in-flight GPU command.
        layer.maximumDrawableCount = 3
        if let device = Self.device {
            context.coordinator.renderer = OrbMetalRenderer(device: device, layer: layer, failed: failed)
        }
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: OrbMetalView, context: Context) {
        context.coordinator.uniforms = uniforms
        context.coordinator.waveform = waveform
        context.coordinator.isActive = isActive
        context.coordinator.changedAt = changedAt
        context.coordinator.advancesTime = advancesTime
        context.coordinator.followsDeviceMotion = followsDeviceMotion
        #if DEBUG
        context.coordinator.renderer?.inputUpdated()
        #endif
        view.pixelLimit = pixelLimit; view.resizeSurface()
        context.coordinator.configure(framesPerSecond: framesPerSecond, paused: paused)
        if paused && visible { context.coordinator.draw() }
    }
    static func dismantleUIView(_ view: OrbMetalView, coordinator: Coordinator) { coordinator.stop() }

    /// The display link only queues work. It never obtains a drawable on main.
    /// MetalKit's own drawing loop would compete with the renderer for drawables.
    @MainActor final class Coordinator: NSObject {
        fileprivate var renderer: OrbMetalRenderer?
        var uniforms: OrbGPUUniforms?
        var waveform: [Float] = []
        private var link: CADisplayLink?
        private var configuredFPS: Int?
        private let animator = OrbFrameAnimator()
        private var holdsScene = true
        var isActive = true
        var changedAt: Date?
        var advancesTime = true
        var followsDeviceMotion = true
        func configure(framesPerSecond: Int, paused: Bool) {
            holdsScene = paused
            if link == nil {
                let value = CADisplayLink(target: self, selector: #selector(tick))
                value.add(to: .main, forMode: .common); link = value
            }
            if configuredFPS != framesPerSecond {
                link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(framesPerSecond), maximum: Float(framesPerSecond), preferred: Float(framesPerSecond))
                configuredFPS = framesPerSecond
            }
            if link?.isPaused != paused { link?.isPaused = paused }
        }
        @objc private func tick() { draw() }
        func draw() {
            guard let uniforms else { return }
            let lean = followsDeviceMotion ? OrbMotion.shared.tilt : CGSize(width: CGFloat(uniforms.lean.x), height: CGFloat(uniforms.lean.y))
            let frame = animator.frame(target: uniforms, waveform: waveform, at: .now,
                isActive: isActive, changedAt: changedAt, advancesTime: advancesTime, lean: lean, holdsScene: holdsScene)
            renderer?.render(frame.uniforms, waveform: frame.waveform)
        }
        func stop() { link?.invalidate(); link = nil; configuredFPS = nil; renderer = nil }
    }
}

@MainActor final class OrbMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metal: CAMetalLayer { layer as! CAMetalLayer }
    var pixelLimit = 1024
    override func layoutSubviews() { super.layoutSubviews(); resizeSurface() }
    func resizeSurface() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(traitCollection.displayScale, CGFloat(pixelLimit) / max(bounds.width, bounds.height))
        let target = CGSize(width: max(1, floor(bounds.width * scale)), height: max(1, floor(bounds.height * scale)))
        if metal.drawableSize != target { metal.drawableSize = target }
    }
}

/// Advances between input snapshots without asking SwiftUI to rebuild the view.
@MainActor final class OrbFrameAnimator {
    private let signal = WaveFlow()
    private let level = WaveFlow()
    private let body = OrbBody()
    private let transition = OrbTransition()
    private let voices = WaveFlow(rate: 7)
    private var sceneTime: Float?

    func frame(target: OrbGPUUniforms, waveform: [Float], at date: Date, isActive: Bool,
               changedAt: Date?, advancesTime: Bool, lean: CGSize, holdsScene: Bool = false) -> (uniforms: OrbGPUUniforms, waveform: [Float]) {
        var value = target
        if advancesTime {
            let now = Float(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            value.time = holdsScene ? (sceneTime ?? now) : now
        }
        sceneTime = value.time
        let age = max(0, Float(date.timeIntervalSince(changedAt ?? .distantPast)))
        value.active = isActive ? min(1, age / 0.8) : max(0, 1 - age / 0.5)
        value.since = isActive && changedAt != nil ? age : 99
        value.level = max(0, level.step(towards: [target.level], at: date)[0])
        // A voice found or lost: its line fades and the others make room, instead of jumping.
        value.speakers = voices.step(towards: [target.speakers], at: date)[0]
        value.morph = transition.step(towards: target.morph, at: date, snaps: holdsScene)
        let shape = signal.step(towards: waveform.isEmpty ? [Float](repeating: 0, count: 64) : waveform, at: date)
        value.gain = 0.12 / max(shape.reduce(Float.zero) { max($0, abs($1)) }, 0.10)
        let position = body.step(towards: lean, at: date)
        value.lean = SIMD2(Float(position.width), Float(position.height))
        return (value, shape)
    }
}

/// Reuse immutable GPU resources when switching between the start orb, topics
/// and assistant. Compilation is requested only from the renderer's background queue.
final class OrbPipelineCache: @unchecked Sendable {
    static let shared = OrbPipelineCache()
    struct Resources {
        let pipeline: any MTLRenderPipelineState
        let commands: any MTLCommandQueue
    }
    private let lock = NSLock()
    private var entries: [UInt64: Resources] = [:]

    func resources(for device: any MTLDevice) throws -> Resources {
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[device.registryID] { return existing }
        let library = try device.makeDefaultLibrary(bundle: .main)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Listen orb"
        descriptor.vertexFunction = library.makeFunction(name: "listenOrbVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "listenOrbFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        guard let commands = device.makeCommandQueue() else { throw OrbPipelineFailure.commandQueue }
        commands.label = "Listen orb"
        let value = Resources(pipeline: try device.makeRenderPipelineState(descriptor: descriptor), commands: commands)
        entries[device.registryID] = value
        return value
    }
    private enum OrbPipelineFailure: Error { case commandQueue }
}

/// Only this serial queue touches the pipeline. At most one frame is queued or
/// in flight. Obtaining a drawable and waiting for the GPU never block the UI.
fileprivate final class OrbMetalRenderer: @unchecked Sendable {
    private let device: any MTLDevice
    private let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "Listen.orb.render", qos: .userInteractive)
    private let slot = DispatchSemaphore(value: 1)
    private var commands: (any MTLCommandQueue)?
    private var pipeline: (any MTLRenderPipelineState)?
    private var broken = false
    private let failed: @MainActor @Sendable () -> Void
    #if DEBUG
    private let statistics = ProcessInfo.processInfo.environment["LISTEN_FRAME_PROBE"] == "1" ? OrbGPUStatistics() : nil
    #endif

    init(device: any MTLDevice, layer: CAMetalLayer, failed: @escaping @MainActor @Sendable () -> Void) {
        self.device = device; self.layer = layer; self.failed = failed
    }
    #if DEBUG
    func inputUpdated() { statistics?.inputUpdated() }
    #endif
    func render(_ values: OrbGPUUniforms, waveform: [Float]) {
        guard slot.wait(timeout: .now()) == .success else {
            #if DEBUG
            statistics?.skipped()
            #endif
            return
        }
        queue.async { [self] in
            autoreleasepool {
                var committed = false
                defer { if !committed { slot.signal() } }
                guard !broken else { return }
                do {
                    if pipeline == nil {
                        let resources = try OrbPipelineCache.shared.resources(for: device)
                        pipeline = resources.pipeline; commands = resources.commands
                    }
                    guard let pipeline, let command = commands?.makeCommandBuffer(), let drawable = layer.nextDrawable() else { return }
                    command.label = "Listen orb frame"
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = drawable.texture
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
                    var uniforms = values
                    uniforms.pixels = SIMD2(Float(drawable.texture.width), Float(drawable.texture.height))
                    var wave = waveform.isEmpty ? [Float](repeating: 0, count: 64) : waveform
                    uniforms.waveCount = UInt32(wave.count)
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OrbGPUUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                    #if DEBUG
                    let statistics = statistics
                    #if !targetEnvironment(simulator)
                    if let statistics { drawable.addPresentedHandler { statistics.presented(at: $0.presentedTime) } }
                    #endif
                    #endif
                    command.present(drawable)
                    let slot = slot
                    let failed = failed
                    command.addCompletedHandler { command in
                        slot.signal()
                        if command.status == .error {
                            #if DEBUG
                            print("[OrbGPU] command failed: \(command.error?.localizedDescription ?? "unknown GPU error")")
                            #endif
                            Task { @MainActor in failed() }
                            return
                        }
                        #if DEBUG
                        statistics?.completed(gpuMilliseconds: max(0, command.gpuEndTime - command.gpuStartTime) * 1000)
                        #endif
                    }
                    command.commit(); committed = true
                } catch {
                    broken = true
                    #if DEBUG
                    print("[OrbGPU] native pipeline unavailable: \(error.localizedDescription)")
                    #endif
                    Task { @MainActor [failed] in failed() }
                }
            }
        }
    }
}

#if DEBUG
/// GPU completion and drawable-presentation timestamps. Neither measures the display glass.
private final class OrbGPUStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var began = ProcessInfo.processInfo.systemUptime
    private var last: Double?
    private var frames = 0, drops = 0, inputs = 0
    private var gpu = 0.0, worst = 0.0
    private var presentations = 0
    private var firstPresentation: Double?, lastPresentation: Double?
    func inputUpdated() { lock.lock(); inputs += 1; lock.unlock() }
    func skipped() { lock.lock(); drops += 1; lock.unlock() }
    func presented(at time: Double) {
        guard time > 0 else { return } // Zero means not presented or skipped.
        lock.lock(); defer { lock.unlock() }
        presentations += 1
        firstPresentation = min(firstPresentation ?? time, time)
        lastPresentation = max(lastPresentation ?? time, time)
    }
    func completed(gpuMilliseconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        frames += 1; gpu += gpuMilliseconds
        if let last { worst = max(worst, now - last) }
        last = now
        let seconds = now - began
        guard seconds >= 5 else { lock.unlock(); return }
        let presented: String
        if presentations > 1, let firstPresentation, let lastPresentation, lastPresentation > firstPresentation {
            presented = String(format: "%.1f", Double(presentations - 1) / (lastPresentation - firstPresentation))
        } else { presented = "n/a" }
        let message = String(format: "[OrbGPU] frames=%d seconds=%.2f completedFPS=%.1f presentedFPS=%@ busyDrops=%d meanGPU=%.2fms maxGap=%.1fms inputUpdates=%d", frames, seconds, Double(frames) / seconds, presented, drops, gpu / Double(frames), worst * 1000, inputs)
        began = now; frames = 0; drops = 0; gpu = 0; worst = 0; inputs = 0
        presentations = 0; firstPresentation = nil; lastPresentation = nil
        lock.unlock()
        print(message)
    }
}
#endif

#endif
