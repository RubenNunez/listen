import AVFoundation
import CoreAudio

/// Microphone capture as 16 kHz mono 16-bit PCM in 100 ms frames.
///
/// Not verified on a device yet: this file compiles and follows Apple's
/// documented lifecycle, but capture, conversion and the notifications below
/// have only been exercised by building.
@MainActor
final class AudioCapture {
    enum CaptureError: Error, Equatable, LocalizedError {
        case noInput, physicalInputDisabled, voiceProcessingUnavailable
        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .physicalInputDisabled: "Physical input is disabled for this test."
            case .voiceProcessingUnavailable: "Continuous listening could not start on this audio route. Reconnect the headset or use the device speaker."
            }
        }
    }

    /// Test actions explicitly disable physical input; file-fed recognition still works.
    /// This also protects the test host's idle orb from reopening the owner's microphone.
    nonisolated static var physicalInputDisabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LISTEN_TEST_NO_MICROPHONE"] == "1"
        #else
        false
        #endif
    }

    var onFrame: ((Data) -> Void)?
    /// The shape of the sound just captured: two lines of `Waveform.points` values
    /// from -1 to 1 (calm, then nearly raw), several times a second. For drawing only.
    var onWaveform: (([Float]) -> Void)?
    var onInterrupted: ((SessionCore.InterruptionReason) -> Void)?
    var onHeadphonesChanged: ((Bool) -> Void)?
    /// Optional input-channel energy metadata supplied by a replay adapter.
    var onSide: ((_ mine: Float, _ theirs: Float) -> Void)?
    private let engine = AVAudioEngine()
    private var silence: AVAudioSourceNode?
    /// Enabled only for an explicitly started voice conversation, never for the idle orb.
    var voiceConversation = false
    private(set) var voiceProcessingActive = false
    private var continuation: AsyncStream<Captured>.Continuation?
    private var delivery: Task<Void, Never>?
    private(set) var isRunning = false

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // The legacy interruption notification is the one available on iOS 26.
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            // An "ended" notification may never come, and is ignored on purpose:
            // only the user resumes a session.
            MainActor.assumeIsolated { self.interrupted(.audioSession) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { _ in
            MainActor.assumeIsolated { self.reportHeadphones() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { _ in
            MainActor.assumeIsolated { self.interrupted(.mediaReset) }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated {
                // The engine stops itself when the hardware configuration changes. Headphones do that
                // when their microphone starts (AirPods change their profile): listening starts again
                // on the new configuration instead of pausing, which paused every start in a call
                // (18 November 2026). Only when that fails, or keeps happening, does the session pause.
                guard self.isRunning, !self.engine.isRunning else { return }
                if !self.restartAfterConfigurationChange() { self.interrupted(.routeChange) }
            }
        }
    }

    static var hasPermission: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        if physicalInputDisabled { return false }
        return AVAudioApplication.shared.recordPermission == .granted
        #endif
    }

    static func requestPermission() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        if physicalInputDisabled { return false }
        return await AVAudioApplication.requestRecordPermission()
        #endif
    }

    /// Stand-in audio for the simulator: two seconds of tone, two of silence.
    private static func simulatedFrame(_ index: Int) -> Data {
        guard (index / 20) % 2 == 1 else { return Data(count: WireProtocol.frameBytes) }
        var samples = [Int16](repeating: 0, count: WireProtocol.frameBytes / 2)
        // A voice-like mix of tones that drifts, so the drawn line visibly changes.
        let drift = Double(index) * 0.9
        for i in samples.indices {
            let t = Double(i) / WireProtocol.sampleRate
            let value = sin(2 * .pi * 30 * t + drift) * 0.6 + sin(2 * .pi * 70 * t + drift * 1.7) * 0.4
            samples[i] = Int16(5000 * value)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// `-audioFile <path>` on a debug build: the recording (16 kHz mono 16-bit, no header)
    /// is fed at the speed of speech instead of the microphone, so a scripted conversation
    /// can run through the real app. `~` is the app's home, for a file copied onto a phone.
    nonisolated static var scriptedFile: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-audioFile"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        #else
        nil
        #endif
    }
    /// The scripted recording has been fed completely.
    var onScriptEnded: (() -> Void)?

    func start() throws {
        guard !isRunning else { return }
        if let file = Self.scriptedFile {
            // An invalid explicit input must never fall back to the microphone.
            let sound = try Data(contentsOf: file)
            delivery = Task { [weak self] in
                let clock = ContinuousClock()
                let began = clock.now
                // The anchor that puts the script's own timeline next to the app's events.
                VoiceTiming.note("script_start", [:])
                var position = 0
                var index = 0
                while position < sound.count, !Task.isCancelled {
                    index += 1
                    try? await clock.sleep(until: began + .milliseconds(100 * index))
                    if Task.isCancelled { return }
                    var frame = sound.subdata(in: position..<min(position + WireProtocol.frameBytes, sound.count))
                    if frame.count < WireProtocol.frameBytes { frame.append(Data(count: WireProtocol.frameBytes - frame.count)) }
                    position += WireProtocol.frameBytes
                    self?.onWaveform?(Waveform.shape(of: frame))
                    self?.onFrame?(frame)
                }
                if !Task.isCancelled { self?.onScriptEnded?() }
                // A room goes quiet after the last word; it does not stop existing. Without the
                // silence the transcriber never closes the last sentence.
                while !Task.isCancelled {
                    index += 1
                    try? await clock.sleep(until: began + .milliseconds(100 * index))
                    if Task.isCancelled { return }
                    self?.onFrame?(Data(count: WireProtocol.frameBytes))
                }
            }
            isRunning = true
            return
        }
        #if targetEnvironment(simulator)
        // The simulator's audio input is unreliable (touching the input node
        // aborted in AURemoteIO::Initialize here), so it gets silent frames at
        // the real cadence. Microphone capture is only ever tested on a device.
        delivery = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                index += 1
                let frame = Self.simulatedFrame(index)
                self?.onWaveform?(Waveform.shape(of: frame))
                self?.onFrame?(frame)
            }
        }
        isRunning = true
        #else
        try startMicrophone()
        #endif
    }

    private func startMicrophone() throws {
        guard !Self.physicalInputDisabled else { throw CaptureError.physicalInputDisabled }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: voiceConversation ? .voiceChat : .default,
                                options: voiceConversation ? [.defaultToSpeaker, .allowBluetoothHFP] : [.defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        // Must be configured with the engine stopped. This switches both I/O nodes;
        // setting the session's mode alone does not enable echo cancellation.
        if input.isVoiceProcessingEnabled != voiceConversation {
            do { try input.setVoiceProcessingEnabled(voiceConversation) }
            catch { throw CaptureError.voiceProcessingUnavailable }
        }
        if voiceConversation {
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingInputMuted = false
            input.isVoiceProcessingAGCEnabled = true
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // VPIO needs a running output reference even before the first reply.
            // Starting a tap-only graph left downlink timestamps invalid and the
            // captured microphone entirely zero on the affected Mac.
            let mixer = engine.mainMixerNode
            let output = engine.outputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.voiceProcessingUnavailable
            }
            if silence == nil {
                let source = Self.silentSource()
                engine.attach(source)
                silence = source
            }
            if let silence { engine.connect(silence, to: mixer, format: format) }
            // VPIO's client input/output formats must agree. Letting the output
            // inherit stereo hardware defaults while tapping mono input failed
            // initialization (-10875) on the built-in Mac route.
            engine.connect(mixer, to: output, format: format)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let chunker = PCMChunker(inputFormat: format) else {
            throw CaptureError.noInput
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Captured.self, bufferingPolicy: .bufferingNewest(120))
        // A tap left from before would make installing this one raise; nil takes the format the
        // input has now, which can differ from what was read a moment ago while headphones
        // switch their profile (a crash at the start of a call, 18 November 2026).
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0, bufferSize: 1600, format: nil,
            block: Self.makeTap(chunker: chunker, continuation: continuation))
        RunRecorder.assistantOutput?.log("voice_capture_configuration", [
            "input_format": format.description,
            "output_format": engine.outputNode.inputFormat(forBus: 0).description,
            "voice_processing_requested": voiceConversation])
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        self.continuation = continuation
        delivery = Task { [weak self] in
            for await item in stream { self?.deliver(item) }
        }
        isRunning = true
        voiceProcessingActive = voiceConversation && input.isVoiceProcessingEnabled
        if voiceProcessingActive { VoiceAudioIO.began(engine) }
        VoiceTiming.note("voice_capture", ["state": voiceProcessingActive ? "echo_cancelled" : "plain"])
        reportHeadphones()
    }

    private func deliver(_ item: Captured) {
        switch item {
        case .frame(let frame): onFrame?(frame)
        case .waveform(let shape): onWaveform?(shape)
        }
    }

    private var restarts: [Date] = []

    private func restartAfterConfigurationChange() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        restarts = restarts.filter { $0.timeIntervalSinceNow > -30 } + [Date()]
        guard restarts.count <= 4, AudioCapture.scriptedFile == nil else { return false }
        stop()
        do {
            try start()
            return true
        } catch {
            return false
        }
        #endif
    }

    /// Ends capture synchronously: after this returns, no further frame is delivered.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        delivery?.cancel()
        delivery = nil
        if Self.scriptedFile != nil { return }
        #if targetEnvironment(simulator)
        return
        #else
        stopMicrophone()
        #endif
    }

    private func stopMicrophone() {
        voiceProcessingActive = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        VoiceAudioIO.ended(engine)
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func interrupted(_ reason: SessionCore.InterruptionReason) {
        guard isRunning else { return }
        onInterrupted?(reason)
    }

    private func reportHeadphones() {
        let personal: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        onHeadphonesChanged?(outputs.contains { personal.contains($0.portType) })
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    nonisolated static func silentSource() -> AVAudioSourceNode {
        AVAudioSourceNode { isSilence, _, _, buffers in
            isSilence.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                buffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
            }
            return 0
        }
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    nonisolated private static func makeTap(
        chunker: PCMChunker, continuation: AsyncStream<Captured>.Continuation
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            for item in chunker.append(buffer) {
                continuation.yield(item)
            }
        }
    }
}

enum Captured: Sendable {
    case frame(Data)
    case waveform([Float])
    /// Sound of the app heard together with the microphone, 16 kHz mono.
    /// The app's sound stopped or could not be taken, and why.
}

enum Waveform {
    static let points = 64

    /// How much sound one drawn line covers: 20 ms, a few periods of a voice.
    private static let window = 320
    /// Width of the moving average that removes hiss and consonant noise
    /// (two passes; roughly a 400 Hz low-pass at 16 kHz).
    private static let smoothing = 24

    /// Reduces 16-bit samples to two lines of `points` values each, one after the
    /// other in the result: first the calm line (low-passed, so it is round), then
    /// the same stretch of sound nearly raw. Both start at a rising zero crossing
    /// of the calm line (as an oscilloscope triggers), so successive lines overlap
    /// instead of jumping, and the drawing can blend from one to the other.
    static func shape(of samples: UnsafeBufferPointer<Int16>) -> [Float] {
        guard samples.count >= points else { return [Float](repeating: 0, count: points * 2) }
        let plain = samples.map { Float($0) / 32_768 }
        var smooth = plain
        for _ in 0..<2 { smooth = movingAverage(smooth, width: smoothing) }
        // Just enough averaging that the raw line is a line, not noise.
        let raw = movingAverage(plain, width: 3)

        let length = min(window, smooth.count)
        var start = 0
        if smooth.count > length {
            for index in 1...(smooth.count - length) where smooth[index - 1] < 0 && smooth[index] >= 0 {
                start = index
                break
            }
        }
        func line(_ values: [Float], delay: Int) -> [Float] {
            (0..<points).map { point in
                let position = Float(point) / Float(points - 1) * Float(length - 1)
                let lower = Int(position)
                let upper = min(lower + 1, length - 1)
                let t = position - Float(lower)
                // A moving average lags by half its width; shift so both lines align.
                let base = max(0, start - delay)
                return values[base + lower] * (1 - t) + values[base + upper] * t
            }
        }
        return line(smooth, delay: 0) + line(raw, delay: smoothing - 1)
    }

    private static func movingAverage(_ values: [Float], width: Int) -> [Float] {
        var result = values
        var sum: Float = 0
        for index in values.indices {
            sum += values[index]
            if index >= width { sum -= values[index - width] }
            result[index] = sum / Float(min(index + 1, width))
        }
        return result
    }

    static func shape(of pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { shape(of: $0.bindMemory(to: Int16.self)) }
    }
}

/// Converts hardware buffers to the wire format and cuts them into frames.
/// Used only from the audio thread.
final class PCMChunker: @unchecked Sendable {
    private var converter: AVAudioConverter
    private let output: AVAudioFormat
    private var ratio: Double
    private var pending = Data()

    init?(inputFormat: AVAudioFormat) {
        guard
            let output = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: WireProtocol.sampleRate, channels: 1,
                interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: output)
        else { return nil }
        self.output = output
        self.converter = converter
        // VoiceProcessingIO can expose auxiliary channels on a Mac. They must
        // not be averaged with channel zero, the captured microphone signal.
        self.converter.channelMap = [0]
        self.ratio = WireProtocol.sampleRate / inputFormat.sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) -> [Captured] {
        // The input's format can change under a running tap; convert from what actually arrives.
        if buffer.format != converter.inputFormat, let fresh = AVAudioConverter(from: buffer.format, to: output) {
            fresh.channelMap = [0]
            converter = fresh
            ratio = WireProtocol.sampleRate / buffer.format.sampleRate
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        let source = OneShot(buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            guard let next = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData else { return [] }
        let fresh = UnsafeBufferPointer(start: samples[0], count: Int(converted.frameLength))
        pending.append(fresh)

        var frames: [Captured] = [.waveform(Waveform.shape(of: fresh))]
        while pending.count >= WireProtocol.frameBytes {
            frames.append(.frame(Data(pending.prefix(WireProtocol.frameBytes))))
            pending.removeFirst(WireProtocol.frameBytes)
        }
        return frames
    }
}

private final class OneShot: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
