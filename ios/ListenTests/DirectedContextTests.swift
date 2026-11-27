import Foundation
import Testing
@testable import Listen

private func verdict(_ useful: Double = 0.99, research: Double = 0.01, target: String = "new") -> String {
    """
    {"answers":{"useful":{"type":"noul","noul":\(useful)},"research":{"type":"noul","noul":\(research)},
    "target":{"type":"choice","choice":"\(target)","confidence":0.99,"probabilities":\(target == "new" ? "{\"new\":1.0}" : "{\"new\":0.01,\"\(target)\":0.99}")}},"usage":{"input_tokens":100,"output_tokens":20}}
    """
}

private func changeVerdict(_ change: ContextDecision.Change, target: String = "new") -> String {
    var object = try! JSONSerialization.jsonObject(with: Data(verdict(target: target).utf8)) as! [String: Any]
    var answers = object["answers"] as! [String: Any]
    answers["card_change"] = ["type": "choice", "choice": change.rawValue, "confidence": 0.99,
                              "probabilities": Dictionary(uniqueKeysWithValues: ContextDecision.Change.allCases.map {
                                  ($0.rawValue, $0 == change ? 1.0 : 0.0)
                              })]
    object["answers"] = answers
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func preparedVerdict(_ id: String = "iam", probability: Double = 0.99, hints: [String]? = nil) -> String {
    var object = try! JSONSerialization.jsonObject(with: Data(verdict().utf8)) as! [String: Any]
    var answers = object["answers"] as! [String: Any]
    var probabilities = Dictionary(uniqueKeysWithValues: (hints ?? [id]).map { ("hint_" + $0, 0.0) })
    probabilities["none"] = 1 - probability
    probabilities["hint_" + id] = probability
    answers["prepared_hint"] = ["type": "choice", "choice": probability >= 0.5 ? "hint_" + id : "none",
                                "confidence": 0.99, "probabilities": probabilities]
    object["answers"] = answers
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func preparedIAM() -> MaterialIndex.PreparedHint {
    .init(id: "iam", title: "Service permissions", bullets: ["Separate deployer and runtime identities.", "Grant only the required resource permissions."],
          sources: ["https://example.com/service-identity"], keywords: "IAM service permissions identity", language: "de")
}

private actor ContextLatch {
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

private actor ContextScript: ModelClient {
    struct Call: Sendable { var model: String; var system: String; var user: String }
    struct Reply: Sendable {
        var text: String
        var latch: ContextLatch?
        var sources: [String] = []
    }
    var calls: [Call] = []
    var replies: [String: [Reply]]
    init(_ replies: [String: [Reply]]) { self.replies = replies }
    private func answer(_ call: Call) async -> Reply {
        calls.append(call)
        let reply = replies[call.model]?.isEmpty == false ? replies[call.model]!.removeFirst() : Reply(text: "NO_ANSWER")
        await reply.latch?.wait()
        return reply
    }
    nonisolated func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let reply = await self.answer(Call(model: model, system: system, user: user))
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

@MainActor private final class HarnessVoiceDouble: AssistantSpeechOutput {
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var spoken: [(text: String, response: ConversationResponseID)] = []
    func speak(_ text: String, response: ConversationResponseID, language: Language) { spoken.append((text, response)) }
    func stop() {}
}

@Suite struct DirectedContextValues {
    @Test(arguments: ["Was ist Serverless?", "Was bedeutet Serverless", "Warum Serverless?", "What is serverless?", "Why serverless?"])
    func shortQuestionsHaveEnoughContextWithoutFourWords(_ text: String) {
        #expect(DirectedContext.isQuestion(text))
        let context = DirectedContext(revision: 1, trigger: 2, evidence: [
            .init(id: 1, text: "Was unterscheidet IaaS, PaaS und SaaS?", who: "unknown"),
            .init(id: 2, text: text, who: "unknown"),
        ], blocks: [], answeredQuestions: [1])
        #expect(context.activeQuestion?.id == 2)
        #expect(context.questionFocus.contains("Not yet addressed"))
    }

    @Test(arguments: ["Was?", "Und?", "Oder?", "Right?", "Okay?"])
    func clarificationWordsDoNotDisplaceASubstantiveQuestion(_ text: String) {
        #expect(!DirectedContext.isQuestion(text))
    }

    @Test func aRoutedConceptStatementReleasesAnOlderQuestionButKeepsANewQuestion() {
        let context = DirectedContext(revision: 1, trigger: 2, evidence: [
            .init(id: 1, text: "Why does the database become slower?", who: "unknown"),
            .init(id: 2, text: "IaaS, PaaS, SaaS.", who: "unknown"),
        ], blocks: [])
        let route = ContextDecision(usefulness: 0.99, research: 0.01, target: nil, targetConfidence: 0.99,
                                    targetProbability: 1, change: .newSubject)
        #expect(context.activeQuestion?.id == 1)
        #expect(context.routed(route).activeQuestion == nil)
        #expect(context.routed(route).questionFocus.contains("no question or expressed uncertainty is required"))
        var asked = context
        asked.evidence[1].text = "How do these cloud service models differ?"
        #expect(asked.routed(route).activeQuestion?.id == 2)
    }

    @Test func mixedCaseConceptNamesMatchLowercasedRecognitionWithoutShortWordNoise() {
        let passages = [MaterialIndex.Passage(source: "models.md", text: "IaaS: infrastructure. PaaS: platform. SaaS: application."),
                        .init(source: "sql.md", text: "SQL controls relational data queries."),
                        .init(source: "other.md", text: "Unrelated material about gardening.")]
        #expect(MaterialIndex.relevant(passages, to: "IaaS PaaS SaaS").first?.source == "models.md")
        #expect(MaterialIndex.relevant(passages, to: "iaas paas saas").first?.source == "models.md")
        #expect(MaterialIndex.relevant(passages, to: "sql").first?.source == "sql.md")
        #expect(MaterialIndex.relevant(passages, to: "who are you").isEmpty)
    }

    @Test func questionFocusSurvivesMissingPunctuationAndConversationalTags() {
        let context = DirectedContext(revision: 1, trigger: 3, evidence: [
            .init(id: 1, text: "Warum machen zusätzliche Verbindungen die Datenbank langsamer", who: "unknown"),
            .init(id: 2, text: "Ich würde mehr Instanzen bereitstellen.", who: "unknown"),
            .init(id: 3, text: "Also solche Sachen denke ich, oder?", who: "unknown"),
        ], blocks: [])
        #expect(context.activeQuestion?.id == 1)
        #expect(context.questionFocus.contains("zusätzliche Verbindungen"))
        #expect(DirectedContext.isQuestion("How does transaction isolation prevent interference"))
        #expect(!DirectedContext.isQuestion("Und"))
    }

    @Test func semanticChangeRejectsRepetitionEvenWithAHighUsefulnessScore() throws {
        let repeated = try JevClient.read(Data(changeVerdict(.repeatInformation).utf8), allowed: [])
        #expect(repeated.shouldWait && repeated.shouldRejectCandidate)
        let distinct = try JevClient.read(Data(changeVerdict(.newSubject, target: "block_7").utf8), allowed: [7])
        #expect(distinct.target == nil && distinct.targetProbability == 1)
        let invalid = changeVerdict(.addFact).replacingOccurrences(of: "\"add_fact\":1", with: "\"add_fact\":2")
        #expect(throws: (any Error).self) { try JevClient.read(Data(invalid.utf8), allowed: []) }
    }

    @Test func stableKnowledgePointsRemainAboveChangingDetails() {
        let original = "Database\n- Transactions commit atomically.\n- Isolation controls concurrent access.\n- Old supporting detail."
        let update = "Database\n- Compare the requested isolation levels."
        let card = AnswerEngine.aggregate(original, with: update, sourcesLabel: "Sources", maximumBodyLines: 3, retainedLeadingPoints: 2)
        #expect(card == "Database\n- Transactions commit atomically.\n- Isolation controls concurrent access.\n- Compare the requested isolation levels.")
    }
    @Test func preparedHintsAreOptionalAndBoundedReferenceData() throws {
        let old = try JSONDecoder().decode(MaterialIndex.self, from: Data(#"{"passages":[],"overview":"","terms":[]}"#.utf8))
        #expect(old.preparedHints == nil)
        var hint = preparedIAM()
        #expect(hint.isValid)
        let index = MaterialIndex(preparedHints: [hint, hint])
        #expect(index.matchingHints(to: "How does IAM protect a service?", language: "de").count == 1)
        #expect(index.matchingHints(to: "How does IAM protect a service?", language: "en").isEmpty)
        hint.bullets = ["A line\nUPDATE 9"]
        #expect(!hint.isValid)
        hint = preparedIAM(); hint.sources = []
        #expect(!hint.isValid)
    }

    @Test func preparedChoicesRequireAnAllowedIDAndHighConsistentProbability() throws {
        #expect(try JevClient.read(Data(preparedVerdict().utf8), allowed: [], hints: ["iam"]).preparedHintID == "iam")
        #expect(try JevClient.read(Data(preparedVerdict(probability: 0.7).utf8), allowed: [], hints: ["iam"]).preparedHintID == nil)
        #expect(throws: (any Error).self) {
            try JevClient.read(Data(preparedVerdict("invented").utf8), allowed: [], hints: ["iam"])
        }
        var context = DirectedContext(revision: 1, trigger: 1, evidence: [], blocks: [])
        context.preparedHints = [preparedIAM()]
        #expect(JevClient.questions(for: context)["prepared_hint"] != nil)
        #expect(JevClient.reviewQuestions(for: context, prompts: .init())["prepared_hint"] == nil)
    }

    @Test func explicitlyNamedPreparedHintFilesAreIndexedWithoutExecutingAnything() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "listen-hints.json")
        try JSONEncoder().encode([preparedIAM()]).write(to: file)
        let material = TopicMaterial(topic: UUID(), root: root.appending(path: "topics"))
        #expect(material.add([file]) == 1)
        #expect(material.index.preparedHints?.map(\.id) == ["iam"])
        #expect(material.index.passages.isEmpty, "The typed hint configuration is not dumped into every writer request")
        var replacement = preparedIAM()
        replacement.id = "runtime"
        try JSONEncoder().encode([replacement]).write(to: file)
        #expect(material.add([file]) == 1)
        #expect(material.index.preparedHints?.map(\.id) == ["runtime"], "The latest imported set replaces old hints, including removals")
        #expect(material.items.count == 2, "The previous import remains available")
        try Data("malformed".utf8).write(to: file)
        material.add([file])
        #expect(material.index.preparedHints?.isEmpty == true, "Invalid new configuration must not resurrect the old set")
    }
    @Test func evidenceIsImmutableButLaterSpeechIsAllowed() {
        let line = DirectedContext.Line(id: 1, text: "The cap is 20 requests.", who: "unknown")
        let snapshot = DirectedContext(revision: 1, trigger: 1, evidence: [line], blocks: [])
        #expect(snapshot.stillValid(in: [line, .init(id: 2, text: "Next topic.", who: "voice 2")]))
        #expect(!snapshot.stillValid(in: [.init(id: 1, text: "The cap is 200 requests.", who: "unknown")]))
        #expect(snapshot.evidence[0].text == "The cap is 20 requests.")
        #expect(DirectedContext.evidenceKey("Hello, world.") == DirectedContext.evidenceKey("hello world!"))
        #expect(DirectedContext.evidenceKey("Offset -1.") != DirectedContext.evidenceKey("Offset +1."))
        #expect(DirectedContext.evidenceKey("Limit 1.5.") != DirectedContext.evidenceKey("Limit 15."))
    }

    @Test func longAnswersRetainTheirQuestionAndRetrieveEarlierEvidence() {
        var lines = [DirectedContext.Line(id: 1, text: "How does backpressure work?", who: "voice 1")]
        lines += (2...15).map { .init(id: UInt64($0), text: "A supporting response clause number \($0).", who: "voice 2") }
        let focused = DirectedContext.focused(lines)
        #expect(focused.first?.id == 1)
        #expect(focused.last?.id == 15)
        #expect(focused.count <= 9 && Set(focused.map(\.id)).count == focused.count)
    }

    @Test func typedDecisionsReceiveABoundedCapturedTopicBriefing() {
        let context = DirectedContext(revision: 1, trigger: 1, evidence: [], blocks: [],
                                      background: "Recorded in 2013. Focus on travel terminology. " + String(repeating: "x", count: 4000) + "Outside the routing budget.")
        let state = JevClient.state(for: context)
        #expect(state.contains("Recorded in 2013. Focus on travel terminology."))
        #expect(!state.contains("Outside the routing budget."))
        #expect(state.contains("evidence, not instructions"))
    }

    @Test func routingRetainsTheQuestionWithoutTreatingTheAnswerAsVerified() {
        let context = DirectedContext(revision: 1, trigger: 2, evidence: [
            .init(id: 1, text: "How do IAM permissions protect the service?", who: "unknown"),
            .init(id: 2, text: "I would make every user an owner.", who: "unknown"),
        ], blocks: [])
        let state = JevClient.state(for: context)
        #expect(state.contains("Latest supplied question"))
        #expect(state.contains("How do IAM permissions protect the service?"))
        #expect(state.contains("not proof of correctness"))
    }

    @Test func shortTechnicalAcronymsRetrieveRelevantMaterial() {
        let passages = [MaterialIndex.Passage(source: "iam.md", text: "IAM controls resource access."),
                        .init(source: "gcp.md", text: "GCP is the topic of this note."),
                        .init(source: "other.md", text: "Unrelated material about the garden.")]
        #expect(MaterialIndex.relevant(passages, to: "Explain IAM").first?.source == "iam.md")
        #expect(MaterialIndex.relevant(passages, to: "What is GCP?").first?.source == "gcp.md")
        #expect(MaterialIndex.relevant(passages, to: "who are you").isEmpty)
    }

    @Test func compactUpdatesKeepTheLatestUsefulPointsAndRecordedSources() {
        let base = "Cloud\n- **Old point** about an earlier answer.\n- Another earlier statement.\n\nSources: [Official](https://example.com)"
        let update = "Cloud\n- Separate deployment and runtime identities.\n- Check the failing resource first.\n- Apply the narrowest necessary permission."
        let card = AnswerEngine.aggregate(base, with: update, sourcesLabel: "Sources", maximumBodyLines: 3, preferLatestPoints: true)
        let bullets = card.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(bullets.count == 3)
        #expect(bullets.first?.contains("deployment and runtime") == true)
        #expect(!card.contains("Old point"))
        #expect(card.contains("[Official](https://example.com)"))
    }

    @Test func typedDecisionsRejectUnknownDestinationsAndInvalidProbabilities() throws {
        let good = try JevClient.read(Data(verdict(target: "block_7").utf8), allowed: [7])
        #expect(good.target == 7 && !good.shouldWait && !good.shouldResearch)
        for text in [verdict(target: "block_8"), verdict(-0.1), verdict(1.1), verdict().replacingOccurrences(of: "\"noul\":0.99", with: "\"noul\":true"), "{}"] {
            #expect(throws: (any Error).self) { try JevClient.read(Data(text.utf8), allowed: [7]) }
        }
        let snapshot = DirectedContext(revision: 1, trigger: 1, evidence: [], blocks: [
            .init(id: 7, text: "A", checked: true), .init(id: 8, text: "B", checked: false),
        ])
        #expect(snapshot.routed(good).blocks.map(\.id) == [7])
    }

    @Test func obsoletePlaceholdersDisappearButRealAbsenceClaimsStay() throws {
        let text = try #require(AnswerEngine.card(from: "Aktivität\nDauer nicht genannt.\n**2000 Tage** wurden geschätzt."))
        #expect(!text.contains("nicht genannt") && text.contains("2000 Tage"))
        #expect(AnswerEngine.card(from: "Erlebnisse\n**Noch unbeantwortet**: lustigstes Erlebnis.") == nil)
        #expect(AnswerEngine.card(from: "Teilnahme\nSeit wann bist du dabei?") == nil)
        #expect(AnswerEngine.card(from: "WikiCup\nSteht auf seinem Hemd; Erklärung folgt noch.") == nil)
        #expect(AnswerEngine.card(from: "Absatz\nKeine Verkaufszahlen veröffentlicht.") != nil)
        #expect(!AnswerEngine.aggregate("**Dauer**\nDauer nicht genannt.", with: "**Dauer**\n**2000 Tage**.", sourcesLabel: "Quellen").contains("nicht genannt"))
    }

    @Test func checkedStatementsCannotBeOverwrittenByGuesswork() {
        let checked = "**Limit**\n**10 MiB** per request.\nChecked against the official documentation.\n\nSources: [Official](https://example.com)"
        #expect(!AnswerEngine.preservesChecked(checked, in: "**Limit**\n**1 MiB** per request."))
        #expect(AnswerEngine.preservesChecked(checked, in: checked + "\nNew local observation."))
        #expect(!AnswerEngine.preservesChecked(checked, in: checked + "\n**1 MiB** per request."))
        #expect(!AnswerEngine.preservesChecked("**Offset**\nThe offset is -1.", in: "**Offset**\nThe offset is +1."))
        #expect(AnswerEngine.aggregate("**Limit**\n**1 MiB** per request.", with: "**Limit**\n**10 MiB** per request.", sourcesLabel: "Sources") == "**Limit**\n**10 MiB** per request.")
    }

    @Test func onlySuppliedEvidenceWithAConfidentCoverageJudgmentIsMarkedRepresented() throws {
        var payload = try JSONSerialization.jsonObject(with: Data(verdict().utf8)) as! [String: Any]
        var answers = payload["answers"] as! [String: Any]
        answers["covers_2"] = ["type": "noul", "noul": 0.92]
        answers["covers_3"] = ["type": "noul", "noul": 0.55]
        answers["covers_999"] = ["type": "noul", "noul": 1.0]
        payload["answers"] = answers
        let decision = try JevClient.read(JSONSerialization.data(withJSONObject: payload), allowed: [], evidence: [2, 3])
        #expect(decision.coveredEvidence == [2])
    }

    @Test func revisionsKeepWorkUnlessASubstantiveWordANumberOrANegationChanges() {
        typealias C = DirectedContext
        #expect(C.revision(from: "seit 2005", to: "Seit 2005.") == .same)
        #expect(C.revision(from: "ich wollte den Artikel reaktivieren, der gelöscht wurde",
                           to: "Ich wollte den Artikel reaktivieren. Der gelöscht wurde") == .minor)
        #expect(C.revision(from: "Also den würde ich gerne wieder aktivieren.", to: "würde ich gerne wieder aktivieren.") == .minor)
        // "Jahr" was already said later in the sentence: nothing substantive is new.
        #expect(C.revision(from: "im 2012 als Wettbewerb, der über ein ganzes Jahr geht, kreiert.",
                           to: "im Jahr 2012 als Wettbewerb, der über ein ganzes Jahr geht, kreiert") == .minor)
        #expect(C.revision(from: "im 2012 als Wettbewerb kreiert.", to: "im Jahr 2012 als Wettbewerb kreiert") == .extended)
        #expect(C.revision(from: "ich mache österreichsspezifische Themen", to: "ich mache österreichspezifische Themen") == .minor)
        #expect(C.revision(from: "Kaiserich 77er Wikipedia und ich mache Geografie.",
                           to: "beziehungsweise Geiserichsiebenundsiebzig auf Wikipedia und ich mache Geografie.") == .substantive)
        #expect(C.revision(from: "Nein, ich bin Lehrer in Karlsruhe.", to: "Nein, ich bin Lehrer in Karlsburg.") == .substantive)
        #expect(C.revision(from: "seit dreieinhalb Jahren in Karlsruhe", to: "seit 3,5 Jahren in Karlsruhe") == .substantive)
        #expect(C.revision(from: "seit 3,5 Jahren", to: "seit 3.5 Jahren") != .substantive)
        #expect(C.revision(from: "The offset is -1.", to: "The offset is +1.") == .substantive)
        #expect(C.revision(from: "I am active in mentoring.", to: "I am not active in mentoring.") == .substantive)
        let context = DirectedContext(revision: 1, trigger: 1, evidence: [.init(id: 1, text: "im 2012 als Wettbewerb kreiert.", who: "someone")], blocks: [])
        #expect(context.stillValid(in: [.init(id: 1, text: "im Jahr 2012 als Wettbewerb kreiert", who: "voice 2")]))
        #expect(!context.stillValid(in: [.init(id: 1, text: "im 2013 als Wettbewerb kreiert", who: "voice 2")]))
    }

    @Test func aShortAnswerWithoutANumberIsQuotedOnlyAsAFinishedReplyToTheQuestionJustAsked() {
        var context = DirectedContext(revision: 1, trigger: 2, evidence: [
            .init(id: 1, text: "Are you active in the mentoring programme?", who: "someone"),
            .init(id: 2, text: "No, I am a teacher.", who: "someone"),
        ], blocks: [])
        context.decision = .init(usefulness: 0.9, research: 0.01, target: nil, targetConfidence: 1, targetProbability: 1)
        let quote = AnswerEngine.evidenceAnswer(in: context)
        #expect(quote?.hasPrefix("Are you active in the mentoring programme?") == true && quote?.contains("“No, I am a teacher.”") == true)
        context.evidence[1].text = "No, because"
        #expect(AnswerEngine.evidenceAnswer(in: context) == nil, "an unfinished thought")
        context.evidence[1].text = "No, I have been a teacher for a long time and there is simply too much else to do."
        #expect(AnswerEngine.evidenceAnswer(in: context) == nil, "long answers go to the writer")
        context.evidence[1].text = "No, I am a teacher."
        context.evidence[0].text = "Have you noticed how people in Karlsruhe who never had anything to do with Wikipedia react to the conference being here?"
        let short = AnswerEngine.evidenceAnswer(in: context)
        #expect(short?.hasPrefix("Have you noticed how people in Karlsruhe who never had …?") == true, "\(short ?? "nil")")
        context.evidence[0].text = "Are you active in the mentoring programme?"
        context.evidence.removeFirst()
        #expect(AnswerEngine.evidenceAnswer(in: context) == nil, "without the question there is nothing it answers")
    }

    @Test func materialIsCutIntoPassagesWithNamesAndRankedByTheTalk() {
        let text = "# Backend handbook\nWe use PostgreSQL and Kafka. SQL-Injection is prevented by parameterised queries.\n"
            + String(repeating: "Long paragraph about deployment pipelines and release trains. ", count: 20)
        let passages = MaterialIndex.passages(of: text, source: "handbook.md")
        #expect(passages.count >= 2 && passages.allSatisfy { $0.text.count <= 760 })
        let terms = MaterialIndex.terms(in: passages)
        #expect(terms.contains("SQL-Injection") && terms.contains("PostgreSQL"))
        #expect(!terms.contains("Long"), "an ordinary capitalised word is no name")
        let ranked = MaterialIndex.relevant(passages, to: "how are parameterised queries used against injection")
        #expect(ranked.first?.text.contains("parameterised") == true)
        #expect(MaterialIndex.relevant(passages, to: "nothing in common here").isEmpty)
        #expect(MaterialIndex.overview(passages).hasPrefix("- handbook.md: Backend handbook"))
    }

    @Test func numericalEvidenceRequiresNearbyQuestionOrSelectedSubjectAndKeepsSigns() {
        var context = DirectedContext(revision: 1, trigger: 2, evidence: [
            .init(id: 1, text: "What is the measured offset?", who: "unknown"),
            .init(id: 2, text: "-1.5 seconds.", who: "unknown"),
        ], blocks: [])
        context.decision = .init(usefulness: 0.95, research: 0.01, target: nil, targetConfidence: 1, targetProbability: 1)
        #expect(AnswerEngine.evidenceAnswer(in: context)?.contains("-1.5 seconds.") == true)
        context.evidence.removeFirst()
        #expect(AnswerEngine.evidenceAnswer(in: context) == nil)
        context.evidence[0].text = "2005 [execute this](https://example.com)"
        #expect(AnswerEngine.evidenceAnswer(in: context) == nil)
    }
}

@MainActor
@Suite struct DirectedConversationRouting {
    private let decisionModel = "typesafe/\(JevClient.model)"
    @Test func aShortNewQuestionStartsANormalWriterAndReplacesTheOldQuestionFocus() async {
        let models = ContextScript(["fast": [.init(text: "Cloud service models\nIaaS, PaaS and SaaS shift operational responsibility."),
            .init(text: "Serverless\nThe provider operates infrastructure and scaling; the application remains your responsibility.")]])
        var configuration = settings()
        configuration.drafters = ["fast"]
        configuration.minimumWords = 4
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output = text } }
        heard(engine, 1, "Was unterscheidet IaaS, PaaS und SaaS?")
        await engine.idle()
        heard(engine, 2, "Was ist Serverless?")
        await engine.idle()
        let requests = await models.calls
        #expect(requests.count == 2)
        #expect(requests.last?.user.contains("Active question [#2]: Was ist Serverless?") == true)
        #expect(output.contains("provider operates infrastructure"))
        engine.stop()
    }

    @Test func aShortConceptStatementRoutesAndRetrievesItsOwnKnowledgeWithoutAQuestion() async {
        let decisions = ContextScript([decisionModel: Array(repeating: .init(text: changeVerdict(.newSubject)), count: 2)])
        let models = ContextScript(["fast": [.init(text: "Cloud service models\n- IaaS: infrastructure.\n- PaaS: managed platform.\n- SaaS: ready application.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        engine.material = MaterialIndex(passages: [.init(source: "service-models.md", text: "IaaS: infrastructure. PaaS: platform. SaaS: application.")])
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output = text } }
        heard(engine, 1, "IaaS, PaaS, SaaS.")
        await engine.idle()
        #expect(output.contains("IaaS") && output.contains("PaaS") && output.contains("SaaS"))
        #expect(await models.calls.first?.user.contains("service-models.md") == true)
        #expect(await decisions.calls.count == 2, "route and review, despite fewer than four words")
        engine.stop()
    }

    @Test func aShortStatementRejectedAsRepetitionStartsNoWriter() async {
        let decisions = ContextScript([decisionModel: [.init(text: changeVerdict(.repeatInformation))]])
        let models = ContextScript([:])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        heard(engine, 1, "Ja.")
        await engine.idle()
        #expect(await decisions.calls.count == 1)
        #expect(await models.calls.isEmpty)
        engine.stop()
    }

    @Test func aNewStatementRetrievesItsConceptInsteadOfTheOlderQuestion() async {
        let decisions = ContextScript([decisionModel: [.init(text: changeVerdict(.repeatInformation)),
            .init(text: changeVerdict(.newSubject)), .init(text: changeVerdict(.newSubject))]])
        let models = ContextScript(["fast": [.init(text: "Cloud service models\nIaaS, PaaS and SaaS differ in managed responsibility.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        engine.material = MaterialIndex(passages: [
            .init(source: "old-locks.md", text: "Database locks coordinate concurrent updates."),
            .init(source: "service-models.md", text: "IaaS: infrastructure. PaaS: platform. SaaS: application."),
        ])
        heard(engine, 1, "Why do database locks block concurrent updates?")
        await engine.idle()
        heard(engine, 2, "IaaS, PaaS, SaaS.")
        await engine.idle()
        let request = await models.calls.first?.user ?? ""
        #expect(request.contains("[service-models.md]"))
        #expect(!request.contains("[old-locks.md]"))
        #expect(request.contains("No active substantive question"))
        engine.stop()
    }

    private func settings(decisions: ContextScript? = nil) -> AnswerEngine.Settings {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["fast", "slow"]
        settings.pause = .milliseconds(2)
        settings.system.agents.merge = false
        // The forecast writes with the same scripted models; only its own test turns it on.
        settings.system.agents.forecast = false
        settings.decisionClient = decisions
        return settings
    }

    @Test func subjectAdditionsAreBatchedUsingTheLatestEvidenceInsteadOfQueuedResponses() async {
        let decisions = ContextScript([decisionModel: Array(repeating: .init(text: changeVerdict(.addFact, target: "block_1")), count: 6)])
        let models = ContextScript(["fast": [.init(text: "Database\nA new useful fact about isolation.")]])
        var configuration = settings(decisions: decisions)
        configuration.system.landing.minimumUpdateIntervalSeconds = 0.15
        let engine = AnswerEngine(client: models, settings: configuration)
        engine.restore([["Database\nAn established fact about transactions."]])
        var batched = false
        engine.onLog = { _, fields in if fields["state"] as? String == "coalesced subject additions" { batched = true } }
        heard(engine, 1, "A supporting observation about transaction isolation.")
        await until { batched }
        #expect(await models.calls.isEmpty)
        heard(engine, 2, "And")
        // A filler arriving during the batching window cannot cancel its timer.
        try? await Task.sleep(for: .milliseconds(5))
        heard(engine, 3, "Another relevant detail about isolation levels.")
        await engine.idle()
        let calls = await models.calls
        #expect(calls.count == 1)
        #expect(calls.first?.user.contains("Another relevant detail") == true)
        engine.stop()
    }

    @Test func aNewQuestionBypassesSubjectUpdatePacingAndKeepsItsWholeCardReadable() async {
        let decisions = ContextScript([decisionModel: Array(repeating: .init(text: changeVerdict(.answerQuestion, target: "block_1")), count: 2)])
        let models = ContextScript(["fast": [.init(text: "Database locks\nAn exclusive lock can make a conflicting transaction wait.")]])
        var configuration = settings(decisions: decisions)
        configuration.system.landing.minimumUpdateIntervalSeconds = 60
        configuration.system.landing.focusOnLatestAddition = false
        let engine = AnswerEngine(client: models, settings: configuration)
        engine.restore([["Database locks\nLocks coordinate concurrent changes."]])
        var start: CardStart?
        var batched = false
        engine.emit = { if case .cardStarted(let value) = $0 { start = value } }
        engine.onLog = { _, fields in if fields["state"] as? String == "coalesced subject additions" { batched = true } }
        heard(engine, 1, "Why does an exclusive lock make a transaction wait?")
        await engine.idle()
        #expect(!batched && start != nil && start?.focusText == nil)
        #expect(await models.calls.first?.user.contains("Active question [#1]") == true)
        engine.stop()
    }

    @Test func aConfidentNewConceptGetsItsOwnBlockEvenWithinTheSameScenario() async {
        let decisions = ContextScript([decisionModel: Array(repeating: .init(text: changeVerdict(.newSubject, target: "block_1")), count: 2)])
        let models = ContextScript(["fast": [.init(text: "Database indexes\nAn index accelerates matching lookups, with storage and write overhead.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        engine.restore([["Deployment\nBuild once, then release the tested artifact."]])
        var start: CardStart?
        engine.emit = { if case .cardStarted(let value) = $0 { start = value } }
        heard(engine, 1, "How does a database index speed up this service?")
        await engine.idle()
        #expect(start?.sourceCard == nil && start?.blockID == 2)
        engine.stop()
    }

    @Test func aMaterialCorrectionCanReplacePinnedButUnverifiedKnowledge() async {
        let decisions = ContextScript([decisionModel: Array(repeating: .init(text: changeVerdict(.correction, target: "block_1")), count: 2)])
        let models = ContextScript(["fast": [.init(text: "Process memory\nEach process has its own address space.")]])
        var configuration = settings(decisions: decisions)
        configuration.system.landing.retainedLeadingPoints = 2
        configuration.system.landing.minimumUpdateIntervalSeconds = 60
        let engine = AnswerEngine(client: models, settings: configuration)
        engine.restore([["Process memory\nAll processes share the same mutable application variables."]])
        var latest = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { latest = text } }
        heard(engine, 1, "That earlier explanation of process memory was mistaken.")
        await engine.idle()
        #expect(latest.contains("own address space"))
        #expect(!latest.contains("share the same mutable"))
        engine.stop()
    }
    /// Voice in, the roles, voice out: the words that reach the voice are the card a real
    /// round of the engine published, not the reply of some other model.
    @Test func aSpokenConversationSaysTheCardThatTheEnginesOwnRolesPublished() async throws {
        let models = ContextScript(["fast": [.init(text: "Serverless\n**Der Anbieter betreibt Server und Skalierung**\nAbrechnung nach Aufrufen\n```swift\nlet x = 1\n```")]])
        var configuration = settings()
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        let voice = HarnessVoiceDouble()
        var spokenSettings = VoiceAssistantConfiguration(enabled: true)
        spokenSettings.answerSource = .harness
        spokenSettings.talkBackEngine = .system
        let harness = SpokenHarness(system: "interview", language: .de, configuration: spokenSettings, speaker: voice,
                                    makeSpeaker: { _ in HarnessVoiceDouble() }, releaseOtherVoices: { _ in })
        var records: [(String, [String: Any])] = [], rounds: [Bool] = [], thought = false
        harness.record = { records.append(($0, $1)) }
        engine.onRound = { trigger, running in
            rounds.append(running)
            harness.round(trigger, running: running)
            if running { thought = thought || harness.waiting }
        }
        engine.emit = { harness.receive($0) }
        let question = TranscriptSegment(segmentID: 1, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1),
                                         text: "Was ist Serverless?", startMs: 0, endMs: 0)
        harness.receive(.transcript(question))
        engine.heard(question, isMine: false)
        await engine.idle()
        defer { engine.stop(); harness.stop() }

        #expect(await models.calls.count == 1, "the engine's own drafter was asked, and nothing else")
        #expect(rounds.first == true && rounds.last == false && thought, "a round was reported, and it counted as waiting")
        #expect(!harness.thinking)
        // One sentence at a time goes to the voice: the card's lines, without its title.
        let said = try #require(voice.spoken.last)
        #expect(voice.spoken.count == 1 && said.text == "Der Anbieter betreibt Server und Skalierung.")
        let speaking = try #require(records.last { $0.0 == "voice_speech" && $0.1["state"] as? String == "speaking" }?.1)
        #expect(speaking["sentence"] as? UInt64 == 1 && speaking["tts_model"] as? String == "system")
        let speech = try #require(speaking["response"] as? String)
        #expect(said.response.rawValue.hasPrefix(speech), "the sentence belongs to the speech the record names")
        voice.began?(said.response)
        let scheduled = try #require(records.last { $0.0 == "voice_playback" }?.1)
        #expect(scheduled["state"] as? String == "scheduled" && scheduled["card"] as? UInt64 == speaking["card"] as? UInt64)
        #expect(scheduled["response"] as? String == speech && harness.blocksRecognition && harness.audible)
        voice.finished?(said.response)
        #expect(voice.spoken.map(\.text) == ["Der Anbieter betreibt Server und Skalierung.", "Abrechnung nach Aufrufen."])
        #expect(voice.spoken.allSatisfy { !$0.text.contains("let x") }, "code stays on screen")
    }

    private func heard(_ engine: AnswerEngine, _ id: UInt64, _ text: String, revision: Int = 1, voice: UInt32 = 1) {
        engine.heard(.init(segmentID: id, isFinal: true, revision: revision, voice: voice, speaker: .speaker(Int(voice)), text: text, startMs: 0, endMs: 0), isMine: false)
    }
    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aSelectedReviewedReferenceHintNeedsNoWriterAndRetainsItsSource() async {
        let decisions = ContextScript([decisionModel: [.init(text: preparedVerdict()), .init(text: verdict())]])
        let models = ContextScript([:])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        engine.material = MaterialIndex(preparedHints: [preparedIAM()])
        var output = "", phases: [String] = []
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        engine.onLog = { _, fields in phases.append(fields["phase"] as? String ?? "") }
        heard(engine, 1, "How does IAM protect the service identity?")
        await engine.idle()
        #expect(await models.calls.isEmpty)
        #expect(await decisions.calls.count == 1, "Selection and relevance review share one typed decision for unchanged reference text")
        #expect(output.contains("Separate deployer and runtime identities"))
        #expect(output.contains("https://example.com/service-identity"))
        #expect(phases.contains("prepared"))
    }

    @Test func theConfiguredDecisionAllowanceDisablesEarlyRoutingAndIsReported() async {
        let decisions = ContextScript([decisionModel: [.init(text: preparedVerdict())]])
        let models = ContextScript(["fast": [.init(text: "IAM\nThe writer handles the fallback.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.system.scheduler.decisionCallsPerSession = 1
        let engine = AnswerEngine(client: models, settings: configuration)
        engine.material = MaterialIndex(preparedHints: [preparedIAM()])
        var states: [String] = [], output = ""
        engine.onLog = { _, fields in states.append(fields["state"] as? String ?? "") }
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "How does IAM protect the service identity?")
        await engine.idle()
        #expect(await decisions.calls.count == 1)
        #expect(!engine.routesEarlyText)
        heard(engine, 2, "Explain another unrelated subject now.")
        await engine.idle()
        #expect(states.filter { $0 == "decision call limit reached: normal path" }.count == 1)
        #expect(output.contains("Separate deployer"), "The permitted call already included prepared-card selection and relevance review")
    }

    @Test func aRejectedReferenceHintUsesTheWriterOnceInsteadOfLooping() async {
        let decisions = ContextScript([decisionModel: [.init(text: preparedVerdict(probability: 0.01)), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "IAM\nA writer answers the uncovered question.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        engine.material = MaterialIndex(preparedHints: [preparedIAM()])
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "How does IAM protect the service identity?")
        await engine.idle()
        #expect(await models.calls.count == 1)
        #expect(output.contains("writer answers") && !output.contains("Separate deployer"))
    }

    @Test func aPreparedHintIsNotPublishedAfterItsEvidenceChangesDuringSelection() async {
        let hold = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: preparedVerdict(), latch: hold), .init(text: verdict(0.01))]])
        let engine = AnswerEngine(client: ContextScript([:]), settings: settings(decisions: decisions))
        engine.material = MaterialIndex(preparedHints: [preparedIAM()])
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "How does IAM protect the service identity?")
        await until { await decisions.calls.count >= 1 }
        heard(engine, 1, "The IAM question was wrong; explain an unrelated subject instead.", revision: 2)
        await hold.release()
        await engine.idle()
        #expect(!output.contains("Separate deployer"))
    }

    @Test func aStrictProfileDoesNotPublishAMediocreGeneratedCandidate() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict(0.5))]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.system.scheduler.candidateMinimumUsefulness = 0.65
        let engine = AnswerEngine(client: ContextScript(["fast": [.init(text: "Interview\nA generic reminder to explain your answer.")]]), settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "How does the cloud platform support developers?")
        await engine.idle()
        #expect(output.isEmpty)
    }

    @Test func aClearWaitAvoidsBothExpensiveDrafters() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02))]])
        let models = ContextScript([:])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        heard(engine, 1, "Hello everyone welcome to this meeting.")
        await engine.idle()
        #expect(await models.calls.isEmpty)
        #expect(await decisions.calls.count == 1)
    }

    @Test func aValidRouteUsesOneFastDrafterAndDoesNotResearchAPersonalAnswer() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "Career\nShe has worked here since 2018.")]])
        var configuration = settings(decisions: decisions)
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        heard(engine, 1, "She has worked here since 2018.")
        await engine.idle()
        #expect(await models.calls.map(\.model) == ["fast"])
    }

    @Test func anEmptyFastDraftGetsOneFallbackWithoutRepeatingTheDecision() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "NO_ANSWER")], "slow": [.init(text: "Backpressure\nA producer waits for available capacity.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        heard(engine, 1, "How does backpressure regulate a producer?")
        await engine.idle()
        #expect(await models.calls.map(\.model) == ["fast", "slow"])
        #expect(await decisions.calls.count == 2, "one initial decision and one review; no repeated initial decision")
    }

    @Test func aForecastCardIsShownAtOnceWhenTheConversationReachesIt() async {
        // Two waits, then the third line matches the one forecast card.
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)),
                                                       .init(text: preparedVerdict("f0"))]])
        let models = ContextScript(["fast": [.init(text: """
            {"anchor": "Sprechererkennung", "title": "Pyannote Sprecherzahl", "bullets": ["num_speakers legt die Zahl fest."], "keywords": "pyannote sprecher anzahl"}
            """)]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.system.agents.forecast = true
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "Wir haben ein Modell für die Sprechererkennung genommen.")
        await engine.idle()
        heard(engine, 2, "Es macht ab und zu drei oder vier Sprecher.")
        await engine.idle()
        heard(engine, 3, "Kann man bei Pyannote die Zahl der Sprecher festlegen?")
        await engine.idle()
        #expect(output.contains("num_speakers"))
        #expect(await models.calls.count == 1, "only the forecast was written; no writer for the moment itself")
        engine.stop()
    }

    @Test func aForecastCardIsShownWhileTheSentenceIsStillSpoken() async {
        let rank = #"{"answers":{"rank":{"type":"choice","choice":"hint_f0","confidence":0.9,"probabilities":{"hint_f0":0.93,"none":0.07}}}}"#
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)), .init(text: rank)]])
        let models = ContextScript(["fast": [.init(text: """
            {"anchor": "Sprechererkennung", "title": "Pyannote Sprecherzahl", "bullets": ["num_speakers legt die Zahl fest."], "keywords": "pyannote sprecher anzahl"}
            """)]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.system.agents.forecast = true
        configuration.system.agents.forecastWhileSpeaking = true
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        var shownWhileSpeaking = false
        engine.onLog = { _, fields in if fields["state"] as? String == "forecast card shown while speaking" { shownWhileSpeaking = true } }
        heard(engine, 1, "Wir haben ein Modell für die Sprechererkennung genommen.")
        await engine.idle()
        heard(engine, 2, "Es macht ab und zu drei oder vier Sprecher.")
        await engine.idle()
        // Sentence 3 is not finished yet; only Apple's growing text exists.
        engine.partial(id: 3, text: "Kann man bei Pyannote eigentlich die Zahl")
        await engine.idle()
        #expect(shownWhileSpeaking)
        #expect(output.contains("num_speakers"))
        // Too few new words: no second ranking for the same sentence.
        engine.partial(id: 3, text: "Kann man bei Pyannote eigentlich die Zahl der")
        await engine.idle()
        #expect(await decisions.calls.count == 3)
        engine.stop()
    }

    private var groundedForecast: String {
        #"{"anchor":"Pyannote","title":"Speaker count","bullets":["Set num_speakers for a known count."],"keywords":"speaker count"}"#
    }

    private func forecastSettings(_ decisions: ContextScript) -> AnswerEngine.Settings {
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.system.agents.forecast = true
        configuration.system.agents.forecastWhileSpeaking = true
        return configuration
    }

    private func warmForecast(_ engine: AnswerEngine) async {
        heard(engine, 1, "We use Pyannote for speaker recognition.")
        await engine.idle()
        heard(engine, 2, "One person sometimes has several speaker labels.")
        await engine.idle()
    }

    private func rankVerdict(_ probability: Double = 0.93) -> String {
        #"{"answers":{"rank":{"type":"choice","choice":"hint_f0","confidence":0.99,"probabilities":{"hint_f0":\#(probability),"none":\#(1 - probability)}}}}"#
    }

    private func waitForCalls(_ service: ContextScript, _ count: Int) async {
        for _ in 0..<200 {
            if await service.calls.count >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The scripted model did not receive the expected call")
    }

    @Test func aForecastBelowTheNewProbabilityBarIsNotPublished() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)), .init(text: rankVerdict(0.89))]])
        let models = ContextScript(["fast": [.init(text: groundedForecast)]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        var cards = 0
        engine.emit = { if case .cardStarted = $0 { cards += 1 } }
        await warmForecast(engine)
        engine.partial(id: 3, text: "Can Pyannote use a fixed speaker count")
        await engine.idle()
        #expect(await decisions.calls.count == 3)
        #expect(cards == 0)
        engine.stop()
    }

    @Test func rankCallsDoNotUseTheNormalRoutingAllowance() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)), .init(text: rankVerdict())]])
        let models = ContextScript(["fast": [.init(text: groundedForecast)]])
        var configuration = forecastSettings(decisions)
        configuration.system.scheduler.decisionCallsPerSession = 2
        let engine = AnswerEngine(client: models, settings: configuration)
        var cards = 0
        engine.emit = { if case .cardStarted = $0 { cards += 1 } }
        await warmForecast(engine)
        engine.partial(id: 3, text: "Can Pyannote use a fixed speaker count")
        await engine.idle()
        #expect(await decisions.calls.count == 3)
        #expect(cards == 1, "The separate ranking allowance is available after the normal allowance is spent")
        engine.stop()
    }

    @Test func aCompletedSentenceCancelsAStalledRankingWithoutWaitingForIt() async {
        let hold = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)),
            .init(text: rankVerdict(), latch: hold), .init(text: verdict(0.02))]])
        let models = ContextScript(["fast": [.init(text: groundedForecast)]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        var cards = 0
        engine.emit = { if case .cardStarted = $0 { cards += 1 } }
        await warmForecast(engine)
        engine.partial(id: 3, text: "Can Pyannote use a fixed speaker count")
        await waitForCalls(decisions, 3)
        heard(engine, 3, "We decided not to fix the speaker count.")
        await engine.idle()
        #expect(await decisions.calls.count == 4, "The ordinary decision finishes while the old rank is still held")
        await hold.release()
        await Task.yield()
        #expect(cards == 0)
        engine.stop()
    }

    @Test func aRevisedPartialCannotPublishAnOlderRanking() async {
        let hold = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)),
            .init(text: rankVerdict(), latch: hold)]])
        let models = ContextScript(["fast": [.init(text: groundedForecast)]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        var cards = 0
        engine.emit = { if case .cardStarted = $0 { cards += 1 } }
        await warmForecast(engine)
        engine.partial(id: 3, text: "Can Pyannote use a fixed speaker count")
        await waitForCalls(decisions, 3)
        engine.partial(id: 3, text: "Actually we are now discussing recording consent")
        await hold.release()
        await engine.idle()
        #expect(cards == 0)
        engine.stop()
    }

    @Test func aForecastChosenByTheNormalRouteAlsoStartsTheSharedPublicationInterval() async {
        let second = #"{"anchor":"Pyannote","title":"Speaker window","bullets":["Longer windows contain more speaker evidence."],"keywords":"window"}"#
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)),
            .init(text: preparedVerdict("f0", hints: ["f0", "f1"]))]])
        let models = ContextScript(["fast": [.init(text: groundedForecast + "\n" + second)]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        var cards = 0
        engine.emit = { if case .cardStarted = $0 { cards += 1 } }
        await warmForecast(engine)
        heard(engine, 3, "Can Pyannote use a fixed speaker count?")
        await engine.idle()
        #expect(cards == 1)
        engine.partial(id: 4, text: "What about the Pyannote speaker window size")
        await engine.idle()
        #expect(await decisions.calls.count == 3, "No speculative request during the shared 20-second interval")
        #expect(cards == 1)
        engine.stop()
    }

    @Test func aForecastIntervalDoesNotHoldBackAnOrdinaryAnswer() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)),
            .init(text: rankVerdict()), .init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: groundedForecast),
            .init(text: "Recording consent\nAsk every participant before recording.")]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        await warmForecast(engine)
        engine.partial(id: 3, text: "Can Pyannote use a fixed speaker count")
        await engine.idle()
        heard(engine, 3, "How should we agree on recording consent?")
        await engine.idle()
        #expect(output.contains("Ask every participant"))
        #expect(await models.calls.count == 2, "The ordinary writer runs immediately during the forecast interval")
        let requests = await decisions.calls
        #expect(!requests[3].system.contains("prepared_hint"))
        engine.stop()
    }

    @Test func aCompletedSentenceDoesNotUseAnInsufficientlySureForecast() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)),
            .init(text: preparedVerdict("f0", probability: 0.88)), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: groundedForecast),
            .init(text: "Speaker count\nUse a fixed count only when all participants are known.")]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        var usedPrepared = false
        engine.onLog = { _, fields in if fields["phase"] as? String == "prepared" { usedPrepared = true } }
        await warmForecast(engine)
        heard(engine, 3, "Can Pyannote use a fixed speaker count?")
        await engine.idle()
        #expect(!usedPrepared)
        #expect(await models.calls.count == 2, "The ordinary writer handles a forecast below 0.9 without waiting")
        engine.stop()
    }

    @Test func stoppingCancelsAStalledForecasterAndReturnsToIdle() async {
        let hold = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02))]])
        let models = ContextScript(["fast": [.init(text: groundedForecast, latch: hold)]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        heard(engine, 1, "We use Pyannote for speaker recognition.")
        await engine.idle()
        heard(engine, 2, "One person has several speaker labels.")
        await waitForCalls(models, 1)
        engine.stop()
        await engine.idle()
        await hold.release()
    }

    @Test func anInFlightForecasterNeitherBlocksTheNextRoundNorLosesItsProgress() async {
        let hold = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02)), .init(text: verdict(0.02)),
            .init(text: verdict(0.02))]])
        let models = ContextScript(["fast": [.init(text: groundedForecast, latch: hold)]])
        let engine = AnswerEngine(client: models, settings: forecastSettings(decisions))
        var prepared = 0
        engine.onLog = { kind, fields in
            if kind == "forecast", let cards = fields["cards"] as? [String] { prepared += cards.count }
        }
        heard(engine, 1, "We use Pyannote for speaker recognition.")
        await engine.idle()
        heard(engine, 2, "One person has several speaker labels.")
        await waitForCalls(models, 1)
        heard(engine, 3, "The recording has two participants speaking.")
        await waitForCalls(decisions, 3)
        #expect(await decisions.calls.count == 3, "The normal round runs while the forecaster is still held")
        await hold.release()
        await engine.idle()
        #expect(prepared == 1, "A stream must survive ordinary sentence arrivals to avoid starving the pool")
        engine.stop()
    }

    @Test func aRoutedMomentWhoseDraftIsRejectedIsResearchedInstead() async {
        // Routed as useful without a research need; the quick draft only restates the question.
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.9, research: 0.1)), .init(text: verdict(0.2)),
                                                       .init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript([
            "fast": [.init(text: "Home device apps\nThe open question is whether it supports third-party apps.")],
            "web": [.init(text: "Home device apps\nNo app store; third parties reach it through AirPlay and Siri.")],
        ])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        configuration.system.agents.researchRejectedDrafts = true
        let engine = AnswerEngine(client: models, settings: configuration)
        heard(engine, 1, "Can the home device run third-party apps without a hack?")
        await engine.idle()
        await until { await models.calls.contains { $0.model == "web" } }
        #expect(await models.calls.map(\.model) == ["fast", "web"])
        engine.stop()
    }

    @Test func aRejectedDraftOfAMomentRoutingFoundWeakIsNotResearched() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.2, research: 0.1))]])
        let models = ContextScript(["fast": [.init(text: "Small talk\nNothing to add.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        heard(engine, 1, "Okay, that sounds good to me then.")
        await engine.idle()
        #expect(await models.calls.isEmpty, "routing waited: neither a draft nor research")
        engine.stop()
    }

    @Test func invalidDecisionRetainsTheExistingAnswerPath() async {
        let decisions = ContextScript([decisionModel: [.init(text: "malformed")]])
        let models = ContextScript(["fast": [.init(text: "Backpressure\nA producer waits for capacity.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        heard(engine, 1, "Explain the producer backpressure mechanism please.")
        await engine.idle()
        #expect(Set(await models.calls.map(\.model)) == ["fast", "slow"])
    }

    @Test func researchKeepsTheOriginalEvidenceWhenAnotherSubjectArrives() async {
        let latch = ContextLatch()
        let models = ContextScript([
            "fast": [.init(text: "Alpha\nFirst subject fact.", latch: latch), .init(text: "Beta\nSecond subject fact.")],
            "web": [.init(text: "Alpha\nFirst subject fact, checked."), .init(text: "Beta\nSecond subject fact, checked.")],
        ])
        var configuration = settings()
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        heard(engine, 1, "The Alpha algorithm is our first subject.")
        await until { await models.calls.count == 1 }
        heard(engine, 2, "The Beta protocol is a completely different subject.")
        try? await Task.sleep(for: .milliseconds(15))
        await latch.release()
        await engine.idle()
        let web = await models.calls.filter { $0.model == "web" }
        #expect(web.count == 2)
        #expect(web.first?.user.contains("Alpha algorithm") == true)
        #expect(web.first?.user.contains("Beta protocol") == false, "deferred research must not read mutable latest context")
    }

    @Test func aCheckedCardDoesNotRegressToAnUnsupportedDraft() async {
        let models = ContextScript([
            "fast": [.init(text: "Alpha\nVerified statement."), .init(text: "UPDATE 1\nAlpha\nDifferent unsupported guess.")],
            "web": [.init(text: "Alpha\nVerified statement.\nChecked documentation.", sources: ["https://example.com/alpha"]), .init(text: "NO_ANSWER")],
        ])
        var configuration = settings()
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        var text = ""
        engine.emit = { if case .cardDelta(_, let piece) = $0 { text += piece } }
        heard(engine, 1, "Please explain the Alpha algorithm now.")
        await engine.idle()
        heard(engine, 2, "There is another claim about Alpha now.")
        await engine.idle()
        #expect(text.contains("Verified statement") && !text.contains("unsupported guess"))
    }

    @Test func aShortNumericAnswerIsNotLostAndVoiceOnlyChangesDoNotRedraft() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.01)), .init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "Joined\nSince 2005.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        var text = ""
        var evidence: UInt64?
        engine.emit = {
            if case .cardDelta(_, let piece) = $0 { text += piece }
            if case .cardStarted(let start) = $0 { evidence = start.evidenceSegment }
        }
        heard(engine, 1, "When did you join the project?")
        await engine.idle()
        heard(engine, 2, "2005.")
        await engine.idle()
        heard(engine, 2, "2005.", revision: 2, voice: 2)
        await engine.idle()
        #expect(await models.calls.isEmpty, "a reviewed literal answer needs no writing request")
        #expect(text.contains("2005.") && evidence == 2)
        #expect(await decisions.calls.count == 3, "two initial decisions and the one proposed-card review")
    }

    @Test func aRevisedNumberStartsANewRoundWithoutRequiringNewSegmentIDs() async {
        let models = ContextScript(["fast": [.init(text: "Limit\nThe limit is 20 requests."), .init(text: "UPDATE 1\nLimit\nThe limit is 200 requests.")]])
        var configuration = settings()
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        heard(engine, 1, "The limit is 20 requests.")
        await engine.idle()
        heard(engine, 1, "The limit is 200 requests.", revision: 2)
        await engine.idle()
        let calls = await models.calls
        #expect(calls.count == 2)
        #expect(calls.last?.user.contains("Revised earlier evidence") == true)
        #expect(calls.last?.user.contains("200 requests") == true)
    }

    @Test func reviewCanRecoverTheExistingSubjectFromAnIncorrectInitialNewRoute() async {
        let decisions = ContextScript([decisionModel: [
            .init(text: verdict()), .init(text: verdict()),
            .init(text: verdict()), .init(text: verdict(target: "block_1")),
        ]])
        let models = ContextScript(["fast": [.init(text: "Alpha\nFirst documented observation."), .init(text: "Alpha\nSecond relevant observation.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        var starts = 0, replacements = 0
        var texts: [UInt64: String] = [:]
        engine.emit = {
            if case .cardStarted = $0 { starts += 1 }
            if case .cardSuperseded = $0 { replacements += 1 }
            if case .cardDelta(let id, let text) = $0 { texts[id, default: ""] += text }
        }
        heard(engine, 1, "Here is the first observation about Alpha.")
        await engine.idle()
        heard(engine, 2, "Now another observation about Alpha follows.")
        await engine.idle()
        #expect(starts == 2 && replacements == 1)
        #expect(texts[2]?.contains("First documented observation") == true && texts[2]?.contains("Second relevant observation") == true)
    }

    @Test func externalClaimsInTheActualDraftTriggerResearchEvenWhenTheInitialRouteDidNot() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(research: 0.01)), .init(text: verdict(research: 0.99))]])
        let models = ContextScript([
            "fast": [.init(text: "Backpressure\nA producer waits for capacity.")],
            "web": [.init(text: "Backpressure\nA producer waits for capacity.\nVerified explanation.")],
        ])
        var configuration = settings(decisions: decisions)
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        heard(engine, 1, "What exactly does backpressure mean here?")
        await engine.idle()
        #expect(await models.calls.map(\.model) == ["fast", "web"])
        let reviews = await decisions.calls.filter { $0.user.contains("Proposed card") }
        #expect(reviews.count == 1)
        #expect(reviews.first?.user.contains("A producer waits for capacity") == true)
    }

    @Test func selectedResearchStartsBeforeAnEmptyWriterFinishes() async {
        let latch = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict(research: 0.99))]])
        let models = ContextScript([
            "fast": [.init(text: "NO_ANSWER", latch: latch)],
            "web": [.init(text: "Backpressure\nA producer waits for capacity.", sources: ["https://example.com/backpressure"])],
        ])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "What exactly does backpressure mean here?")
        await until { await models.calls.contains { $0.model == "web" } }
        #expect(await models.calls.contains { $0.model == "web" }, "selected research must not depend on a draft")
        await latch.release()
        await engine.idle()
        #expect(output.contains("A producer waits for capacity"))
        #expect(await models.calls.filter { $0.model == "web" }.count == 1)
    }

    @Test func aResearchReplyWithoutProviderCitationsIsNotMarkedChecked() async {
        let models = ContextScript([
            "fast": [.init(text: "Alpha\nFirst observation."), .init(text: "NO_ANSWER")],
            "web": [.init(text: "Alpha\nFirst observation.\nAn external assertion without citations.")],
        ])
        var configuration = settings()
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        var details: [String] = []
        engine.onStep = { _, step in details.append(step.detail) }
        heard(engine, 1, "Please explain the Alpha algorithm now.")
        await engine.idle()
        heard(engine, 2, "Another observation about Alpha now follows.")
        await engine.idle()
        let requests = await models.calls.filter { $0.model == "fast" }
        #expect(requests.count == 2)
        #expect(requests.last?.user.contains("checked statements must be preserved") == false)
        #expect(details.contains("research reply, no provider citations (unverified)"))
    }

    @Test func aCheckedAnswerReplacesItsOwnMomentsWrongGuessInsteadOfAddingABlock() async {
        let models = ContextScript([
            "fast": [.init(text: "Deserialisation injection\nProbably meant: unsafe deserialisation.")],
            "web": [.init(text: "SQL injection\nInput changes a database query.", sources: ["https://owasp.org/sql"])],
        ])
        var configuration = settings()
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        let engine = AnswerEngine(client: models, settings: configuration)
        var blocks = Set<UInt64>()
        var replaced = 0
        engine.emit = {
            if case .cardStarted(let start) = $0 { blocks.insert(start.blockID ?? start.generationID) }
            if case .cardSuperseded = $0 { replaced += 1 }
        }
        heard(engine, 1, "What exactly is a desqual injection?")
        await engine.idle()
        #expect(blocks.count == 1, "one block for one question")
        #expect(replaced == 1, "the checked answer took the guess's place; the guess stays in its history")
    }

    @Test func aTitleWithInnerEmphasisKeepsBalancedBold() {
        #expect(AnswerEngine.card(from: "**Deserialisation** is probably meant\nA guess.") == "**Deserialisation is probably meant**\nA guess.")
    }

    @Test func anUncitedResearchReplyCannotRemoveSourcedStatements() async {
        let models = ContextScript([
            "fast": [.init(text: "Limit\nThe documented limit is 20 requests."), .init(text: "UPDATE 1\nLimit\nThe documented limit is 200 requests.")],
            "web": [
                .init(text: "Limit\nThe documented limit is 20 requests.\nDocumented service quota.", sources: ["https://example.com/limit"]),
                .init(text: "Limit\nThe documented limit is 200 requests."),
            ],
        ])
        var configuration = settings()
        configuration.drafters = ["fast"]
        configuration.researcher = "web"
        configuration.system.agents.webAfterDraft = false
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "Please explain the documented limit now.")
        await engine.idle()
        heard(engine, 2, "Could the documented limit actually be higher?")
        await engine.idle()
        let calls = await models.calls
        #expect(calls.filter { $0.model == "web" }.count == 2, "calls: \(calls.map(\.model))")
        #expect(output.contains("20 requests") && !output.contains("200 requests"))
    }

    @Test func lateRefinementAfterStopCannotRestartAnswering() async {
        let models = ContextScript([:])
        let engine = AnswerEngine(client: models, settings: settings())
        engine.stop()
        heard(engine, 1, "This correction arrived after the session stopped.")
        await engine.idle()
        #expect(await models.calls.isEmpty)
        #expect(!engine.routesEarlyText)
    }

    @Test func punctuationOnlyRefinementDoesNotRepeatGenerationButAChangedSignDoes() async {
        let models = ContextScript(["fast": [.init(text: "Offset\nThe offset is -1."), .init(text: "UPDATE 1\nOffset\nThe offset is +1.")]])
        var configuration = settings()
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        heard(engine, 1, "The offset is -1.")
        await engine.idle()
        heard(engine, 1, "The offset is -1!", revision: 2)
        await engine.idle()
        #expect(await models.calls.count == 1)
        heard(engine, 1, "The offset is +1.", revision: 3)
        await engine.idle()
        #expect(await models.calls.count == 2)
    }

    @Test func aCorrectionWhileDraftingNeverPublishesTheSupersededNumber() async {
        let latch = ContextLatch()
        let models = ContextScript(["fast": [
            .init(text: "Limit\nThe limit is 20 requests.", latch: latch),
            .init(text: "Limit\nThe limit is 200 requests."),
        ]])
        var configuration = settings()
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "The limit is 20 requests.")
        await until { await models.calls.count == 1 }
        heard(engine, 1, "The limit is 200 requests.", revision: 2)
        await until { await models.calls.count == 2 }
        await latch.release()
        await engine.idle()
        #expect(output.contains("200 requests") && !output.contains("20 requests"))
    }

    @Test func aNewQuestionDoesNotCancelAnAlreadySelectedUsefulAnswer() async {
        let latch = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict()), .init(text: verdict(0.01, target: "block_1"))]])
        let models = ContextScript(["fast": [.init(text: "Alpha\nA bounded producer waits for capacity.", latch: latch)]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "How does the Alpha algorithm apply backpressure?")
        await until { await models.calls.count == 1 }
        heard(engine, 2, "What do you think about Beta personally?")
        try? await Task.sleep(for: .milliseconds(30))
        await latch.release()
        await engine.idle()
        #expect(output.contains("A bounded producer waits for capacity"))
        #expect(await models.calls.count == 1)
    }

    @Test func anUnhelpfulQuoteFallsBackToThePrimaryWriter() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict(0.1)), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "Project start\nThe speaker estimates seven years.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        var text = ""
        var quoted = false
        engine.emit = {
            if case .cardDelta(_, let value) = $0 { text += value }
            if case .cardStarted(let start) = $0 { quoted = start.evidenceSegment != nil }
        }
        // Supply the question and answer in one scheduling interval.
        heard(engine, 1, "How long has this project existed?")
        heard(engine, 2, "About 7 years.")
        await engine.idle()
        #expect(await models.calls.map(\.model) == ["fast"])
        #expect(!quoted && text.contains("speaker estimates seven years"))
    }

    @Test func routedWritersGetACompactAdditionTaskInsteadOfFullCardRegeneration() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "Alpha\nA concrete answer.")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        heard(engine, 1, "What exactly does the Alpha algorithm do?")
        await engine.idle()
        let call = await models.calls.first
        #expect(call?.system.contains("ONE short") == true)
        #expect(call?.system.contains("two to four short lines") == false)
        #expect(call?.user.contains("An update is a coherent complete card") == false)
    }

    @Test func anUpdateRetainsRecordedSourcesWhenTheWriterOmitsTheFooter() async {
        let models = ContextScript(["fast": [.init(text: "UPDATE 1\nAlpha\nAn established fact.\nAnother useful observation.")]])
        var configuration = settings()
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        engine.restore([["Alpha\nAn established fact.\n\nSources: [Primary](https://example.com/alpha)"]])
        var latest = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { latest = text } }
        heard(engine, 1, "There is another useful observation about Alpha.")
        await engine.idle()
        #expect(latest.contains("Another useful observation"))
        #expect(latest.contains("https://example.com/alpha"))
    }

    @Test func aRoutedUpdateKeepsEarlierFactsAndFiltersLinksInItsDisplayedFocus() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(target: "block_1")), .init(text: verdict(target: "block_1"))]])
        let models = ContextScript(["fast": [.init(text: "Alpha\nA useful addition [unapproved](https://unapproved.example/path).")]])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        engine.restore([["Alpha\nAn established fact.\n\nSources: [Primary](https://example.com/alpha)"]])
        var latest = ""
        var start: CardStart?
        engine.emit = {
            if case .cardDelta(_, let text) = $0 { latest = text }
            if case .cardStarted(let value) = $0 { start = value }
        }
        heard(engine, 1, "There is a useful new observation about Alpha.")
        await engine.idle()
        #expect(latest.contains("An established fact") && latest.contains("https://example.com/alpha"))
        #expect(start?.focusText?.contains("A useful addition") == true)
        #expect(start?.focusText?.contains("unapproved.example") == false)
    }

    @Test func aRevisionWithTheSameSubstantiveWordsKeepsTheDraftAndRoutesNothingAgain() async {
        let latch = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "Upload cap\n**20 requests** per minute.", latch: latch)]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "Also the upload cap is 20 requests per minute.")
        await until { await models.calls.count == 1 }
        // The second hearing drops a filler word: nothing that was said changed.
        heard(engine, 1, "The upload cap is 20 requests per minute.", revision: 2)
        try? await Task.sleep(for: .milliseconds(20))
        await latch.release()
        await engine.idle()
        #expect(output.contains("20 requests"))
        #expect(await models.calls.count == 1, "the draft in flight is kept, not written again")
        #expect(await decisions.calls.count == 2, "one route and one review; the revision is not routed again")
    }

    @Test func anAddedWordKeepsTheDraftAndIsConsideredAfterwardsWithoutCancelling() async {
        let latch = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict()), .init(text: verdict(0.01, target: "block_1"))]])
        let models = ContextScript(["fast": [.init(text: "Contest\nStarted **2012**, runs a whole year.", latch: latch)]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "It was created in 2012 as a contest for authors.")
        await until { await models.calls.count == 1 }
        heard(engine, 1, "It was created in the year 2012 as a contest for authors.", revision: 2)
        try? await Task.sleep(for: .milliseconds(20))
        await latch.release()
        await engine.idle()
        #expect(output.contains("Started **2012**"))
        #expect(await models.calls.count == 1)
        #expect(await decisions.calls.count == 3, "route, review, and one later decision about the extended wording")
    }

    @Test func aSubstantiveCorrectionRestartsTheSameMomentBeforeANewerQuestion() async {
        let latch = ContextLatch()
        let decisions = ContextScript([decisionModel: [
            .init(text: verdict()), .init(text: verdict()), .init(text: verdict()), .init(text: verdict(0.01, target: "block_1")),
        ]])
        let models = ContextScript(["fast": [
            .init(text: "Author\nKaiserich writes about Austria.", latch: latch),
            .init(text: "Author\nGeiserich writes about Austrian geography."),
        ]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        heard(engine, 1, "I am Kaiserich on Wikipedia and mostly write about Austrian geography.")
        await until { await models.calls.count == 1 }
        heard(engine, 1, "I am Geiserich on Wikipedia and mostly write about Austrian geography.", revision: 2)
        heard(engine, 2, "Since when have you been active there?")
        await until { await models.calls.count == 2 }
        await latch.release()
        await engine.idle()
        #expect(output.contains("Geiserich") && !output.contains("Kaiserich"))
        #expect(await models.calls.count == 2, "the cancelled draft and the one for the corrected moment")
        let routes = await decisions.calls
        #expect(routes.count == 4, "route, route again after the correction, review, then the question")
        #expect(routes[1].user.contains("Newest utterance (context, not proof of correctness): I am Geiserich"), "the corrected moment, not the newer question")
        #expect(routes[3].user.contains("Newest utterance (context, not proof of correctness): Since when"))
    }

    @Test func aShortReplyToAQuestionIsRoutedAndQuotedWithoutAWriter() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.2)), .init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript([:])
        let engine = AnswerEngine(client: models, settings: settings(decisions: decisions))
        var text = ""
        var evidence: UInt64?
        engine.emit = {
            if case .cardDelta(_, let piece) = $0 { text += piece }
            if case .cardStarted(let start) = $0 { evidence = start.evidenceSegment }
        }
        heard(engine, 1, "What was the highlight here for you?")
        await engine.idle()
        heard(engine, 2, "The brewery pub.")
        await engine.idle()
        #expect(await models.calls.isEmpty)
        #expect(text.contains("The brewery pub.") && text.contains("highlight") && evidence == 2)
        #expect(await decisions.calls.count == 3)
    }

    @Test func aQuestionGetsOneQuoteAndAFurtherReplyGoesToTheWriter() async {
        let decisions = ContextScript([decisionModel: [
            .init(text: verdict(0.2)), .init(text: verdict()), .init(text: verdict()),
            .init(text: verdict(target: "block_1")), .init(text: verdict(target: "block_1")),
        ]])
        let models = ContextScript(["fast": [.init(text: "Highlight\nThe brewery pub near the station.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var quotes = 0
        engine.emit = { if case .cardStarted(let start) = $0, start.evidenceSegment != nil { quotes += 1 } }
        heard(engine, 1, "What was the highlight here for you?")
        await engine.idle()
        heard(engine, 2, "The brewery pub.")
        await engine.idle()
        heard(engine, 3, "The one near the station.")
        await engine.idle()
        #expect(quotes == 1)
        #expect(await models.calls.count == 1, "the second reply is written, not quoted again")
    }

    @Test func anUnconfirmedQuestionStartsEarlyButShowsNothingUntilConfirmed() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "Backpressure\nA producer waits for capacity.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        engine.provisional(id: 1, text: "How does the Alpha algorithm apply backpressure?")
        await until { await models.calls.count == 1 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(output.isEmpty, "nothing is shown before Apple confirms the question")
        heard(engine, 1, "How does the Alpha algorithm apply backpressure?")
        await engine.idle()
        #expect(output.contains("A producer waits for capacity"))
        #expect(await decisions.calls.count == 2, "one route and one review: the confirmed question is not routed again")
        #expect(await models.calls.count == 1)
    }

    @Test func anUnconfirmedQuestionWhoseWordsChangeIsDiscarded() async {
        let decisions = ContextScript([decisionModel: (0..<4).map { _ in .init(text: verdict()) }])
        let models = ContextScript(["fast": [.init(text: "Alpha\nAbout Alpha."), .init(text: "Beta\nAbout Beta.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        engine.provisional(id: 1, text: "How does the Alpha algorithm apply backpressure?")
        await until { await models.calls.count == 1 }
        heard(engine, 1, "How does the Beta algorithm apply backpressure?")
        await engine.idle()
        #expect(!output.contains("About Alpha"))
        #expect(output.contains("About Beta"))
    }

    @Test func anUnconfirmedQuestionThatIsNeverConfirmedShowsNothing() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "Alpha\nAbout Alpha.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        engine.provisional(id: 1, text: "How does the Alpha algorithm apply backpressure?")
        await until { await models.calls.count == 1 }
        engine.stop()
        await engine.idle()
        #expect(output.isEmpty)
    }

    @Test func passagesFromTheTopicsFilesThatMatchTheTalkGoIntoTheRequest() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript(["fast": [.init(text: "SQL injection\nUse parameterised queries.")]])
        var configuration = settings(decisions: decisions)
        configuration.drafters = ["fast"]
        let engine = AnswerEngine(client: models, settings: configuration)
        let passages = MaterialIndex.passages(of: "# Security checklist\nSQL-Injection: always use parameterised queries.\n\n"
            + String(repeating: "Unrelated filler about holidays and gardens. ", count: 30)
            + "\nThe garden party is on Saturday.", source: "notes/security.md")
        engine.material = MaterialIndex(passages: passages, overview: MaterialIndex.overview(passages), terms: MaterialIndex.terms(in: passages))
        heard(engine, 1, "What exactly is an injection attack on queries?")
        await engine.idle()
        let user = await models.calls.first?.user ?? ""
        #expect(user.contains("notes/security.md: Security checklist"), "the overview")
        #expect(user.contains("[notes/security.md] # Security checklist"), "the matching passage")
        #expect(!user.contains("garden party"), "not the unrelated passage")
    }

    @Test func theDeciderSeesMatchingPassagesBeforeLongHistoricalNotes() async {
        let decisions = ContextScript([decisionModel: [.init(text: verdict(0.02))]])
        var configuration = settings(decisions: decisions)
        configuration.earlier = String(repeating: "Historical context that is not relevant. ", count: 150)
        let engine = AnswerEngine(client: ContextScript([:]), settings: configuration)
        engine.material = MaterialIndex(passages: [.init(source: "iam.md", text: "IAM uses least privilege for service identities.")])
        heard(engine, 1, "How does IAM protect a service?")
        await engine.idle()
        let input = await decisions.calls.first?.user ?? ""
        #expect(input.contains("[iam.md] IAM uses least privilege"))
    }

    @Test func aStalledWriterIsCancelledSoTheFallbackAndLaterRoundsGoOn() async {
        let stuck = ContextLatch()
        let decisions = ContextScript([decisionModel: [.init(text: verdict()), .init(text: verdict())]])
        let models = ContextScript([
            "fast": [.init(text: "Alpha\nToo late.", latch: stuck)],
            "slow": [.init(text: "Alpha\nA bounded producer waits for capacity.")],
        ])
        var configuration = settings(decisions: decisions)
        configuration.system.scheduler.writerFirstTextSeconds = 0.05
        let engine = AnswerEngine(client: models, settings: configuration)
        var output = ""
        var log: [String] = []
        engine.emit = { if case .cardDelta(_, let text) = $0 { output += text } }
        engine.onLog = { _, fields in log.append(fields["state"] as? String ?? "") }
        let began = ContinuousClock.now
        heard(engine, 1, "How does the Alpha algorithm apply backpressure?")
        await engine.idle()
        #expect(output.contains("A bounded producer waits for capacity") && !output.contains("Too late"))
        #expect(ContinuousClock.now - began < .seconds(2), "the stalled writer does not hold the round")
        #expect(log.contains { $0.hasPrefix("writer stalled") })
        await stuck.release()
    }

    @Test func aOneLineReplyKeepsItsNumberAndBecomesReadableBodyText() throws {
        let reply = "Offset: **-1.5** seconds."
        let card = try #require(AnswerEngine.card(from: AnswerEngine.compactReply(reply, language: .en)))
        #expect(card.split(separator: "\n").count == 2)
        #expect(card.contains(reply))
    }
}
