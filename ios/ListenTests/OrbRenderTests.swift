import Combine
import Foundation
import Metal
import Testing
@testable import Listen

@MainActor @Suite(.timeLimit(.minutes(1))) struct OrbSystemNotifications {
    @Test func backgroundThermalAndPowerNotificationsReachTheMainActor() async {
        let center = NotificationCenter()
        let events = AsyncStream.makeStream(of: String.self)
        let thermal = OrbSystemState.thermalChanges(center: center).sink { _ in
            MainActor.preconditionIsolated()
            events.continuation.yield("thermal")
        }
        let power = OrbSystemState.powerChanges(center: center).sink { _ in
            MainActor.preconditionIsolated()
            events.continuation.yield("power")
        }
        defer { thermal.cancel(); power.cancel(); events.continuation.finish() }
        await Task.detached {
            for _ in 0..<20 {
                center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
                center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            }
        }.value
        var received: [String] = []
        for await event in events.stream.prefix(40) { received.append(event) }
        #expect(received.filter { $0 == "thermal" }.count == 20)
        #expect(received.filter { $0 == "power" }.count == 20)
    }
}

/// The Metal fragment reads this ABI directly, with no encoder translating fields.
@Suite struct OrbRenderABI {
    @MainActor @Test func nativeFragmentLinksFromTheActualAppLibrary() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try #require(library.makeFunction(name: "listenOrbVertex"))
        descriptor.fragmentFunction = try #require(library.makeFunction(name: "listenOrbFragment"))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    @MainActor @Test func newSurfacesReuseTheirCompiledPipelineAndQueue() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = OrbPipelineCache()
        let first = try cache.resources(for: device), next = try cache.resources(for: device)
        #expect(first.pipeline === next.pipeline)
        #expect(first.commands === next.commands)
    }
    @Test func uniformLayoutMatchesTheMetalBufferContract() {
        #expect(MemoryLayout<OrbGPUUniforms>.stride == 72)
        #expect(MemoryLayout<OrbGPUUniforms>.offset(of: \.canvas) == 0)
        #expect(MemoryLayout<OrbGPUUniforms>.offset(of: \.pixels) == 8)
        #expect(MemoryLayout<OrbGPUUniforms>.offset(of: \.lean) == 16)
        #expect(MemoryLayout<OrbGPUUniforms>.offset(of: \.time) == 24)
        #expect(MemoryLayout<OrbGPUUniforms>.offset(of: \.waveCount) == 64)
    }
}


@MainActor @Suite struct OrbNativeAnimation {
    private func input(level: Float = 0) -> OrbGPUUniforms {
        OrbGPUUniforms(canvas: SIMD2(850, 850), lean: .zero, time: 40, morph: 0,
            level: level, speakers: 1, active: 1, dark: 1, gather: 0, since: 99, bleed: 255, gain: 1)
    }
    @Test func animationAndSignalAdvanceBetweenUnchangedInputSnapshots() {
        let animation = OrbFrameAnimator(), began = Date(timeIntervalSinceReferenceDate: 100)
        _ = animation.frame(target: input(), waveform: [0, 0], at: began, isActive: true, changedAt: nil, advancesTime: true, lean: .zero)
        let target = input(level: 1)
        let first = animation.frame(target: target, waveform: [1, 1], at: began.addingTimeInterval(1.0 / 60), isActive: true, changedAt: nil, advancesTime: true, lean: CGSize(width: 1, height: 0))
        let second = animation.frame(target: target, waveform: [1, 1], at: began.addingTimeInterval(2.0 / 60), isActive: true, changedAt: nil, advancesTime: true, lean: CGSize(width: 1, height: 0))
        #expect(first.uniforms.time > 100 && second.uniforms.time > first.uniforms.time)
        #expect(first.uniforms.level > 0 && first.uniforms.level < second.uniforms.level && second.uniforms.level < 1)
        #expect(first.waveform[0] > 0 && first.waveform[0] < second.waveform[0] && second.waveform[0] < 1)
        #expect(second.uniforms.lean.x > first.uniforms.lean.x)
    }
    @Test func microphoneFadeAndFixedPreviewKeepTheirTiming() {
        let animation = OrbFrameAnimator(), began = Date(timeIntervalSinceReferenceDate: 100)
        let first = animation.frame(target: input(), waveform: [], at: began, isActive: true, changedAt: began, advancesTime: false, lean: .zero)
        let warm = animation.frame(target: input(), waveform: [], at: began.addingTimeInterval(0.8), isActive: true, changedAt: began, advancesTime: false, lean: .zero)
        let off = animation.frame(target: input(), waveform: [], at: began.addingTimeInterval(0.5), isActive: false, changedAt: began, advancesTime: false, lean: .zero)
        #expect(first.uniforms.active == 0 && warm.uniforms.active == 1 && off.uniforms.active == 0)
        #expect(first.uniforms.time == 40 && warm.uniforms.time == 40)
        #expect(warm.uniforms.since > 0.79 && warm.uniforms.since < 0.81 && off.uniforms.since == 99)
        #expect(off.waveform.count == 64 && abs(off.uniforms.gain - 1.2) < 0.00001)
    }
    @Test func aPausedSceneStaysStillWhileSignalInputsCanChange() {
        let animation = OrbFrameAnimator(), began = Date(timeIntervalSinceReferenceDate: 100)
        _ = animation.frame(target: input(), waveform: [0, 0], at: began, isActive: true, changedAt: nil, advancesTime: true, lean: .zero)
        let paused = animation.frame(target: input(level: 1), waveform: [1, 1], at: began.addingTimeInterval(0.1), isActive: true, changedAt: nil, advancesTime: true, lean: .zero, holdsScene: true)
        let still = animation.frame(target: input(level: 1), waveform: [1, 1], at: began.addingTimeInterval(1), isActive: true, changedAt: nil, advancesTime: true, lean: .zero, holdsScene: true)
        #expect(paused.uniforms.time == 100 && still.uniforms.time == 100)
        #expect(paused.waveform[0] > 0 && still.waveform[0] > paused.waveform[0])
        let resumed = animation.frame(target: input(), waveform: [0, 0], at: began.addingTimeInterval(2), isActive: true, changedAt: nil, advancesTime: true, lean: .zero)
        #expect(resumed.uniforms.time == 102)
    }
    @Test func anEarlierClockDoesNotReverseTheSmoothing() {
        let animation = OrbFrameAnimator(), began = Date(timeIntervalSinceReferenceDate: 100)
        let zero = animation.frame(target: input(), waveform: [0, 0], at: began, isActive: true, changedAt: nil, advancesTime: false, lean: .zero)
        let earlier = animation.frame(target: input(level: 1), waveform: [1, 1], at: began.addingTimeInterval(-0.01), isActive: true, changedAt: nil, advancesTime: false, lean: .zero)
        #expect(earlier.waveform == zero.waveform && earlier.uniforms.level == zero.uniforms.level)
    }
}
