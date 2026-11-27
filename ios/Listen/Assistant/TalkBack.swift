import Foundation

/// Which voice speaks the assistant's replies.
enum TalkBackEngine: String, Codable, Sendable, CaseIterable {
    /// The device's own speech synthesizer.
    case system
    /// A model on this device (`LocalVoiceSpeaker`): the family that
    /// `talkBackModel` names. Needs a downloaded model.
    case local

    /// The default: the local voice wherever this device can run it, the system voice elsewhere.
    static var preferred: TalkBackEngine { LocalVoice.unsupported == nil ? .local : .system }
}

/// The fixed catalogue for the local voices. A system can only name these models and voices,
/// so an imported system cannot make the app download anything else.
enum TalkBack {
    /// What runs a model. Each family has its own synthesizer and its own files.
    enum Family: Sendable {
        /// Qwen3-TTS through mlx-audio-swift (`QwenVoice`).
        case qwen
        /// Pocket TTS through FluidAudio and Core ML (`PocketVoice`).
        case pocket
        /// Supertonic 3 through FluidAudio, fixed Int4 Core ML bundles.
        case supertonic
    }

    struct Model: Equatable, Sendable {
        let id: String
        let title: String
        /// Download size: as published for Qwen, the pinned files for Core ML voices.
        let gigabytes: Double
        var family = Family.qwen
        /// The name in the voice menu, and a form of it for accessibility identifiers.
        var short = ""
        var slug = ""
    }

    /// Kyutai's German 6-layer Pocket TTS in FluidInference's Core ML conversion (`PocketVoiceFiles`).
    static let pocketGerman = "FluidInference/pocket-tts-coreml/v2.1/german"
    static let supertonic = "FluidInference/supertonic-3-coreml/ane-int4-v2"

    static let models = [
        Model(id: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit", title: "Qwen3-TTS 0.6B, 4-bit (slips more often)", gigabytes: 1.7,
              short: "Qwen3-TTS 0.6B 4-bit", slug: "qwen-4bit"),
        Model(id: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit", title: "Qwen3-TTS 0.6B, 8-bit", gigabytes: 2.0,
              short: "Qwen3-TTS 0.6B 8-bit", slug: "qwen-8bit"),
        Model(id: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16", title: "Qwen3-TTS 0.6B, full", gigabytes: 2.5,
              short: "Qwen3-TTS 0.6B BF16", slug: "qwen-full"),
        Model(id: pocketGerman, title: "Pocket TTS, German (Core ML)", gigabytes: 0.4, family: .pocket,
              short: "Pocket TTS German", slug: "pocket-german"),
        Model(id: supertonic, title: "Supertonic 3, Int4 (Core ML, experimental)", gigabytes: 0.17, family: .supertonic,
              short: "Supertonic 3 Int4 · experimental", slug: "supertonic-3-int4"),
    ]
    /// The 8-bit model. On 120 synthetic replies the 4-bit one sighed, ran on or garbled
    /// words several times as often; the two start speaking equally fast.
    static let defaultModel = models[1].id
    /// The speakers the Qwen CustomVoice checkpoints ship with.
    static let voices = ["Serena", "Vivian", "Uncle_Fu", "Ryan", "Aiden", "Ono_Anna", "Sohee", "Eric", "Dylan"]
    static let defaultVoice = "Serena"
    /// The Pocket TTS voices this app fetches with the German pack. The pack has more.
    static let pocketVoices = ["alba", "cosette", "fantine", "eponine"]
    /// The Qwen voices a conversation offers for comparison (Ruben, 23 November 2026: female
    /// voices only). The other speakers stay valid in a saved system.
    static let comparedQwenVoices = ["Serena", "Vivian", "Ono_Anna", "Sohee"]

    /// Known, but not offered: nothing of it is downloaded, bundled or run.
    struct Unavailable: Equatable, Sendable {
        let title: String
        let reason: String
    }
    /// Phonon 40M-DE: gated and under a non-commercial licence according to the plan of
    /// 23 November 2026 (not checked again here). Listed so its absence is not taken for an oversight.
    static let unavailable = [Unavailable(title: "Phonon 40M-DE", reason: "gated, non-commercial licence")]

    static func model(_ id: String) -> Model? { models.first { $0.id == id } }

    /// Every voice a model can speak with. Empty for a model outside the catalogue.
    static func voices(for model: String) -> [String] {
        switch Self.model(model)?.family {
        case .qwen: voices
        case .pocket: pocketVoices
        case .supertonic: ["F2"]
        case nil: []
        }
    }

    /// The voices of a model that a conversation offers for comparison.
    static func comparedVoices(for model: String) -> [String] {
        switch Self.model(model)?.family {
        case .qwen: comparedQwenVoices
        case .pocket: pocketVoices
        case .supertonic: ["F2"]
        case nil: []
        }
    }

    /// "Ono_Anna" and "alba" as a person reads them.
    static func voiceName(_ voice: String) -> String {
        voice.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Why this model cannot speak this language, if so.
    static func unsupported(_ model: String, language: Language) -> String? {
        Self.model(model)?.family == .pocket && language != .de ? "Pocket TTS German speaks German only." : nil
    }

    /// Debug builds: `LISTEN_TALKBACK_MUTE=1` speaks every reply at volume 0, for measurements
    /// that run the whole path on a phone without sound.
    static var muted: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LISTEN_TALKBACK_MUTE"] == "1"
        #else
        false
        #endif
    }

    /// The speaker a session uses. There is one engine per choice and no fallback between
    /// them: a local voice that cannot speak says so (`LocalVoice.notice`) and stays silent.
    @MainActor static func speaker(
        for configuration: VoiceAssistantConfiguration, synthesizer: (any LocalVoiceSynthesizing)? = nil
    ) -> any AssistantSpeechOutput {
        guard configuration.speakReplies, configuration.talkBackEngine == .local else { return AssistantSpeaker() }
        return LocalVoiceSpeaker(model: configuration.talkBackModel, voice: configuration.talkBackVoice,
                                 synthesizer: synthesizer ?? Self.synthesizer(for: configuration.talkBackModel))
    }

    /// The synthesizer that runs a catalogue model.
    static func synthesizer(for model: String) -> any LocalVoiceSynthesizing {
        switch Self.model(model)?.family {
        case .pocket: PocketVoice.shared
        case .supertonic: SupertonicVoice.shared
        default: QwenVoice.shared
        }
    }

    /// After a change of voice: frees the other family's model where memory is short. With
    /// 12 GB or more both stay loaded, so switching back needs no reload. The threshold is
    /// a guess, not a measurement.
    static func release(except model: String) {
        guard ProcessInfo.processInfo.physicalMemory < 12 * 1_073_741_824 else { return }
        let kept = Self.model(model)?.family
        Task {
            if kept != .qwen { await QwenVoice.shared.unloadAll() }
            if kept != .pocket { await PocketVoice.shared.unload() }
            if kept != .supertonic { await SupertonicVoice.shared.unload() }
        }
    }
}

/// Brings streamed speech to one loudness. The level is the running RMS of the reply so
/// far, so the gain settles within the first chunk and then moves slowly; it carries over
/// to the next reply. Peaks are rounded off instead of clipped.
struct LoudnessLeveler: Sendable {
    var target: Float = 0.09
    private(set) var gain: Float = 2
    private var energy = 0.0
    private var count = 0

    /// Forget the level of the last reply, keep its gain as the starting point.
    mutating func beginReply() {
        energy = 0
        count = 0
    }

    mutating func level(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        energy += samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        count += samples.count
        let rms = Float((energy / Double(count)).squareRoot())
        let wanted = rms > 0.001 ? min(max(target / rms, 0.5), 4) : gain
        let step = (wanted - gain) / Float(samples.count)
        var current = gain
        let knee: Float = 0.8
        let result = samples.map { sample -> Float in
            current += step
            let value = sample * current
            let size = abs(value)
            guard size > knee else { return value }
            let rounded = knee + (1 - knee) * tanh((size - knee) / (1 - knee))
            return value < 0 ? -rounded : rounded
        }
        gain = wanted
        return result
    }
}
