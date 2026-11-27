import AVFoundation

/// Reads a card with the system voice. Never a cloned or custom voice.
@MainActor
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: Language) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AssistantSpeaker.voice(for: language)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinished?() }
    }
}
