import Foundation

/// Gives a voice one sentence at a time and says which sentence the player has begun.
///
/// A speech of several sentences is not handed over whole: whoever speaks keeps the plan
/// and can still change what follows (`next`). How far ahead the voice is fed depends on it:
///
/// - A voice that reports its own progress (`AssistantSentenceSpeechOutput`, the local
///   voices) gets one sentence ahead: when the player begins sentence n, sentence n + 1 is
///   handed over, so it is generated while n plays and follows without a gap. A change of
///   plan therefore takes effect after the sentence already prepared.
/// - Any other voice (the device voice) gets each sentence when the one before it has ended.
///
/// `reached` is the only thing that says a sentence was heard. A sentence that was handed
/// over and not reached was prepared, not heard.
@MainActor final class SentenceVoice {
    /// The next sentence to say, asked for when the voice can take one. Nil: nothing more now.
    var next: (() -> String?)?
    /// The player has begun the sentence handed over as number `index` of this speech, from 0.
    var reached: ((Int) -> Void)?
    /// Everything handed over was played and `next` had nothing more.
    var finished: (() -> Void)?
    /// The voice gave up by itself (no model, an engine error). `stop` does not report.
    var cancelled: (() -> Void)?
    /// A brief acknowledgement has separate identity and never reaches card history.
    var briefBegan: (() -> Void)?
    var briefEnded: (() -> Void)?
    private var brief: ConversationResponseID?
    private(set) var briefAudible = false
    var isBriefSpeaking: Bool { brief != nil }

    private let output: any AssistantSpeechOutput
    private var progress: (any AssistantSentenceSpeechOutput)? { output as? any AssistantSentenceSpeechOutput }
    private var speech: ConversationResponseID?
    /// Without progress reports: the sentence the voice has now.
    private var current: ConversationResponseID?
    private var language = Language.en
    private var handed = 0
    /// With progress reports: the voice still accepts sentences for this speech.
    private var open = false
    private var serial = 0

    init(output: any AssistantSpeechOutput) {
        self.output = output
        if let progress {
            progress.reached = { [weak self] id, index in
                guard let self else { return }
                if brief == id { if index == 0 { beginBrief() }; return }
                guard speech == id, index < handed else { return }
                arrived(index)
            }
            output.began = { [weak self] id in
                guard let self, brief == id else { return }
                beginBrief()
            }
            output.finished = { [weak self] id in
                guard let self else { return }
                if brief == id { endBrief(); return }
                guard speech == id else { return }
                end()
                finished?()
            }
            output.cancelled = { [weak self] id in
                guard let self else { return }
                if brief == id { endBrief(); return }
                guard speech == id else { return }
                end()
                cancelled?()
            }
        } else {
            output.began = { [weak self] id in
                guard let self else { return }
                if brief == id { beginBrief(); return }
                guard current == id else { return }
                arrived(handed - 1)
            }
            output.finished = { [weak self] id in
                guard let self else { return }
                if brief == id { endBrief(); return }
                guard current == id else { return }
                current = nil
                if !hand() {
                    end()
                    finished?()
                }
            }
            output.cancelled = { [weak self] id in
                guard let self else { return }
                if brief == id { endBrief(); return }
                guard current == id else { return }
                end()
                cancelled?()
            }
        }
    }

    var isSpeaking: Bool { speech != nil }
    /// A sentence added to the plan now will still be said in this speech.
    var canExtend: Bool { speech != nil && (progress == nil || open) }

    func startBrief(_ text: String, language: Language) -> Bool {
        guard speech == nil, brief == nil else { return false }
        let id = ConversationResponseID("reaction-\(UUID().uuidString)")
        brief = id
        briefAudible = false
        output.speak(text, response: id, language: language)
        return true
    }

    private func beginBrief() {
        guard !briefAudible else { return }
        briefAudible = true
        briefBegan?()
    }

    private func endBrief() {
        brief = nil
        briefAudible = false
        briefEnded?()
    }

    func stopBrief() {
        guard brief != nil else { return }
        brief = nil
        briefAudible = false
        output.stop()
    }

    /// Begins a speech with what `next` gives. False when it gives nothing.
    func start(language: Language) -> Bool {
        stop()
        serial += 1
        let id = ConversationResponseID("spoken-\(serial)")
        speech = id
        self.language = language
        handed = 0
        if let progress {
            progress.begin(response: id, language: language)
            open = true
        }
        guard hand() else {
            stop()
            return false
        }
        return true
    }

    /// The name of the speech under way, for a record.
    var response: String? { speech?.rawValue }

    private func hand() -> Bool {
        guard let speech, let text = next?() else { return false }
        handed += 1
        if let progress {
            progress.append(text, response: speech)
        } else {
            let id = ConversationResponseID("\(speech.rawValue).\(handed)")
            current = id
            output.speak(text, response: id, language: language)
        }
        return true
    }

    private func arrived(_ index: Int) {
        reached?(index)
        // Still the same speech: a listener may have stopped it.
        guard speech != nil, let progress, open, index == handed - 1 else { return }
        // The sentence after this one is generated while this one plays.
        if !hand(), let speech {
            open = false
            progress.complete(response: speech)
        }
    }

    private func end() {
        speech = nil
        current = nil
        open = false
    }

    /// Ends the speech without a report. What the voice still delivers for it is ignored.
    func stop() {
        stopBrief()
        guard speech != nil else { return }
        end()
        output.stop()
    }

    /// This voice was replaced and will not speak again.
    func retire() {
        next = nil
        reached = nil
        finished = nil
        cancelled = nil
        briefBegan = nil
        briefEnded = nil
        brief = nil
        briefAudible = false
        end()
        output.retire()
    }
}
