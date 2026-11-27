import Foundation
import Testing

@testable import Listen

// Whole spoken turns: a committed sentence goes into the real `AnswerEngine` with a system's
// roles (decision service, fast writers, main model, researcher), scripted models answer with
// chosen delays, and what `SpokenHarness` hands to a silent voice is observed. No microphone,
// no sound, no network, no account.

private func verdict(useful: Double = 0.99, research: Double = 0.01, target: String = "new", change: ContextDecision.Change? = nil) -> String {
    var answers: [String: Any] = [
        "useful": ["type": "noul", "noul": useful], "research": ["type": "noul", "noul": research],
        "target": ["type": "choice", "choice": target, "confidence": 0.99,
                   "probabilities": target == "new" ? ["new": 1.0] : ["new": 0.01, target: 0.99]],
    ]
    if let change {
        answers["card_change"] = ["type": "choice", "choice": change.rawValue, "confidence": 0.99,
                                  "probabilities": Dictionary(uniqueKeysWithValues: ContextDecision.Change.allCases.map {
                                      ($0.rawValue, $0 == change ? 1.0 : 0.0)
                                  })]
    }
    let object: [String: Any] = ["answers": answers, "usage": ["input_tokens": 100, "output_tokens": 20]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Scripted models: each model answers its calls in order, optionally only once its gate opens.
private actor Script: ModelClient {
    struct Call: Sendable { var model: String; var system: String; var user: String; var maxTokens: Int }
    struct Reply: Sendable {
        var text: String
        var gate: Gate?
        var sources: [String] = []
    }
    private(set) var calls: [Call] = []
    private var replies: [String: [Reply]]
    init(_ replies: [String: [Reply]]) { self.replies = replies }
    func calls(to model: String) -> [Call] { calls.filter { $0.model == model } }
    func count(_ model: String) -> Int { calls(to: model).count }
    private func answer(_ call: Call) async -> Reply {
        calls.append(call)
        let reply = replies[call.model]?.isEmpty == false ? replies[call.model]!.removeFirst() : Reply(text: "NO_ANSWER")
        await reply.gate?.wait()
        return reply
    }
    nonisolated func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let reply = await self.answer(Call(model: model, system: system, user: user, maxTokens: maxTokens))
                if !Task.isCancelled {
                    continuation.yield(.text(reply.text))
                    reply.sources.forEach { continuation.yield(.source($0)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A voice that makes no sound. It gets one sentence at a time; a test says when the player
/// begins a sentence and when it has played.
@MainActor private final class SilentVoice: AssistantSpeechOutput {
    let name: String
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var spoken: [(text: String, response: ConversationResponseID)] = []
    var texts: [String] { spoken.map(\.text) }
    var stops = 0
    private var played = 0
    init(_ name: String = "first") { self.name = name }
    func speak(_ text: String, response: ConversationResponseID, language: Language) { spoken.append((text, response)) }
    func stop() { stops += 1 }
    func begin(_ index: Int) { began?(spoken[index].response) }
    func finish(_ index: Int) { played = max(played, index + 1); finished?(spoken[index].response) }
    /// Plays every sentence it has and every one that follows at once.
    func playOn() {
        while played < spoken.count {
            let index = played
            begin(index)
            finish(index)
        }
    }
}

private let decisionModel = "typesafe/\(JevClient.model)"

private func form(grace: Double = 0.05) -> SpokenAnswerForm {
    var form = SpokenAnswerForm()
    // A test does not wait a second and a half for a writer that will not answer.
    form.hedgeGraceSeconds = grace
    return form
}

@MainActor @Suite struct SpokenConversationFlow {
    /// A conversation wired as `SessionModel` wires it: the engine publishes, the harness
    /// follows the same events, rounds and corrections.
    @MainActor fileprivate final class Conversation {
        let engine: AnswerEngine
        let harness: SpokenHarness
        var voices: [SilentVoice] = [SilentVoice()]
        var records: [(kind: String, fields: [String: Any])] = []
        var cards: [UInt64: String] = [:]
        var voice: SilentVoice { voices[voices.count - 1] }

        init(models: Script, decisions: Script?, researcher: String? = "web", spoken: SpokenAnswerForm? = form(),
             drafters: [String] = ["fast", "second"], merger: String = "main", configure: (inout AnswerEngine.Settings) -> Void = { _ in }) {
            var settings = AnswerEngine.Settings()
            settings.drafters = drafters
            settings.merger = merger
            settings.researcher = researcher
            settings.pause = .milliseconds(2)
            settings.language = .de
            settings.system.agents.forecast = false
            settings.system.agents.names = false
            settings.system.landing.minimumUpdateIntervalSeconds = 0
            settings.decisionClient = decisions
            settings.spoken = spoken
            // The owner's own instruction file and notes for the topic.
            settings.instructions = "Sprich die Person mit Du an."
            settings.notes = "Ein Gespräch über Cloud-Kosten."
            configure(&settings)
            engine = AnswerEngine(client: models, settings: settings)
            // The topic's own file, as indexed when it was added.
            engine.material = MaterialIndex(passages: [.init(source: "kosten.md", text: "Serverless: Abrechnung pro Aufruf und Laufzeit, keine Grundgebühr.")])
            var configuration = VoiceAssistantConfiguration(enabled: true)
            configuration.answerSource = .harness
            configuration.talkBackEngine = .system
            var make: (VoiceAssistantConfiguration) -> any AssistantSpeechOutput = { _ in SilentVoice("unused") }
            harness = SpokenHarness(system: "interview", language: .de, configuration: configuration, speaker: voices[0],
                                    source: "Interview answers.", makeSpeaker: { make($0) }, releaseOtherVoices: { _ in },
                                    saveVoice: { _ in })
            // Weak: a round that is still ending may report after the test has let go of this.
            make = { [weak self] next in
                let voice = SilentVoice(next.talkBackVoice)
                self?.voices.append(voice)
                return voice
            }
            harness.record = { [weak self] in self?.records.append(($0, $1)) }
            engine.onRound = { [weak self] trigger, running in self?.harness.round(trigger, running: running) }
            engine.onCorrection = { [weak self] card in self?.harness.correction(card: card) }
            engine.emit = { [weak self] event in
                if case .cardDelta(let id, let text) = event { self?.cards[id, default: ""] += text }
                self?.harness.receive(event)
            }
        }

        /// A sentence the recogniser committed, as `LocalTransport` passes it on.
        func say(_ id: UInt64, _ text: String, revision: Int = 1) {
            let segment = TranscriptSegment(segmentID: id, isFinal: true, revision: revision, voice: 1, speaker: .speaker(1),
                                            text: text, startMs: 0, endMs: 0)
            harness.receive(.transcript(segment))
            engine.heard(segment, isMine: true)
        }

        func until(_ condition: () async -> Bool) async {
            for _ in 0..<800 {
                if await condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// The voice plays everything it is given, and the room settles.
        func speakOut(on voice: SilentVoice? = nil) async {
            let voice = voice ?? self.voice
            voice.playOn()
            await until { !self.harness.settling }
            voice.playOn()
            await until { !self.harness.settling && !self.harness.speaking }
        }

        func reasons(_ kind: String = "voice_speech") -> [String] { records.filter { $0.kind == kind }.compactMap { $0.fields["reason"] as? String } }
        var said: [[String: Any]] { records.filter { $0.kind == "voice_speech" && $0.fields["state"] as? String == "speaking" }.map(\.fields) }
        func end() { engine.stop(); harness.stop() }
    }

    private let question = "Was kostet Serverless eigentlich im Betrieb?"
    private let first = "Du zahlst bei Serverless nur für Aufrufe und Laufzeit."
    private let second = "Eine Grundgebühr für laufende Server gibt es nicht."
    private var fastAnswer: String { "Serverless-Kosten\n\(first)\n\(second)" }
    private let researched = """
        Serverless-Kosten
        Du zahlst bei Serverless nur für Aufrufe und Laufzeit.
        Bei AWS Lambda ist eine Million Aufrufe im Monat kostenlos.
        """
    private func filled(_ text: String) -> String { SystemConfig.filled(text, language: .de) }

    // MARK: The deeper answer

    /// The strategy the owner asked for: one fast writer answers at once, and the system's main
    /// model, a different and slower one, gets the time the first answer takes to be said.
    /// The decision service saw no need for research, so nothing else would deepen the answer.
    @Test func aFastWriterAnswersAtOnceAndTheMainModelAddsToItWhileItIsBeingSaid() async throws {
        let thinking = Gate()
        let decisions = Script([decisionModel: [.init(text: verdict(research: 0.01)), .init(text: verdict()), .init(text: verdict())]])
        let deeper = "Bei dauerhaft hoher Last ist ein eigener Server meistens günstiger."
        let models = Script(["luna": [.init(text: fastAnswer)], "sol": [.init(text: "Serverless-Kosten\n\(deeper)", gate: thinking)]])
        // A researcher is attached to the system; this moment does not need it.
        let talk = Conversation(models: models, decisions: decisions, researcher: "web", drafters: ["luna"], merger: "sol")
        defer { talk.end() }
        talk.say(1, question)

        // The first useful sentence is at the voice while the main model has not answered.
        await talk.until { talk.voice.spoken.count == 1 }
        await talk.until { await models.count("sol") == 1 }
        #expect(talk.voice.texts == [first], "the fast accepted answer starts; nothing waits for the main model")
        let asked = await models.calls.map(\.model)
        #expect(asked == ["luna", "sol"], "the configured main model is really asked, and the researcher is not")

        // The main model was asked with the system's rules, the owner's instructions, the topic's
        // context and the answer that is being said.
        let request = try #require(await models.calls(to: "sol").first)
        #expect(request.system.contains(filled(SystemConfig().prompts.cardRules)) && request.system.contains("Sprich die Person mit Du an."))
        #expect(request.system.contains(filled(SpokenAnswerForm.defaultDeepenRules)) && request.system.hasSuffix(filled(SpokenAnswerForm.defaultRules)))
        #expect(request.user.contains("[kosten.md]") && request.user.contains("Ein Gespräch über Cloud-Kosten.") && request.user.contains(question))
        #expect(request.user.contains("First answer, already being said") && request.user.contains(first) && request.user.contains(second))
        #expect(request.maxTokens == SpokenAnswerForm().deepenTokens)

        // It answers while the first sentence is being said.
        talk.voice.begin(0)
        let stops = talk.voice.stops
        await thinking.release()
        await talk.until { talk.harness.plannedSentences == 2 }
        #expect(talk.voice.spoken.count == 1 && talk.voice.stops == stops, "the running answer is not restarted or cut")
        talk.voice.finish(0)
        talk.voice.playOn()
        #expect(talk.voice.texts == [first, "Dazu noch: \(deeper)", second],
                "the reviewed deeper sentence comes at the next sentence end, once; the rest of the answer follows it")

        // What is said was reviewed: route, the fast draft, the main model's addition.
        let judged = await decisions.calls
        #expect(judged.count == 3 && judged[2].user.contains(deeper) && judged[2].user.contains("Proposed card"))
        #expect(talk.cards.values.contains { $0.contains(first) && $0.contains(deeper) }, "the block on screen holds both")
        #expect(talk.said.map { $0["part"] as? String } == ["answer", "addition"] && talk.said.map { $0["card_kind"] as? String } == ["fast", "deep"])
        #expect(talk.said[1]["joined"] as? Bool == true && talk.said.allSatisfy { $0["sentence"] as? UInt64 == 1 })
        await talk.engine.idle()
        await talk.speakOut()
        let total = await models.calls.count
        #expect(total == 2 && talk.voice.spoken.count == 3, "one fast draft, one main-model request, nothing twice")
    }

    @Test func whatTheMainModelAddsIsNotSaidWithoutReviewAndNotAfterTheTurnHasChanged() async throws {
        // The decision service rejects the addition: it is neither shown nor said.
        let rejecting = Script([decisionModel: [.init(text: verdict()), .init(text: verdict()), .init(text: verdict(useful: 0.05))]])
        let wrong = "Serverless ist immer die billigste Lösung."
        let models = Script(["luna": [.init(text: fastAnswer)], "sol": [.init(text: "Serverless-Kosten\n\(wrong)")]])
        let talk = Conversation(models: models, decisions: rejecting, researcher: nil, drafters: ["luna"], merger: "sol")
        talk.say(1, question)
        await talk.until { talk.voice.spoken.count == 1 }
        await talk.engine.idle()
        await talk.speakOut()
        let reviews = await rejecting.calls.count
        #expect(reviews == 3 && talk.voice.texts == [first, second])
        #expect(talk.cards.values.allSatisfy { !$0.contains(wrong) }, "a rejected addition is not on screen either")
        talk.end()

        // The decision service does not answer for the addition: unreviewed is unsaid.
        let silent = Script([decisionModel: [.init(text: verdict()), .init(text: verdict()), .init(text: "not a verdict")]])
        let again = Script(["luna": [.init(text: fastAnswer)], "sol": [.init(text: "Serverless-Kosten\n\(wrong)")]])
        let unreviewed = Conversation(models: again, decisions: silent, researcher: nil, drafters: ["luna"], merger: "sol")
        unreviewed.say(1, question)
        await unreviewed.until { unreviewed.voice.spoken.count == 1 }
        await unreviewed.engine.idle()
        await unreviewed.speakOut()
        #expect(unreviewed.voice.texts == [first, second] && unreviewed.cards.values.allSatisfy { !$0.contains(wrong) })
        unreviewed.end()

        // The person asks something new while the main model still thinks: its late reply is dropped.
        let thinking = Gate()
        let decisions = Script([decisionModel: Array(repeating: .init(text: verdict()), count: 6)])
        let late = "Diese Ergänzung kommt zu spät."
        let slow = Script(["luna": [.init(text: fastAnswer), .init(text: "Kaltstart\nEin Kaltstart dauert meist unter einer Sekunde.")],
                           "sol": [.init(text: "Serverless-Kosten\n\(late)", gate: thinking)]])
        let moved = Conversation(models: slow, decisions: decisions, researcher: nil, drafters: ["luna"], merger: "sol")
        defer { moved.end() }
        moved.say(1, question)
        await moved.until { await slow.count("sol") == 1 }
        await moved.speakOut()
        moved.say(2, "Und wie lange dauert ein Kaltstart ungefähr?")
        await moved.until { await slow.count("luna") == 2 }
        await thinking.release()
        await moved.engine.idle()
        await moved.speakOut()
        #expect(moved.cards.values.allSatisfy { !$0.contains(late) } && !moved.voice.texts.contains { $0.contains(late) },
                "a deeper answer to a turn the person has left is neither shown nor said")
        #expect(moved.voice.texts.contains("Ein Kaltstart dauert meist unter einer Sekunde."))
    }

    @Test func aGreetingOrAFewWordsAreNotDeepenedAndResearchIsNotDoubledByTheMainModel() async throws {
        // A greeting: one fast answer, and no request to the main model.
        let decisions = Script([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = Script(["luna": [.init(text: "Begrüssung\nHallo, schön dass du da bist.")], "sol": [.init(text: "Begrüssung\nNoch mehr Worte.")]])
        let hello = Conversation(models: models, decisions: decisions, researcher: nil, drafters: ["luna"], merger: "sol")
        hello.say(1, "Hallo, wie geht's?")
        await hello.until { hello.voice.spoken.count == 1 }
        await hello.engine.idle()
        let asked = await models.calls.map(\.model)
        #expect(asked == ["luna"] && hello.voice.texts == ["Hallo, schön dass du da bist."], "nothing is added to a trivial reply")
        hello.end()

        // The owner switched the main model's merge off for this system: it stays off.
        let off = Script([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let plain = Script(["luna": [.init(text: fastAnswer)]])
        let merged = Conversation(models: plain, decisions: off, researcher: nil, drafters: ["luna"], merger: "sol") { $0.system.agents.merge = false }
        merged.say(1, question)
        await merged.until { merged.voice.spoken.count == 1 }
        await merged.engine.idle()
        let without = await plain.calls.map(\.model)
        #expect(without == ["luna"] && !merged.engine.deepens)
        merged.end()
    }

    @Test func aSecondWritersDraftIsNotSaidAsItIsButWeighedByTheMainModel() async throws {
        let other = Gate()
        let decisions = Script([decisionModel: [.init(text: verdict()), .init(text: verdict()), .init(text: verdict())]])
        let draft = "Serverless-Kosten\nAbgerechnet wird in Schritten von einer Millisekunde."
        let deeper = "Abgerechnet wird dabei in Schritten von einer Millisekunde Laufzeit."
        let models = Script(["luna": [.init(text: fastAnswer)], "nova": [.init(text: draft, gate: other)],
                             "sol": [.init(text: "Serverless-Kosten\n\(deeper)")]])
        let talk = Conversation(models: models, decisions: decisions, researcher: nil, spoken: form(grace: 2), drafters: ["luna", "nova"], merger: "sol")
        defer { talk.end() }
        talk.say(1, question)
        await talk.until { talk.voice.spoken.count == 1 }
        #expect(talk.voice.texts == [first], "the first complete draft is said; the second writer is not waited for")
        talk.voice.begin(0)
        // The second writer finishes a little later.
        await other.release()
        await talk.until { await models.count("sol") == 1 }
        let request = try #require(await models.calls(to: "sol").first)
        #expect(request.user.contains("Other drafts for the same moment (unreviewed") && request.user.contains("Schritten von einer Millisekunde"),
                "the later draft is not dropped: the main model weighs it")
        await talk.engine.idle()
        await talk.speakOut()
        #expect(talk.voice.texts == [first, "Dazu noch: \(deeper)", second])
        #expect(!talk.voice.texts.contains("Abgerechnet wird in Schritten von einer Millisekunde."), "the unreviewed draft itself is never said")
        let reviews = await decisions.calls.count
        #expect(reviews == 3, "route, the draft that was said, the main model's addition: the second draft cost no review")
    }

    // MARK: Research

    @Test func theSystemsRolesAndContextAnswerAndResearchJoinsTheAnswerThatIsBeingSaid() async throws {
        let research = Gate(), slow = Gate()
        let decisions = Script([decisionModel: [.init(text: verdict(research: 0.99)), .init(text: verdict())]])
        let models = Script(["fast": [.init(text: fastAnswer)], "second": [.init(text: "Andere Antwort\nDiese Antwort wird nicht gebraucht.", gate: slow)],
                             "web": [.init(text: researched, gate: research, sources: ["https://example.org/lambda-preise"])]])
        let talk = Conversation(models: models, decisions: decisions)
        defer { talk.end() }
        talk.harness.began()
        talk.say(1, question)

        // The fast accepted answer reaches the voice while the web look-up has not answered.
        await talk.until { talk.voice.spoken.count == 1 }
        #expect(talk.voice.texts == [first], "prose of the card, without its title, one sentence at the voice")
        let lookingUp = await models.count("web")
        #expect(lookingUp == 1, "research is under way, and nothing waits for it")
        #expect(talk.harness.speaking && !talk.harness.waiting, "no waiting sound over the answer")

        // The same roles as on screen were asked, with the owner's prompts and the topic's context.
        let draft = try #require(await models.calls(to: "fast").first)
        #expect(draft.system.contains(filled(SystemConfig().prompts.firstCard)), "the system's own writer prompt")
        #expect(draft.system.contains("Sprich die Person mit Du an."), "the owner's instructions")
        #expect(draft.system.hasSuffix(filled(SpokenAnswerForm.defaultRules)), "the spoken form follows them")
        #expect(draft.user.contains("[kosten.md]") && draft.user.contains("Ein Gespräch über Cloud-Kosten."), "the topic's file and notes")
        #expect(draft.user.contains(question) && draft.maxTokens == SpokenAnswerForm().routedDraftTokens)
        let reviewed = await decisions.calls.last?.user ?? ""
        #expect(reviewed.contains(first), "the review saw the words that are said")

        // Research ends while the first sentence is being said.
        talk.voice.begin(0)
        let stops = talk.voice.stops
        await research.release()
        await talk.until { talk.harness.plannedSentences == 2 }
        #expect(talk.voice.spoken.count == 1 && talk.voice.stops == stops, "the running answer is not restarted or cut")
        talk.voice.finish(0)
        talk.voice.playOn()
        #expect(talk.voice.texts == [first, "Dazu noch: Bei AWS Lambda ist eine Million Aufrufe im Monat kostenlos.", second],
                "only what was not heard; the sources stay on screen")
        let web = try #require(await models.calls(to: "web").first)
        #expect(web.system.contains(filled(SystemConfig().prompts.web)) && web.system.hasSuffix(filled(SpokenAnswerForm.defaultRules)))
        #expect(web.user.contains("[kosten.md]"))
        // The citation the provider returned is on the card and was not read out.
        #expect(talk.cards.values.contains { $0.contains("https://example.org/lambda-preise") })
        #expect(talk.voice.texts.allSatisfy { !$0.contains("example.org") && !$0.contains("Quellen") })

        await slow.release()
        await talk.engine.idle()
        await talk.speakOut()
        #expect(talk.voice.spoken.count == 3, "nothing is said twice and nothing is added to fill time")
        let asked = await models.calls.map(\.model).sorted(), judged = await decisions.calls.count
        #expect(asked == ["fast", "second", "web"] && judged == 2, "the look-up is the deeper answer: the main model is not asked as well")

        // The record ties each part to its turn, card, voice and the time since the sentence.
        #expect(talk.said.map { $0["part"] as? String } == ["answer", "addition"] && talk.said.map { $0["card_kind"] as? String } == ["fast", "deep"])
        #expect(talk.said.allSatisfy { $0["sentence"] as? UInt64 == 1 && $0["tts_model"] as? String == "system" && $0["since_sentence_s"] is Double })
        #expect(talk.said[1]["joined"] as? Bool == true && talk.said[0]["block"] as? UInt64 == talk.said[1]["block"] as? UInt64)
        #expect(talk.records.first?.fields["answers"] as? String == "Interview answers.")
    }

    @Test func theSameSystemWithoutVoiceAsksOneWriterInTheFormOfCards() async throws {
        let decisions = Script([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = Script(["fast": [.init(text: "Serverless-Kosten\n**Nur Aufrufe und Laufzeit** werden berechnet.")],
                             "second": [.init(text: "Andere Antwort\nNicht gebraucht.")]])
        let talk = Conversation(models: models, decisions: decisions, researcher: nil, spoken: nil)
        defer { talk.end() }
        talk.say(1, question)
        await talk.engine.idle()
        let draft = try #require(await models.calls.first)
        let asked = await models.calls.map(\.model)
        #expect(asked == ["fast"], "one writer per routed round and no main-model request, as before")
        #expect(draft.maxTokens == 160 && !draft.system.contains("This conversation is spoken"))
        #expect(draft.system.hasSuffix("Sprich die Person mit Du an.") && !talk.engine.deepens)
    }

    @Test func aSlowOrEmptyFirstWriterDoesNotHoldTheSpokenAnswerAndEveryDraftSaidIsReviewed() async throws {
        let slow = Gate()
        // The first writer has nothing; the second one's draft is rejected by the review; no answer is said.
        let rejecting = Script([decisionModel: [.init(text: verdict()), .init(text: verdict(useful: 0.05))]])
        let empty = Script(["fast": [.init(text: "NO_ANSWER")], "second": [.init(text: "Serverless-Kosten\nDas ist ein unbrauchbarer Entwurf.")]])
        let quiet = Conversation(models: empty, decisions: rejecting, researcher: nil)
        quiet.say(1, question)
        await quiet.engine.idle()
        #expect(quiet.voice.spoken.isEmpty && quiet.cards.isEmpty, "a rejected draft is neither shown nor said")
        let reviews = await rejecting.calls.count
        #expect(reviews == 2, "the draft that could have been said was reviewed")
        quiet.end()

        // The first writer hangs; the second one's reviewed draft is said without waiting for it.
        let decisions = Script([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = Script(["fast": [.init(text: "Zu spät\nDiese Antwort kommt zu spät.", gate: slow)], "second": [.init(text: fastAnswer)]])
        let talk = Conversation(models: models, decisions: decisions, researcher: nil)
        defer { talk.end() }
        talk.say(1, question)
        await talk.until { talk.voice.spoken.count == 1 }
        #expect(talk.voice.texts == [first])
        // It is stopped after its moment of grace and holds the main model back no longer.
        await talk.until { await models.count("main") == 1 }
        await slow.release()
        await talk.engine.idle()
        await talk.speakOut()
        #expect(talk.voice.texts == [first, second] && talk.cards.count == 1, "the late draft changes nothing")
    }

    @Test func aCorrectionTheDecisionServiceClassifiesIsSaidAsACorrection() async throws {
        let decisions = Script([decisionModel: [
            .init(text: verdict()), .init(text: verdict()),
            .init(text: verdict(target: "block_1", change: .correction)), .init(text: verdict(target: "block_1", change: .correction)),
        ]])
        let models = Script(["fast": [
            .init(text: "Lambda-Laufzeit\nEine Lambda-Funktion darf höchstens fünf Minuten laufen."),
            .init(text: "Lambda-Laufzeit\nEine Lambda-Funktion darf bis zu einer Viertelstunde laufen."),
        ]])
        let talk = Conversation(models: models, decisions: decisions, researcher: nil, drafters: ["fast"])
        defer { talk.end() }
        talk.say(1, "Wie lange darf eine Lambda-Funktion laufen?")
        await talk.until { talk.voice.spoken.count == 1 }
        await talk.engine.idle()
        await talk.speakOut()
        talk.say(2, "Das stimmt so nicht, die Grenze wurde doch angehoben.")
        await talk.until { talk.voice.spoken.count == 2 }
        #expect(talk.voice.texts[1] == "Eine Korrektur dazu: Eine Lambda-Funktion darf bis zu einer Viertelstunde laufen.",
                "no changed number in the words: the typed classification marks it")
        #expect(talk.said.last?["part"] as? String == "correction" && talk.said.last?["sentence"] as? UInt64 == 2)
        // The system has quoted answers on; spoken, the person's own sentence is not handed back as the answer.
        #expect(talk.voice.texts.allSatisfy { !$0.contains("Das stimmt so nicht") } && talk.cards.values.allSatisfy { !$0.contains("Das stimmt so nicht") })
        let writes = await models.count("fast")
        #expect(writes == 2, "the writer answered both turns")
    }

    @Test func researchForATurnThePersonHasLeftIsNotSaidAndALaterHearingOfTheSameSentenceStartsNoNewWork() async throws {
        let research = Gate()
        let decisions = Script([decisionModel: [
            .init(text: verdict(research: 0.99)), .init(text: verdict()),
            // The next sentence is judged to need no answer.
            .init(text: verdict(change: .repeatInformation)),
        ]])
        let models = Script(["fast": [.init(text: fastAnswer)],
                             "web": [.init(text: researched, gate: research, sources: ["https://example.org/lambda-preise"])]])
        let talk = Conversation(models: models, decisions: decisions, drafters: ["fast"])
        defer { talk.end() }
        talk.say(1, question)
        await talk.until { talk.voice.spoken.count == 1 }
        await talk.speakOut()
        // The second hearing writes the same sentence with other punctuation: nothing is asked again.
        let before = (await models.calls.count, await decisions.calls.count)
        talk.say(1, "Was kostet Serverless eigentlich im Betrieb", revision: 2)
        try await Task.sleep(for: .milliseconds(60))
        let after = (await models.calls.count, await decisions.calls.count)
        #expect(after == before, "late words of the same sentence cause no new inference")

        // The person goes on to something else before research returns.
        talk.say(2, "Okay, das reicht mir dazu.")
        await talk.until { await decisions.calls.count == 3 }
        await research.release()
        await talk.engine.idle()
        #expect(talk.cards.values.contains { $0.contains("eine Million Aufrufe") }, "the researched card is on screen")
        #expect(talk.voice.texts == [first, second] && talk.reasons().contains("the conversation moved on"), "and is not said into the new turn")
        let lookups = await models.count("web")
        #expect(lookups == 1, "the look-up itself was not cancelled or repeated")
    }

    @Test func changingTheVoiceOrStoppingSpeechLeavesTheRolesAndTheirWorkInFlightAlone() async throws {
        let research = Gate()
        let decisions = Script([decisionModel: [.init(text: verdict(research: 0.99)), .init(text: verdict())]])
        let models = Script(["fast": [.init(text: fastAnswer)],
                             "web": [.init(text: researched, gate: research, sources: ["https://example.org/lambda-preise"])]])
        let talk = Conversation(models: models, decisions: decisions, drafters: ["fast"])
        defer { talk.end() }
        talk.say(1, question)
        await talk.until { talk.voice.spoken.count == 1 }
        let old = talk.voice
        old.begin(0)
        // A new voice in the middle of the first sentence, while research is still out.
        try talk.harness.chooseVoice(.init(engine: .local, model: TalkBack.pocketGerman, voice: "alba"))
        #expect(talk.voices.count == 2 && talk.voice.name == "alba" && !talk.harness.speaking)
        let lookingUp = await models.count("web")
        #expect(lookingUp == 1, "the look-up in flight is left alone")
        await research.release()
        await talk.engine.idle()
        await talk.speakOut()
        #expect(old.texts == [first], "the old voice said what it had begun, and no more")
        // Which of the two comes first depends on whether research returned before the new voice
        // went on: the addition comes at the next sentence end (`SpokenHarnessTests`).
        #expect(talk.voice.texts.sorted() == ["Dazu noch: Bei AWS Lambda ist eine Million Aufrufe im Monat kostenlos.", second],
                "the new voice goes on where the old one stopped, and says what research added, each once")
        let asked = await models.calls.count
        #expect(asked == 2, "nothing was asked again for the voice")
        #expect(talk.said.last?["tts_voice"] as? String == "alba" && talk.said.last?["tts_model"] as? String == TalkBack.pocketGerman)

        // Stopping what is said ends the speech, and asks nothing of the roles.
        talk.say(2, "Und was kostet das bei sehr vielen Aufrufen ungefähr?")
        await talk.until { await decisions.calls.count >= 3 }
        talk.harness.interrupt()
        let afterStop = await models.calls.count
        #expect(talk.engine.routesEarlyText && afterStop >= 2, "the engine is not stopped by it")
    }

    @Test func aNewQuestionIsNotHeldBehindWhatAnAnsweredRoundStillImproves() async throws {
        // Without a decision service every writer drafts; the slow one keeps the round open.
        func conversation(spoken: SpokenAnswerForm?, slow: Gate) -> (Conversation, Script) {
            let models = Script(["fast": [.init(text: fastAnswer), .init(text: "Kaltstart\nEin Kaltstart dauert meist unter einer Sekunde.")],
                                 "second": [.init(text: "Serverless-Kosten\nNur die Nutzung kostet.", gate: slow), .init(text: "NO_ANSWER")]])
            return (Conversation(models: models, decisions: nil, researcher: nil, spoken: spoken) { $0.system.agents.merge = false }, models)
        }
        let open = Gate()
        let (talk, models) = conversation(spoken: form(), slow: open)
        talk.say(1, question)
        await talk.until { talk.voice.spoken.count == 1 }
        await talk.speakOut()
        talk.say(2, "Und wie lange dauert ein Kaltstart?")
        // The answer to the new question is on its way although the old round has not ended.
        await talk.until { await models.count("fast") == 2 }
        let asked = await models.count("fast")
        #expect(asked == 2, "spoken: the question takes the place of the round that had answered")
        await talk.until { talk.voice.texts.contains("Ein Kaltstart dauert meist unter einer Sekunde.") }
        #expect(talk.voice.texts.last == "Ein Kaltstart dauert meist unter einer Sekunde.")
        await open.release()
        talk.end()

        // Cards keep their scheduling: the round that showed a card is finished first.
        let held = Gate()
        let (table, cardModels) = conversation(spoken: nil, slow: held)
        table.say(1, question)
        await table.until { !table.cards.isEmpty }
        table.say(2, "Und wie lange dauert ein Kaltstart?")
        try await Task.sleep(for: .milliseconds(120))
        let waiting = await cardModels.count("fast")
        #expect(waiting == 1, "cards: the new question waits for the running round")
        await held.release()
        await table.until { await cardModels.count("fast") == 2 }
        let then = await cardModels.count("fast")
        #expect(then == 2)
        table.end()
    }

    @Test func theBudgetOfTheSystemStillEndsTheAnswers() async throws {
        let decisions = Script([decisionModel: Array(repeating: .init(text: verdict()), count: 4)])
        let models = Script(["fast": [.init(text: fastAnswer)]])
        let talk = Conversation(models: models, decisions: decisions, researcher: nil, drafters: ["fast"]) { $0.limitUSD = 0 }
        defer { talk.end() }
        var exhausted = false
        let emit = talk.engine.emit
        talk.engine.emit = { event in
            if case .budget(_, _, true) = event { exhausted = true }
            emit?(event)
        }
        talk.say(1, question)
        await talk.engine.idle()
        #expect(exhausted && talk.voice.spoken.isEmpty, "a spent budget asks no model and says nothing")
        let written = await models.calls.count, decided = await decisions.calls.count
        #expect(written == 0 && decided == 0)
    }
}

/// A recogniser's transport that hears what a test says. It opens no microphone and runs no
/// speech model.
@MainActor private final class TestTransport: Transport {
    var onEvent: ((TransportEvent) -> Void)?
    let answers: AnswerEngine?
    private(set) var frames: [Data] = []
    private(set) var endedUtterances = 0
    private(set) var listening = false
    private var seq: UInt64 = 0

    init(answers: AnswerEngine?) {
        self.answers = answers
        answers?.emit = { [weak self] event in self?.emit(event) }
    }

    func connect() { Task { self.onEvent?(.connected) } }
    func disconnect() { listening = false; answers?.stop(); onEvent?(.disconnected) }
    func send(_ event: ClientEvent) {
        switch event {
        case .start, .resume:
            listening = true
            emit(.state(.listening, reason: nil))
        case .pause(let reason):
            listening = false
            emit(.state(.paused, reason: reason))
        case .stop:
            listening = false
            answers?.stop()
            emit(.state(.stopped, reason: nil))
        default: break
        }
    }
    func sendAudio(_ frame: AudioFrame) { if listening { frames.append(frame.pcm) } }
    func endUtterance() { endedUtterances += 1 }

    func emit(_ event: ServerEvent) {
        seq += 1
        onEvent?(.envelope(Envelope(v: WireProtocol.version, seq: seq, event: event)))
    }

    /// The recogniser heard this: a finished sentence also goes to the roles, as in `LocalTransport`.
    func hear(_ id: UInt64, _ text: String, final: Bool) {
        let segment = TranscriptSegment(segmentID: id, isFinal: final, revision: 1, voice: nil, speaker: .unknown, text: text, startMs: 0, endMs: 0)
        emit(.transcript(segment))
        if final { answers?.heard(segment, isMine: false) }
    }
}

@MainActor @Suite struct SpokenSessionWiring {
    private func pcm(seconds: Double, level: Int16) -> Data {
        let samples = [Int16](repeating: level, count: Int(seconds * WireProtocol.sampleRate))
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @MainActor private final class Built {
        var transports: [TestTransport] = []
        var voices: [SilentVoice] = []
        var forms: [SpokenAnswerForm?] = []
        var systems: [String] = []
    }

    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<800 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `SessionModel.start` itself, with the parts a test can stand in for: Talk with Listen
    /// starts the topic's own system and roles, their answer reaches the voice, the microphone's
    /// frames are withheld while Listen speaks, and a pause reaches the recogniser.
    @Test func talkStartsTheTopicsOwnSystemAndItsPauseReachesTheRecogniser() async throws {
        try #require(AudioCapture.physicalInputDisabled, "the test action must disable the physical microphone")
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-session-wiring-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig())
        let expert = try #require(store.system("expert-talk"))
        var topic = Topic(name: "Synthetic cloud costs"); topic.system = expert.id
        topic.language = .de

        let decisions = Script([decisionModel: Array(repeating: .init(text: verdict()), count: 4)])
        let models = Script(["luna": [.init(text: "Serverless-Kosten\nDu zahlst nur für Aufrufe und Laufzeit.")]])
        let built = Built()
        let parts = SessionModel.Parts(
            system: { [built] topic in
                let chosen = store.chosen(for: topic)
                built.systems.append(chosen.id)
                return (SystemConfig.Loaded(config: SystemConfig(), problem: nil, edited: false), chosen)
            },
            answers: { [built] _, loaded, _, form in
                built.forms.append(form)
                var settings = AnswerEngine.Settings()
                // The configuration `start` applied the system to, and the form it chose.
                settings.system = loaded.config
                settings.system.agents.forecast = false
                settings.system.agents.names = false
                settings.spoken = form
                settings.drafters = ["luna"]
                settings.merger = "luna"
                settings.researcher = nil
                settings.pause = .milliseconds(2)
                settings.language = .de
                settings.decisionClient = decisions
                return AnswerEngine(client: models, settings: settings)
            },
            transport: { [built] _, answers in
                let transport = TestTransport(answers: answers)
                built.transports.append(transport)
                return transport
            },
            speaker: { [built] _ in
                let voice = SilentVoice("voice \(built.voices.count)")
                built.voices.append(voice)
                return voice
            })

        let model = SessionModel(parts: parts)
        model.start(topic, spoken: true)
        await until { model.core.phase == .listening }
        #expect(model.core.phase == .listening && model.startFailure == nil && !model.microphoneDenied)
        let spoken = try #require(model.spoken)
        #expect(model.assistant == nil, "the topic's own roles answer, not the one-model assistant")
        #expect(built.systems == ["expert-talk"] && built.forms.count == 1 && built.forms[0] != nil, "the selected system, asked for spoken answers")
        #expect(spoken.source.hasPrefix("Expert talk answers:") && !spoken.source.contains("main model"), "only what is attached is named")
        #expect(store.system("expert-talk") == expert, "the system was not changed to be talked with")
        let transport = try #require(built.transports.first), voice = try #require(built.voices.first)

        // A question goes through the system's decision service and writer, and is said.
        transport.hear(1, "Was kostet Serverless eigentlich im Betrieb?", final: true)
        await until { voice.spoken.count == 1 }
        #expect(voice.texts == ["Du zahlst nur für Aufrufe und Laufzeit."])
        let draft = try #require(await models.calls.first)
        #expect(draft.system.hasSuffix(SystemConfig.filled(SpokenAnswerForm.defaultRules, language: .de)))
        let judged = await decisions.calls.count
        #expect(judged == 2, "expert talk has decisions on: route and review ran")
        #expect(model.core.cards.contains { $0.text.contains("Aufrufe und Laufzeit") }, "the card is on the table as always")

        // While Listen speaks, what the microphone captures does not reach the recogniser.
        voice.begin(0)
        model.captured(pcm(seconds: 0.1, level: 9_000))
        let withheld = try #require(transport.frames.last)
        #expect(withheld.count == pcm(seconds: 0.1, level: 0).count && withheld.allSatisfy { $0 == 0 })
        voice.finish(0)
        await until { !spoken.blocksRecognition }

        // Afterwards it does; and at a pause after unfinished words the recogniser is asked to finish.
        model.captured(pcm(seconds: 0.1, level: 9_000))
        #expect(transport.frames.last?.contains { $0 != 0 } == true)
        transport.hear(2, "Und bei sehr vielen Aufrufen?", final: false)
        #expect(transport.endedUtterances == 0)
        model.captured(pcm(seconds: 0.3, level: 0))
        #expect(transport.endedUtterances == 0, "a breath is not the end of the turn")
        model.captured(pcm(seconds: 0.5, level: 0))
        #expect(transport.endedUtterances == 1, "the pause reached the recogniser")
        model.captured(pcm(seconds: 0.5, level: 0))
        #expect(transport.endedUtterances == 1)

        model.send(.stop)
        await until { model.core.phase != .listening }
        #expect(!spoken.speaking && !spoken.blocksRecognition)

        // The same topic from the normal Start is a conversation of cards: no voice, no spoken form.
        let cards = SessionModel(parts: parts)
        cards.start(topic)
        await until { cards.core.phase == .listening }
        #expect(cards.spoken == nil && cards.assistant == nil && built.forms.count == 2 && built.forms[1] == nil && built.voices.count == 1)
        cards.send(.stop)
    }
}

@MainActor @Suite struct VoicePresentationTests {
    private func stores() throws -> (TopicStore, SystemStore, UserDefaults, URL, String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Listen-voice-presentation-" + UUID().uuidString)
        let name = "Listen-voice-presentation-tests-" + UUID().uuidString
        return (TopicStore(file: root.appending(path: "topics.json")),
                SystemStore(file: root.appending(path: "systems.json"), current: SystemConfig()),
                try #require(UserDefaults(suiteName: name)), root, name)
    }

    @Test func talkingWithAnOrdinaryTopicSpeaksItsOwnSystemAndChangesNothingInIt() throws {
        let (topics, systems, prefs, root, domain) = try stores()
        defer { try? FileManager.default.removeItem(at: root); prefs.removePersistentDomain(forName: domain) }
        var topic = Topic(name: "Synthetic expert topic"); topic.system = "expert-talk"
        topics.upsert(topic)
        let file = root.appending(path: "systems.json")
        let before = try Data(contentsOf: file)
        let system = try #require(systems.system("expert-talk"))
        #expect(system.configuration?.conversation == nil && !system.hasSpokenConversation)

        // Talk with Listen accepts the topic as it is.
        #expect(try AssistantLaunch.topic(topic.id, store: topics, systems: systems, preferences: prefs).id == topic.id)
        // Started the usual way it is a conversation of cards; by Talk, the same system is spoken.
        #expect(VoicePresentation.plan(for: system, requested: false, preferences: prefs) == nil)
        let plan = try #require(VoicePresentation.plan(for: system, requested: true, preferences: prefs))
        #expect(plan.configuration.enabled && plan.configuration.answerSource == .harness && plan.configuration.speakReplies && !plan.savedInSystem)
        #expect(plan.configuration.toolIDs.isEmpty && plan.configuration.model.isEmpty, "no tools and no other model come with it")
        #expect((try? plan.configuration.validate()) != nil)
        // Its roles are the system's: blocks, decisions and requirements are read from the system, which is untouched.
        #expect(system.usesDecisions && system.isOn(.research) && system.requires(.writer))

        // A voice chosen while talking is remembered beside the system, not in it.
        let alba = AssistantVoiceChoice(engine: .local, model: TalkBack.pocketGerman, voice: "alba")
        let harness = SpokenHarness(system: system.id, language: .de, configuration: plan.configuration, speaker: SilentVoice(),
                                    makeSpeaker: { _ in SilentVoice() }, releaseOtherVoices: { _ in },
                                    saveVoice: { try VoicePresentation.remember($0, system: system.id, preferences: prefs) })
        try harness.chooseVoice(alba, store: systems)
        harness.stop()
        #expect(try Data(contentsOf: file) == before, "the systems file is byte for byte what it was")
        #expect(SystemStore(file: file, current: SystemConfig()).system("expert-talk") == system)
        let again = try #require(VoicePresentation.plan(for: system, requested: true, preferences: prefs))
        #expect(AssistantVoiceChoice(again.configuration) == alba, "the next conversation starts with the chosen voice")
        // Another system has its own memory; a damaged entry falls back to the default voice.
        let interview = try #require(systems.system("interview"))
        #expect(AssistantVoiceChoice(try #require(VoicePresentation.plan(for: interview, requested: true, preferences: prefs)).configuration) != alba)
        prefs.set(Data(#"{"engine":"local","model":"not/a-model","voice":"nobody"}"#.utf8), forKey: VoicePresentation.key(system.id))
        let fallback = try #require(VoicePresentation.plan(for: system, requested: true, preferences: prefs))
        #expect(AssistantVoiceChoice(fallback.configuration) == AssistantVoiceChoice(VoiceAssistantConfiguration()))
        #expect(throws: (any Error).self) {
            try VoicePresentation.remember(.init(engine: .local, model: TalkBack.pocketGerman, voice: "nobody"), system: system.id, preferences: prefs)
        }
    }

    @Test func systemsWithTheirOwnVoiceSettingsKeepThemAndTheToolAssistantStaysWhatItIs() throws {
        let (_, systems, prefs, root, domain) = try stores()
        defer { try? FileManager.default.removeItem(at: root); prefs.removePersistentDomain(forName: domain) }
        // One model with tools: it speaks for itself, requested or not.
        let assistant = try #require(systems.system("voice-assistant"))
        #expect(VoicePresentation.plan(for: assistant, requested: true, preferences: prefs) == nil && assistant.isVoiceAssistant)

        // A system set to speak its roles is spoken either way, with its saved settings.
        var spoken = try #require(systems.system("interview"))
        var settings = VoiceAssistantConfiguration(enabled: true)
        settings.answerSource = .harness
        settings.talkBackEngine = .local
        settings.talkBackModel = TalkBack.pocketGerman
        settings.talkBackVoice = "fantine"
        settings.recordAudio = false
        spoken.configuration?.conversation = settings
        prefs.set(Data(#"{"engine":"system","model":"","voice":""}"#.utf8), forKey: VoicePresentation.key(spoken.id))
        for requested in [false, true] {
            let plan = try #require(VoicePresentation.plan(for: spoken, requested: requested, preferences: prefs))
            #expect(plan.configuration == settings && plan.savedInSystem, "its own settings, not the remembered presentation voice")
        }

        // Voice settings the owner switched off keep their voice and their recording choice, and stay off in the system.
        settings.enabled = false
        spoken.configuration?.conversation = settings
        systems.update(spoken)
        #expect(VoicePresentation.plan(for: spoken, requested: false, preferences: prefs) == nil)
        let plan = try #require(VoicePresentation.plan(for: spoken, requested: true, preferences: prefs))
        #expect(plan.savedInSystem && plan.configuration.talkBackVoice == "fantine" && !plan.configuration.recordAudio && plan.configuration.enabled)
        try AssistantVoiceChoice(engine: .local, model: TalkBack.pocketGerman, voice: "cosette").save(system: spoken.id, in: systems)
        let saved = try #require(systems.system(spoken.id))
        #expect(saved.configuration?.conversation?.talkBackVoice == "cosette" && saved.configuration?.conversation?.enabled == false && !saved.speaksCards)
    }

    @Test func whatAnswersIsNamedInTheSystemsOwnWordsAndOnlyAsWhatItMayDo() throws {
        let (_, systems, prefs, root, domain) = try stores()
        defer { try? FileManager.default.removeItem(at: root); prefs.removePersistentDomain(forName: domain) }
        let expert = try #require(systems.system("expert-talk"))
        let full = VoicePresentation.summary(of: expert, decisions: true, deepens: true, research: true, material: true)
        #expect(full == "Expert talk answers: its decisions choose what to answer, a fast model answers first and its main model can add to that, "
            + "web research is used when a question needs it, with this topic's notes and files.")
        // Only what is attached is named, and research is not said to be running.
        let plain = VoicePresentation.summary(of: expert, decisions: false, deepens: false, research: false, material: false)
        #expect(plain == "Expert talk answers: its models write the answer.")
        #expect(!full.contains("web research adds") && !full.contains("is researching"))
        for word in ["harness", "Jev", "LLM", "pipeline", "TTS", "prompt"] { #expect(!full.localizedCaseInsensitiveContains(word)) }
    }
}
