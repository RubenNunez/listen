import Foundation
import Testing

@testable import Listen

@Suite struct RecordedQuietSpeechRegression {
    @Test func softlySpokenWordsAreNotAContinuousPause() {
        // A synthetic amplitude envelope, never a real recording in the repository.
        for gain in [1, 8] {
            var activity = ConversationActivity()
            for index in 0..<60 {
                let level = [120, 240, 150, 360, 190, 280][index % 6] * gain
                let samples = [Int16](repeating: Int16(level), count: 1_600)
                activity.receive(samples.withUnsafeBufferPointer { Data(buffer: $0) })
                #expect(activity.quietSeconds < 0.6)
            }
            for _ in 0..<10 { activity.receive(Data(count: 3_200)) }
            #expect(activity.quietSeconds >= 0.8)
        }
    }
}

// Synthetic cards and voices only: no model, no microphone, no sound, no network.

private func started(_ id: UInt64, sentence: UInt64? = 1, block: UInt64? = nil, source: UInt64? = nil, kind: CardKind = .fast,
                     focus: String? = nil, meeting: Bool? = nil) -> ServerEvent {
    .cardStarted(CardStart(generationID: id, kind: kind, style: .answer, triggerSegment: sentence, sourceCard: source,
                           contextVersion: 0, mappingVersion: 0, blockID: block ?? id, focusText: focus, meeting: meeting))
}

private func transcript(_ id: UInt64, _ text: String = "Synthetic.", final: Bool = true, revision: Int = 1) -> ServerEvent {
    .transcript(TranscriptSegment(segmentID: id, isFinal: final, revision: revision, voice: 1, speaker: .unknown, text: text, startMs: 0, endMs: 0))
}

private func final(_ id: UInt64) -> ServerEvent { transcript(id) }

/// A whole card, as the engine publishes one that was not streamed.
private func card(_ id: UInt64, _ text: String, sentence: UInt64? = 1, block: UInt64? = nil, source: UInt64? = nil,
                  kind: CardKind = .fast, focus: String? = nil, meeting: Bool? = nil) -> [ServerEvent] {
    [started(id, sentence: sentence, block: block, source: source, kind: kind, focus: focus, meeting: meeting),
     .cardDelta(generationID: id, text: text), .cardFinished(generationID: id)]
}

@Suite struct SpokenCardsTests {
    /// Feeds events; `hear` marks what is chosen as heard, as the voice does once audio is scheduled.
    private func decisions(_ cards: inout SpokenCards, _ events: [ServerEvent], hear: Bool = true) -> [SpokenCards.Decision] {
        events.compactMap { event in
            let decision = cards.receive(event)
            if hear, case .speak(let utterance) = decision { cards.heard(utterance) }
            return decision
        }
    }

    private func utterance(_ decision: SpokenCards.Decision?) -> SpokenCards.Utterance? {
        if case .speak(let utterance) = decision { return utterance }
        return nil
    }

    @Test func onlyAFinishedCardIsSaidAndOnlyItsSentencesNotItsTitle() throws {
        var cards = SpokenCards()
        // Being written: nothing, however much text has arrived.
        #expect(cards.receive(started(1)) == nil)
        #expect(cards.receive(.cardDelta(generationID: 1, text: "Mondentfernung\n**384 400 km** im Mittel")) == nil)
        // Replaced before it finished: never said, also not when a late finish arrives.
        #expect(cards.receive(.cardSuperseded(generationID: 1, by: 2)) == nil)
        #expect(cards.receive(.cardFinished(generationID: 1)) == nil)

        let text = """
            Mondentfernung
            Der Mond ist im Mittel **384 400 Kilometer** entfernt.
            - Die Bahn schwankt zwischen [Perigäum](https://example.org/a) und Apogäum.
            Mehr dazu unter https://example.org/b
            ```swift
            let distance = 384_400
            ```
            ```svg
            <svg viewBox="0 0 1 1"><circle r="1"/></svg>
            ```
            {"calls":[],"speech":"not for the ear"}
            <b>markup</b>
            | a | b |
            [NASA](https://example.org/nasa) · [ESA](https://example.org/esa)
            Quellen: [NASA](https://example.org/nasa)
            """
        let said = try #require(utterance(decisions(&cards, card(2, text, block: 1, source: 1)).last))
        #expect(said.text == "Der Mond ist im Mittel 384 400 Kilometer entfernt. Die Bahn schwankt zwischen Perigäum und Apogäum. Mehr dazu unter.")
        #expect(said.card == 2 && said.block == 1 && said.sentence == 1 && said.part == .answer && said.lead == nil && said.version == 1)
        // An answer adds no word: nothing is announced as checked, researched or certain.
        let onScreen = SpokenCards.key(text)
        for word in said.text.split(separator: " ") { #expect(onScreen.contains(SpokenCards.key(String(word)))) }
        // A card that has nothing but its title says the title: it is the answer then.
        #expect(SpokenCards.sentences(of: "**Am Dienstag**") == ["Am Dienstag."])
    }

    @Test func aCardOfOnlyCodeOrMarkupSaysNothing() {
        var cards = SpokenCards()
        let decision = decisions(&cards, card(1, "```json\n{\"a\": 1}\n```\n<svg></svg>\n[1, 2, 3]\n{ \"b\": 2 }")).last
        #expect(decision == .skip(card: 1, block: 1, sentence: 1, reason: .empty))
        // An unclosed second fence hides everything after it.
        #expect(SpokenCards.sentences(of: "Titel\n```swift\nlet a = 1\n```\nDer Text danach.\n```python\nprint(1)\nnoch Code") == ["Der Text danach."])
    }

    @Test func sentencesAreSplitWhereTheyEndAndNotAtAbbreviationsOrNumbers() {
        #expect(SpokenCards.split("Das kostet ca. 5 Franken. Danach z. B. die 3. Stufe wählen. Fertig! Und dann?")
            == ["Das kostet ca. 5 Franken.", "Danach z. B. die 3. Stufe wählen.", "Fertig!", "Und dann?"])
        #expect(SpokenCards.split("Version 3.5 ist aktuell") == ["Version 3.5 ist aktuell"])
    }

    /// Spoken answers write numbers as words; a changed number word is a changed claim.
    @Test func aNumberWrittenAsAWordCountsLikeADigitWhenAClaimChanges() {
        #expect(SpokenCards.changed("Der Akku hält ungefähr zehn Stunden.", "Der Akku hält ungefähr sechs Stunden."))
        #expect(SpokenCards.changed("Das dauert etwa fünfzehn Minuten.", "Das dauert etwa fünfzig Minuten."))
        #expect(SpokenCards.changed("It takes about twenty minutes.", "It takes about thirty minutes."))
        #expect(SpokenCards.changed("Der Akku hält 10 Stunden.", "Der Akku hält 6 Stunden."))
        #expect(!SpokenCards.changed("Der Anbieter betreibt die Server.", "Der Anbieter betreibt alle Server."), "another article is no other claim")
        #expect(!SpokenCards.changed("Der Akku hält zehn Stunden.", "Kubernetes verteilt zehn Container."), "another subject is no correction")
        #expect(!SpokenCards.says("Der Akku hält ungefähr zehn Stunden.", "Der Akku hält ungefähr sechs Stunden."))
        #expect(SpokenCards.says("Der Anbieter betreibt die Server.", "Der Anbieter betreibt alle Server."))
    }

    @Test func aLongAnswerIsCutBetweenSentencesNeverInsideOne() throws {
        var cards = SpokenCards()
        let lines = (1...12).map { "Das hier ist der Satz Nummer \($0) der Antwort." }
        let cut = try #require(utterance(decisions(&cards, card(1, (["Titel"] + lines).joined(separator: "\n"))).last))
        #expect(cut.sentences == Array(lines.prefix(SpokenCards.maximumSentences)))
        var long = SpokenCards()
        let wordy = (1...6).map { "Satz \($0) " + String(repeating: "Wort ", count: 38) + "Ende." }
        let limited = try #require(utterance(decisions(&long, card(1, (["Titel"] + wordy).joined(separator: "\n"))).last))
        #expect(limited.sentences == Array(wordy.prefix(limited.sentences.count)) && limited.sentences.count < wordy.count)
        #expect(limited.text.count <= SpokenCards.maximumCharacters + limited.sentences.count)
        #expect(limited.sentences.allSatisfy { $0.hasSuffix("Ende.") }, "whole sentences only")
    }

    @Test func laterVersionsOfATurnAddOnlyWhatWasNotHeardAndANewTurnIsAnAnswerAgain() throws {
        var cards = SpokenCards(language: .de)
        _ = decisions(&cards, card(1, "Serverless\nDer Anbieter betreibt die Server.\nAbgerechnet wird nach Aufrufen."))
        // The same card again, with other formatting and a sources line: nothing new.
        let same = decisions(&cards, card(2, "Serverless\n**Der Anbieter betreibt die Server**\n- Abgerechnet wird nach Aufrufen\nQuellen: [x](https://example.org)",
                                          block: 1, source: 1, kind: .deep)).last
        #expect(same == .skip(card: 2, block: 1, sentence: 1, reason: .repeated))
        // Nearly the same words say the same thing: not said twice.
        let reworded = decisions(&cards, card(3, "Serverless\nDer Anbieter betreibt alle Server.", block: 1, source: 2, kind: .deep)).last
        #expect(reworded == .skip(card: 3, block: 1, sentence: 1, reason: .repeated))
        // A researched version: what was heard is not said again, the rest is an addition.
        let more = try #require(utterance(decisions(&cards, card(4, "Serverless\nDer Anbieter betreibt die Server.\nAbgerechnet wird nach Aufrufen.\nEin Kaltstart kostet einige hundert Millisekunden.",
                                                                 block: 1, source: 3, kind: .deep)).last))
        #expect(more.text == "Dazu noch: Ein Kaltstart kostet einige hundert Millisekunden.")
        #expect(more.part == .addition && more.sentences == ["Ein Kaltstart kostet einige hundert Millisekunden."] && more.kind == .deep && more.version == 4)
        // The reviewed addition is what a version with one is asked about; its title is not said.
        let focused = try #require(utterance(decisions(&cards, card(5, "Serverless\nDer Anbieter betreibt die Server.\nAWS Lambda ist ein Beispiel dafür.", block: 1, source: 4,
                                                                    focus: "Serverless\nAWS Lambda ist ein Beispiel dafür.")).last))
        #expect(focused.sentences == ["AWS Lambda ist ein Beispiel dafür."] && focused.part == .addition)
        // A turn is not talked about for ever.
        let third = decisions(&cards, card(6, "Serverless\nNoch ein ganz anderer Satz zum selben Thema.", block: 1, source: 5)).last
        #expect(third == .skip(card: 6, block: 1, sentence: 1, reason: .limit))
        // A newer sentence about the same subject is a turn of its own: an answer, without a transition.
        let next = try #require(utterance(decisions(&cards, card(7, "Serverless\nDer Anbieter betreibt die Server.\nFür Dauerlast ist ein eigener Server meist günstiger.",
                                                                 sentence: 2, block: 1, source: 6)).last))
        #expect(next.text == "Für Dauerlast ist ein eigener Server meist günstiger." && next.part == .answer && next.sentence == 2)
        let after = try #require(utterance(decisions(&cards, card(8, "Serverless\nDie Grenze liegt oft bei einigen Millionen Aufrufen im Monat.", sentence: 2, block: 1, source: 7, kind: .deep)).last))
        #expect(after.part == .addition, "the new turn has its own additions")
        // Another subject starts fresh. English has its own transitions.
        #expect(utterance(decisions(&cards, card(9, "Kubernetes\nEs verteilt Container auf Rechner.", sentence: 3)).last)?.text == "Es verteilt Container auf Rechner.")
        #expect(SpokenCards.lead(.addition, .en) == "One more thing on that:" && SpokenCards.lead(.correction, .en) == "A correction to that:")
    }

    @Test func aChangedNumberOrNegationOrATypedCorrectionIsSaidAsACorrection() throws {
        var cards = SpokenCards(language: .de)
        _ = decisions(&cards, card(1, "Mondentfernung\nDer Mond ist im Mittel 384 400 Kilometer entfernt.\nDas Angebot ist kostenlos."))
        // The same statement with another number: never appended as if nothing had been said.
        let number = try #require(utterance(decisions(&cards, card(2, "Mondentfernung\nDer Mond ist im Mittel 405 500 Kilometer entfernt.",
                                                                   block: 1, source: 1, kind: .deep)).last))
        #expect(number.part == .correction && number.text == "Eine Korrektur dazu: Der Mond ist im Mittel 405 500 Kilometer entfernt.")
        let negated = try #require(utterance(decisions(&cards, card(3, "Mondentfernung\nDas Angebot ist nicht kostenlos.", block: 1, source: 2, kind: .deep)).last))
        #expect(negated.part == .correction)
        // A correction is not held back by the addition limit, and does not use it up.
        let more = try #require(utterance(decisions(&cards, card(4, "Mondentfernung\nDie Entfernung wird mit Laserstrahlen gemessen.", block: 1, source: 3)).last))
        #expect(more.part == .addition)
        // The decision service's classification, where the words alone do not show it.
        cards.markCorrection(card: 5)
        let typed = try #require(utterance(decisions(&cards, card(5, "Mondentfernung\nGemessen wird mit Radar und nicht mit Lasern.", block: 1, source: 4)).last))
        #expect(typed.part == .correction && typed.lead == "Eine Korrektur dazu:")
        // The first thing said for a block is an answer even when the engine calls it a correction.
        cards.markCorrection(card: 6)
        #expect(utterance(decisions(&cards, card(6, "Gezeiten\nEbbe und Flut entstehen durch den Mond.", sentence: 2)).last)?.part == .answer)
    }

    @Test func wordsCountAsHeardOnlyOnceTheirAudioWasScheduled() throws {
        var cards = SpokenCards(language: .de)
        // Chosen, but the voice never played it (it waited too long, or it has no model).
        let first = try #require(utterance(decisions(&cards, card(1, "Serverless\nDer Anbieter betreibt die Server."), hear: false).last))
        let second = try #require(utterance(decisions(&cards, card(2, "Serverless\nDer Anbieter betreibt die Server.\nAbgerechnet wird nach Aufrufen.", block: 1, source: 1),
                                                      hear: false).last))
        #expect(second.part == .answer && second.sentences.count == 2, "nothing was heard: the newer version says all of it")
        // The first one is heard after all, while the second waits: the second is composed again.
        cards.heard(first)
        let fresh = try #require(cards.refreshed(second))
        #expect(fresh.text == "Dazu noch: Abgerechnet wird nach Aufrufen." && fresh.part == .addition)
        cards.heard(fresh)
        #expect(cards.refreshed(second) == nil, "nothing of it is left to say")
    }

    @Test func ledgerCarriedAndOutdatedCardsAreNotSaid() {
        var cards = SpokenCards()
        #expect(decisions(&cards, card(1, "Entscheidungen\nRelease am Freitag", meeting: true)).last == .skip(card: 1, block: 1, sentence: 1, reason: .meeting))
        // A verbatim quote of what someone just said is shown, not read back to them.
        let quote = CardStart(generationID: 8, kind: .fast, style: .answer, triggerSegment: 1, sourceCard: nil, contextVersion: 0, mappingVersion: 0,
                              evidenceSegment: 1, blockID: 8)
        #expect(decisions(&cards, [.cardStarted(quote), .cardDelta(generationID: 8, text: "Seit wann?\n„Seit 2005.“"), .cardFinished(generationID: 8)]).last
            == .skip(card: 8, block: 8, sentence: 1, reason: .quoted))
        // Blocks carried over from an earlier conversation answer no sentence of this one.
        #expect(decisions(&cards, card(2, "Früher\nEine alte Karte", sentence: 0)).last == .skip(card: 2, block: 2, sentence: 0, reason: .carried))
        #expect(decisions(&cards, card(3, "Früher\nEine alte Karte", sentence: nil)).last == .skip(card: 3, block: 3, sentence: nil, reason: .carried))
        // Two newer sentences are a conversation in flow; three have moved on.
        _ = decisions(&cards, [final(4), final(5), final(6), final(6)])
        #expect(utterance(decisions(&cards, card(4, "Thema\nNoch aktuell genug.", sentence: 4)).last) != nil)
        _ = decisions(&cards, [final(7)])
        #expect(decisions(&cards, card(5, "Thema zwei\nZu spät dafür.", sentence: 4)).last == .skip(card: 5, block: 5, sentence: 4, reason: .stale))
    }
}

/// A voice that says nothing and keeps its callbacks when retired, so a test can deliver
/// what a replaced voice might still have queued. It gets one sentence at a time.
@MainActor private final class CardVoice: AssistantSpeechOutput {
    typealias Callback = (ConversationResponseID) -> Void
    let name: String
    var began: Callback?
    var finished: Callback?
    var cancelled: Callback?
    var spoken: [(text: String, response: ConversationResponseID)] = []
    var texts: [String] { spoken.map(\.text) }
    var stops = 0
    var retirements = 0
    var late: (began: Callback?, finished: Callback?, cancelled: Callback?)?
    init(_ name: String) { self.name = name }
    func speak(_ text: String, response: ConversationResponseID, language: Language) { spoken.append((text, response)) }
    func stop() { stops += 1 }
    func retire() {
        retirements += 1
        late = (began, finished, cancelled)
        stop()
    }
    /// The player begins the sentence.
    func begin(_ index: Int) { began?(spoken[index].response) }
    /// The sentence has played to its end.
    func finish(_ index: Int) { finished?(spoken[index].response) }
    func play(_ index: Int) { begin(index); finish(index) }
    /// Plays every sentence it is given from `index` on, also those that follow at once.
    func playOn(from index: Int) {
        var next = index
        while next < spoken.count { play(next); next += 1 }
    }
}

/// A voice that reports its own progress, as the local voices do: it is given a sentence
/// ahead and says which one the player has begun.
@MainActor private final class StreamVoice: AssistantSentenceSpeechOutput {
    let name: String
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var reached: ((ConversationResponseID, Int) -> Void)?
    var responses: [ConversationResponseID] = []
    var appended: [String] = []
    var completed = 0
    var stops = 0
    init(_ name: String = "stream") { self.name = name }
    func begin(response: ConversationResponseID, language: Language) { responses.append(response); appended = [] }
    func append(_ text: String, response: ConversationResponseID) { if response == responses.last { appended.append(text) } }
    func complete(response: ConversationResponseID) { if response == responses.last { completed += 1 } }
    func speak(_ text: String, response: ConversationResponseID, language: Language) {
        begin(response: response, language: language); append(text, response: response); complete(response: response)
    }
    func stop() { stops += 1 }
    func reach(_ index: Int) { reached?(responses[responses.count - 1], index) }
    func end() { finished?(responses[responses.count - 1]) }
}

@MainActor @Suite struct SpokenHarnessTests {
    @MainActor fileprivate final class Stage {
        var clock = 100.0
        var voices: [CardVoice] = [CardVoice("first")]
        var streams: [StreamVoice] = []
        var records: [(kind: String, fields: [String: Any])] = []
        var turnPauses = 0
        let harness: SpokenHarness
        let systems: SystemStore
        let file: URL

        /// `streaming`: the voices report their own progress and are fed a sentence ahead.
        init(engine: TalkBackEngine = .system, speak: Bool = true, streaming: Bool = false,
             reactionDelay: Duration? = nil) throws {
            file = URL.temporaryDirectory.appending(path: "spoken-harness-\(UUID())/systems.json")
            systems = SystemStore(file: file, current: SystemConfig())
            var settings = VoiceAssistantConfiguration(enabled: true, speakReplies: speak)
            settings.answerSource = .harness
            settings.talkBackEngine = engine
            var system = try #require(systems.system("interview"))
            var configuration = system.configuration ?? SystemConfig()
            configuration.conversation = settings
            system.configuration = configuration
            systems.update(system)
            var read: () -> Double = { 0 }
            var make: (VoiceAssistantConfiguration) -> any AssistantSpeechOutput = { _ in CardVoice("unused") }
            let first: any AssistantSpeechOutput
            if streaming {
                let stream = StreamVoice("first")
                streams = [stream]
                first = stream
            } else {
                first = voices[0]
            }
            harness = SpokenHarness(system: "interview", language: .de, configuration: settings, speaker: first,
                                    makeSpeaker: { make($0) }, releaseOtherVoices: { _ in }, reactionDelay: reactionDelay,
                                    reactionBank: ConversationReactionBank(), now: { read() })
            read = { [unowned self] in self.clock }
            make = { [unowned self] next in
                let name = next.talkBackEngine == .system ? "system" : next.talkBackVoice
                if streaming {
                    let voice = StreamVoice(name)
                    self.streams.append(voice)
                    return voice
                }
                let voice = CardVoice(name)
                self.voices.append(voice)
                return voice
            }
            harness.record = { [unowned self] in self.records.append(($0, $1)) }
            harness.onTurnPause = { [unowned self] in self.turnPauses += 1 }
        }

        func send(_ events: [ServerEvent]) { events.forEach(harness.receive) }
        func states(_ kind: String) -> [String] { records.filter { $0.kind == kind }.compactMap { $0.fields["state"] as? String } }
        func reasons(card: UInt64) -> [String] { records.filter { $0.fields["card"] as? UInt64 == card }.compactMap { $0.fields["reason"] as? String } }
        func cleanUp() { harness.stop(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var saved: VoiceAssistantConfiguration? {
            SystemStore(file: file, current: SystemConfig()).system("interview")?.configuration?.conversation
        }
    }

    private func settled(_ stage: Stage) async throws {
        for _ in 0..<300 where stage.harness.settling { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!stage.harness.settling)
    }

    private let three = "Akku\nDer Akku hält ungefähr zehn Stunden.\nGeladen ist er in etwa einer Stunde.\nBei Kälte hält er spürbar kürzer."

    @Test func aLocalBridgeDoesNotBecomeACardAndParallelRolesKeepWorking() async throws {
        let stage = try Stage(reactionDelay: .milliseconds(10)); defer { stage.cleanUp() }
        let saved = stage.saved
        stage.harness.setDuplexListening(true)
        stage.send([transcript(3, "Erkläre mir bitte den Unterschied.")])
        stage.harness.heardQuiet(for: 0.6)
        stage.harness.round(3, running: true)
        stage.harness.round(4, running: true)
        for _ in 0..<200 where stage.voices[0].spoken.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(stage.voices[0].texts == ["Ich gehe die Unterschiede durch."] && stage.harness.reacting)
        stage.voices[0].begin(0)
        stage.harness.round(3, running: false)
        #expect(stage.harness.thinking, "one finished role must not clear another active role")
        stage.send(card(7, "Unterschied\nHier ist die inhaltliche Antwort.", sentence: 3))
        #expect(stage.voices[0].spoken.count == 1, "let the short audible bridge finish")
        stage.voices[0].finish(0)
        #expect(stage.voices[0].texts == ["Ich gehe die Unterschiede durch.", "Hier ist die inhaltliche Antwort."])
        #expect(stage.records.filter { $0.kind == "voice_speech" }.allSatisfy { $0.fields["card"] as? UInt64 == 7 })
        #expect(stage.saved == saved)
        stage.harness.round(0, running: false) // AnswerEngine.stop's all-rounds signal
        #expect(!stage.harness.thinking)
    }

    @Test func aStreamingVoiceYieldsTheBridgeWithoutStoppingTheRoles() async throws {
        let stage = try Stage(streaming: true, reactionDelay: .milliseconds(10)); defer { stage.cleanUp() }
        stage.harness.setDuplexListening(true)
        stage.send([transcript(3, "Erkläre mir bitte den Unterschied.")])
        stage.harness.heardQuiet(for: 0.6)
        stage.harness.round(3, running: true)
        for _ in 0..<200 where stage.streams[0].appended.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(stage.streams[0].appended == ["Ich gehe die Unterschiede durch."])
        stage.streams[0].reach(0)
        stage.harness.microphoneActivity(speechSeconds: 0.2)
        #expect(!stage.harness.reacting && !stage.harness.speaking && stage.harness.thinking)
        // Late bridge callbacks do not acknowledge a card or start output.
        stage.streams[0].end()
        stage.harness.heardQuiet(for: 0.6)
        stage.send(card(7, "Unterschied\nDie Antwort bleibt erhalten.", sentence: 3))
        #expect(stage.streams[0].appended == ["Die Antwort bleibt erhalten."])
        #expect(stage.harness.thinking)
    }

    @Test func anAnswerIsSaidOnceTheMicrophoneIsQuietAndIsCorrelatedInTheRecord() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        stage.harness.began()
        #expect(stage.records.first?.kind == "voice_choice" && stage.records.first?.fields["tts_model"] as? String == "system")
        stage.send([final(3)])
        stage.clock += 2
        // The person is still speaking: the answer waits.
        stage.harness.heardQuiet(for: 0)
        stage.send(card(7, "Serverless\nDer Anbieter betreibt die Server.", sentence: 3))
        #expect(stage.voices[0].spoken.isEmpty && stage.states("voice_speech") == ["queued"] && stage.harness.hearing && stage.harness.waitingCount == 1)
        stage.clock += 1
        stage.harness.heardQuiet(for: 0.6)
        let said = try #require(stage.voices[0].spoken.first)
        #expect(said.text == "Der Anbieter betreibt die Server." && stage.harness.speaking && !stage.harness.audible)
        #expect(stage.harness.blocksRecognition && stage.harness.lastSpoken == said.text)
        let speaking = try #require(stage.records.last?.fields)
        #expect(speaking["state"] as? String == "speaking" && speaking["card"] as? UInt64 == 7 && speaking["sentence"] as? UInt64 == 3)
        #expect(speaking["block"] as? UInt64 == 7 && speaking["part"] as? String == "answer" && speaking["joined"] as? Bool == false)
        #expect(speaking["since_card_s"] as? Double == 1 && speaking["chars"] as? Int == said.text.count)
        #expect(speaking["since_sentence_s"] as? Double == 3, "from the committed sentence to the words reaching the voice")
        #expect(stage.records.allSatisfy { $0.fields["text"] == nil }, "the record holds identifiers and lengths, not the words")

        stage.clock += 0.25
        stage.voices[0].begin(0)
        #expect(stage.harness.audible)
        let scheduled = try #require(stage.records.last)
        #expect(scheduled.kind == "voice_playback" && scheduled.fields["state"] as? String == "scheduled")
        #expect(scheduled.fields["heard_sentences"] as? Int == 1 && scheduled.fields["heard"] as? Bool == true)
        #expect(scheduled.fields["since_voice_s"] as? Double == 0.25 && scheduled.fields["since_card_s"] as? Double == 1.25)
        #expect(scheduled.fields["since_sentence_s"] as? Double == 3.25 && scheduled.fields["response"] as? String == speaking["response"] as? String)
        #expect((scheduled.fields["audio"] as? String)?.contains("not measured as sound") == true, "audio at the player is not called heard sound")
        stage.clock += 2
        stage.voices[0].finish(0)
        #expect(!stage.harness.speaking && !stage.harness.audible && stage.states("voice_playback") == ["scheduled", "finished"])
        #expect(stage.records.last?.fields["heard_sentences"] as? Int == 1)
        #expect(stage.harness.blocksRecognition, "the room still carries the voice for a moment")
        try await settled(stage)
        #expect(!stage.harness.blocksRecognition)
    }

    @Test func answersToSeveralQuestionsAreSaidInOrderAndNothingTalksOverAnother() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        for id in UInt64(1)...5 { stage.send(card(id, "Thema \(id)\nDas ist die Antwort Nummer \(id).", sentence: id)) }
        #expect(stage.voices[0].spoken.count == 1, "nothing talks over the answer being said")
        // Three blocks wait; the oldest gives way to a fourth.
        #expect(stage.reasons(card: 2) == ["too many blocks waited"] && stage.harness.waitingCount == 3)
        // A waiting answer that is replaced or withdrawn is not said afterwards.
        stage.send([.cardSuperseded(generationID: 4, by: 9)])
        stage.voices[0].play(0)
        try await settled(stage)
        stage.voices[0].play(1)
        try await settled(stage)
        #expect(stage.voices[0].texts == ["Das ist die Antwort Nummer 1.", "Das ist die Antwort Nummer 3.", "Das ist die Antwort Nummer 5."])
    }

    @Test func aDeepResultJoinsAThreeSentenceAnswerAtTheNextSentenceEndWithoutRestartingIt() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        let voice = stage.voices[0]
        stage.send([final(1)])
        stage.send(card(1, three))
        // One sentence at the voice; the others are a plan that can still change.
        #expect(voice.texts == ["Der Akku hält ungefähr zehn Stunden."] && stage.harness.plannedSentences == 2)
        voice.begin(0)
        voice.finish(0)
        #expect(voice.texts.last == "Geladen ist er in etwa einer Stunde." && stage.harness.speaking && !stage.harness.settling)
        voice.begin(1)
        let stops = voice.stops
        // The deeper version arrives while the second sentence is being said.
        stage.send(card(2, three + "\nEr hat eine Kapazität von sechzig Wattstunden.", block: 1, source: 1, kind: .deep))
        #expect(voice.spoken.count == 2 && voice.stops == stops, "the running answer is neither restarted nor cut")
        #expect(stage.harness.plannedSentences == 2 && stage.harness.waitingCount == 0, "it joined the speech; it does not wait for the end of a long answer")
        let placed = try #require(stage.records.last?.fields)
        #expect(placed["state"] as? String == "queued" && placed["joined"] as? Bool == true && placed["queue_priority"] as? Int == 1)
        #expect(placed["queue_position"] as? Int == 0 && placed["queue_ahead"] as? Int == 0, "next, before the rest of the answer")
        // The same version again: nothing is planned twice.
        stage.send(card(3, three + "\nEr hat eine Kapazität von sechzig Wattstunden.", block: 1, source: 2, kind: .deep))
        #expect(stage.harness.plannedSentences == 2)
        voice.finish(1)
        voice.playOn(from: 2)
        // The addition comes at the next sentence end; what was left of the answer follows it, once.
        #expect(voice.texts == ["Der Akku hält ungefähr zehn Stunden.", "Geladen ist er in etwa einer Stunde.",
                                "Dazu noch: Er hat eine Kapazität von sechzig Wattstunden.", "Bei Kälte hält er spürbar kürzer."])
        #expect(stage.harness.blocksRecognition, "one speech: Listen's own voice stayed withheld from recognition throughout")
        let joined = try #require(stage.records.last { $0.fields["state"] as? String == "speaking" }?.fields)
        #expect(joined["joined"] as? Bool == true && joined["part"] as? String == "addition" && joined["card_kind"] as? String == "deep")
        #expect(stage.states("voice_playback") == ["scheduled", "scheduled", "finished"] && stage.records.last?.fields["heard_sentences"] as? Int == 4)
        try await settled(stage)
        // Nothing is padded: with nothing new, nothing more is said.
        stage.send(card(4, three + "\nEr hat eine Kapazität von sechzig Wattstunden.", block: 1, source: 3, kind: .deep))
        #expect(voice.spoken.count == 4 && stage.records.last?.fields["reason"] as? String == SpokenCards.Skip.repeated.rawValue)
    }

    @Test func aCorrectionComesAtTheNextSentenceEndAndAnObsoleteClaimNotYetSaidIsReplacedSilently() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        let voice = stage.voices[0]
        stage.send(card(1, three))
        voice.begin(0)
        // The deeper version changes a claim nobody has heard yet, and one that is being heard.
        stage.send(card(2, "Akku\nDer Akku hält ungefähr sechs Stunden.\nGeladen ist er in etwa zwei Stunden.\nBei Kälte hält er spürbar kürzer.",
                        block: 1, source: 1, kind: .deep))
        voice.finish(0)
        voice.playOn(from: 1)
        #expect(voice.texts == [
            "Der Akku hält ungefähr zehn Stunden.",
            // What was heard is corrected aloud, at once.
            "Eine Korrektur dazu: Der Akku hält ungefähr sechs Stunden.",
            // What was only planned is said right, in its place, as if it had never been otherwise.
            "Geladen ist er in etwa zwei Stunden.",
            "Bei Kälte hält er spürbar kürzer.",
        ])
        #expect(!voice.texts.contains("Geladen ist er in etwa einer Stunde."), "the obsolete claim is never said")
        #expect(stage.records.contains { $0.fields["state"] as? String == "replaced" && $0.fields["sentences"] as? Int == 1 })
    }

    /// The backlog measured on two recorded questions (23 November 2026): the main model's
    /// addition was ready while the second sentence of a four-sentence answer was prepared,
    /// and reached the player 18 s later, behind every sentence that was left.
    @Test func aDeepAdditionIsSaidAtTheNextBoundaryAndNotBehindTheRestOfTheAnswer() async throws {
        let stage = try Stage(streaming: true); defer { stage.cleanUp() }
        let voice = stage.streams[0]
        let answer = ["Eine Anfrage schickst du mit einer Sitzung ab.", "Ein Zeitlimit beweist nicht, dass die Anmeldung gescheitert ist.",
                      "Die Anmeldung daher nicht blind wiederholen.", "Zeige am Ende einen passenden Fehlerzustand an."]
        let more = ["Den Statuscode prüfst du, bevor du die Antwort liest.", "Das Zeitlimit begrenzt nur die Wartezeit ohne neue Daten."]
        stage.send([final(1)])
        stage.send(card(1, (["Anfrage"] + answer).joined(separator: "\n")))
        #expect(stage.harness.activity == .preparing && stage.harness.audibleSentence.isEmpty, "given to the voice is not said")
        stage.clock += 0.2
        voice.reach(0)
        #expect(stage.harness.activity == .speaking && stage.harness.audibleSentence == answer[0] && stage.harness.lastSpoken == answer[1])
        #expect(voice.appended == Array(answer.prefix(2)), "one sentence is prepared ahead")

        // The main model's addition is ready while the first sentence plays.
        stage.clock += 7.8
        let deep = (["Anfrage"] + more).joined(separator: "\n")
        stage.send(card(2, (["Anfrage"] + answer + more).joined(separator: "\n"), block: 1, source: 1, kind: .deep, focus: deep))
        #expect(voice.appended.count == 2 && voice.stops == 0, "nothing prepared is taken back or cut")
        let placed = try #require(stage.records.last?.fields)
        #expect(placed["state"] as? String == "queued" && placed["card"] as? UInt64 == 2 && placed["part"] as? String == "addition")
        #expect(placed["queue_priority"] as? Int == 1 && placed["queue_position"] as? Int == 1 && placed["queue_ahead"] as? Int == 2,
                "after the prepared sentence and the one that leans on it")
        #expect(placed["card_ready_uptime_s"] as? Double == 108 && placed["since_ready_s"] as? Double == 0 && placed["plan_sentences"] as? Int == 4)

        stage.clock += 1
        voice.reach(1)
        stage.clock += 5
        // The third sentence begins: the addition is given to the voice now, not after the fourth.
        voice.reach(2)
        #expect(voice.appended.last == "Dazu noch: " + more[0] && stage.harness.audibleSentence == answer[2])
        let given = try #require(stage.records.last?.fields)
        #expect(given["state"] as? String == "speaking" && given["card"] as? UInt64 == 2 && given["queue_wait_s"] as? Double == 6)
        stage.clock += 3
        voice.reach(3)
        let onset = try #require(stage.records.last)
        #expect(onset.kind == "voice_playback" && onset.fields["state"] as? String == "scheduled" && onset.fields["part"] as? String == "addition")
        #expect(onset.fields["since_ready_s"] as? Double == 9 && onset.fields["queue_wait_s"] as? Double == 6 && onset.fields["queue_priority"] as? Int == 1,
                "card ready to the player's onset, and how much of it was the queue")
        #expect(stage.harness.audibleSentence == "Dazu noch: " + more[0])
        voice.reach(4)
        voice.reach(5)
        #expect(voice.appended == [answer[0], answer[1], answer[2], "Dazu noch: " + more[0], more[1], answer[3]],
                "the whole first answer is still said, nothing twice")
        #expect(voice.completed == 1)
        voice.end()
        #expect(stage.harness.activity == .speaking && stage.harness.blocksRecognition, "the room still carries the voice: not listening yet")
        try await settled(stage)
        #expect(stage.harness.activity == .listening && stage.harness.audibleSentence == answer[3] && !stage.harness.audible)
    }

    @Test func correctionsThenAdditionsThenTheRestOfTheAnswerEachInTheOrderTheyCame() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        let voice = stage.voices[0]
        let answer = ["Der Akku hält ungefähr zehn Stunden.", "Geladen ist er in etwa einer Stunde.", "Das Netzteil liegt dem Gerät bei.",
                      "Bei Kälte hält er spürbar kürzer.", "Im Flugmodus sparst du am meisten Strom."]
        func more(_ id: UInt64, _ sentences: [String]) -> [ServerEvent] {
            card(id, "Akku\nSynthetic block text.", block: 1, source: id - 1, kind: .deep, focus: (["Akku"] + sentences).joined(separator: "\n"))
        }
        stage.send([final(1)])
        stage.send(card(1, (["Akku"] + answer).joined(separator: "\n")))
        voice.begin(0)
        // Two additions; the first says one of the answer's remaining sentences in more words.
        stage.send(more(2, ["Er hat eine Kapazität von sechzig Wattstunden.", "Bei Kälte hält er spürbar kürzer als im Sommer."]))
        #expect(stage.records.last?.fields["covered_sentences"] as? Int == 1 && stage.harness.plannedSentences == 5)
        stage.send(more(3, ["Nach fünfhundert Ladezyklen lässt er merklich nach."]))
        stage.send(more(4, ["Ein Tausch kostet beim Hersteller etwa achtzig Franken."]))
        // Two corrections, classified by the decision service, arrive after the additions.
        stage.harness.correction(card: 5)
        stage.send(more(5, ["Die Garantie deckt den Akku nicht ab."]))
        stage.harness.correction(card: 6)
        stage.send(more(6, ["Verkauft wird das Gerät seit dem Frühjahr."]))
        #expect(stage.records.last?.fields["queue_priority"] as? Int == 0 && stage.records.last?.fields["queue_position"] as? Int == 1,
                "behind the correction that came first, ahead of everything else")
        // One addition is taken back before it is said.
        stage.send([.cardCancelled(generationID: 4)])
        #expect(voice.spoken.count == 1 && stage.harness.speaking, "the answer goes on")
        voice.finish(0)
        voice.playOn(from: 1)
        #expect(voice.texts == [
            answer[0],
            "Eine Korrektur dazu: Die Garantie deckt den Akku nicht ab.", "Eine Korrektur dazu: Verkauft wird das Gerät seit dem Frühjahr.",
            "Dazu noch: Er hat eine Kapazität von sechzig Wattstunden.", "Bei Kälte hält er spürbar kürzer als im Sommer.",
            "Dazu noch: Nach fünfhundert Ladezyklen lässt er merklich nach.",
            answer[1], answer[2], answer[4],
        ])
    }

    @Test func approximateSimilarityCannotEraseAnUnheardFact() {
        #expect(SpokenHarness.covers("Bei Kälte hält er spürbar kürzer als im Sommer.", "Bei Kälte hält er spürbar kürzer."))
        #expect(!SpokenHarness.covers("Der Server liest die Datei vom Client.", "Der Client liest die Datei vom Server."))
        #expect(!SpokenHarness.covers("Der Akku lädt über USB und wird dabei warm.", "Der Akku lädt über USB und unterstützt Schnellladen."))
    }

    @Test func aCorrectionGoesAheadOfWhatAVoiceChangeLeftAndStaysWhenThePersonSpeaksOn() async throws {
        let stage = try Stage(streaming: true); defer { stage.cleanUp() }
        let old = stage.streams[0]
        stage.send([final(1)])
        stage.send(card(1, three))
        old.reach(0)
        stage.send(card(2, "Akku\nSynthetic block text.", block: 1, source: 1, kind: .deep, focus: "Akku\nEr hat eine Kapazität von sechzig Wattstunden."))
        #expect(stage.harness.plannedSentences == 2)
        try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.pocketGerman, voice: "alba"), store: stage.systems)
        #expect(stage.harness.waitingCount == 1 && stage.harness.activity == .speaking)
        // A correction arrives before the new voice goes on: it joins what was left, in front.
        stage.harness.correction(card: 3)
        stage.send(card(3, "Akku\nSynthetic block text.", block: 1, source: 2, kind: .deep, focus: "Akku\nDie Garantie deckt den Akku nicht ab."))
        #expect(stage.harness.waitingCount == 1 && stage.records.last?.fields["queue_position"] as? Int == 0)
        // The person says something new: the old answer and its addition are left, the correction is owed.
        stage.send([final(2)])
        #expect(stage.harness.waitingCount == 1 && stage.records.last?.fields["reason"] as? String == "the conversation moved on")
        try await settled(stage)
        let new = stage.streams[1]
        #expect(new.appended == ["Eine Korrektur dazu: Die Garantie deckt den Akku nicht ab."])
        new.reach(0)
        #expect(new.completed == 1 && stage.harness.audibleSentence == new.appended[0])
    }

    @Test func aCorrectionThatWaitsForAPauseIsNotLostToANewerVersionOfItsBlock() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        let voice = stage.voices[0]
        stage.send([final(1)])
        stage.send(card(1, "Akku\nDer Akku hält ungefähr zehn Stunden."))
        voice.play(0)
        try await settled(stage)
        // The person speaks: what comes now waits.
        stage.harness.heardQuiet(for: 0)
        stage.harness.correction(card: 2)
        stage.send(card(2, "Akku\nSynthetic block text.", block: 1, source: 1, kind: .deep, focus: "Akku\nDie Garantie deckt den Akku nicht ab."))
        stage.send([.cardSuperseded(generationID: 2, by: 3)])
        #expect(stage.harness.waitingCount == 1 && stage.harness.activity == .waitingForPause)
        stage.send(card(3, "Akku\nSynthetic block text.", block: 1, source: 2, kind: .deep, focus: "Akku\nEr hat eine Kapazität von sechzig Wattstunden."))
        #expect(stage.harness.waitingCount == 1 && voice.spoken.count == 1)
        stage.harness.heardQuiet(for: 1)
        voice.playOn(from: 1)
        #expect(voice.texts.suffix(2) == ["Eine Korrektur dazu: Die Garantie deckt den Akku nicht ab.",
                                          "Dazu noch: Er hat eine Kapazität von sechzig Wattstunden."])
    }

    @Test func aVoiceChangeDuringTheSecondSentenceKeepsTheThirdAndRepeatsNothing() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        let before = try #require(stage.systems.system("interview"))
        let old = stage.voices[0]
        stage.send(card(1, three))
        stage.send(card(2, "Lüfter\nDer Lüfter läuft nur unter Last.", sentence: 2))
        old.play(0)
        old.begin(1)
        #expect(stage.harness.audible && stage.harness.plannedSentences == 1)

        let alba = AssistantVoiceChoice(engine: .local, model: TalkBack.pocketGerman, voice: "alba")
        try stage.harness.chooseVoice(alba, store: stage.systems)
        #expect(old.retirements == 1 && old.stops >= 1 && !stage.harness.speaking && !stage.harness.audible)
        #expect(stage.voices.count == 2 && stage.voices[1].name == "alba" && stage.harness.voice == alba)
        #expect(stage.states("voice_choice") == ["changed"] && stage.records.last?.fields["tts_voice"] as? String == "alba")
        let cut = try #require(stage.records.last { $0.kind == "voice_playback" }?.fields)
        #expect(cut["state"] as? String == "cancelled" && cut["heard_sentences"] as? Int == 2 && cut["prepared_sentences"] as? Int == 2)
        // What the replaced voice might still deliver marks nothing heard and starts nothing.
        let count = stage.records.count
        old.late?.began?(old.spoken[1].response); old.late?.finished?(old.spoken[1].response); old.late?.cancelled?(old.spoken[0].response)
        #expect(stage.records.count == count && old.spoken.count == 2 && !stage.harness.speaking)

        try await settled(stage)
        let new = stage.voices[1]
        #expect(new.texts == ["Bei Kälte hält er spürbar kürzer."], "the sentence not yet begun is said in the new voice; the two heard are not")
        #expect(stage.records.last?.fields["tts_voice"] as? String == "alba")
        new.play(0)
        try await settled(stage)
        #expect(new.texts == ["Bei Kälte hält er spürbar kürzer.", "Der Lüfter läuft nur unter Last."], "what waited still waited")
        new.play(1)
        try await settled(stage)
        // The whole answer counts as heard now: its next version adds nothing.
        stage.send(card(3, three, block: 1, source: 1, kind: .deep))
        #expect(new.spoken.count == 2 && stage.records.last?.fields["reason"] as? String == SpokenCards.Skip.repeated.rawValue)

        // Rapid changes: every voice but the last is retired, and only the last one speaks.
        for voice in ["cosette", "fantine", "eponine"] {
            try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.pocketGerman, voice: voice), store: stage.systems)
        }
        try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.defaultModel, voice: "Sohee"), store: stage.systems)
        try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.defaultModel, voice: "Sohee"), store: stage.systems)
        #expect(stage.voices.map(\.name) == ["first", "alba", "cosette", "fantine", "eponine", "Sohee"])
        #expect(stage.voices.dropLast().allSatisfy { $0.retirements == 1 } && stage.voices.last?.retirements == 0)
        try await settled(stage)
        stage.send(card(4, "Netzteil\nDas Netzteil liefert 65 Watt.", sentence: 3))
        #expect(stage.voices.last?.texts == ["Das Netzteil liefert 65 Watt."])

        // Saved: the voice, and nothing else of the system.
        let after = try #require(SystemStore(file: stage.file, current: SystemConfig()).system("interview"))
        var expected = before
        expected.configuration?.conversation?.talkBackEngine = .local
        expected.configuration?.conversation?.talkBackModel = TalkBack.defaultModel
        expected.configuration?.conversation?.talkBackVoice = "Sohee"
        #expect(after == expected && after.speaksCards && !after.isVoiceAssistant)
        #expect(throws: (any Error).self) {
            try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.pocketGerman, voice: "Sohee"), store: stage.systems)
        }
        #expect(stage.voices.count == 6 && stage.saved?.talkBackVoice == "Sohee")
    }

    @Test func aVoiceThatIsFedAheadCountsOnlyTheSentenceThePlayerHasBegunAsHeard() async throws {
        let stage = try Stage(streaming: true); defer { stage.cleanUp() }
        let first = stage.streams[0]
        stage.send(card(1, three))
        #expect(first.responses.count == 1 && first.appended == ["Der Akku hält ungefähr zehn Stunden."] && !stage.harness.audible)
        // The player begins the first sentence: the second is handed over, to be generated meanwhile.
        first.reach(0)
        #expect(first.appended.count == 2 && stage.harness.audible && stage.harness.plannedSentences == 1 && first.completed == 0)
        // A correction now takes effect after the sentence already prepared, not after the whole answer.
        stage.send(card(2, "Akku\nDer Akku hält ungefähr zehn Stunden.\nGeladen ist er in etwa einer Stunde.\nBei Kälte hält er nicht spürbar kürzer.",
                        block: 1, source: 1, kind: .deep))
        #expect(stage.harness.plannedSentences == 1, "the planned claim was replaced in its place")
        // The voice is changed while the first sentence plays: the prepared second was not heard.
        try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.pocketGerman, voice: "alba"), store: stage.systems)
        // A late report of the replaced voice cannot mark anything heard.
        first.reach(1)
        try await settled(stage)
        let second = stage.streams[1]
        #expect(second.appended == ["Geladen ist er in etwa einer Stunde."], "prepared is not heard: the second sentence is said, the first is not repeated")
        second.reach(0)
        #expect(second.appended.last == "Bei Kälte hält er nicht spürbar kürzer." && second.appended.count == 2)
        second.reach(1)
        #expect(second.completed == 1, "nothing more to come: the voice may end after this sentence")
        // More arrives when the voice can take nothing further: it follows as the next speech, at once.
        stage.send(card(3, "Akku\nDer Akku hält ungefähr zehn Stunden.\nBei Kälte hält er nicht spürbar kürzer.\nEr hat eine Kapazität von sechzig Wattstunden.",
                        block: 1, source: 2, kind: .deep))
        #expect(second.responses.count == 1 && stage.harness.waitingCount == 1)
        second.end()
        #expect(second.responses.count == 2 && second.appended == ["Dazu noch: Er hat eine Kapazität von sechzig Wattstunden."] && !stage.harness.settling)
    }

    @Test func whatTheVoiceNeverBeganStaysEligibleAndWhatItBeganIsNotRepeated() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        let voice = stage.voices[0]
        stage.send(card(1, three))
        // The voice gives up before any audio (no model on the device, an engine error).
        voice.cancelled?(voice.spoken[0].response)
        let unheard = try #require(stage.records.last { $0.kind == "voice_playback" }?.fields)
        #expect(unheard["state"] as? String == "cancelled" && unheard["heard"] as? Bool == false && unheard["heard_sentences"] as? Int == 0)
        try await settled(stage)
        // Nothing was heard: the next version says all of it, as the answer.
        stage.send(card(2, three, block: 1, source: 1, kind: .deep))
        #expect(voice.texts.last == "Der Akku hält ungefähr zehn Stunden." && voice.spoken.count == 2)
        voice.play(1)
        voice.begin(2)
        // Stopped by the person in the second sentence: the third was never begun.
        stage.harness.interrupt()
        #expect(!stage.harness.speaking && stage.records.last?.fields["heard_sentences"] as? Int == 2)
        // A finish that arrives for the stopped sentence starts nothing.
        voice.finish(2)
        #expect(voice.spoken.count == 3)
        try await settled(stage)
        stage.send(card(3, three, block: 1, source: 2, kind: .deep))
        #expect(voice.texts.last == "Dazu noch: Bei Kälte hält er spürbar kürzer." && voice.spoken.count == 4,
                "only the sentence that was never begun is still owed")
    }

    @Test func aLateAdditionIsDroppedOnceThePersonHasMovedOnButACorrectionIsStillSaid() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        let voice = stage.voices[0]
        stage.send([final(1)])
        stage.send(card(1, "Akku\nDer Akku hält ungefähr 10 Stunden."))
        voice.play(0)
        try await settled(stage)
        // More for the same turn while nobody has spoken since: said, after the pause.
        stage.send(card(2, "Akku\nDer Akku hält ungefähr 10 Stunden.\nGeladen ist er in etwa einer Stunde.", block: 1, source: 1, kind: .deep))
        #expect(voice.texts.last == "Dazu noch: Geladen ist er in etwa einer Stunde.")
        voice.play(1)
        try await settled(stage)
        // A later hearing of the same sentence (Whisper, a voice label) is not a new turn.
        stage.send([transcript(1, "Synthetic, heard again.", revision: 2)])
        stage.send(card(3, "Akku\nDer Akku hält ungefähr 10 Stunden.\nEr hat eine Kapazität von 60 Wattstunden.", block: 1, source: 2, kind: .deep))
        #expect(voice.spoken.count == 3)
        voice.play(2)
        try await settled(stage)

        // A second question and its answer.
        stage.send([final(2)])
        stage.send(card(5, "Lüfter\nDer Lüfter läuft nur unter Last.", sentence: 2))
        voice.play(3)
        try await settled(stage)
        // The person says something new; research for the second question arrives after that.
        stage.send([final(3)])
        stage.send(card(6, "Lüfter\nDer Lüfter läuft nur unter Last.\nEr lässt sich im Menü abschalten.", sentence: 2, block: 5, source: 5, kind: .deep))
        #expect(voice.spoken.count == 4 && stage.reasons(card: 6) == ["the conversation moved on"])
        // A correction of what was said is still owed, also to an older turn.
        stage.send(card(7, "Akku\nDer Akku hält ungefähr 6 Stunden.", block: 1, source: 3, kind: .deep))
        #expect(voice.texts.last == "Eine Korrektur dazu: Der Akku hält ungefähr 6 Stunden.")
        voice.play(4)
        try await settled(stage)

        // An addition that already waits for a pause is dropped when the person speaks on.
        stage.send(card(8, "Netzteil\nDas Netzteil liefert 65 Watt.", sentence: 3))
        voice.play(5)
        try await settled(stage)
        stage.harness.heardQuiet(for: 0)
        stage.send(card(9, "Netzteil\nDas Netzteil liefert 65 Watt.\nEs wiegt etwa 200 Gramm.", sentence: 3, block: 8, source: 8, kind: .deep))
        #expect(stage.harness.waitingCount == 1 && voice.spoken.count == 6)
        stage.send([final(4)])
        #expect(stage.harness.waitingCount == 0 && stage.reasons(card: 9) == ["the conversation moved on"])
        stage.harness.heardQuiet(for: 3)
        #expect(voice.spoken.count == 6)
    }

    @Test func whatWasLeftOfAnInterruptedSpeechIsDroppedWhenThePersonSpeaksOn() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        stage.send([final(1)])
        stage.send(card(1, three))
        stage.voices[0].play(0)
        try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.pocketGerman, voice: "alba"), store: stage.systems)
        #expect(stage.harness.waitingCount == 1)
        // Before the new voice goes on, the person says something new.
        stage.send([final(2)])
        #expect(stage.harness.waitingCount == 0 && stage.records.last?.fields["reason"] as? String == "the conversation moved on")
        try await settled(stage)
        #expect(stage.voices[1].spoken.isEmpty)
    }

    @Test func aBlockThatWaitsTooLongForAPauseIsGivenUp() throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        stage.harness.heardQuiet(for: 0)
        stage.send(card(1, "Thema\nEine Antwort, die niemand mehr braucht."))
        stage.clock += SpokenHarness.patience + 1
        stage.harness.heardQuiet(for: 2)
        #expect(stage.voices[0].spoken.isEmpty)
        #expect(stage.records.last?.fields["reason"] as? String == "waited too long for a pause")
        // It was never heard, so its next version is said in full.
        stage.send(card(2, "Thema\nEine Antwort, die niemand mehr braucht.\nUnd ein neuer Satz.", block: 1, source: 1))
        stage.voices[0].playOn(from: 0)
        #expect(stage.voices[0].texts == ["Eine Antwort, die niemand mehr braucht.", "Und ein neuer Satz."])
    }

    @Test func atAPauseAfterUnfinishedWordsTheRecogniserIsAskedOnceToFinishThem() throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        stage.harness.heardQuiet(for: 3)
        #expect(stage.turnPauses == 0, "nothing was said")
        // A complete question the recogniser still holds back.
        stage.send([transcript(1, "Was ist Serverless?", final: false)])
        stage.harness.heardQuiet(for: 0.3)
        #expect(stage.turnPauses == 0, "a breath is not the end of a turn")
        stage.harness.heardQuiet(for: 0.7)
        stage.harness.heardQuiet(for: 0.9)
        #expect(stage.turnPauses == 1, "asked once for the same words")
        #expect(stage.records.last?.kind == "voice_turn_pause" && stage.records.last?.fields["sentence"] as? UInt64 == 1)
        stage.send([transcript(1, "Was ist Serverless?")])
        stage.harness.heardQuiet(for: 2)
        #expect(stage.turnPauses == 1, "the sentence is finished")
        // After a word that usually goes on, the person gets more time; without an end mark, a little more.
        stage.send([transcript(2, "Ich frage mich, ob das teuer ist und", final: false)])
        stage.harness.heardQuiet(for: 1.0)
        #expect(stage.turnPauses == 1)
        stage.send([transcript(2, "Ich frage mich, ob das teuer ist und wie lange es dauert", final: false)])
        stage.harness.heardQuiet(for: 0.7)
        #expect(stage.turnPauses == 1)
        stage.harness.heardQuiet(for: 0.85)
        #expect(stage.turnPauses == 2)
        // While Listen speaks, the microphone hears Listen: no turn ends there.
        stage.send([transcript(3, "Noch eine Frage?", final: false)])
        stage.send(card(1, "Thema\nDie Antwort ist da.", sentence: 2))
        #expect(stage.harness.speaking)
        stage.harness.heardQuiet(for: 5)
        #expect(stage.turnPauses == 2)
    }

    @Test func anAnswerTakenBackWhileItIsSaidStopsAndSpeechOffSaysNothing() throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        stage.send(card(1, "Thema\nEine Antwort, die zurückgezogen wird.\nUnd ihr zweiter Satz."))
        let before = stage.voices[0].stops
        stage.send([.cardCancelled(generationID: 1)])
        #expect(stage.voices[0].stops > before && !stage.harness.speaking && stage.states("voice_playback") == ["cancelled"])
        #expect(stage.voices[0].spoken.count == 1, "its second sentence is not said either")

        let silent = try Stage(speak: false); defer { silent.cleanUp() }
        silent.send(card(1, "Thema\nNur auf dem Bildschirm."))
        silent.harness.round(1, running: true)
        #expect(silent.voices[0].spoken.isEmpty && silent.records.last?.fields["reason"] as? String == "speech is off")
        #expect(!silent.harness.waiting && !silent.harness.blocksRecognition, "no voice, no waiting sound, no withheld hearing")
    }

    @Test func theWaitingSoundIsOnlyDueWhileARoundRunsAndNobodySpeaks() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        #expect(!stage.harness.waiting, "listening alone is silent")
        stage.harness.round(1, running: true)
        #expect(stage.harness.waiting && stage.harness.thinking)
        stage.harness.heardQuiet(for: 0)
        #expect(!stage.harness.waiting, "the person speaks")
        stage.harness.heardQuiet(for: 1)
        #expect(stage.harness.waiting)
        stage.send(card(1, "Thema\nDie Antwort ist da."))
        #expect(!stage.harness.waiting, "the voice speaks")
        stage.voices[0].play(0)
        stage.harness.round(1, running: false)
        #expect(!stage.harness.waiting && !stage.harness.thinking)
        stage.harness.round(2, running: true)
        stage.harness.setPaused(true)
        #expect(!stage.harness.waiting, "paused")
        stage.harness.setPaused(false)
        #expect(stage.harness.waiting)
        stage.harness.stop()
        #expect(!stage.harness.waiting && !stage.harness.thinking)
        stage.harness.round(3, running: true)
        #expect(!stage.harness.waiting, "a late round report after the end starts nothing")
    }

    @Test func afterTheEndNothingIsSaidStartedOrReported() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        stage.send(card(1, three))
        stage.send(card(2, "Zweites Thema\nWartet noch.", sentence: 2))
        stage.send([transcript(3, "Und noch etwas", final: false)])
        stage.harness.round(2, running: true)
        let voice = stage.voices[0], playing = voice.spoken[0].response
        stage.harness.stop()
        #expect(voice.retirements == 1 && !stage.harness.speaking && !stage.harness.blocksRecognition && !stage.harness.waiting)
        #expect(stage.harness.waitingCount == 0 && stage.harness.plannedSentences == 0)
        let count = stage.records.count
        voice.late?.began?(playing); voice.late?.finished?(playing)
        stage.send(card(3, "Drittes Thema\nKommt nach dem Ende.", sentence: 3))
        stage.harness.heardQuiet(for: 5)
        stage.harness.playSample()
        try stage.harness.chooseVoice(.init(engine: .local, model: TalkBack.pocketGerman, voice: "alba"), store: stage.systems)
        try await Task.sleep(for: .milliseconds(400))
        #expect(voice.spoken.count == 1 && stage.voices.count == 1 && stage.records.count == count && stage.turnPauses == 0)
        #expect(stage.harness.preview.playing == nil && !stage.harness.settling)
    }

    @Test func pausingStopsSpeechAndASampleIsNotHeardAsSpeech() async throws {
        let stage = try Stage(); defer { stage.cleanUp() }
        stage.send(card(1, "Erstes Thema\nEine erste Antwort dazu."))
        stage.harness.setPaused(true)
        #expect(!stage.harness.speaking && stage.states("voice_playback") == ["cancelled"])
        stage.send(card(2, "Zweites Thema\nWährend der Pause.", sentence: 2))
        stage.harness.playSample()
        #expect(stage.voices[0].spoken.count == 1 && stage.voices.count == 1 && stage.records.last?.fields["reason"] as? String == "paused")
        stage.harness.setPaused(false)
        try await settled(stage)

        stage.harness.playSample()
        let sample = try #require(stage.voices.last)
        #expect(stage.voices.count == 2 && sample.texts == [AssistantVoicePreview.text(.de)])
        #expect(stage.harness.blocksRecognition && stage.harness.preview.playing == stage.harness.voice)
        // An answer that finishes meanwhile waits for the sample; it does not talk over it.
        stage.send(card(3, "Drittes Thema\nNach der Hörprobe.", sentence: 3))
        #expect(stage.voices[0].spoken.count == 1)
        sample.finished?(sample.spoken[0].response)
        try await settled(stage)
        #expect(stage.voices[0].texts.last == "Nach der Hörprobe.")
    }
}

@Suite struct SpokenCardsConfigurationTests {
    @Test func aSavedSystemWithoutTheFieldStaysAnAssistantAndTheFieldRoundTrips() throws {
        let old = try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: Data(#"{"enabled":true,"model":"synthetic/model"}"#.utf8))
        #expect(old.answerSource == .assistant)
        var spoken = old
        spoken.answerSource = .harness
        let again = try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: JSONEncoder().encode(spoken))
        #expect(again == spoken && again.model == "synthetic/model")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VoiceAssistantConfiguration.self, from: Data(#"{"answerSource":"somewhere"}"#.utf8))
        }
    }

    @Test func spokenCardsKeepTheSystemsBlocksDecisionsAndRequirements() throws {
        let interview = try #require(ListenSystem.builtIns.first { $0.id == "interview" })
        var spoken = interview
        var settings = VoiceAssistantConfiguration(enabled: true)
        settings.answerSource = .harness
        spoken.configuration = SystemConfig(conversation: settings)
        #expect(spoken.speaksCards && !spoken.isVoiceAssistant)
        #expect(spoken.usesDecisions == interview.usesDecisions && spoken.usesDecisions, "the decision service stays the system's choice")
        #expect(spoken.requirements == interview.requirements && spoken.requires(.writer) && spoken.missingBlocks == interview.missingBlocks)
        var config = SystemConfig()
        spoken.apply(to: &config)
        #expect(config.agents.web && config.agents.forecast && config.conversation?.answerSource == .harness)

        // The other mode is what it was: one model, no writer, no decision service.
        settings.answerSource = .assistant
        spoken.configuration = SystemConfig(conversation: settings)
        #expect(spoken.isVoiceAssistant && !spoken.speaksCards && !spoken.usesDecisions && !spoken.requires(.writer))
        settings.enabled = false
        settings.answerSource = .harness
        spoken.configuration = SystemConfig(conversation: settings)
        #expect(!spoken.isVoiceAssistant && !spoken.speaksCards)
    }

    @MainActor @Test func savingASystemWithSpokenCardsKeepsItsWriterAndPackagesBothWays() throws {
        let file = URL.temporaryDirectory.appending(path: "spoken-cards-\(UUID())/systems.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = SystemStore(file: file, current: SystemConfig())
        var system = try #require(store.system("interview"))
        let blocks = system.blocks
        var settings = VoiceAssistantConfiguration(enabled: true)
        settings.answerSource = .harness
        var configuration = system.configuration ?? SystemConfig()
        configuration.conversation = settings
        system.configuration = configuration
        store.update(system)
        let saved = try #require(SystemStore(file: file, current: SystemConfig()).system("interview"))
        #expect(saved.blocks == blocks && saved.isOn(.writer) && saved.isOn(.research) && saved.speaksCards)

        let data = try SystemPackage(system: saved, defaults: SystemConfig()).data()
        #expect(try SystemPackage.read(data).system.speaksCards)
        // A package written before the field existed is an assistant, as it was.
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var definition = raw["system"] as! [String: Any]
        var packed = definition["settings"] as! [String: Any]
        var conversation = packed["conversation"] as! [String: Any]
        conversation["answerSource"] = nil
        packed["conversation"] = conversation; definition["settings"] = packed; raw["system"] = definition
        let restored = try SystemPackage.read(JSONSerialization.data(withJSONObject: raw)).system
        #expect(restored.configuration?.conversation?.answerSource == .assistant)
    }
}

@Suite struct ThinkingCueTests {
    @Test func theHeartbeatIsQuietAndLoopsWithoutAClick() {
        let samples = ThinkingCue.heartbeat()
        #expect(samples == ThinkingCue.heartbeat(), "reproducible sound")
        #expect(samples.count == Int(ThinkingCue.sampleRate * ThinkingCue.loopSeconds))
        let peak = samples.map(abs).max() ?? 1
        #expect(peak <= Float(ThinkingCue.peak) + 0.0005 && peak > 0.005, "quiet, and there")
        // No click at the seam or at the start of a pulse: it begins and ends at nothing.
        #expect(abs(samples[0]) < 0.0005 && abs(samples[samples.count - 1]) < 0.0005)
        let jump = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        #expect(jump < 0.004, "no click or discontinuity")
        func loudness(_ from: Double, _ to: Double) -> Float {
            let part = samples[Int(from * ThinkingCue.sampleRate)..<Int(to * ThinkingCue.sampleRate)]
            return (part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
        }
        #expect(loudness(1.6, 2.4) == 0)
        #expect(loudness(0, 1.5) > 0.001)
        #expect(loudness(0.05, 0.35) > loudness(0.48, 0.78), "second beat is softer")
        #expect(loudness(0.37, 0.42) == 0, "two separate beats")
        let mean = samples.reduce(0, +) / Float(samples.count)
        #expect(abs(mean) < 0.0005, "no offset")
    }

    @Test func theElevatorMusicComesWithTheAppShortAndQuiet() throws {
        let samples = try ThinkingCue.elevatorMusic()
        let seconds = Double(samples.count) / ThinkingCue.sampleRate
        #expect(seconds > 19 && seconds < 20.5, "about as long as the longest wait")
        let peak = samples.map(abs).max() ?? 1
        #expect(abs(peak - Float(ThinkingCue.musicPeak)) < 0.0001, "brought down to its quiet level")
        // Faded in and out, so playing it once from the start cannot click at either end.
        #expect((samples.prefix(24).map(abs).max() ?? 1) < 0.002)
        #expect((samples.suffix(1_200).map(abs).max() ?? 1) < 0.002)
    }

    @Test func aRetiredWaitingSoundBecomesTheHeartbeat() {
        for raw in ["idle", "soft", "breath", "", nil] {
            #expect(ThinkingSound.stored(raw) == .heartbeat)
        }
        #expect(ThinkingSound.stored("elevator") == .elevator)
        #expect(ThinkingSound.heartbeat.loops && !ThinkingSound.elevator.loops)
    }
}

extension SpokenHarnessTests {
    @Test func nativeDuplexHearsAndInterruptsWithoutChangingTheSystemsRoles() throws {
        let stage = try Stage()
        defer { stage.cleanUp() }
        let saved = stage.saved
        stage.harness.setDuplexListening(true)
        stage.send([final(3)])
        stage.send(card(7, "Serverless\nDer Anbieter betreibt die Server.", sentence: 3))
        stage.harness.heardQuiet(for: 1)
        #expect(stage.harness.speaking && !stage.harness.blocksRecognition)
        stage.voices[0].begin(0)
        stage.harness.microphoneActivity(speechSeconds: 0.2)
        #expect(!stage.harness.speaking && !stage.harness.blocksRecognition && stage.harness.hearing)
        #expect(stage.voices[0].stops > 0)
        #expect(stage.saved == saved)
        #expect(stage.records.contains { $0.kind == "voice_barge_in" })
    }
}
