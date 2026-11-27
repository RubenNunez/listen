import Foundation

/// Feeds complete sentences to either voice while preserving one logical reply.
/// A pause in the model's text stream is not the end of playback.
@MainActor final class AssistantReplySpeech: AssistantSpeechOutput {
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var failed: ((ConversationResponseID) -> Void)?
    var playoutChanged: ((ConversationResponseID, Bool) -> Void)?
    /// End of the appended text the player has actually begun. Presentation only:
    /// this is a sentence cue, never word alignment or a heard-character receipt.
    var presentationReached: ((ConversationResponseID, Int) -> Void)?
    private let output: any AssistantSpeechOutput
    private var response: ConversationResponseID?
    private var utterance: ConversationResponseID?
    private var language = Language.en
    private var waiting: [String] = []
    private var closed = false
    private var started = false
    private var sequence = 0
    private var textEnds: [Int] = []
    private var utteranceEnd = 0

    init(output: any AssistantSpeechOutput) {
        self.output = output
        if let sentences = output as? any AssistantSentenceSpeechOutput {
            sentences.reached = { [weak self] id, index in
                guard let self, utterance == id, let response, textEnds.indices.contains(index) else { return }
                presentationReached?(response, textEnds[index])
            }
        }
        if let progress = output as? any AssistantPlaybackReporting {
            progress.playoutChanged = { [weak self] id, playing in
                guard let self, utterance == id, let response else { return }
                playoutChanged?(response, playing)
            }
        }
        output.began = { [weak self] id in
            guard let self, utterance == id, let response else { return }
            if !(self.output is any AssistantSentenceSpeechOutput) {
                presentationReached?(response, utteranceEnd)
            }
            guard !started else { return }
            started = true
            began?(response)
        }
        output.finished = { [weak self] id in
            guard let self, utterance == id else { return }
            utterance = nil
            advance()
        }
        output.cancelled = { [weak self] id in
            guard let self, utterance == id else { return }
            stop()
        }
        if let fallible = output as? any AssistantSpeechFailureReporting {
            fallible.failed = { [weak self] id in
                guard let self, utterance == id, let response else { return }
                reset(notifyCancellation: false)
                if let failed { failed(response) } else { cancelled?(response) }
            }
        }
    }

    func begin(response: ConversationResponseID, language: Language) {
        stop()
        self.response = response
        self.language = language
        if let streaming = output as? any AssistantStreamingSpeechOutput {
            utterance = response
            streaming.begin(response: response, language: language)
        }
    }

    func append(_ text: String, response: ConversationResponseID) {
        guard self.response == response, !closed else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textEnds.append((textEnds.last.map { $0 + 1 } ?? 0) + text.count)
        if output is any AssistantStreamingSpeechOutput { utteranceEnd = textEnds.last ?? 0 }
        if let streaming = output as? any AssistantStreamingSpeechOutput {
            streaming.append(text, response: response)
            return
        }
        waiting.append(text)
        advance()
    }

    func complete(response: ConversationResponseID) {
        guard self.response == response else { return }
        closed = true
        if let streaming = output as? any AssistantStreamingSpeechOutput {
            streaming.complete(response: response)
            return
        }
        advance()
    }

    func speak(_ text: String, response: ConversationResponseID, language: Language) {
        begin(response: response, language: language)
        append(text, response: response)
        complete(response: response)
    }

    func stop() {
        reset(notifyCancellation: true)
    }

    private func reset(notifyCancellation: Bool) {
        let interrupted = response
        response = nil
        utterance = nil
        waiting.removeAll()
        closed = false
        started = false
        sequence = 0
        textEnds = []
        utteranceEnd = 0
        // Invalidate before stopping: the underlying voice may cancel synchronously.
        output.stop()
        if notifyCancellation, let interrupted { cancelled?(interrupted) }
    }

    func retire() {
        began = nil
        finished = nil
        cancelled = nil
        failed = nil
        playoutChanged = nil
        presentationReached = nil
        stop()
        output.retire()
    }

    private func advance() {
        guard let response, utterance == nil else { return }
        if !waiting.isEmpty {
            sequence += 1
            let id = sequence == 1 ? response : ConversationResponseID("\(response.rawValue).speech.\(sequence)")
            utterance = id
            let text = waiting.joined(separator: " ")
            utteranceEnd = textEnds.last ?? 0
            waiting.removeAll()
            output.speak(text, response: id, language: language)
        } else if closed {
            self.response = nil
            if started { finished?(response) } else { cancelled?(response) }
        }
    }
}
