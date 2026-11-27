import AVFoundation

@MainActor protocol AssistantSpeechOutput: AnyObject {
    var began: ((ConversationResponseID) -> Void)? { get set }
    var finished: ((ConversationResponseID) -> Void)? { get set }
    var cancelled: ((ConversationResponseID) -> Void)? { get set }
    func speak(_ text: String, response: ConversationResponseID, language: Language)
    func stop()
    /// This voice was replaced and will not speak again: it stops, and nothing it still has
    /// under way (loading, a late callback) may reach the app afterwards.
    func retire()
}

extension AssistantSpeechOutput {
    func retire() {
        began = nil
        finished = nil
        cancelled = nil
        stop()
    }
}

/// Accepts later sentences while earlier audio is still playing, without replacing it.
@MainActor protocol AssistantStreamingSpeechOutput: AssistantSpeechOutput {
    func begin(response: ConversationResponseID, language: Language)
    func append(_ text: String, response: ConversationResponseID)
    func complete(response: ConversationResponseID)
}

/// Actual player flow, including a dry buffer between generated parts.
@MainActor protocol AssistantPlaybackReporting: AssistantSpeechOutput {
    var playoutChanged: ((ConversationResponseID, Bool) -> Void)? { get set }
}

/// A voice failure is distinct from an intentional interruption by the person.
@MainActor protocol AssistantSpeechFailureReporting: AssistantSpeechOutput {
    var failed: ((ConversationResponseID) -> Void)? { get set }
}

/// Says which of the appended texts the player has begun, so a caller that appends one
/// sentence at a time knows how far the listener has got while later sentences are
/// already being generated.
@MainActor protocol AssistantSentenceSpeechOutput: AssistantStreamingSpeechOutput {
    /// The player has begun the text appended as number `index` (from 0) of this response.
    /// What was appended after it is prepared, not heard.
    var reached: ((ConversationResponseID, Int) -> Void)? { get set }
}

/// Native, interruptible utterances with identity-safe callbacks. No cloned voice.
@MainActor final class AssistantSpeaker: NSObject, AssistantSpeechOutput, AVSpeechSynthesizerDelegate {
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterances: [ObjectIdentifier: ConversationResponseID] = [:]
    override init() { super.init(); synthesizer.delegate = self }

    func speak(_ text: String, response: ConversationResponseID, language: Language) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: language)
        utterance.rate = Self.rate
        if TalkBack.muted { utterance.volume = 0 }
        utterances[ObjectIdentifier(utterance)] = response
        synthesizer.speak(utterance)
    }

    /// A little quicker than the system's default (0.5): a conversation, not a reading.
    static let rate: Float = 0.54

    /// The best voice installed for the language: a premium or enhanced one if the user has
    /// downloaded it (Settings → Accessibility → Spoken Content), the plain one otherwise.
    /// Personal voices and novelty voices are never chosen.
    static func voice(for language: Language) -> AVSpeechSynthesisVoice? {
        let code = language == .de ? "de-DE" : "en-US"
        let installed = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == code && !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        return installed.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: code)
    }
    func stop() {
        utterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let voice = utterance.voice.map { "\($0.name) \($0.quality.rawValue)" } ?? "default"
        Task { @MainActor in
            if let response = self.utterances[id] {
                VoiceTiming.note("voice_system", ["state": voice, "response": response.rawValue])
                self.began?(response)
            }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if let response = self.utterances.removeValue(forKey: id) { self.finished?(response) } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if let response = self.utterances.removeValue(forKey: id) { self.cancelled?(response) } }
    }
}
