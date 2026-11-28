import Foundation
import Observation

/// Speaks for a running harness: voice in, Listen's own roles, voice out.
///
/// The answers are not made here. Hearing, decisions, drafters, the main model and research
/// run in `LocalTransport` and `AnswerEngine` exactly as in a conversation without voice,
/// with the system's saved roles, prompts, account and budget. This class only follows the
/// events they publish, lets `SpokenCards` pick the words, and gives them to the chosen
/// voice one sentence at a time (`SentenceVoice`). It offers and runs no tool, and asks no
/// model.
///
/// How a turn is spoken:
/// - The first accepted answer to a sentence starts as soon as its card is finished and the
///   microphone has been quiet for half a second. A short local acknowledgement may
///   bridge a slow round; it is separate from the cards and their delivery history.
/// - A speech is a plan of sentences, not one block of text. Deeper work for the same turn
///   (the main model's version, a researched one) goes on while it is said. What that work
///   adds joins the plan in an order (`fit`), not at its end:
///   1. corrections, in the order they came, at the next sentence end;
///   2. additions, in the order they came, at the next sentence end where the answer can be
///      left: its first sentence is never passed, and a sentence that leans on the one before
///      it ("daher", "therefore", `leans`) stays with that one;
///   3. what is left of the answer the addition passed. Nothing of it is thrown away, except
///      a sentence the addition says itself.
///   A sentence that changes a claim still to come takes that claim's place. A local voice
///   has one sentence prepared ahead; that one is said as it is, so every change takes
///   effect after it. No sentence is cut.
/// - A sentence counts as heard when the player has begun it, not when it was chosen or
///   prepared (`SpokenCards.heard`). Stopping or changing the voice in the middle leaves the
///   sentences not yet begun unheard: after a change of voice they are said in the new voice,
///   after a stop they can come again with a later version. Nothing begun is said twice.
/// - A newer version of a block that still waits takes its predecessor's place; a correction
///   that waits stays ahead of it unless the newer version says or changes the same. Up to
///   three blocks wait; a waiting one is given up after eight seconds without a pause.
/// - When the person has said something new since a block was spoken, a late addition to
///   that older turn and what was left of an interrupted speech are dropped: the conversation
///   moved on. A correction is still said.
/// - At a pause after unfinished words, the recogniser is asked to finish them now
///   (`onTurnPause`), so the turn does not wait for the recogniser's own long pause.
///
/// With the active native echo-cancelled input, recognition continues during playback and
/// near-end speech interrupts output. Without that capability, `blocksRecognition` retains
/// the older turn-taking behavior (including silent test doubles).
///
/// What it records (`record`): `voice_choice`, `voice_turn_pause`, `voice_speech` (queued,
/// skipped with the reason, speaking) and `voice_playback` (scheduled when the player begins
/// an utterance's first sentence; finished or cancelled for a whole speech, with how many
/// sentences were heard and how many prepared), each with card, block, turn sentence, part,
/// voice identity and the seconds since that sentence was committed. "Begun by the player"
/// is the first audio of a sentence handed to the player, or the system synthesizer
/// starting it. It is not the sound in the room: nothing here listens to the loudspeaker.
///
/// The wait in the queue, per card (`waited`): a card is ready when it is finished and chosen
/// to be said, which is when its `queued` record is written. From then on every record of it
/// carries `queue_priority` (0 correction, 1 addition, 2 answer), `since_ready_s` and
/// `card_ready_uptime_s` (this class's clock, the device's uptime; not the run's `t`).
/// `queued` also says where it was put: `queue_position` in the plan and `queue_ahead`, the
/// sentences not yet begun that come before it. `speaking` and `scheduled` add `queue_wait_s`,
/// ready until its first sentence was given to the voice. On `voice_playback` `scheduled`,
/// `since_ready_s` is therefore: card ready until the player began its first sentence.
@MainActor @Observable final class SpokenHarness {
    private(set) var configuration: VoiceAssistantConfiguration
    private(set) var speaking = false
    /// The player has begun a sentence of the speech under way.
    private(set) var audible = false
    private(set) var paused = false
    private(set) var microphoneMuted = false
    /// A round of the roles is working on a sentence.
    private(set) var thinking = false
    /// The microphone hears more than room noise.
    private(set) var hearing = false
    private(set) var settling = false
    /// The words last given to the voice: prepared, not necessarily begun.
    private(set) var lastSpoken = ""
    /// The sentence the player last began, as it is said. It is being said while `audible`;
    /// afterwards it is the last one that was. Empty until the player has begun one.
    private(set) var audibleSentence = ""
    /// What answers in this conversation, in the product's words (`VoicePresentation.summary`).
    @ObservationIgnored let source: String
    /// The fixed sample of the current voice (`playSample`). Observable by itself.
    @ObservationIgnored let preview: AssistantVoicePreview
    @ObservationIgnored var record: ((String, [String: Any]) -> Void)?
    /// Asks the recogniser to finish the words it has heard now (`Transport.endUtterance`).
    @ObservationIgnored var onTurnPause: (() -> Void)?

    /// One sentence of a card, and the utterance it was chosen for.
    private struct Segment {
        var sentence: String
        var utterance: SpokenCards.Utterance
        /// It takes the place of a sentence nobody heard: said where that one stood, without
        /// a transition, because there is nothing the listener has to unlearn.
        var replaces = false
        /// Its turn in a plan: 0 a correction, 1 an addition, 2 a sentence of an answer.
        var priority: Int
        /// When its card was finished and chosen to be said, and when it was given to the voice.
        var ready: Double
        var given: Double?
        /// As the voice says it: with the transition it opens with.
        var said = ""
    }

    /// Where an utterance went in a plan (`fit`).
    private struct Fit {
        var position = 0
        var added = 0
        var replaced = 0
        /// Sentences of the answer that were taken out because the utterance says them.
        var covered = 0
    }

    /// What the conversation is doing, for the person: one state, the one that matters most.
    enum Activity: Equatable, Sendable {
        case paused
        /// The voice has the words; the player has not begun them.
        case preparing
        /// The player is in a sentence, or the room still carries it. Recognition is withheld.
        case speaking
        case sample
        case thinking
        /// An answer is ready and waits for the room to be quiet.
        case waitingForPause
        case listening
    }

    /// Sentences of one block that wait to be said.
    private struct Pending {
        var block: UInt64
        var segments: [Segment]
        var queued: Double
        /// What was left of a speech when the voice was changed: it goes on, it does not wait.
        var resumes = false
        var first: SpokenCards.Utterance { segments[0].utterance }
    }

    /// The speech under way: what the voice has, how much of that the player has begun, and
    /// what is still to come.
    private struct Speech {
        var block: UInt64
        var handed: [Segment] = []
        var reached = 0
        var plan: [Segment]
        var queued: Double
        var began: Double
    }

    @ObservationIgnored private let system: String
    @ObservationIgnored private let language: Language
    @ObservationIgnored private var voiceOutput: SentenceVoice
    @ObservationIgnored private let makeSpeaker: (VoiceAssistantConfiguration) -> any AssistantSpeechOutput
    @ObservationIgnored private let releaseOtherVoices: (String) -> Void
    @ObservationIgnored private let saveVoice: ((AssistantVoiceChoice) throws -> Void)?
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private var cards: SpokenCards
    @ObservationIgnored private var speech: Speech?
    private var waitingToSpeak: [Pending] = []
    /// Cards of which the player has begun a sentence: their transition was said.
    @ObservationIgnored private var begunCards: Set<UInt64> = []
    /// Cards whose first sentence actually began, including a silent replacement of an
    /// unheard claim. Separate from `begunCards`, which tracks spoken transitions.
    @ObservationIgnored private var timedCards: Set<UInt64> = []
    @ObservationIgnored private var settlingTask: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var quiet = 60.0
    /// The newest finished sentence of the person, and when each was first committed.
    @ObservationIgnored private var latestFinal: UInt64 = 0
    @ObservationIgnored private var committed: [UInt64: Double] = [:]
    /// Per block: the newest finished sentence when the block was last spoken.
    @ObservationIgnored private var spokenThrough: [UInt64: UInt64] = [:]
    /// Words the recogniser has not finished: the sentence, its text, and when it last changed.
    @ObservationIgnored private var unfinished: (id: UInt64, text: String, changed: Double, asked: Bool)?
    @ObservationIgnored private let reactionDelay: Duration?
    @ObservationIgnored private let reactionBank: ConversationReactionBank
    @ObservationIgnored private var reactionTimer: Task<Void, Never>?
    @ObservationIgnored private var reactionRound: UInt64?
    @ObservationIgnored private var reactionDue = false
    @ObservationIgnored private var lastReactionAt = -Double.infinity
    @ObservationIgnored private var latestWords = ""
    @ObservationIgnored private var activeRounds: Set<UInt64> = []
    private(set) var reacting = false

    /// A waiting block starts after this much quiet at the microphone, and is given up after `patience`.
    static let quietBeforeSpeaking = 0.5
    static let patience = 8.0
    static let maximumWaiting = 3
    /// An addition waits for at most this many sentences that lean on the one before them.
    static let maximumLeaning = 2

    init(system: String, language: Language, configuration: VoiceAssistantConfiguration, speaker: any AssistantSpeechOutput,
         source: String = "",
         makeSpeaker: @escaping (VoiceAssistantConfiguration) -> any AssistantSpeechOutput = { TalkBack.speaker(for: $0) },
         releaseOtherVoices: @escaping (String) -> Void = { TalkBack.release(except: $0) },
         saveVoice: ((AssistantVoiceChoice) throws -> Void)? = nil,
         reactionDelay: Duration? = nil,
         reactionBank: ConversationReactionBank = .shared,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.system = system
        self.language = language
        self.configuration = configuration
        self.source = source
        voiceOutput = SentenceVoice(output: speaker)
        self.makeSpeaker = makeSpeaker
        self.releaseOtherVoices = releaseOtherVoices
        self.saveVoice = saveVoice
        self.reactionDelay = reactionDelay
        self.reactionBank = reactionBank
        self.now = now
        cards = SpokenCards(language: language)
        preview = AssistantVoicePreview(makeSpeaker: makeSpeaker)
        connectVoice()
        preview.ended = { [weak self] in self?.settle() }
    }

    var voice: AssistantVoiceChoice { AssistantVoiceChoice(configuration) }
    /// Listen's own voice, and a sample, must not come back as something that was said.
    private(set) var listensWhileSpeaking = false
    var blocksRecognition: Bool { microphoneMuted || !listensWhileSpeaking && (speaking || settling || preview.playing != nil || ThinkingCuePreview.shared.playing) }

    func setDuplexListening(_ enabled: Bool) { listensWhileSpeaking = enabled }

    func microphoneActivity(speechSeconds: Double) {
        guard listensWhileSpeaking, !paused, !microphoneMuted, !stopped, speechSeconds >= 0.2 else { return }
        if speaking || preview.playing != nil {
            record?("voice_barge_in", ["state": "microphone", "speech_s": speechSeconds])
            if reacting { stopReaction() } else { interrupt() }
            settlingTask?.cancel()
            settling = false
        }
        hearing = true
    }
    /// An answer is being worked on and nobody is speaking: the moment for the waiting sound.
    var waiting: Bool {
        thinking && !stopped && !paused && !speaking && !hearing && configuration.speakReplies && preview.playing == nil
    }
    /// How many blocks wait to be said.
    var waitingCount: Int { waitingToSpeak.count }
    /// How many sentences of the speech under way are still to come.
    var plannedSentences: Int { speech?.plan.count ?? 0 }
    /// Never `listening` while Listen's own voice is withheld from recognition: the moment
    /// after a speech, in which the room still carries it, counts as speaking.
    var activity: Activity {
        if paused || stopped { return .paused }
        if speaking { return audible ? .speaking : .preparing }
        if preview.playing != nil { return .sample }
        if settling && !listensWhileSpeaking { return .speaking }
        if thinking, !hearing { return .thinking }
        return waitingToSpeak.isEmpty ? .listening : .waitingForPause
    }

    private var voiceFields: [String: Any] {
        ["engine": configuration.talkBackEngine.rawValue, "tts_model": configuration.talkBackEngine == .local ? configuration.talkBackModel : "system",
         "tts_voice": configuration.talkBackEngine == .local ? configuration.talkBackVoice : "system"]
    }

    /// The voice the conversation begins with, for the run's record.
    func began() { record?("voice_choice", voiceFields.merging(["state": "initial", "answers": source]) { $1 }) }

    // MARK: What the harness publishes

    func receive(_ event: ServerEvent) {
        guard !stopped else { return }
        if case .transcript = event, microphoneMuted { return }
        switch event {
        case .transcript(let segment): heard(segment)
        case .cardSuperseded(let id, _):
            // A waiting card gives way to its newer version, which brings what it would have
            // said. A correction is owed until that version is there (`queue`). What was left
            // of a speech that had begun stays: it was accepted and is owed.
            drop("replaced before it was said") {
                !$0.resumes && $0.first.part != .correction && $0.segments.allSatisfy { $0.utterance.card == id }
            }
        case .cardCancelled(let id), .cardError(let id, _):
            drop("withdrawn before it was said") { $0.segments.contains { $0.utterance.card == id } }
            withdraw(card: id)
        default: break
        }
        switch cards.receive(event) {
        case .speak(let utterance): queue(utterance)
        case .skip(let card, let block, let sentence, let reason):
            record?("voice_speech", ["card": card, "block": block, "sentence": sentence ?? 0, "state": "skipped", "reason": reason.rawValue])
        case nil: break
        }
    }

    /// The decision service classified this card as a correction (`AnswerEngine.onCorrection`).
    func correction(card: UInt64) {
        guard !stopped else { return }
        cards.markCorrection(card: card)
    }

    /// A round of the roles started or ended (`AnswerEngine.onRound`).
    func round(_ trigger: UInt64, running: Bool) {
        if !running, trigger == 0 { activeRounds.removeAll() }
        else if running { activeRounds.insert(trigger) } else { activeRounds.remove(trigger) }
        thinking = !activeRounds.isEmpty && !stopped
        if running, let reactionDelay, reactionRound == nil, !speaking, waitingToSpeak.isEmpty {
            reactionRound = trigger
            reactionDue = false
            reactionTimer = Task { [weak self] in
                try? await Task.sleep(for: reactionDelay)
                guard !Task.isCancelled, let self else { return }
                reactionDue = true
                reactIfReady()
            }
        } else if !thinking {
            reactionTimer?.cancel()
            reactionRound = nil
            reactionDue = false
        }
    }

    private func reactIfReady() {
        guard reactionDue, let trigger = reactionRound, activeRounds.contains(trigger), thinking,
              !stopped, !paused, !reacting, !speaking, speech == nil, !hearing, !settling,
              quiet >= Self.quietBeforeSpeaking, waitingToSpeak.isEmpty, configuration.speakReplies,
              preview.playing == nil, !ThinkingCuePreview.shared.playing,
              latestWords.split(whereSeparator: \.isWhitespace).count >= 3,
              now() - lastReactionAt >= ConversationReaction.spacing else { return }
        reactionDue = false
        let text = reactionBank.choose(for: latestWords, language: language, hasPrevious: committed.count > 1).text
        reacting = true
        speaking = true
        audible = false
        lastSpoken = text
        record?("voice_acknowledgement", voiceFields.merging(["state": "requested", "purpose": "reaction",
            "trigger": trigger, "text": text]) { $1 })
        if !voiceOutput.startBrief(text, language: language) {
            reacting = false
            speaking = false
        }
    }

    private func stopReaction() {
        reactionTimer?.cancel()
        reactionTimer = nil
        reactionRound = nil
        reactionDue = false
        guard reacting else { return }
        reacting = false
        speaking = false
        audible = false
        audibleSentence = ""
        voiceOutput.stopBrief()
        record?("voice_acknowledgement", ["state": "stopped", "purpose": "reaction"])
    }

    /// The microphone has been quiet for `seconds`.
    func heardQuiet(for seconds: Double) {
        quiet = seconds
        // With native echo cancellation, microphone activity can be the person even during output.
        hearing = !blocksRecognition && seconds < Self.quietBeforeSpeaking
        endTurnAtPause(quiet: seconds)
        advance()
        reactIfReady()
    }

    private func heard(_ segment: TranscriptSegment) {
        latestWords = segment.text
        guard segment.isFinal else {
            if unfinished?.id != segment.segmentID || unfinished?.text != segment.text {
                unfinished = (segment.segmentID, segment.text, now(), false)
            }
            return
        }
        if unfinished?.id == segment.segmentID { unfinished = nil }
        guard committed[segment.segmentID] == nil else { return }
        // A later hearing of the same sentence (Whisper, a voice label) is not a new turn.
        committed[segment.segmentID] = now()
        if committed.count > 64, let oldest = committed.keys.min() { committed[oldest] = nil }
        latestFinal = max(latestFinal, segment.segmentID)
        for index in waitingToSpeak.indices.reversed() {
            let entry = waitingToSpeak[index]
            let stays = entry.segments.filter { !leftBehind($0, resumes: entry.resumes) }
            guard stays.count < entry.segments.count else { continue }
            if let gone = entry.segments.first(where: { leftBehind($0, resumes: entry.resumes) }) {
                skipped(gone.utterance, "the conversation moved on")
            }
            if stays.isEmpty { waitingToSpeak.remove(at: index) } else { waitingToSpeak[index].segments = stays }
        }
    }

    /// A waiting sentence the conversation has left behind: an addition to an older turn, or
    /// what was left of an interrupted speech. A correction is never left behind.
    private func leftBehind(_ segment: Segment, resumes: Bool) -> Bool {
        segment.priority != 0 && (resumes || segment.utterance.part == .addition) && movedOn(segment.utterance)
    }

    /// Last words after which a speaker usually goes on are given more time, as in a
    /// voice-assistant conversation (`VoiceAssistantSession.heardQuiet`).
    private func endTurnAtPause(quiet seconds: Double) {
        guard let words = unfinished, !words.asked, !blocksRecognition, !paused, !stopped, let onTurnPause else { return }
        let needed = ConversationTurnTiming.quiet(for: words.text, language: language)
        // A transcriber that hasn't added a word for two seconds may simply be catching up.
        // Its delay is not evidence that the person stopped speaking.
        guard seconds >= needed else { return }
        unfinished?.asked = true
        record?("voice_turn_pause", ["sentence": words.id, "quiet_s": seconds])
        onTurnPause()
    }

    /// The person said something new after this block was last spoken, and the utterance
    /// still belongs to the older turn.
    private func movedOn(_ utterance: SpokenCards.Utterance) -> Bool {
        guard let through = spokenThrough[utterance.block] else { return false }
        return latestFinal > through && utterance.sentence <= through
    }

    private func fields(_ utterance: SpokenCards.Utterance) -> [String: Any] {
        var fields = voiceFields.merging(["card": utterance.card, "block": utterance.block, "version": utterance.version,
                                          "sentence": utterance.sentence, "card_kind": utterance.kind.rawValue,
                                          "part": utterance.part.rawValue, "update": utterance.part != .answer,
                                          "chars": utterance.text.count, "sentences": utterance.sentences.count]) { $1 }
        if let committed = committed[utterance.sentence] { fields["since_sentence_s"] = now() - committed }
        return fields
    }

    private func skipped(_ utterance: SpokenCards.Utterance, _ reason: String) {
        record?("voice_speech", fields(utterance).merging(["state": "skipped", "reason": reason]) { $1 })
    }

    private static func priority(_ part: SpokenCards.Part) -> Int {
        switch part {
        case .correction: 0
        case .addition: 1
        case .answer: 2
        }
    }

    private func segments(_ utterance: SpokenCards.Utterance, ready: Double) -> [Segment] {
        utterance.sentences.map { Segment(sentence: $0, utterance: utterance, priority: Self.priority(utterance.part), ready: ready) }
    }

    /// How long a sentence's card has been ready, and with which priority it waits.
    private func waited(_ segment: Segment) -> [String: Any] {
        var fields: [String: Any] = ["queue_priority": segment.priority, "card_ready_uptime_s": segment.ready,
                                     "since_ready_s": now() - segment.ready]
        if let given = segment.given { fields["queue_wait_s"] = given - segment.ready }
        return fields
    }

    private func queue(_ utterance: SpokenCards.Utterance) {
        guard configuration.speakReplies, !paused else { skipped(utterance, paused ? "paused" : "speech is off"); return }
        if utterance.part == .addition, movedOn(utterance) { skipped(utterance, "the conversation moved on"); return }
        let ready = now()
        // More for the block that is being said joins the speech under way, unless the voice
        // can take nothing more for it; it then follows as the next one.
        if var speech, speech.block == utterance.block, voiceOutput.canExtend {
            let placed = fit(utterance, ready: ready, into: &speech.plan, atVoice: speech.handed, begun: speech.reached)
            self.speech = speech
            joined(utterance, placed, ready: ready, ahead: speech.handed.count - speech.reached, plan: speech.plan.count)
            return
        }
        // So does more for what was left of a speech when the voice was changed. An answer to
        // a newer sentence waits for its own pause.
        if utterance.part != .answer, let index = waitingToSpeak.firstIndex(where: { $0.block == utterance.block && $0.resumes }) {
            let placed = fit(utterance, ready: ready, into: &waitingToSpeak[index].segments, atVoice: [], begun: 0)
            joined(utterance, placed, ready: ready, ahead: 0, plan: waitingToSpeak[index].segments.count)
            advance()
            return
        }
        // One waiting entry per block: the newer version holds what an older answer or
        // addition would say. A correction that still waits is owed and stays ahead of it,
        // unless the newer version says or changes the same. What was left of an interrupted
        // speech stays; the new sentences follow it.
        var entry = Pending(block: utterance.block, segments: segments(utterance, ready: ready), queued: ready)
        if let index = waitingToSpeak.firstIndex(where: { $0.block == utterance.block && !$0.resumes }) {
            let older = waitingToSpeak.remove(at: index)
            let owed = older.segments.filter { old in
                old.priority == 0 && !utterance.sentences.contains { SpokenCards.says($0, old.sentence) || SpokenCards.changed($0, old.sentence) }
            }
            if owed.isEmpty {
                skipped(older.first, "a newer version of its block took its place")
            } else {
                entry.segments = owed + entry.segments.filter { new in !owed.contains { SpokenCards.says($0.sentence, new.sentence) } }
                entry.queued = older.queued
            }
        }
        waitingToSpeak.append(entry)
        while waitingToSpeak.count > Self.maximumWaiting { skipped(waitingToSpeak.removeFirst().first, "too many blocks waited") }
        record?("voice_speech", fields(utterance).merging([
            "state": "queued", "queue_priority": Self.priority(utterance.part), "queue_position": waitingToSpeak.count - 1,
            "card_ready_uptime_s": ready, "since_ready_s": 0.0]) { $1 })
        advance()
    }

    private func joined(_ utterance: SpokenCards.Utterance, _ fit: Fit, ready: Double, ahead: Int, plan: Int) {
        guard fit.added > 0 || fit.replaced > 0 else { skipped(utterance, "already in what is being said"); return }
        if fit.replaced > 0 {
            record?("voice_speech", fields(utterance).merging(["state": "replaced", "sentences": fit.replaced,
                                                                "reason": "takes the place of sentences not yet said"]) { $1 })
        }
        record?("voice_speech", fields(utterance).merging([
            "state": "queued", "joined": true, "queue_priority": Self.priority(utterance.part), "queue_position": fit.position,
            "queue_ahead": ahead + fit.position, "plan_sentences": plan, "covered_sentences": fit.covered,
            "card_ready_uptime_s": ready, "since_ready_s": 0.0]) { $1 })
    }

    /// Fits more for a block into the sentences of it still to come. `atVoice`: what the
    /// voice was given for this speech, of which the player has begun the first `begun`.
    ///
    /// The order of a plan is: corrections, additions, the rest of the answer, each in the
    /// order it came. An addition goes to the first place where the answer can be left:
    /// - never before the first sentence of an answer, which stands on its own, and never
    ///   into an answer to a newer sentence than its own;
    /// - after a sentence that leans on the one before it, so the two stay together.
    /// What it passes is said after it, except a sentence it says itself. A sentence that
    /// changes a claim still to come takes that claim's place, without a transition. What the
    /// voice already has is neither moved nor planned again.
    private func fit(_ utterance: SpokenCards.Utterance, ready: Double, into plan: inout [Segment], atVoice: [Segment], begun: Int) -> Fit {
        let own = Self.priority(utterance.part)
        let prepared = atVoice.dropFirst(begun).map(\.sentence)
        var result = Fit()
        /// A sentence of an answer the listener is already in, for this turn or an older one:
        /// it can wait for this utterance.
        func yields(_ index: Int, in plan: [Segment]) -> Bool {
            let segment = plan[index], card = segment.utterance.card
            guard segment.priority > own, segment.utterance.sentence <= utterance.sentence else { return false }
            return begunCards.contains(card) || atVoice.contains { $0.utterance.card == card }
                || plan[..<index].contains { $0.utterance.card == card }
        }
        var rest: [String] = []
        for sentence in utterance.sentences {
            if prepared.contains(where: { SpokenCards.says($0, sentence) }) { continue }
            // A sentence of the answer that this one says in other words gives way to it.
            let covered = plan.indices.filter {
                yields($0, in: plan) && SpokenCards.key(plan[$0].sentence) != SpokenCards.key(sentence)
                    && Self.covers(sentence, plan[$0].sentence)
            }
            // Sentences the voice will get anyway are not planned twice.
            if plan.indices.contains(where: { !covered.contains($0) && SpokenCards.says(plan[$0].sentence, sentence) }) { continue }
            // A sentence that changes one still to come takes its place: the obsolete claim is
            // never said, so there is nothing to correct aloud.
            if let place = plan.firstIndex(where: { SpokenCards.changed(sentence, $0.sentence) }) {
                plan[place] = Segment(sentence: sentence, utterance: utterance, replaces: true, priority: plan[place].priority, ready: ready)
                result.replaced += 1
                continue
            }
            covered.reversed().forEach { plan.remove(at: $0) }
            result.covered += covered.count
            rest.append(sentence)
        }
        var place = plan.lastIndex { $0.priority <= own }.map { $0 + 1 } ?? 0
        if utterance.part == .addition {
            place = plan.indices[place...].first { yields($0, in: plan) } ?? plan.count
            var kept = 0
            while place < plan.count, kept < Self.maximumLeaning, plan[place].priority > own, Self.leans(plan[place].sentence) {
                let card = plan[place].utterance.card
                let before = place > 0 ? plan[place - 1].utterance.card : atVoice.last?.utterance.card ?? (begunCards.contains(card) ? card : nil)
                guard before == card else { break }
                place += 1
                kept += 1
            }
        }
        plan.insert(contentsOf: rest.map { Segment(sentence: $0, utterance: utterance, priority: own, ready: ready) }, at: place)
        result.position = place
        result.added = rest.count
        return result
    }

    private static let openers: Set<String> = [
        "und", "aber", "doch", "denn", "oder", "sondern", "also", "dann", "sonst",
        "and", "but", "or", "so", "then", "because", "which", "otherwise",
    ]

    /// Removing an unheard fact needs stronger evidence than approximate word similarity.
    /// Keep its full word sequence in the new sentence; otherwise preserve the old tail.
    static func covers(_ detail: String, _ earlier: String) -> Bool {
        guard !SpokenCards.changed(detail, earlier) else { return false }
        let whole = Correction.words(detail), part = Correction.words(earlier)
        guard !part.isEmpty, whole.count >= part.count else { return false }
        return (0...(whole.count - part.count)).contains { Array(whole[$0..<($0 + part.count)]) == part }
    }
    private static let connectives: Set<String> = [
        "daher", "deshalb", "deswegen", "darum", "dadurch", "dafür", "dagegen", "danach", "davor", "dabei", "somit", "folglich",
        "trotzdem", "dennoch", "stattdessen", "andernfalls", "demnach",
        "therefore", "thus", "hence", "consequently", "instead", "nevertheless", "nonetheless", "afterwards", "thereby",
    ]

    /// The sentence leans on the one before it: it opens with a conjunction, or one of its
    /// first four words refers back ("Den Login daher nicht blind wiederholen."). By these
    /// words only: a reference made in other words is not seen, and nothing here judges meaning.
    static func leans(_ sentence: String) -> Bool {
        let words = Correction.words(sentence)
        guard let first = words.first else { return false }
        return openers.contains(first) || !connectives.isDisjoint(with: words.prefix(4))
    }

    /// A card that was taken back is not read on.
    private func withdraw(card: UInt64) {
        guard var speech else { return }
        speech.plan.removeAll { $0.utterance.card == card }
        self.speech = speech
        let playing = speech.handed.indices.contains(speech.reached - 1) ? speech.handed[speech.reached - 1] : speech.handed.last
        if playing?.utterance.card == card {
            voiceOutput.stop()
            ended("cancelled")
        }
    }

    private func drop(_ reason: String, where matches: (Pending) -> Bool = { _ in true }) {
        let dropped = waitingToSpeak.filter(matches)
        guard !dropped.isEmpty else { return }
        waitingToSpeak.removeAll(where: matches)
        dropped.forEach { skipped($0.first, reason) }
    }

    /// `joining`: the block whose speech has just ended. More for it follows at once;
    /// anything else waits for the room to be quiet.
    private func advance(joining: UInt64? = nil) {
        guard !stopped, !paused, speech == nil, !settling, preview.playing == nil, !ThinkingCuePreview.shared.playing else { return }
        if !waitingToSpeak.isEmpty, voiceOutput.isBriefSpeaking {
            if voiceOutput.briefAudible { return }
            stopReaction()
        }
        while let next = waitingToSpeak.first {
            let joins = next.resumes || (joining == next.block && next.first.part != .answer)
            if !joins, now() - next.queued > Self.patience {
                waitingToSpeak.removeFirst()
                skipped(next.first, "waited too long for a pause")
                continue
            }
            let fresh = current(next)
            guard let unheard = fresh.first?.utterance else {
                waitingToSpeak.removeFirst()
                skipped(next.first, "heard in the meantime")
                continue
            }
            let plan = fresh.filter { !leftBehind($0, resumes: next.resumes) }
            guard let first = plan.first?.utterance else {
                waitingToSpeak.removeFirst()
                skipped(unheard, "the conversation moved on")
                continue
            }
            guard next.resumes || (joining == next.block && first.part != .answer) || quiet >= Self.quietBeforeSpeaking else { return }
            waitingToSpeak.removeFirst()
            start(Speech(block: next.block, plan: plan, queued: next.queued, began: now()))
            return
        }
    }

    /// What a waiting entry would say now. What was heard since it was queued is not said
    /// again; a waiting card is composed again, so an answer whose beginning was heard
    /// meanwhile is an addition. A correction kept from an older version stays as it was.
    private func current(_ entry: Pending) -> [Segment] {
        let unheard = entry.segments.filter { !cards.hasHeard($0.sentence, block: entry.block) }
        guard !entry.resumes, let newest = entry.segments.last else { return unheard }
        let owed = unheard.filter { $0.utterance.card != newest.utterance.card }
        let fresh = cards.refreshed(newest.utterance).map { segments($0, ready: newest.ready) } ?? []
        return owed + fresh.filter { new in !owed.contains { SpokenCards.says($0.sentence, new.sentence) } }
    }

    private func start(_ next: Speech) {
        speech = next
        spokenThrough[next.block] = latestFinal
        if spokenThrough.count > 64, let oldest = spokenThrough.keys.min() { spokenThrough[oldest] = nil }
        speaking = true
        audible = false
        guard voiceOutput.start(language: language) else {
            speech = nil
            speaking = false
            return
        }
    }

    // MARK: The voice

    private func connectVoice() {
        voiceOutput.briefBegan = { [weak self] in
            guard let self, reacting else { return }
            audible = true
            audibleSentence = lastSpoken
            lastReactionAt = now()
            reactionBank.used(lastSpoken, language: language)
            record?("voice_acknowledgement", voiceFields.merging(["state": "scheduled", "purpose": "reaction",
                "trigger": reactionRound ?? 0, "audio": "begun by the player, not measured as sound"]) { $1 })
        }
        voiceOutput.briefEnded = { [weak self] in
            guard let self, reacting else { return }
            reacting = false
            speaking = false
            audible = false
            audibleSentence = ""
            record?("voice_acknowledgement", ["state": "ended", "purpose": "reaction", "trigger": reactionRound ?? 0])
            if listensWhileSpeaking { advance() } else { settle() }
        }
        voiceOutput.next = { [weak self] in self?.take() }
        voiceOutput.reached = { [weak self] index in self?.arrived(index) }
        voiceOutput.finished = { [weak self] in self?.ended("finished") }
        voiceOutput.cancelled = { [weak self] in self?.ended("cancelled") }
    }

    /// The next sentence of the plan, as the voice says it: the first sentence of an addition
    /// or correction nobody has begun to hear opens with its transition.
    private func take() -> String? {
        guard var speech, !speech.plan.isEmpty else { return nil }
        var segment = speech.plan.removeFirst()
        let opens = !segment.replaces && !begunCards.contains(segment.utterance.card)
            && !speech.handed.contains { $0.utterance.card == segment.utterance.card && !$0.replaces }
        let text = ([opens ? segment.utterance.lead : nil].compactMap { $0 } + [segment.sentence]).joined(separator: " ")
        segment.given = now()
        segment.said = text
        speech.handed.append(segment)
        self.speech = speech
        lastSpoken = text
        if opens {
            record?("voice_speech", fields(segment.utterance).merging([
                "state": "speaking", "response": voiceOutput.response ?? "", "joined": speech.handed.count > 1,
                "since_card_s": now() - speech.queued]) { $1 }.merging(waited(segment)) { $1 })
        }
        return text
    }

    /// The player has begun the sentence handed over as number `index`: it is heard.
    private func arrived(_ index: Int) {
        guard var speech, speech.handed.indices.contains(index), index >= speech.reached else { return }
        // A voice that skips ahead has played what lies between.
        for position in speech.reached...index {
            let segment = speech.handed[position]
            speech.reached = position + 1
            let firstPlayed = timedCards.insert(segment.utterance.card).inserted
            if segment.replaces {
                cards.heard(segment.sentence, of: segment.utterance, first: false)
                if firstPlayed { playback("scheduled", segment.utterance, speech, segment) }
                continue
            }
            let first = begunCards.insert(segment.utterance.card).inserted
            cards.heard(segment.sentence, of: segment.utterance, first: first)
            if firstPlayed { playback("scheduled", segment.utterance, speech, segment) }
        }
        speech.reached = index + 1
        self.speech = speech
        audible = true
        audibleSentence = speech.handed[index].said
        if begunCards.count > 256 { begunCards.removeAll() }
        if timedCards.count > 256 { timedCards.removeAll() }
    }

    /// `segment`: the sentence the player has just begun, the first of its card.
    private func playback(_ state: String, _ utterance: SpokenCards.Utterance, _ speech: Speech, _ segment: Segment? = nil) {
        record?("voice_playback", fields(utterance).merging([
            "state": state, "response": voiceOutput.response ?? "", "since_card_s": now() - speech.queued,
            "since_voice_s": now() - speech.began, "heard_sentences": speech.reached, "prepared_sentences": speech.handed.count,
            "heard": speech.reached > 0, "audio": "begun by the player, not measured as sound",
        ]) { $1 }.merging(segment.map(waited) ?? [:]) { $1 })
    }

    private func ended(_ state: String) {
        guard let ending = speech else { return }
        if let last = ending.handed.last?.utterance ?? ending.plan.first?.utterance { playback(state, last, ending) }
        speech = nil
        speaking = false
        audible = false
        if state == "finished" {
            if let first = ending.handed.first {
                reactionBank.accumulate(from: first.said, language: language,
                    kind: ConversationReaction.kind(for: latestWords, hasPrevious: committed.count > 1))
            }
            // More for the same block follows at this sentence end.
            advance(joining: ending.block)
            if speech != nil { return }
        }
        settle()
    }

    /// The room still carries the voice for a moment after it ends.
    private func settle() {
        settlingTask?.cancel()
        guard !stopped else { settling = false; return }
        settling = true
        settlingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            settling = false
            advance()
        }
    }

    /// Stops what is being said, a sample, and what waits to be said. The roles go on working.
    /// Sentences the player had not begun stay unheard: a later version may say them.
    func interrupt() {
        stopReaction()
        drop("interrupted")
        preview.stop()
        guard speech != nil else { return }
        voiceOutput.stop()
        ended("cancelled")
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
        unfinished = nil
        hearing = false
        quiet = muted ? .infinity : 0
        if muted { advance() }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused { interrupt() }
    }

    /// The conversation is over: nothing is said, started or reported after this.
    func stop() {
        guard !stopped else { return }
        interrupt()
        stopped = true
        thinking = false
        activeRounds.removeAll()
        hearing = false
        unfinished = nil
        settlingTask?.cancel()
        settling = false
        voiceOutput.retire()
    }

    /// Changes the voice of this conversation, and nothing else: roles, prompts, account,
    /// budget, decisions and the work in flight stay. As in `VoiceAssistantSession.chooseVoice`,
    /// the choice is checked and saved first, then the old voice is retired before the new one
    /// is made. The sentence the old voice was saying ends there and is not repeated; the
    /// sentences the player had not begun, and what waited, are said in the new voice.
    func chooseVoice(_ choice: AssistantVoiceChoice, store: SystemStore = SystemStore()) throws {
        guard !stopped else { return }
        let next = try choice.applying(to: configuration)
        guard next != configuration else { return }
        if let saveVoice { try saveVoice(choice) } else { try choice.save(system: system, in: store) }
        preview.stop()
        stopReaction()
        let cut = speech
        speech = nil
        speaking = false
        audible = false
        voiceOutput.retire()
        if let cut {
            if let last = cut.handed.last?.utterance { playback("cancelled", last, cut) }
            // What the old voice had prepared is given to the new one. Its card stays ready
            // since it was.
            let left = (Array(cut.handed.dropFirst(cut.reached)) + cut.plan).map { segment in
                var segment = segment
                segment.given = nil
                segment.said = ""
                return segment
            }
            if !left.isEmpty {
                waitingToSpeak.insert(Pending(block: cut.block, segments: left, queued: now(), resumes: true), at: 0)
            }
        }
        configuration = next
        voiceOutput = SentenceVoice(output: makeSpeaker(next))
        connectVoice()
        record?("voice_choice", voiceFields.merging(["state": "changed"]) { $1 })
        if next.talkBackEngine == .local { releaseOtherVoices(next.talkBackModel) }
        settle()
    }

    /// Speaks the fixed sample in the current voice, or stops it. Speech is interrupted.
    func playSample() {
        guard !stopped, !paused else { return }
        if preview.playing != nil { preview.stop(); return }
        interrupt()
        preview.play(voice, configuration: configuration, language: language)
    }
}
