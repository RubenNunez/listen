import Foundation
import Testing
@testable import Listen

private func meetingReply(_ candidates: [MeetingCandidate], ledger: MeetingLedger = MeetingLedger(),
                          kinds: [MeetingKind], targets: [String] = [], changes: [String] = [],
                          owner: String = "proposed", due: String = "proposed", supported: Double = 0.99) -> String {
    let questions = MeetingReview.questions(candidates: candidates, existing: ledger.items, instructions: "Fixture")
    var answers: [String: Any] = [:]
    for (name, raw) in questions {
        let question = raw as! [String: Any]
        let index = Int(name.split(separator: "_").last!)!
        if question["type"] as? String == "noul" {
            answers[name] = ["type": "noul", "noul": supported]
            continue
        }
        let criteria = question["criteria"] as! [String: String]
        let proposed: String
        if name.hasPrefix("kind_") { proposed = kinds[index].rawValue }
        else if name.hasPrefix("target_") { proposed = targets.indices.contains(index) ? targets[index] : "new" }
        else if name.hasPrefix("change_") { proposed = changes.indices.contains(index) ? changes[index] : "record" }
        else if name.hasPrefix("owner_") { proposed = owner }
        else { proposed = due }
        let choice = criteria[proposed] != nil ? proposed : "none"
        answers[name] = ["type": "choice", "choice": choice, "confidence": 0.99,
                         "probabilities": Dictionary(uniqueKeysWithValues: criteria.keys.map { ($0, $0 == choice ? 1.0 : 0.0) })]
    }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["answers": answers]), as: UTF8.self)
}

@Suite struct MeetingValues {
    private let evidence = MeetingEvidence(id: 1, text: "I will test retries by Friday.", speaker: "voice 2")

    private var candidate: MeetingCandidate {
        .init(text: "Test retries", quote: evidence.text, source: 1, owner: "voice 2", due: "Friday")
    }

    @Test func candidatesMustQuoteTheSelectedEvidenceAndCannotInventOwnersOrDates() throws {
        let reply = #"[{"text":"Test retries","quote":"I will test retries by Friday.","source":1,"owner":"speaker","due":"Friday"},{"text":"Invented","quote":"We chose a database.","source":1,"owner":null,"due":null},{"text":"Wrong source","quote":"I will test retries by Friday.","source":999,"owner":null,"due":null}]"#
        let values = try MeetingCandidate.read(reply, evidence: [evidence], context: [evidence], limit: 8)
        #expect(values.count == 1)
        #expect(values.first?.owner == "voice 2" && values.first?.due == "Friday")
        let invented = reply.replacingOccurrences(of: "\"speaker\"", with: "\"Invented Person\"")
            .replacingOccurrences(of: "\"due\":\"Friday\"", with: "\"due\":\"Monday\"")
        let cleared = try MeetingCandidate.read(invented, evidence: [evidence], context: [evidence], limit: 8)
        #expect(cleared.first?.owner == nil && cleared.first?.due == nil)
    }

    @Test func unknownAndOverlappingSpeakersNeverAcquireAnOwner() throws {
        let reply = #"[{"text":"Test retries","quote":"I will test retries by Friday.","source":1,"owner":"speaker","due":null}]"#
        for speaker in [nil, "unknown", "Someone", "overlap"] as [String?] {
            var line = evidence; line.speaker = speaker
            #expect(try MeetingCandidate.read(reply, evidence: [line], context: [line], limit: 8).first?.owner == nil)
        }
    }

    @Test func classificationIsTypedAndOwnerAndDeadlineVotesAreIndependent() throws {
        let reply = meetingReply([candidate], kinds: [.task], owner: "none", due: "proposed")
        let decision = try #require(MeetingReview.read(reply, candidates: [candidate], existing: []).first)
        #expect(decision.kind == .task && decision.candidate.owner == nil && decision.candidate.due == "Friday")
        #expect(try MeetingReview.read(meetingReply([candidate], kinds: [.decision], supported: 0.4), candidates: [candidate], existing: []).isEmpty)
    }

    @Test func malformedAndUnknownClassificationChoicesFailClosed() throws {
        let valid = meetingReply([candidate], kinds: [.task])
        var object = try JSONSerialization.jsonObject(with: Data(valid.utf8)) as! [String: Any]
        var answers = object["answers"] as! [String: [String: Any]]
        answers["target_0"]?["choice"] = "item_999"
        object["answers"] = answers
        let unknown = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(throws: (any Error).self) { try MeetingReview.read(unknown, candidates: [candidate], existing: []) }
        answers["supported_0"]?["noul"] = true
        object["answers"] = answers
        let boolean = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(throws: (any Error).self) { try MeetingReview.read(boolean, candidates: [candidate], existing: []) }
    }

    @Test func correctionsUpdateOneStableItemAndResolutionMovesItBetweenSections() {
        var ledger = MeetingLedger()
        var proposal = candidate
        proposal.owner = nil; proposal.due = nil; proposal.text = "Which delivery guarantee?"
        ledger.apply(.init(candidate: proposal, kind: .openQuestion, target: nil, change: .record))
        let id = ledger.items[0].id
        proposal.text = "Adopt at-least-once delivery"; proposal.quote = "We adopt at-least-once delivery."
        ledger.apply(.init(candidate: proposal, kind: .decision, target: id, change: .resolve))
        #expect(ledger.items.count == 1 && ledger.items[0].id == id)
        #expect(!ledger.block(.openQuestion, language: .en).contains("Which delivery"))
        #expect(ledger.block(.decision, language: .en).contains("Adopt at-least-once"))
        ledger.apply(.init(candidate: proposal, kind: .decision, target: nil, change: .record))
        #expect(ledger.items.count == 1, "Exact repetitions cannot add another row even if routed as new")
    }

    @Test func metadataCanBeRetainedOrExplicitlyWithdrawnWithoutAddingRows() throws {
        var ledger = MeetingLedger()
        ledger.apply(.init(candidate: candidate, kind: .task, target: nil, change: .record))
        var next = candidate; next.text = "Test retry jitter"; next.owner = nil; next.due = nil
        let kept = meetingReply([next], ledger: ledger, kinds: [.task], targets: ["item_1"], owner: "existing", due: "existing")
        for decision in try MeetingReview.read(kept, candidates: [next], existing: ledger.items) { ledger.apply(decision) }
        #expect(ledger.items.count == 1 && ledger.items[0].owner == "voice 2" && ledger.items[0].due == "Friday")
        let cleared = meetingReply([next], ledger: ledger, kinds: [.task], targets: ["item_1"], owner: "none", due: "none")
        for decision in try MeetingReview.read(cleared, candidates: [next], existing: ledger.items) { ledger.apply(decision) }
        #expect(ledger.items[0].owner == nil && ledger.items[0].due == nil)
    }

    @Test func removedRecognitionEvidenceCannotSurviveAsAnUnchangedDecision() {
        var ledger = MeetingLedger()
        ledger.apply(.init(candidate: candidate, kind: .task, target: nil, change: .record))
        ledger.discardInvalidQuotes(in: [.init(id: 1, text: "We will not test retries.", speaker: "voice 2")])
        #expect(ledger.items.isEmpty)
    }

    @Test func minutesUseTheTopicLanguageAndNeverFillUnknownMetadata() {
        var ledger = MeetingLedger()
        var unknown = candidate; unknown.owner = nil; unknown.due = nil
        ledger.apply(.init(candidate: unknown, kind: .task, target: nil, change: .record))
        let english = ledger.minutes(language: .en), german = ledger.minutes(language: .de)
        #expect(english.contains("### Decisions") && english.contains("Owner: unassigned") && english.contains("### Open points"))
        #expect(german.contains("### Entscheide") && german.contains("Zuständig: offen") && german.contains("### Offene Punkte"))
        #expect(!english.contains("Friday") && !german.contains("Friday"))
        #expect(!SystemConfig().agents.meetingItems && !SystemConfig().agents.meetingMinutes)
    }
}

private actor MeetingScript: ModelClient {
    private var replies: [String]
    private(set) var calls: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    nonisolated func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let reply = await self.take(system)
                if !Task.isCancelled { continuation.yield(.text(reply)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func take(_ system: String) -> String {
        calls.append(system)
        return replies.isEmpty ? "[]" : replies.removeFirst()
    }
}

/// A deterministic fixture for the two independent lanes, rather than sharing one reply queue
/// whose order would make concurrent normal/meeting requests nondeterministic.
private actor MeetingRoutingFixture: ModelClient {
    private var extracts: [String]
    private var reviews: [String]
    private let ordinary: Bool
    private(set) var ordinaryRequests: [String] = []

    init(extracts: [String], reviews: [String], ordinary: Bool = false) {
        self.extracts = extracts; self.reviews = reviews; self.ordinary = ordinary
    }

    nonisolated func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let value = await self.response(system, user)
                if !Task.isCancelled { continuation.yield(.text(value)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func response(_ system: String, _ user: String) -> String {
        if system.hasPrefix("Extract meeting items") {
            return extracts.isEmpty ? "[]" : extracts.removeFirst()
        }
        if let data = system.data(using: .utf8), let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if schema["kind_0"] != nil { return reviews.isEmpty ? "{}" : reviews.removeFirst() }
            ordinaryRequests.append(user)
            var answers: [String: Any] = [:]
            for (name, raw) in schema {
                guard let question = raw as? [String: Any] else { continue }
                if question["type"] as? String == "noul" {
                    answers[name] = ["type": "noul", "noul": name == "research" ? 0.01 : ordinary ? 0.99 : 0.01]
                } else if let criteria = question["criteria"] as? [String: Any] {
                    let choice = criteria["new"] != nil ? "new" : criteria["new_subject"] != nil ? "new_subject" : criteria.keys.sorted().first!
                    answers[name] = ["type": "choice", "choice": choice, "confidence": 0.99,
                        "probabilities": Dictionary(uniqueKeysWithValues: criteria.keys.map { ($0, $0 == choice ? 1.0 : 0.0) })]
                }
            }
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["answers": answers]), as: UTF8.self)
        }
        return "Ordinary answer\nAn ordinary answer can still be shown."
    }
}

@MainActor
@Suite struct MeetingRuntime {
    private let line = MeetingEvidence(id: 1, text: "We adopt a queue.", speaker: "voice 1")
    private var candidate: MeetingCandidate { .init(text: "Adopt a queue", quote: line.text, source: 1, owner: nil, due: nil) }
    private let proposal = #"[{"text":"Adopt a queue","quote":"We adopt a queue.","source":1,"owner":null,"due":null}]"#

    @Test func repeatedEvidenceDoesNotCallModelsOrRepublishAStableSection() async {
        let writer = MeetingScript([proposal])
        let decider = MeetingScript([meetingReply([candidate], kinds: [.decision])])
        let lane = MeetingEngine(language: .de, model: "fixture", prompts: .init(), client: { _, _, typed in typed ? decider : writer }, log: { _, _ in })
        var blocks: [(MeetingKind, String)] = []
        lane.publish = { kind, text, _ in blocks.append((kind, text)) }
        lane.ingest([line]); await lane.idle()
        lane.ingest([line]); await lane.idle()
        #expect(blocks.count == 1 && blocks.first?.0 == .decision)
        let writerCalls = await writer.calls.count
        let decisionCalls = await decider.calls.count
        #expect(writerCalls == 1 && decisionCalls == 1)
        lane.stop()
    }

    @Test func sessionEndCanProduceVerifiedMinutesWithLiveItemsOffAndSummaryOff() async throws {
        let source = MeetingEvidence(id: 1_000_000_000, text: line.text, speaker: "Voice 1")
        var endCandidate = candidate; endCandidate.source = source.id
        let endProposal = proposal.replacingOccurrences(of: "\"source\":1", with: "\"source\":1000000000")
        let writer = MeetingScript([endProposal])
        let decider = MeetingScript([meetingReply([endCandidate], kinds: [.decision])])
        var settings = AnswerEngine.Settings()
        settings.drafters = ["fixture"]
        settings.system.agents.summary = false
        settings.system.agents.meetingMinutes = true
        settings.decisionClient = decider
        let engine = AnswerEngine(client: writer, settings: settings)
        var emitted = 0
        engine.emit = { _ in emitted += 1 }
        engine.stop()
        let before = emitted
        let minutes = try #require(await engine.summarise("Voice 1: We adopt a queue."))
        #expect(minutes.contains("Adopt a queue") && minutes.contains("### Entscheide"))
        #expect(emitted == before, "End minutes never publish a card after Stop")
    }

    @Test func missingTypedServiceDoesNotFabricateMinutesOrUseAWriterAsAJudge() async {
        let writer = MeetingScript([proposal])
        let lane = MeetingEngine(language: .en, model: "fixture", prompts: .init(), client: { _, _, typed in typed ? nil : writer }, log: { _, _ in })
        #expect(await lane.finish("Voice 1: We adopt a queue.") == nil)
        #expect(await writer.calls.isEmpty)
    }

    @Test func finalMinutesReconcileRetractionsInsteadOfCopyingTheLiveLedger() async throws {
        let final = MeetingCandidate(text: "We did not adopt a queue.", quote: "We did not adopt a queue.", source: 1_000_000_000, owner: nil, due: nil)
        let writer = MeetingScript([proposal, "[]"])
        let decider = MeetingScript([meetingReply([candidate], kinds: [.decision]), meetingReply([final], kinds: [.none])])
        let lane = MeetingEngine(language: .en, model: "fixture", prompts: .init(), client: { _, _, typed in typed ? decider : writer }, log: { _, _ in })
        lane.ingest([line]); await lane.idle()
        #expect(lane.ledger.items.count == 1)
        lane.stop()
        let minutes = try #require(await lane.finish("Voice 1: We did not adopt a queue."))
        #expect(!minutes.contains("Adopt a queue"))
        #expect(lane.ledger.items.isEmpty)
    }

    @Test func minutesOnlyModeStoresSpeakerUncertaintyWithoutStartingLiveCalls() async throws {
        let text = "I will test retries by Friday."
        let proposal = #"[{"text":"Test retries","quote":"I will test retries by Friday.","source":1000000000,"owner":"speaker","due":"Friday"}]"#
        let candidate = MeetingCandidate(text: "Test retries", quote: text, source: 1_000_000_000, owner: nil, due: "Friday")
        let writer = MeetingScript([proposal]), decider = MeetingScript([meetingReply([candidate], kinds: [.task])])
        let lane = MeetingEngine(language: .en, model: "fixture", prompts: .init(), client: { _, _, typed in typed ? decider : writer }, log: { _, _ in })
        lane.ingest([.init(id: 1, text: text, speaker: nil)], live: false)
        await lane.idle()
        #expect(await writer.calls.isEmpty)
        #expect(await decider.calls.isEmpty)
        lane.stop()
        let minutes = try #require(await lane.finish("Voice 2: " + text))
        #expect(minutes.contains("Owner: unassigned") && !minutes.contains("Owner: Voice 2"))
    }

    @Test func verifiedUpdatesKeepTheSameCardBlockAndDoNotDuplicateRows() async {
        var ledger = MeetingLedger()
        ledger.apply(.init(candidate: candidate, kind: .decision, target: nil, change: .record))
        let next = MeetingCandidate(text: "Adopt a Kafka queue", quote: "We adopt Kafka instead.", source: 2, owner: nil, due: nil)
        let fixture = MeetingRoutingFixture(extracts: [proposal,
            #"[{"text":"Adopt a Kafka queue","quote":"We adopt Kafka instead.","source":2,"owner":null,"due":null}]"#],
            reviews: [meetingReply([candidate], kinds: [.decision]),
                meetingReply([next], ledger: ledger, kinds: [.decision], targets: ["item_1"])])
        var settings = AnswerEngine.Settings()
        settings.drafters = ["fixture"]; settings.decisionClient = fixture
        settings.pause = .milliseconds(2)
        settings.system.agents.meetingItems = true
        settings.system.agents.forecast = false
        settings.system.agents.web = false
        let engine = AnswerEngine(client: fixture, settings: settings)
        var starts: [CardStart] = [], bodies: [String] = []
        engine.emit = { event in
            if case .cardStarted(let start) = event { starts.append(start) }
            if case .cardDelta(_, let text) = event { bodies.append(text) }
        }
        engine.heard(.init(segmentID: 1, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: line.text, startMs: 0, endMs: 1), isMine: false)
        await engine.idle()
        engine.heard(.init(segmentID: 2, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: next.quote, startMs: 1, endMs: 2), isMine: false)
        await engine.idle()
        #expect(starts.count == 2 && starts.first?.blockID == starts.last?.blockID)
        #expect(bodies.last?.contains("Adopt a Kafka queue") == true && bodies.last?.contains("\n- Adopt a queue") == false)
        let ordinaryRequests = await fixture.ordinaryRequests
        #expect(!ordinaryRequests.last!.contains("Entscheide\n"))
        engine.stop()
    }

    @Test func normalAnswersAndMeetingItemsCanBothRun() async {
        let fixture = MeetingRoutingFixture(extracts: [proposal], reviews: [meetingReply([candidate], kinds: [.decision])], ordinary: true)
        var settings = AnswerEngine.Settings()
        settings.drafters = ["fixture"]; settings.decisionClient = fixture; settings.pause = .milliseconds(2)
        settings.system.agents.meetingItems = true
        settings.system.agents.forecast = false; settings.system.agents.web = false; settings.system.agents.merge = false
        let engine = AnswerEngine(client: fixture, settings: settings)
        var bodies: [String] = []
        engine.emit = { if case .cardDelta(_, let text) = $0 { bodies.append(text) } }
        engine.heard(.init(segmentID: 1, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: line.text, startMs: 0, endMs: 1), isMine: false)
        await engine.idle()
        #expect(bodies.contains { $0.contains("An ordinary answer") })
        #expect(bodies.contains { $0.contains("Entscheide") && $0.contains("Adopt a queue") })
        engine.stop()
    }

    @Test func minutesUseTheExistingTopicNoteWriter() throws {
        var ledger = MeetingLedger()
        ledger.apply(.init(candidate: candidate, kind: .decision, target: nil, change: .record))
        let root = FileManager.default.temporaryDirectory.appending(path: "meeting-note-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sandbox = TopicSandbox(topic: UUID(), root: root)
        let note = TopicSandbox.Conversation(topic: "Synthetic meeting", began: .now, seconds: 1, people: [], cards: [], blocks: [], sentences: 1,
                                             summary: ledger.minutes(language: .en))
        let file = try #require(sandbox.write(note))
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("## Summary") && content.contains("### Decisions") && content.contains("Adopt a queue"))
    }

    @Test func normalAnswerTrafficDoesNotEvictTheThreeMeetingBlocks() {
        var core = SessionCore()
        var sequence: UInt64 = 0
        func send(_ event: ServerEvent) {
            sequence += 1
            _ = core.handle(.envelope(.init(v: 1, seq: sequence, event: event)))
        }
        _ = core.handle(.start(language: .en))
        _ = core.handle(.microphonePermission(true))
        _ = core.handle(.transportConnected)
        send(.state(.listening, reason: nil))
        for id in UInt64(1)...23 {
            send(.cardStarted(.init(generationID: id, kind: .fast, style: .answer, triggerSegment: 1, sourceCard: nil,
                                   contextVersion: 0, mappingVersion: 0, meeting: id <= 3 ? true : nil)))
            send(.cardDelta(generationID: id, text: "Section \(id)\nA recorded item."))
            send(.cardFinished(generationID: id))
        }
        #expect(core.cards.count == SessionCore.maxCards)
        #expect(Set(core.cards.filter { $0.start.meeting == true }.map(\.id)) == [1, 2, 3])
        #expect(Set(core.cards.filter { $0.start.meeting != true }.map(\.id)) == Set(UInt64(19)...23))
    }
}
