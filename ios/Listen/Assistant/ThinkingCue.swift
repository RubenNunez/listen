import AVFoundation
import Observation
import SwiftUI

enum ThinkingSound: String, CaseIterable, Identifiable {
    case heartbeat, elevator
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heartbeat: "Heartbeat"
        case .elevator: "Elevator music"
        }
    }
    /// The heartbeat loops; the elevator music is as long as the longest wait and plays once.
    var loops: Bool { self == .heartbeat }
    static let key = "thinkingSound"
    static let volumeKey = "thinkingSoundVolume"
    /// A choice saved earlier that no longer exists (idle, soft, breath) becomes the heartbeat.
    static func stored(_ raw: String?) -> Self { Self(rawValue: raw ?? "") ?? .heartbeat }
    static var current: Self { stored(UserDefaults.standard.string(forKey: key)) }
    static var volume: Float {
        guard let value = UserDefaults.standard.object(forKey: volumeKey) as? Double else { return 0.6 }
        return Float(max(0, min(1, value)))
    }
}

/// A quiet heartbeat while an answer is being prepared, generated on the device; or, as a
/// joke, a short piece of elevator music that comes with the app. Gone as soon as the
/// voice speaks or the person speaks again. Nothing is recorded or sent.
///
/// It is a waiting sound, not an idle one: while Listen only listens there is no sound at
/// all. It begins half a second into a wait, so a round that ends at once stays silent, and
/// fades out by itself after twenty seconds, so a wait that never ends does not drone.
@MainActor final class ThinkingCue {
    private let standalone = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var loop: AVAudioPCMBuffer?
    private var loopSound: ThinkingSound?
    private var fading: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private(set) var playing = false
    /// Raised by every change, so a start or a limit that was overtaken does nothing.
    private var generation = 0

    static let delay = Duration.milliseconds(500)
    static let longest = Duration.seconds(20)

    func set(_ on: Bool, immediately: Bool = false) {
        // Repeated updates must not invalidate the running twenty-second limit.
        if on && (playing || starting != nil) { return }
        generation += 1
        starting?.cancel()
        starting = nil
        guard on else { stop(); return }
        guard !playing else { return }
        let generation = generation
        starting = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: Self.delay) }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.start()
        }
    }

    private func start() {
        guard !playing, !TalkBack.muted else { return }
        do {
            let sound = ThinkingSound.current
            let loop = try loopSound == sound ? (self.loop ?? Self.makeLoop(sound: sound)) : Self.makeLoop(sound: sound)
            self.loop = loop
            loopSound = sound
            let engine = VoiceAudioIO.engine ?? standalone
            VoiceAudioIO.reuse(player)
            if player.engine !== engine {
                player.stop()
                if let previous = player.engine { VoiceAudioIO.retire(player, from: previous) }
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: loop.format)
            }
            if !engine.isRunning { try engine.start() }
            fading?.cancel()
            player.stop()
            player.volume = 0
            player.scheduleBuffer(loop, at: nil, options: sound.loops ? .loops : [])
            player.play()
            playing = true
            fade(to: ThinkingSound.volume, over: 0.5)
            let generation = generation
            limit?.cancel()
            limit = Task { [weak self] in
                try? await Task.sleep(for: Self.longest)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.stop()
            }
        } catch {
            playing = false
        }
    }

    private func stop() {
        limit?.cancel()
        limit = nil
        guard playing else { return }
        playing = false
        fade(to: 0, over: 0.25) { [player, standalone] in
            player.stop()
            if let engine = player.engine, engine !== standalone { VoiceAudioIO.retire(player, from: engine) }
        }
    }

    private func fade(to target: Float, over seconds: Double, then done: (@MainActor () -> Void)? = nil) {
        fading?.cancel()
        let start = player.volume, steps = max(1, Int(seconds / 0.02))
        fading = Task { [player] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
                player.volume = start + (target - start) * Float(step) / Float(steps)
            }
            done?()
        }
    }

    // MARK: The sound

    nonisolated static let sampleRate = 24_000.0
    /// The heartbeat's loop, with silence at its seam.
    nonisolated static let loopSeconds = 2.4
    /// About -31 dBFS at the loudest sample.
    nonisolated static let peak = 0.028
    /// Music never pauses, so it may peak a little higher for a similar loudness (about -28 dBFS).
    nonisolated static let musicPeak = 0.04

    /// Two soft beats, the second quieter, on a low tone. The same samples every time:
    /// nothing here is random.
    nonisolated static func heartbeat() -> [Float] {
        let count = Int(sampleRate * loopSeconds)
        let pulses: [(at: Double, seconds: Double, level: Double)] = [(0, 0.36, 1), (0.43, 0.42, 0.65)]
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            var envelope = 0.0
            for pulse in pulses {
                let position = (time - pulse.at) / pulse.seconds
                guard position > 0, position < 1 else { continue }
                let shaped = sin(.pi * position)
                envelope += pulse.level * shaped * shaped
            }
            // No musical fifth: a low fundamental with a soft second harmonic.
            let tone = 0.9 * sin(2 * .pi * 110 * time) + 0.1 * sin(2 * .pi * 220 * time)
            return Float(peak * min(envelope, 1) * tone)
        }
    }

    /// "Local Forecast – Slower" by Kevin MacLeod (incompetech.com), CC BY 4.0, credited in
    /// NOTICE, THIRD_PARTY.md and the menu. The bundled file holds its first 20 seconds, mono
    /// at 24 kHz, faded in and out; here it is brought down to `musicPeak`.
    nonisolated static func elevatorMusic(in bundle: Bundle = .main) throws -> [Float] {
        guard let url = bundle.url(forResource: "ElevatorMusic", withExtension: "m4a") else {
            throw LocalVoiceUnavailable(message: "The elevator music is missing from the app.")
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == sampleRate, format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw LocalVoiceUnavailable(message: "The elevator music has an unexpected format.") }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw LocalVoiceUnavailable(message: "The elevator music could not be read.")
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard let loudest = samples.map(abs).max(), loudest > 0 else {
            throw LocalVoiceUnavailable(message: "The elevator music is silent.")
        }
        let gain = Float(musicPeak) / loudest
        return samples.map { $0 * gain }
    }

    private static func makeLoop(sound: ThinkingSound) throws -> AVAudioPCMBuffer {
        let samples: [Float]
        switch sound {
        case .heartbeat: samples = heartbeat()
        case .elevator: samples = try elevatorMusic()
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw LocalVoiceUnavailable(message: "The thinking sound could not be prepared.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// A short, explicit sample. The normal waiting cue yields to it, and recognition waits
/// so the sample cannot become a user turn. It never opens a microphone or asks a model.
@MainActor @Observable final class ThinkingCuePreview {
    static let shared = ThinkingCuePreview()
    private(set) var playing = false
    private let cue = ThinkingCue()
    private var end: Task<Void, Never>?

    func play() {
        stop()
        guard !TalkBack.muted else { return }
        playing = true
        cue.set(true, immediately: true)
        end = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
    func stop() {
        end?.cancel(); end = nil
        cue.set(false)
        playing = false
    }
}

struct ThinkingSoundControl: View {
    var language = Language.de
    var canPreview = true
    @State private var showing = false
    @State private var preview = ThinkingCuePreview.shared
    @AppStorage(ThinkingSound.key) private var sound = ThinkingSound.heartbeat.rawValue
    @AppStorage(ThinkingSound.volumeKey) private var volume = 0.6
    @Environment(\.scenePhase) private var scenePhase
    /// Shows a retired saved choice as the heartbeat it now plays.
    private var choice: Binding<ThinkingSound> {
        Binding(get: { ThinkingSound.stored(sound) }, set: { sound = $0.rawValue })
    }

    var body: some View {
        let previewController = preview
        Button("Waiting sound", systemImage: "waveform") { showing.toggle() }
            .labelStyle(.iconOnly).frame(width: 44, height: 44)
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .accessibilityIdentifier("assistant.waitingSound")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Waiting sound").font(.headline)
                    Picker("Sound", selection: choice) {
                        ForEach(ThinkingSound.allCases) { Text($0.title).tag($0) }
                    }
                    if ThinkingSound.stored(sound) == .elevator {
                        Text("“Local Forecast – Slower” by Kevin MacLeod (incompetech.com), CC BY 4.0; its first 20 seconds, mono and quieter.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: $volume, in: 0...1) { Text("Volume") }
                    Button(preview.playing ? "Stop sample" : "Play sample", systemImage: preview.playing ? "stop.fill" : "play.fill") {
                        if preview.playing { preview.stop() } else { preview.play() }
                    }
                    .disabled(!canPreview)
                    Text("Plays only while an answer is being prepared.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding().frame(width: 280)
                .onDisappear { @Sendable in Task { @MainActor in previewController.stop() } }
            }
            // SwiftUI invokes these nonisolated callbacks while native menus track
            // events. Keep actor-bound work in an explicitly enqueued main-actor task,
            // rather than a synchronous inferred-isolation check in that callback.
            .onChange(of: sound) { @Sendable _, _ in
                Task { @MainActor in if previewController.playing { previewController.play() } }
            }
            .onChange(of: volume) { @Sendable _, _ in
                Task { @MainActor in if previewController.playing { previewController.play() } }
            }
            .onChange(of: canPreview) { @Sendable _, allowed in
                Task { @MainActor in if !allowed { previewController.stop() } }
            }
            .onChange(of: scenePhase) { @Sendable _, phase in
                Task { @MainActor in if phase != .active { previewController.stop() } }
            }
            .onDisappear { @Sendable in Task { @MainActor in previewController.stop() } }
    }
}

/// Plays the waiting pulse while `waiting` holds and the app is in front. It ends when the
/// view goes away or the app leaves the foreground, whatever `waiting` says then.
private struct ThinkingCueWhile: ViewModifier {
    let waiting: Bool
    @State private var cue = ThinkingCue()
    @State private var preview = ThinkingCuePreview.shared
    @AppStorage(ThinkingSound.key) private var sound = ThinkingSound.heartbeat.rawValue
    @AppStorage(ThinkingSound.volumeKey) private var volume = 0.6
    @Environment(\.scenePhase) private var scenePhase
    private var shouldPlay: Bool { waiting && scenePhase == .active && !preview.playing }

    func body(content: Content) -> some View {
        content
            .onChange(of: shouldPlay, initial: true) { _, on in cue.set(on) }
            .onChange(of: sound) { cue.set(false); cue.set(shouldPlay) }
            .onChange(of: volume) { cue.set(false); cue.set(shouldPlay) }
            .onDisappear { cue.set(false) }
    }
}

extension View {
    func thinkingCue(while waiting: Bool) -> some View { modifier(ThinkingCueWhile(waiting: waiting)) }
}
