import Foundation
import Testing

@testable import Listen

@Suite struct OptionalDecisionService {
    @Test func jevIsSeparateFromCardGeneratingModels() {
        #expect(Connector.jev.group == .decisions)
        #expect(Connector.jev.access == .apiKey)
        let cardProviders = Connector.allCases.filter { $0.group == .intelligence }
        #expect(!cardProviders.contains(.jev))
        #expect(cardProviders.contains(.chatGPT) && cardProviders.contains(.openAI))
    }

    @Test func checkingJevAccessDoesNotRunInferenceOrSendConversationContent() throws {
        let request = try #require(Connector.jev.check(with: "test-key-not-a-real-secret"))
        #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil && request.httpBodyStream == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-a-real-secret")
        #expect(request.url?.query == nil, "The key must never appear in a URL.")
    }
}

@MainActor
@Suite struct TokenAccounting {
    @Test func responsesReportUsageOnlyWhenActuallyPresent() {
        let usage = #""usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":80},"output_tokens":30,"output_tokens_details":{"reasoning_tokens":20},"total_tokens":150}"#
        for type in ["response.completed", "response.incomplete", "response.failed"] {
            let line = "data: {\"type\":\"\(type)\",\"response\":{\(usage)}}"
            #expect(ResponsesClient.tokenUsage(inLine: line) == TokenUsage(input: 120, output: 30, cachedInput: 80, reasoningOutput: 20))
        }
        #expect(ResponsesClient.tokenUsage(inLine: #"data: {"type":"response.completed","response":{}}"#) == nil)
        #expect(TokenUsage.read(["input_tokens": 0, "output_tokens": 0], responses: true)?.total == 0)
        #expect(TokenUsage.read(["input_tokens": 10], responses: true) == nil)
        #expect(TokenUsage.read(["input_tokens": -1, "output_tokens": 2], responses: true) == nil)
        #expect(TokenUsage.read(["input_tokens": Int.max, "output_tokens": 1], responses: true) == nil)
    }

    @Test func chatCompletionUsageIncludesCacheAndReasoningWithoutAddingThemAgain() {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":25,"prompt_tokens_details":{"cached_tokens":50},"completion_tokens_details":{"reasoning_tokens":10},"cost":0.001}}"#
        #expect(OpenRouterClient.chunks(inLine: line) == [
            .cost(0.001), .usage(TokenUsage(input: 100, output: 25, cachedInput: 50, reasoningOutput: 10)),
        ])
        #expect(OpenRouterClient.chunks(inLine: #"data: {"choices":[],"usage":null}"#).isEmpty)
    }

    private struct Chunks: ModelClient {
        var values: [ModelChunk]
        var fails = false
        func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
            AsyncThrowingStream { stream in
                for value in values { stream.yield(value) }
                if fails { stream.finish(throwing: CocoaError(.fileReadUnknown)) } else { stream.finish() }
            }
        }
    }

    private actor Reports {
        var values: [UsageReportingClient.Report] = []
        var starts: [UsageReportingClient.Start] = []
        func append(_ report: UsageReportingClient.Report) { values.append(report) }
        func begin(_ start: UsageReportingClient.Start) { starts.append(start) }
    }

    @Test func cumulativeChunksCountOnceAndDoNotChangeTheAnswer() async throws {
        let first = TokenUsage(input: 100, output: 10)
        let final = TokenUsage(input: 100, output: 25)
        let reports = Reports()
        let client = UsageReportingClient(base: Chunks(values: [.text("NO_ANSWER"), .usage(first), .usage(final), .cost(0.001)])) {
            await reports.append($0)
        }
        var received: [ModelChunk] = []
        for try await chunk in client.stream(model: "test", system: "Rules", user: "Text", maxTokens: 30) { received.append(chunk) }
        #expect(received == [.text("NO_ANSWER"), .cost(0.001)])
        let recorded = await reports.values
        #expect(recorded.count == 1 && recorded.first?.usage == final)
        #expect(recorded.first?.outcome == "completed")
        #expect(recorded.first?.response == nil, "without tracing, raw model text is not retained")
    }

    @Test func theInspectorRecordsExactInputsAndRawResponseWithOneRequestID() async throws {
        let instructions = String(repeating: "A rule. ", count: 2_000)
        let input = String(repeating: "A conversation line. ", count: 1_000)
        let response = "UPDATE 1\nTitle\n" + String(repeating: "Full untrimmed response.\n", count: 1_000)
        let reports = Reports()
        let client = UsageReportingClient(
            base: Chunks(values: [.text(response), .source("https://example.com/a"), .source("https://example.com/a"), .cost(0.001)]),
            started: { await reports.begin($0) }
        ) { await reports.append($0) }
        for try await _ in client.stream(model: "chatgpt/test", system: instructions, user: input, maxTokens: 400) {}
        let starts = await reports.starts
        let ends = await reports.values
        #expect(starts.count == 1 && ends.count == 1)
        #expect(starts.first?.id == ends.first?.id)
        #expect(starts.first?.instructions == instructions && starts.first?.input == input)
        #expect(ends.first?.response == response, "the raw answer is not replaced with a cleaned card")
        #expect(ends.first?.sources == ["https://example.com/a"] && ends.first?.costUSD == 0.001)
    }

    @Test func aFailedTraceRetainsItsPartialResponse() async {
        let reports = Reports()
        let client = UsageReportingClient(base: Chunks(values: [.text("Partial answer" )], fails: true), started: { await reports.begin($0) }) {
            await reports.append($0)
        }
        do { for try await _ in client.stream(model: "test", system: "Rules", user: "Input", maxTokens: 20) {} } catch {}
        let ends = await reports.values
        #expect(ends.first?.response == "Partial answer" && ends.first?.outcome == "failed")
        #expect(ends.first?.failure != nil)
    }

    @Test func aFailedRequestKeepsItsReportedUsageAndMissingUsageStaysUnknown() async {
        let reports = Reports()
        let usage = TokenUsage(input: 10, output: 5)
        let batches: [[ModelChunk]] = [[.usage(usage)], []]
        for values in batches {
            let client = UsageReportingClient(base: Chunks(values: values, fails: true)) { await reports.append($0) }
            do { for try await _ in client.stream(model: "test", system: "", user: "", maxTokens: 30) {} }
            catch {}
        }
        let recorded = await reports.values
        #expect(recorded.count == 2)
        #expect(recorded[0].usage == usage && recorded[1].usage == nil)
        #expect(recorded.allSatisfy { $0.outcome == "failed" })
        #expect(Set(recorded.map(\.id)).count == 2)
    }

    @Test func gatesDraftsAndSummariesAllReachTheRunLog() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["test"]
        settings.gated = ["test"]
        settings.pause = .milliseconds(1)
        settings.system.agents.merge = false
        settings.system.agents.web = false
        let engine = AnswerEngine(client: Chunks(values: [.text("YES Eiffelturm\n330 Meter hoch."), .usage(TokenUsage(input: 10, output: 3))]), settings: settings)
        var reports: [[String: Any]] = []
        engine.onLog = { kind, fields in if kind == "usage" { reports.append(fields) } }
        engine.heard(TranscriptSegment(segmentID: 1, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1),
                                       text: "Wie hoch ist der Eiffelturm?", startMs: 0, endMs: 0), isMine: false)
        await engine.idle()
        #expect(reports.count == 2, "a gate and its draft are separate model calls")
        _ = await engine.summarise(String(repeating: "Ein Satz über den Eiffelturm. ", count: 8))
        #expect(reports.count == 3, "the summary also belongs to the run's usage")
        #expect(reports.allSatisfy { ($0["input_tokens"] as? Int) == 10 && ($0["output_tokens"] as? Int) == 3 })
    }

    private func timeline(_ events: [[String: Any]]) throws -> RunTimeline {
        let folder = FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try lines.joined(separator: "\n").write(to: folder.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
        return RunTimeline(folder: folder)
    }

    @Test func replayDeduplicatesUsageAndMarksPartialTotals() throws {
        let run = try timeline([
            ["t": 1, "kind": "usage", "request_id": "a", "input_tokens": 100, "output_tokens": 10],
            ["t": 2, "kind": "usage", "request_id": "a", "input_tokens": 120, "output_tokens": 30],
            ["t": 3, "kind": "usage", "request_id": "b"],
        ])
        #expect(run.usage.count == 2 && run.unreportedCalls == 1)
        #expect(run.reportedTokens?.total == 150)
        #expect(run.tokenCountLabel.hasPrefix("≥ "))
        #expect(run.tokenUsageDetail.contains("incomplete"))
    }

    @Test func modelAndMCPCallsRemainSeparateAndReplayNeverShowsAFutureToolResult() throws {
        let run = try timeline([
            ["kind": "model_request", "t": 1.0, "request_id": "main", "agent": "voice", "model": "synthetic-main"],
            ["kind": "model_request", "t": 1.01, "request_id": "fast", "agent": "voice-fast", "model": "synthetic-fast"],
            ["kind": "mcp_request", "t": 2.0, "request_id": "tool", "server": "Synthetic automation", "method": "tools/call", "tool": "set_light", "input": "{}"],
            ["kind": "mcp_result", "t": 3.0, "request_id": "tool", "outcome": "completed"],
        ])
        #expect(run.requests.count == 2 && run.toolRequests.count == 1)
        #expect(run.statistics(at: 1.5).requests == 2 && run.statistics(at: 1.5).toolRequests == 0)
        #expect(run.statistics(at: 2.5).toolRequests == 1)
        #expect(run.through(2.5).toolRequests[0].end == nil && run.through(2.5).toolRequests[0].outcome == nil)
        #expect(run.through(3).toolRequests[0].outcome == "completed")
    }

    @Test func replayCountersFollowRecordedArrivalsInBothDirections() throws {
        let run = try timeline([
            ["t": 1, "kind": "sentence", "id": 1, "start_ms": 0, "end_ms": 500, "text": "First recognised text"],
            ["t": 2, "kind": "model_request", "request_id": "a", "agent": "draft", "model": "chatgpt/model", "sentence": 1],
            ["t": 3, "kind": "sentence", "id": 2, "start_ms": 500, "end_ms": 1500, "text": "Second sentence"],
            ["t": 4, "kind": "usage", "request_id": "a", "outcome": "completed", "response": "Recorded answer", "input_tokens": 10, "output_tokens": 2],
            ["t": 5, "kind": "layer", "name": "3 · model", "sentence": 1, "detail": "nothing to show"],
            ["t": 6, "kind": "layer", "name": "4 · merge", "sentence": 2, "detail": "nothing new"],
            ["t": 7, "kind": "card_started", "card": 1, "sentence": 2, "layer": "fast"],
            ["t": 7.1, "kind": "landed", "card": 1, "block": 1, "version": 1],
            ["t": 8, "kind": "sentence", "id": 1, "start_ms": 0, "end_ms": 500, "text": "Corrected recognised text"],
            ["t": 9, "kind": "model_request", "request_id": "b", "agent": "web", "sentence": 2],
        ])
        let beginning = run.through(0)
        #expect(beginning.sentences.isEmpty && beginning.requests.isEmpty && beginning.cards.isEmpty && beginning.blocks.isEmpty)
        let waiting = run.through(2)
        #expect(waiting.sentences.count == 1 && waiting.sentences[0].text == "First recognised text")
        #expect(waiting.requests.count == 1 && waiting.openNow == 1)
        #expect(waiting.reportedTokens == nil && waiting.tokenCountLabel == "—")
        #expect(waiting.requests[0].response == nil && waiting.requests[0].result == "open")
        let answered = run.through(4)
        #expect(answered.requests.count == 1 && answered.openNow == 0 && answered.reportedTokens?.total == 12)
        #expect(answered.requests[0].result == "completed")
        #expect(run.through(5).requests.filter { $0.result.contains("nothing to show") }.count == 1)
        #expect(run.through(6).gates.count == 1 && run.through(6).cards.isEmpty)
        #expect(run.through(7).cards.count == 1 && run.through(7).blocks.count == 1)
        let end = run.through(run.length)
        #expect(end.sentences.count == 2 && end.sentences[0].text == "Corrected recognised text")
        #expect(end.requests.count == 2 && end.openNow == 1 && end.tokenCountLabel.hasPrefix("≥ "))
        #expect(run.through(2).sentences[0].text == "First recognised text", "Backward seeking forgets future corrections and counters")
        #expect(run.requests.count == 2 && run.cards.count == 1, "Projection does not change the recorded timeline")
        for moment in [0.0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 4, 0] {
            let snapshot = run.through(moment)
            let cached = run.statistics(at: moment)
            #expect(cached.sentences == snapshot.sentences.count && cached.requests == snapshot.requests.count)
            #expect(cached.openNow == snapshot.openNow && cached.cardEvents == snapshot.cards.count && cached.blocks == snapshot.blocks.count)
            #expect(cached.heldBack == snapshot.gates.count)
            #expect(cached.saidNothing == snapshot.requests.filter { $0.result.contains("nothing to show") }.count)
            #expect(cached.tokenCountLabel == snapshot.tokenCountLabel && cached.tokenUsageDetail == snapshot.tokenUsageDetail)
        }
    }

    @Test func replayTokensUseOnlyReportsThatHadArrivedAndPreserveUnknownCounts() throws {
        let run = try timeline([
            ["t": 1, "kind": "usage", "request_id": "a", "input_tokens": 100, "output_tokens": 10],
            ["t": 2, "kind": "usage", "request_id": "a", "input_tokens": 120, "output_tokens": 30],
            ["t": 3, "kind": "usage", "request_id": "b"],
        ])
        #expect(run.through(0).reportedTokens == nil)
        #expect(run.through(1).reportedTokens?.total == 110)
        #expect(run.through(2).reportedTokens?.total == 150 && run.through(2).usage.count == 1)
        #expect(run.through(3).unreportedCalls == 1 && run.through(3).tokenCountLabel.hasPrefix("≥ "))
        #expect(run.through(1).reportedTokens?.total == 110)
        for moment in [0.0, 1, 2, 3, 1] {
            #expect(run.statistics(at: moment).tokenCountLabel == run.through(moment).tokenCountLabel)
            #expect(run.statistics(at: moment).tokenUsageDetail == run.through(moment).tokenUsageDetail)
        }
    }

    @Test func replayCheckpointsSkipUnchangedFramesAndPreserveHistoricalCorrections() throws {
        let run = try timeline([
            ["t": 1, "kind": "sentence", "id": 1, "start_ms": 0, "end_ms": 500, "text": "First wording"],
            ["t": 2, "kind": "card_started", "card": 1, "sentence": 1, "layer": "fast"],
            ["t": 3, "kind": "card_text", "card": 1, "text": "Alpha\nFirst answer."],
            ["t": 4, "kind": "sentence", "id": 1, "start_ms": 0, "end_ms": 500, "text": "Corrected wording"],
            ["t": 5, "kind": "card_text", "card": 1, "text": "\nAn additional fact."],
        ])
        #expect(run.cardCheckpoint(at: 3) == run.cardCheckpoint(at: 4.99))
        #expect(run.cardCheckpoint(at: 5) > run.cardCheckpoint(at: 4.99))
        #expect(run.transcriptCheckpoint(at: 1) == run.transcriptCheckpoint(at: 3.99))
        #expect(run.heard(by: 0.9).isEmpty)
        #expect(run.heard(by: 3.99).first?.text == "First wording")
        #expect(run.heard(by: 4).first?.text == "Corrected wording")
        #expect(run.heard(by: 1).first?.text == "First wording")
    }

    @Test func legacyReplayCountsHistoricalOpenRequestsWithoutInventingUsage() throws {
        let run = try timeline([
            ["t": 1, "kind": "request", "agent": "draft", "sentence": 1],
            ["t": 3, "kind": "layer", "name": "3 · a", "sentence": 1, "detail": "first draft, shown"],
        ])
        #expect(run.through(2).openNow == 1 && run.through(2).requests[0].result == "open")
        #expect(run.through(3).openNow == 0 && run.through(3).requests[0].result == "first draft, shown")
        #expect(run.through(3).reportedTokens == nil)
    }

    @Test func concurrentRequestsAreJoinedByIDAndLegacyMarkersDoNotDuplicateThem() throws {
        let run = try timeline([
            ["t": 1, "kind": "request", "agent": "draft", "model": "a", "sentence": 1],
            ["t": 1.1, "kind": "model_request", "request_id": "a", "agent": "draft", "model": "chatgpt/a", "sentence": 1, "instructions": "Rules A", "input": "Input A"],
            ["t": 1.2, "kind": "model_request", "request_id": "b", "agent": "draft", "model": "chatgpt/b", "sentence": 1, "instructions": "Rules B", "input": "Input B"],
            ["t": 3, "kind": "usage", "request_id": "b", "outcome": "completed", "response": "Raw B", "input_tokens": 20, "output_tokens": 4],
            ["t": 3.1, "kind": "layer", "name": "3 · b", "sentence": 1, "detail": "first draft, shown"],
            ["t": 4, "kind": "usage", "request_id": "a", "outcome": "completed", "response": "Raw A", "input_tokens": 30, "output_tokens": 5],
            ["t": 4.1, "kind": "layer", "name": "3 · a", "sentence": 1, "detail": "draft"],
        ])
        #expect(run.requests.count == 2 && run.openNow == 0)
        #expect(run.requests[0].response == "Raw A" && run.requests[0].input == "Input A" && run.requests[0].end == 4)
        #expect(run.requests[1].response == "Raw B" && run.requests[1].input == "Input B" && run.requests[1].end == 3)
        #expect(run.requests[0].result == "draft" && run.requests[1].result == "first draft, shown")
        #expect(run.reportedTokens?.total == 59)
        let sections = run.requests[0].details(sentences: [], cards: [])
        #expect(sections.first { $0.title == "Instructions" }?.text == "Rules A")
        #expect(sections.first { $0.title == "Response" }?.text == "Raw A")
    }

    @Test func aLegacyInspectorShowsAvailableCardsWithoutInventingPromptsOrRawReplies() throws {
        let run = try timeline([
            ["t": 1, "kind": "request", "agent": "draft", "model": "a", "sentence": 1],
            ["t": 2, "kind": "layer", "name": "3 · a", "sentence": 1, "detail": "first draft, shown"],
            ["t": 2, "kind": "card_started", "card": 1, "sentence": 1, "layer": "fast"],
            ["t": 2.1, "kind": "card_text", "card": 1, "text": "Title\nThe full recorded card."],
        ])
        let sections = try #require(run.requests.first).details(sentences: run.sentences, cards: run.cards)
        #expect(sections.first { $0.title == "Instructions" }?.text == "Not recorded for this run.")
        #expect(sections.first { $0.title == "Response" }?.text == "Not recorded for this run.")
        #expect(sections.first { $0.title == "Cards for the same transcript segment" }?.text.contains("The full recorded card.") == true)
    }

    @Test func oldRecordingsDoNotPretendToHaveUsedZeroTokens() throws {
        let old = try timeline([["t": 1, "kind": "request", "model": "test"]])
        #expect(old.reportedTokens == nil && old.tokenCountLabel == "—")
        let zero = try timeline([["t": 1, "kind": "usage", "request_id": "a", "input_tokens": 0, "output_tokens": 0]])
        #expect(zero.reportedTokens?.total == 0 && zero.tokenCountLabel == "0")
    }

    @Test func theSummaryUsageIsSavedAfterRecordingStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try #require(RunRecorder(topic: "Token test", language: "de", root: root))
        recorder.finish()
        let engine = AnswerEngine(client: Chunks(values: [.text("- A note"), .usage(TokenUsage(input: 20, output: 4))]), settings: .init())
        engine.onLog = { [recorder] kind, fields in recorder.logModelEvent(kind, fields) }
        _ = await engine.summarise(String(repeating: "A sentence with enough words. ", count: 8))
        let run = RunTimeline(folder: recorder.directory)
        #expect(run.reportedTokens?.total == 24)
        #expect(run.requests.count == 1 && run.requests.first?.agent == "summary")
        #expect(run.requests.first?.response == "- A note")
        #expect(try Data(contentsOf: recorder.directory.appending(path: "audio.wav")).count == 44,
                "late accounting does not reopen or modify the audio")
    }

    @Test func aRecordedQuoteKeepsItsEvidenceAndStableSubjectInReplay() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "quote-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try #require(RunRecorder(topic: "Quote test", language: "de", root: root))
        recorder.log(.cardStarted(CardStart(generationID: 99, kind: .fast, style: .answer,
            triggerSegment: 12, sourceCard: nil, contextVersion: 1, mappingVersion: 0, evidenceSegment: 12, blockID: 42)))
        recorder.log(.cardDelta(generationID: 99, text: "Joined\n**“2005.”**"))
        recorder.log("landed", ["card": 99, "block": 42, "version": 1, "sentence": 12])
        recorder.finish()
        let run = RunTimeline(folder: recorder.directory)
        let block = try #require(run.blocks(at: 100).first)
        #expect(block.id == 42 && block.current.start.evidenceSegment == 12)
        #expect(CardEvidence.of(block.current) == .conversation)
    }

    @Test func replayDoesNotShowTheFocusBeforeItsCardTextArrives() throws {
        let run = try timeline([
            ["t": 1, "kind": "card_started", "card": 1, "sentence": 1, "layer": "fast", "focus_text": "Alpha\nNew useful answer."],
            ["t": 2, "kind": "card_text", "card": 1, "text": "Alpha\nEarlier fact.\nNew useful answer."],
        ])
        #expect(run.blocks(at: 1.5).isEmpty)
        let card = try #require(run.blocks(at: 2.5).first?.current)
        #expect(card.start.focusText == "Alpha\nNew useful answer.")
    }
}

/// Replies with a fixed text per model, after an optional delay.
private struct ScriptedClient: ModelClient {
    var replies: [String: String]
    var delays: [String: Duration] = [:]

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if let delay = delays[model] { try? await Task.sleep(for: delay) }
                guard let reply = replies[model] else {
                    continuation.finish(throwing: CocoaError(.featureUnsupported))
                    return
                }
                continuation.yield(.text(reply))
                continuation.yield(.cost(0.001))
                continuation.finish()
            }
        }
    }
}

@MainActor
@Suite struct AnswerEngineRounds {
    private func segment(_ id: UInt64, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            segmentID: id, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: text, startMs: 0, endMs: 0)
    }

    private func engine(_ client: ScriptedClient, drafters: [String], merger: String = "merge") -> (AnswerEngine, () -> [ServerEvent]) {
        var settings = AnswerEngine.Settings()
        settings.drafters = drafters
        settings.merger = merger
        settings.pause = .milliseconds(10)
        let engine = AnswerEngine(client: client, settings: settings)
        final class Box { var events: [ServerEvent] = [] }
        let box = Box()
        engine.emit = { box.events.append($0) }
        return (engine, { box.events })
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func aFinishedConversationIsSummarisedAsBullets() async {
        let talk = String(repeating: "Anna: Wir verschieben den Lasttest auf Dienstag. ", count: 6)
        let (summariser, _) = engine(
            ScriptedClient(replies: ["merge": "Here are the notes:\n- - Lasttest auf Dienstag verschoben\n* Offen: wer ihn fährt"]),
            drafters: ["a"])
        #expect(await summariser.summarise(talk) == "- Lasttest auf Dienstag verschoben\n- Offen: wer ihn fährt")
        #expect(await summariser.summarise("Hallo zusammen") == nil, "too little was said")
        let (failing, _) = engine(ScriptedClient(replies: [:]), drafters: ["a"])
        #expect(await failing.summarise(talk) == nil)
    }

    @Test func aGatedModelIsAskedFirstWhetherThereIsAnythingToShow() async {
        // The scripted client gives the same reply to both questions: without "YES" in it, no card.
        var settings = AnswerEngine.Settings()
        settings.drafters = ["small"]
        settings.gated = ["small"]
        settings.pause = .milliseconds(10)
        let silent = AnswerEngine(client: ScriptedClient(replies: ["small": "Wetter\nSchön heute"]), settings: settings)
        var cards = 0
        silent.emit = { if case .cardStarted = $0 { cards += 1 } }
        silent.heard(segment(1, "Das Wetter ist heute wirklich schön"), isMine: false)
        await silent.idle()
        #expect(cards == 0)

        let speaking = AnswerEngine(client: ScriptedClient(replies: ["small": "YES Eiffelturm\n330 Meter"]), settings: settings)
        speaking.emit = { if case .cardStarted = $0 { cards += 1 } }
        speaking.heard(segment(1, "Wie hoch ist der Eiffelturm nochmal"), isMine: false)
        await speaking.idle()
        #expect(cards == 1)
    }

    @Test func aCardActionReplacesTheCardWithANewVersion() async {
        let (acted, events) = engine(
            ScriptedClient(replies: ["a": "Eiffelturm\nDer Turm ist 330 Meter hoch und steht in Paris.", "merge": "Eiffelturm\n**330 m**"]),
            drafters: ["a"])
        acted.heard(segment(1, "Wie hoch ist der Eiffelturm nochmal"), isMine: false)
        await acted.idle()
        #expect(acted.act(.shorter, on: 1))
        #expect(!acted.act(.shorter, on: 99), "an unknown card cannot be acted on")
        await acted.idle()
        let all = events()
        #expect(all.contains { if case .cardStarted(let start) = $0 { start.style == .shorter && start.sourceCard == 1 } else { false } })
        #expect(all.contains { if case .cardSuperseded(1, by: 2) = $0 { true } else { false } })
    }

    @Test func linesThatOnlySayNothingIsKnownAreDropped() {
        #expect(AnswerEngine.card(from: "Wetter heute\nSonne scheint stark.\nKeine weiteren Daten verfügbar.") == "**Wetter heute**\nSonne scheint stark.")
        #expect(AnswerEngine.card(from: "**keine** Informationen verfügbar**") == nil)
        #expect(AnswerEngine.card(from: "**keine passende Information**") == nil)
        #expect(AnswerEngine.card(from: "Ergebnis\nKeine klare Zahl vorhanden.\n(Datum unsicher)") == nil)
        #expect(AnswerEngine.card(from: "GTA 6\nErscheint im Herbst, das genaue Datum ist nicht bekannt gegeben worden, sagt der Hersteller auf seiner Seite.") != nil)
        #expect(AnswerEngine.card(from: "Eiffelturm") == "**Eiffelturm**", "a title alone is still a card")
    }

    @Test func aNewSubjectGetsItsOwnCardAndAnUpdateReplaces() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        final class Script: ModelClient, @unchecked Sendable {
            var replies = ["iPhone\nErschien 2007.", "Programmiersprachen\nSwift und Objective-C.", "UPDATE\nProgrammiersprachen\nSwift, Objective-C und C++."]
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                let reply = replies.isEmpty ? "NO_ANSWER" : replies.removeFirst()
                return AsyncThrowingStream { $0.yield(.text(reply)); $0.finish() }
            }
        }
        let talk = AnswerEngine(client: Script(), settings: settings)
        var events: [ServerEvent] = []
        talk.emit = { events.append($0) }
        talk.heard(segment(1, "Wann ist das iPhone erschienen"), isMine: false)
        await talk.idle()
        talk.heard(segment(2, "Welche Programmiersprachen gibt es dafür"), isMine: false)
        await talk.idle()
        #expect(!events.contains { if case .cardSuperseded = $0 { true } else { false } }, "the first card stays")
        talk.heard(segment(3, "Und sonst noch welche Sprachen"), isMine: false)
        await talk.idle()
        #expect(events.contains { if case .cardSuperseded(2, by: 3) = $0 { true } else { false } })
    }

    @Test func theWebCardTakesTheDraftsPlaceAndLinksOnlyWhatWasFound() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.researcher = "deep+web"
        settings.system.agents.webAfterDraft = false
        settings.pause = .milliseconds(10)
        struct Web: ModelClient {
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                AsyncThrowingStream { continuation in
                    Task {
                        if model == "deep+web" {
                            try? await Task.sleep(for: .milliseconds(80))
                            continuation.yield(.source("https://developer.apple.com/support/app-store/?utm_source=openai"))
                            continuation.yield(.text("iOS-Verteilung\n**54 %** nutzen iOS 26. ([developer.apple.com](https://developer.apple.com/support/app-store/?utm_source=openai))\n\n[Erfunden](https://invented.example/x)\n```chart\ntitle: iOS\nunit: %\niOS 26: 54\niOS 18: 31\n```"))
                        } else {
                            continuation.yield(.text("iOS-Verteilung\nApple veröffentlicht Zahlen."))
                        }
                        continuation.finish()
                    }
                }
            }
        }
        let talk = AnswerEngine(client: Web(), settings: settings)
        var texts: [String] = []
        var superseded = false
        var checking: [Bool] = []
        talk.emit = { event in
            if case .cardDelta(_, let text) = event { texts.append(text) }
            if case .cardSuperseded(1, by: 2) = event { superseded = true }
        }
        talk.onChecking = { _, running in checking.append(running) }
        talk.heard(segment(1, "Wie ist die Verteilung der iOS Versionen"), isMine: false)
        await talk.idle()
        #expect(superseded, "the checked card takes the draft's place")
        #expect(checking == [true, false])
        let final = texts.last ?? ""
        #expect(final.contains("**54 %** nutzen iOS 26.\n"), "the citation left the line")
        #expect(final.contains("Quellen: [developer.apple.com](https://developer.apple.com/support/app-store/)"))
        #expect(!final.contains("invented.example") && !final.contains("Erfunden"), "a source the search did not report is dropped")
        let chart = CardChart.split(final).chart
        #expect(chart?.rows.map(\.label) == ["iOS 26", "iOS 18"])
    }

    @Test func aReplyNamesTheBlockItContinues() {
        #expect(AnswerEngine.updatedBlock(in: "UPDATE 2\nTitel\nText", of: [10, 11, 12]) == 11)
        #expect(AnswerEngine.updatedBlock(in: "UPDATE\nTitel\nText", of: [10, 11, 12]) == 12, "no number: the newest block")
        #expect(AnswerEngine.updatedBlock(in: "UPDATE 9\nTitel", of: [10, 11]) == 11)
        #expect(AnswerEngine.updatedBlock(in: "Titel\nText", of: [10, 11]) == nil, "a new subject is a new block")
        #expect(AnswerEngine.card(from: "UPDATE 2\nSwift\nSeit 2014.") == "**Swift**\nSeit 2014.")
    }

    /// A real German interview, 16 November 2026: the reply opened with "**UPDATE 1**", the card
    /// was titled "UPDATE 1" and stood beside its block instead of updating it.
    @Test func theUpdateLineMaySitInMarkdown() {
        let blocks: [UInt64] = [10, 11, 12]
        #expect(AnswerEngine.updatedBlock(in: "**UPDATE 1**\niPhone\nErschien 2007.", of: blocks) == 10)
        #expect(AnswerEngine.card(from: "**UPDATE 1**\niPhone\nErschien 2007.") == "**iPhone**\nErschien 2007.")
        #expect(AnswerEngine.updatedBlock(in: "**UPDATE**\n**iPhone**\nErschien 2007.", of: blocks) == 12, "no number: the newest block")
        #expect(AnswerEngine.card(from: "**UPDATE**\n**iPhone**\nErschien 2007.") == "**iPhone**\nErschien 2007.")
        for header in ["*UPDATE 2*", "__UPDATE [2]__", "## UPDATE 2", "**UPDATE** 2", "**UPDATE 2:**", "UPDATE [2]", "UPDATE 2:", " **UPDATE 2** "] {
            #expect(AnswerEngine.updatedBlock(in: header + "\nSwift\nSeit 2014.", of: blocks) == 11, "\(header)")
            #expect(AnswerEngine.card(from: header + "\n\nSwift\nSeit 2014.") == "**Swift**\nSeit 2014.", "\(header)")
        }
        #expect(AnswerEngine.updatedBlock(in: "**UPDATE 9**\nTitel", of: blocks) == 12, "an unknown number: the newest block")
        #expect(AnswerEngine.card(from: "**UPDATE 1**") == nil, "the line alone is no card")
        // The card itself is not touched: emphasis and numbers in it stay.
        #expect(AnswerEngine.card(from: "**UPDATE 1**\niPhone\n**2007** in den USA, _UPDATE 2_ folgte.") == "**iPhone**\n**2007** in den USA, _UPDATE 2_ folgte.")
    }

    @Test func anOrdinaryTitleIsNotAnUpdateLine() {
        let blocks: [UInt64] = [10, 11]
        for title in ["Updated software", "Update on the conference", "**Update on the conference**", "UPDATE on the conference", "UPDATED software", "**UPDATE 2 of the plan**", "Updates"] {
            #expect(AnswerEngine.updatedBlock(in: title + "\nText dazu.", of: blocks) == nil, "\(title)")
            #expect(AnswerEngine.updateHeader(in: title + "\nText dazu.") == nil, "\(title)")
            let plain = title.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            #expect(AnswerEngine.card(from: title + "\nText dazu.") == "**\(plain)**\nText dazu.", "\(title)")
        }
        #expect(AnswerEngine.updatedBlock(in: "Titel\nUPDATE 1\nText", of: blocks) == nil, "only the first line routes")
    }

    @Test func aMarkdownUpdateLandsInTheNamedBlockAndKeepsItsSources() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        let sources = "Quellen: [apple.com](https://www.apple.com/newsroom/a/)"
        let reply = "**UPDATE 1**\niPhone\nErschien 2007, in Deutschland im November.\n\n" + sources
        let talk = AnswerEngine(client: ScriptedClient(replies: ["a": reply]), settings: settings)
        var events: [ServerEvent] = []
        talk.emit = { events.append($0) }
        talk.restore([["**iPhone**\nErschien 2007.\n\n" + sources], ["**Swift**\nSeit 2014."]])
        talk.heard(segment(1, "Und wann kam das iPhone nach Deutschland"), isMine: false)
        await talk.idle()
        #expect(events.contains(.cardSuperseded(generationID: 1, by: 3)), "the first block is the one named")
        #expect(events.filter { if case .cardSuperseded = $0 { true } else { false } }.count == 1, "the other block stays")
        let texts = cardTexts(events)
        #expect(texts.count == 3, "two blocks, one of them in two versions: no card beside them")
        let updated = texts.last ?? ""
        #expect(updated.hasPrefix("**iPhone**\nErschien 2007, in Deutschland im November."), "the card's own title, not the update line")
        #expect(!updated.contains("UPDATE"))
        #expect(updated.contains("[apple.com](https://www.apple.com/newsroom/a/)"), "the block's source link is kept")
    }

    @Test func anOlderBlockIsUpdatedInPlaceWhenTheTalkReturnsToIt() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        final class Script: ModelClient, @unchecked Sendable {
            var replies = ["iPhone\nErschien 2007.", "Swift\nSeit 2014.", "UPDATE 1\niPhone\nErschien 2007, in Deutschland im November."]
            var asked: [String] = []
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                asked.append(user)
                let reply = replies.isEmpty ? "NO_ANSWER" : replies.removeFirst()
                return AsyncThrowingStream { $0.yield(.text(reply)); $0.finish() }
            }
        }
        let script = Script()
        let talk = AnswerEngine(client: script, settings: settings)
        var events: [ServerEvent] = []
        talk.emit = { events.append($0) }
        for (index, line) in ["Wann ist das iPhone erschienen", "Seit wann gibt es Swift eigentlich", "Und wann kam das iPhone nach Deutschland"].enumerated() {
            talk.heard(segment(UInt64(index + 1), line), isMine: false)
            await talk.idle()
        }
        #expect(script.asked.last?.contains("[1]\n**iPhone**") == true, "the blocks on the table are offered")
        #expect(script.asked.last?.contains("[2]\n**Swift**") == true)
        #expect(events.contains { if case .cardSuperseded(1, by: 3) = $0 { true } else { false } })
        #expect(!events.contains { if case .cardSuperseded(2, by: _) = $0 { true } else { false } }, "the other block stays")
    }

    @Test func aChartAndACodeExampleAreTakenOutOfTheText() {
        let parts = CardChart.split("**iOS**\nZahlen von Apple.\n```chart\ntitle: Anteile\nunit: %\niOS 26: 54,2 %\niOS 18: 31\nÄlter: 14.8\n```")
        #expect(parts.text == "**iOS**\nZahlen von Apple.")
        #expect(parts.chart?.title == "Anteile")
        #expect(parts.chart?.rows.map(\.value) == [54.2, 31, 14.8])
        #expect(parts.chart?.label(54.2) == "54.2 %")
        #expect(parts.chart?.full == 100, "shares are drawn against the whole")
        #expect(CardChart.split("**iOS**\n```chart\ntitle: x\nnur eine: 3\n```").chart == nil, "one row is no chart")
        let code = CardChart.split("**Schleife in Swift**\nSo zählt man bis drei:\n```swift\nfor i in 1...3 {\n    print(i)\n}\n```")
        #expect(code.text == "**Schleife in Swift**\nSo zählt man bis drei:")
        #expect(code.code == "for i in 1...3 {\n    print(i)\n}")
        #expect(code.chart == nil)
    }

    @Test func sourcesLeaveTheLinesAndStandOnceAtTheEnd() {
        let card = "**Erstes iPhone**\nVorgestellt am **9. Januar 2007**. ([apple.com](https://www.apple.com/newsroom/a/?utm_source=openai))\nIm Handel ab **29. Juni 2007**. ([apple.com](https://www.apple.com/newsroom/b/?utm_source=openai))\n\n[Apple – Vorstellung](https://www.apple.com/newsroom/a/)\n[Apple – Verkaufsstart](https://www.apple.com/newsroom/b/)"
        let tidy = LinkContext.tidy(card, found: ["https://www.apple.com/newsroom/a/?utm_source=openai", "https://www.apple.com/newsroom/b/?utm_source=openai"], sourcesLabel: "Quellen")
        #expect(tidy == "**Erstes iPhone**\nVorgestellt am **9. Januar 2007**.\nIm Handel ab **29. Juni 2007**.\n\nQuellen: [apple.com](https://www.apple.com/newsroom/a/)")
        #expect(LinkContext.plain("https://example.com/x?utm_source=openai&id=3") == "https://example.com/x?id=3")
        #expect(LinkContext.tidy("**Titel**\nText.", found: [], sourcesLabel: "Quellen") == "**Titel**\nText.")
    }

    @Test func nothingWorthShowingMakesNoCard() async {
        let (engine, events) = engine(ScriptedClient(replies: ["a": "NO_ANSWER"]), drafters: ["a"])
        engine.heard(segment(1, "Das Wetter ist heute wirklich schön"), isMine: false)
        await settle()
        #expect(!events().contains { if case .cardStarted = $0 { true } else { false } })
    }

    @Test func tooLittleSpeechAsksNobody() async {
        let (engine, events) = engine(ScriptedClient(replies: ["a": "Titel\nText"]), drafters: ["a"])
        engine.heard(segment(1, "Ja genau"), isMine: false)
        await settle()
        #expect(events().isEmpty)
    }

    /// The text of every card, in the order the cards began; a card may arrive in pieces.
    private func cardTexts(_ events: [ServerEvent]) -> [String] {
        var order: [UInt64] = []
        var texts: [UInt64: String] = [:]
        for event in events {
            if case .cardDelta(let id, let text) = event {
                if texts[id] == nil { order.append(id) }
                texts[id, default: ""] += text
            }
        }
        return order.map { texts[$0] ?? "" }
    }

    @Test func oneDraftBecomesACardWithABoldTitle() async {
        let (engine, events) = engine(ScriptedClient(replies: ["a": "Backpressure\nDer Empfänger bremst den Sender."]), drafters: ["a"])
        engine.heard(segment(1, "Wie funktioniert eigentlich Backpressure genau"), isMine: false)
        await settle()
        #expect(cardTexts(events()) == ["**Backpressure**\nDer Empfänger bremst den Sender."])
        #expect(events().contains(.cardFinished(generationID: 1)))
    }

    @Test func severalDraftsAreMergedAndTheMergeReplacesTheFirst() async {
        let client = ScriptedClient(
            replies: ["fast": "Titel\nErster Entwurf", "slow": "Titel\nZweiter Entwurf", "merge": "Titel\nZusammengeführt"],
            delays: ["slow": .milliseconds(40)])
        let (engine, events) = engine(client, drafters: ["fast", "slow"])
        engine.heard(segment(1, "Wie funktioniert eigentlich Backpressure genau"), isMine: false)
        await settle()
        #expect(cardTexts(events()) == ["**Titel**\nErster Entwurf", "**Titel**\nZusammengeführt"])
        #expect(events().contains(.cardSuperseded(generationID: 1, by: 2)))
    }

    @Test func aFailingModelDoesNotStopTheOthers() async {
        let (engine, events) = engine(ScriptedClient(replies: ["ok": "Titel\nText"]), drafters: ["broken", "ok"])
        engine.heard(segment(1, "Wie funktioniert eigentlich Backpressure genau"), isMine: false)
        await settle()
        #expect(events().contains(.cardFinished(generationID: 1)))
    }

    @Test func readsCardsAndRefusals() {
        #expect(AnswerEngine.card(from: " NO_ANSWER ") == nil)
        #expect(AnswerEngine.card(from: "") == nil)
        #expect(AnswerEngine.card(from: "UPDATE\n## Titel\nMehr") == "**Titel**\nMehr")
    }
}

struct OpenRouterPieces {
    @Test func readsStreamLines() {
        #expect(OpenRouterClient.chunks(inLine: #"data: {"choices":[{"delta":{"content":"Hal"}}]}"#) == [.text("Hal")])
        #expect(OpenRouterClient.chunks(inLine: #"data: {"choices":[],"usage":{"cost":0.0004}}"#) == [.cost(0.0004)])
        #expect(OpenRouterClient.chunks(inLine: "data: [DONE]").isEmpty)
        #expect(OpenRouterClient.chunks(inLine: ": OPENROUTER PROCESSING").isEmpty)
    }

    @Test func challengeMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        #expect(OpenRouterSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func findsTheCodeInTheCallbackRequest() {
        #expect(OpenRouterSignIn.code(inRequest: "GET /callback?code=abc-123&x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n") == "abc-123")
        #expect(OpenRouterSignIn.code(inRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
    }
}

struct CardSimilarity {
    @Test func rewordingIsNotNews() {
        #expect(Correction.similarity("**Titel** Reguliert Anfragen. Verhindert Überlastung.", "Titel reguliert Anfragen, verhindert Überlastung") >= 0.8)
        #expect(Correction.similarity("Reguliert Anfragen.", "Test mit 10.000 Verbindungen gleichzeitig.") < 0.8)
    }
}

struct FigureAssignment {
    @Test func voicesGetDifferentAnimalsAndNeverTheUsersOwn() {
        let animals = (1...7).map { Figure.forVoice(UInt32($0), mine: .fox).figure }
        #expect(Set(animals).count == 7)
        #expect(!animals.contains(.fox))
    }

    @Test func fromTheEighthVoiceAnimalsReturnInANewColour() {
        let first = Figure.forVoice(1, mine: .fox)
        let eighth = Figure.forVoice(8, mine: .fox)
        #expect(eighth.figure == first.figure)
        #expect(first.turn == 0)
        #expect(eighth.turn > 0)
    }
}

@MainActor
@Suite struct WhoIsWho {
    @Test func readsNamesFromAReply() {
        #expect(AnswerEngine.names(in: "1=Anna\n[2] = Markus.\n3=??\nNONE") == [1: "Anna", 2: "Markus"])
        #expect(AnswerEngine.names(in: "NONE").isEmpty)
    }

    @Test func namesFromTheTalkAreReportedAndTheUserIsFound() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = []
        settings.namer = "namer"
        settings.userName = "Markus Muster"
        settings.namingEvery = 2
        let engine = AnswerEngine(client: ScriptedClient(replies: ["namer": "1=Anna\n2=Markus\n9=Nobody"]), settings: settings)
        final class Box { var names: [UInt32: String] = [:]; var me: UInt32? }
        let box = Box()
        engine.onNames = { box.names = $0; box.me = $1 }
        for (id, voice, text) in [(UInt64(1), UInt32(1), "Guten Tag, ich bin Anna."), (2, 2, "Hallo Anna, ich heisse Markus.")] {
            engine.heard(TranscriptSegment(
                segmentID: id, isFinal: true, revision: 1, voice: voice, speaker: .speaker(Int(voice)), text: text,
                startMs: 0, endMs: 0), isMine: false)
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(box.names == [1: "Anna", 2: "Markus"])
        #expect(box.me == 2)
    }
}

struct RunFiles {
    @Test func wavHeaderDescribesTheSound() {
        let header = RunRecorder.header(dataBytes: 32_000)
        #expect(header.count == 44)
        #expect(String(decoding: header[0..<4], as: UTF8.self) == "RIFF")
        #expect(header[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 32_000)
        #expect(header[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 16_000)
    }
}

@Suite struct ChatGPTPlan {
    private let callback = URL(string: "http://127.0.0.1:1455/auth/callback")!

    @Test func aFirstSignInRegistersTheAppAndAsksForThePlan() throws {
        let url = ChatGPT.authorizationURL(
            callback: callback, state: "s", nonce: "n", verifier: "v", hostID: "urn:uuid:1", saved: nil)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        #expect(value("client_id") == "dynamic_agent_client")
        #expect(value("agent_name_hint") == "Listen")
        #expect(value("redirect_uri") == "http://127.0.0.1:1455/auth/callback")
        #expect(value("scope")?.contains("chatgpt.tokens.use.direct") == true)
        #expect(value("resource") == "https://api.openai.com/v1")
        #expect(value("code_challenge") == OpenRouterSignIn.challenge(for: "v"))
        #expect(value("id_token_hint") == nil)
    }

    @Test func aReturningSignInReusesTheIssuedClient() throws {
        let saved = ChatGPT.Registration(clientID: "oaiapp_1", subject: "sub", idToken: "old.id.token")
        let url = ChatGPT.authorizationURL(
            callback: callback, state: "s", nonce: "n", verifier: "v", hostID: "urn:uuid:1", saved: saved)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "client_id" }?.value == "oaiapp_1")
        #expect(items.first { $0.name == "id_token_hint" }?.value == "old.id.token")
        #expect(!items.contains { $0.name == "agent_name_hint" })
    }

    @Test func theCallbackIsReadOnlyFromItsOwnPath() {
        let request = "GET /auth/callback?code=abc&state=s&client_id=oaiapp_9&scope=openid+email HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let values = ChatGPT.callbackValues(inRequest: request)
        #expect(values["code"] == "abc")
        #expect(values["client_id"] == "oaiapp_9")
        #expect(ChatGPT.callbackValues(inRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n").isEmpty)
        #expect(ChatGPT.callbackValues(inRequest: "GET /callback?code=abc HTTP/1.1\r\n\r\n").isEmpty)
    }

    /// A token signed here with a fresh key, and the matching key set.
    private func signed(_ claims: [String: Any], kid: String = "k1") throws -> (token: String, keys: Data) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        // PKCS#1: SEQUENCE { INTEGER modulus, INTEGER exponent }; read both back out.
        let der = [UInt8](try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data)
        var index = 1
        func length() -> Int {
            var count = Int(der[index])
            index += 1
            if count & 0x80 != 0 {
                let bytes = count & 0x7f
                count = 0
                for _ in 0..<bytes {
                    count = count << 8 | Int(der[index])
                    index += 1
                }
            }
            return count
        }
        _ = length()
        func integer() -> Data {
            index += 1
            let count = length()
            defer { index += count }
            return Data(der[index..<index + count])
        }
        let modulus = integer(), exponent = integer()
        #expect(ChatGPT.rsaPublicKey(modulus: modulus, exponent: exponent) == Data(der), "our DER matches the system's")
        func part(_ object: Any) throws -> String {
            OpenRouterSignIn.base64URL(try JSONSerialization.data(withJSONObject: object))
        }
        let head = try part(["alg": "RS256", "kid": kid]) + "." + part(claims)
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(head.utf8) as CFData, nil)) as Data
        let keys = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "RSA", "kid": kid, "alg": "RS256",
            "n": OpenRouterSignIn.base64URL(modulus), "e": OpenRouterSignIn.base64URL(exponent),
        ]]])
        return (head + "." + OpenRouterSignIn.base64URL(signature), keys)
    }

    private func claims(_ changes: [String: Any] = [:]) -> [String: Any] {
        var claims: [String: Any] = [
            "iss": "https://auth.openai.com", "aud": "oaiapp_1", "sub": "user-1", "nonce": "n1",
            "exp": Date().timeIntervalSince1970 + 600, "email": "person@example.com",
        ]
        for (key, value) in changes { claims[key] = value }
        return claims
    }

    @Test func aProperlySignedIdentityIsAccepted() throws {
        let (token, keys) = try signed(claims())
        let identity = try ChatGPT.verify(idToken: token, keys: keys, clientID: "oaiapp_1", nonce: "n1")
        #expect(identity == ChatGPT.Identity(subject: "user-1", email: "person@example.com"))
    }

    @Test func aTokenThatIsForgedOrNotMeantForUsIsRejected() throws {
        let (token, keys) = try signed(claims())
        let (_, otherKeys) = try signed(claims())
        #expect(throws: ChatGPT.Failure.badToken("signature")) {
            try ChatGPT.verify(idToken: token, keys: otherKeys, clientID: "oaiapp_1", nonce: "n1")
        }
        #expect(throws: ChatGPT.Failure.badToken("audience")) {
            try ChatGPT.verify(idToken: token, keys: keys, clientID: "oaiapp_2", nonce: "n1")
        }
        #expect(throws: ChatGPT.Failure.badToken("nonce")) {
            try ChatGPT.verify(idToken: token, keys: keys, clientID: "oaiapp_1", nonce: "other")
        }
        let (old, oldKeys) = try signed(claims(["exp": Date().timeIntervalSince1970 - 3600]))
        #expect(throws: ChatGPT.Failure.badToken("expired")) {
            try ChatGPT.verify(idToken: old, keys: oldKeys, clientID: "oaiapp_1", nonce: "n1")
        }
        let (foreign, foreignKeys) = try signed(claims(["iss": "https://example.com"]))
        #expect(throws: ChatGPT.Failure.badToken("issuer")) {
            try ChatGPT.verify(idToken: foreign, keys: foreignKeys, clientID: "oaiapp_1", nonce: "n1")
        }
    }

    @Test func aRefreshKeepsWhatItDoesNotSendAgain() throws {
        let first = try #require(ChatGPT.credentials(
            fromTokenResponse: Data(#"{"access_token":"a1","refresh_token":"r1","id_token":"i1","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}"#.utf8),
            clientID: "oaiapp_1", identity: .init(subject: "user-1", email: nil), previous: nil))
        #expect(first.allowsPlan)
        var chosen = first
        chosen.model = "gpt-x"
        let renewed = try #require(ChatGPT.credentials(
            fromTokenResponse: Data(#"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#.utf8),
            clientID: "oaiapp_1", identity: nil, previous: chosen))
        #expect(renewed.accessToken == "a2")
        #expect(renewed.refreshToken == "r2")
        #expect(renewed.idToken == "i1")
        #expect(renewed.model == "gpt-x")
        #expect(renewed.allowsPlan)
        let withoutPlan = try #require(ChatGPT.credentials(
            fromTokenResponse: Data(#"{"access_token":"a","refresh_token":"r","id_token":"i","scope":"openid email"}"#.utf8),
            clientID: "oaiapp_1", identity: .init(subject: "user-1", email: nil), previous: nil))
        #expect(!withoutPlan.allowsPlan)
    }

    @Test func theRequestFollowsThePlanRoutesLimits() {
        let body = ResponsesClient.body(model: "chatgpt/gpt-x", system: "Rules", user: "Lines")
        #expect(body["model"] as? String == "gpt-x")
        #expect(body["instructions"] as? String == "Rules")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(Set(body.keys) == ["model", "instructions", "input", "store", "stream"], "no field the route rejects")
        let web = ResponsesClient.body(model: "chatgpt/gpt-x+web", system: "Rules", user: "Lines")
        #expect(web["model"] as? String == "gpt-x")
        #expect((web["tools"] as? [[String: String]])?.first?["type"] == "web_search")
    }

    @Test func streamEventsAreRead() {
        #expect(ResponsesClient.event(inLine: #"data: {"type":"response.output_text.delta","delta":"Hal"}"#) == .text("Hal"))
        #expect(ResponsesClient.event(inLine: #"data: {"type":"response.output_text.done","text":"An opening."}"#) == .text("\n"), "separate assistant messages must not merge or wait until the whole response ends")
        #expect(ResponsesClient.event(inLine: #"data: {"type":"response.completed","response":{}}"#) == .completed)
        #expect(ResponsesClient.event(inLine: #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)
            == .failed("subscription_sharing_usage_limit_exceeded"))
        #expect(ResponsesClient.event(inLine: "event: response.created") == .other)
        #expect(ResponsesClient.citedAddresses(inLine: #"data: {"type":"response.completed","response":{"output":[{"content":[{"annotations":[{"type":"url_citation","url":"https://example.com/b"}]}]}]}}"#) == ["https://example.com/b"])
        #expect(ResponsesClient.event(inLine: #"data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://example.com/a"}}"#) == .sources(["https://example.com/a"]))
    }

    @Test func onlyModelsMeantForDisplayAreOffered() {
        let data = Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list"},{"slug":"b","visibility":"hide"}]}"#.utf8)
        let models = ChatGPT.models(in: data)
        #expect(models.map(\.slug) == ["a"])
        #expect(models.first?.name == "A")
    }
}

@Suite struct MathTextTests {
    @Test func formulasBecomePlainSigns() {
        #expect(MathText.plain(#"Punkte \((x,\text{Steigung})\) eintragen"#) == "Punkte (x,Steigung) eintragen")
        #expect(MathText.plain(#"\(f'(x) = \frac{a+b}{2} \cdot x^2\)"#) == "f'(x) = (a+b)/2 · x²")
        #expect(MathText.plain(#"$x_1 \le x_{2}$ und \[\sqrt{x} \to \infty\]"#) == "x₁ ≤ x₂ und √(x) → ∞")
        #expect(MathText.plain(#"\(e^{x+y}\), \(a^{2n}\)"#) == "e^(x+y), a²ⁿ")
    }
    @Test func ordinaryTextStaysAsItIs() {
        #expect(MathText.plain("Kostet $5 oder $7, snake_case bleibt.") == "Kostet $5 oder $7, snake_case bleibt.")
        #expect(MathText.plain("**Antwort** zuerst") == "**Antwort** zuerst")
    }
}

@MainActor
@Suite struct OneBlockPerSubject {
    private func segment(_ id: UInt64, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            segmentID: id, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: text, startMs: 0, endMs: 0)
    }

    /// The run of 15 November 2026: four sentences about one Swift question, four web
    /// look-ups in flight at once, four boxes on the table.
    @Test func sentencesDuringASlowLookUpDoNotAddBlocks() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.researcher = "deep+web"
        settings.system.agents.webAfterDraft = false
        settings.pause = .milliseconds(10)
        settings.system.scheduler.webLookupsAtOnce = 1
        final class Web: ModelClient, @unchecked Sendable {
            let lock = NSLock()
            var running = 0
            var most = 0
            var asked = 0
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                AsyncThrowingStream { continuation in
                    Task {
                        guard model == "deep+web" else {
                            continuation.yield(.text("NO_ANSWER"))
                            continuation.finish()
                            return
                        }
                        let number = self.lock.withLock {
                            self.running += 1
                            self.most = max(self.most, self.running)
                            self.asked += 1
                            return self.asked
                        }
                        try? await Task.sleep(for: .milliseconds(120))
                        self.lock.withLock { self.running -= 1 }
                        // Never says UPDATE: the engine has to see that the subject is the same.
                        continuation.yield(.text("Swift: Request mit Retry \(number)\nURLSession mit async/await.\n```swift\nfunc send() async throws {\n    try await load()\n}\n```"))
                        continuation.finish()
                    }
                }
            }
        }
        let web = Web()
        let talk = AnswerEngine(client: web, settings: settings)
        var started = 0
        var replaced = 0
        var last = ""
        talk.emit = { event in
            if case .cardStarted = event { started += 1 }
            if case .cardSuperseded = event { replaced += 1 }
            if case .cardDelta(_, let text) = event { last = text }
        }
        for (index, line) in ["Wie schreibt man in Swift einen Request", "mit async await und einem Retry", "Was wäre hier eigentlich das Beste", "Okay lass mich kurz überlegen"].enumerated() {
            talk.heard(segment(UInt64(index + 1), line), isMine: false)
            try? await Task.sleep(for: .milliseconds(40))
        }
        await talk.idle()
        #expect(web.most == 1, "one look-up at a time")
        #expect(web.asked <= 3, "sentences that arrive meanwhile share one later look-up")
        #expect(started - replaced == 1, "one block on the table")
        #expect(last.contains("\n    try await load()"), "code keeps its indentation")
    }

    @Test func cardsAboutTheSameSubjectAreRecognised() {
        let code = "```swift\nfunc send(_ request: URLRequest) async throws -> Data {\n    try await URLSession.shared.data(for: request).0\n}\n```"
        #expect(AnswerEngine.sameSubject("**HTTP-Request in Swift**\nURLSession mit async/await.\n" + code, "**Swift: Login mit Retry**\nURLSession mit async/await; Retry bei Timeout.\n" + code), "the same answer under another title")
        #expect(AnswerEngine.sameSubject("**Android-Versionen weltweit**\n**Android 16: 38 %**", "**Android-Versionen weltweit 2026**\n**25 %** nutzen Android 16."))
        // The same thing, another question: one block that collects both (runs of 15 November 2026).
        #expect(AnswerEngine.sameSubject(
            "**Cricut Joy: Marktstart**\n**1. März 2020**: Verkaufsstart des ursprünglichen Cricut Joy.",
            "**Cricut Joy: Verkaufszahlen**\n**Keine belastbare Stückzahl gefunden** für den ursprünglichen Joy."))
        #expect(AnswerEngine.sameSubject("**Klinge beim Cricut Joy**\n**Ja**: Klinge inklusive.", "**Cricut Joy: Klinge wechseln**\n**Ja, austauschbar.**"))
        #expect(AnswerEngine.sameSubject("**Klingenwechsel beim Cricut Joy**\nKein festes Intervall.", "**Cricut Joy: Ersatzklinge Preis**\n**13,19 €**"), "words built on the same stem")
        #expect(!AnswerEngine.sameSubject("**Cricut Joy: Klinge**\nAustauschbar.", "**Sekundenkleber: vollständig ausgehärtet**\n**24 Stunden**"))
        #expect(AnswerEngine.sameSubject("**iPhone auf Deutsch**\nAuch iPhone.", "**iPhone: Erscheinungsdatum**\n**29. Juni 2007**"), "titles that begin with the same subject")
        #expect(AnswerEngine.sameSubject("**Benötigte Worker**\n**100**", "**Benötigte Parallelität**\n**100 Nachrichten gleichzeitig**"))
        #expect(!AnswerEngine.sameSubject("**Aktuelle iOS-Verteilung**\n79 %", "**Aktuelle Android-Verteilung**\n25 %"), "a vague first word is not a subject")
        #expect(!AnswerEngine.sameSubject("**iOS-Verteilung auf iPhones**\n**79 % iOS 26**, 14 % iOS 18.", "**Android-Verteilung**\n**25 %** nutzen Android 16."))
    }

    @Test func aBlockDoesNotGoBackToWhatItSaidBefore() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        final class Script: ModelClient, @unchecked Sendable {
            var replies = ["Cricut Joy\nErschien am 1. März 2020.", "UPDATE 1\nCricut Joy\nKeine Verkaufszahlen veröffentlicht, nur Nutzerzahlen.", "UPDATE 1\nCricut Joy\nErschien am 1. März 2020."]
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                let reply = replies.isEmpty ? "NO_ANSWER" : replies.removeFirst()
                return AsyncThrowingStream { $0.yield(.text(reply)); $0.finish() }
            }
        }
        let talk = AnswerEngine(client: Script(), settings: settings)
        var started = 0
        talk.emit = { if case .cardStarted = $0 { started += 1 } }
        for (index, line) in ["Wann kam der Cricut Joy heraus", "Und wie viele wurden davon verkauft", "Ja genau das meine ich"].enumerated() {
            talk.heard(TranscriptSegment(segmentID: UInt64(index + 1), isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: line, startMs: 0, endMs: 0), isMine: false)
            await talk.idle()
        }
        #expect(started == 2, "the third reply repeats the first version and is dropped")
    }

    @Test func aCardIsSplitIntoItsParts() {
        let card = "**Exponential Backoff**\n**16 s** vor dem fünften Retry.\n```formula\nt_n = t_0 \\cdot 2^n\n```\nt₀: erste Wartezeit.\n\nQuellen: [aws.amazon.com](https://aws.amazon.com/x)"
        let parts = CardChart.split(card)
        #expect(parts.formula == "tₙ = t₀ · 2ⁿ")
        #expect(parts.sources == "[aws.amazon.com](https://aws.amazon.com/x)")
        #expect(parts.text == "**Exponential Backoff**\n**16 s** vor dem fünften Retry.\nt₀: erste Wartezeit.")
        #expect(parts.code == nil)
        // A formula a model set in bold on its own line stands alone too; a bold answer does not.
        let bold = CardChart.split("**Backoff**\n**t = min(t_max, t₀ × 2ⁿ)**\nn zählt ab 0.")
        #expect(bold.formula == "t = min(t_max, t₀ × 2ⁿ)")
        #expect(CardChart.split("**Backoff**\n**16 Sekunden** vor dem fünften Retry.").formula == nil)
    }
}

@Suite struct NamesFromTheTalk {
    @Test func aNameCountsOnlyWhenTheTalkIntroducesIt() {
        let talk = ["Hallo, ich bin Ruben und ich leite die App Entwicklung.", "Können Sie das erklären, Markus?", "émon, das in die Wellen wagt.", "Paris liegt an der Seine.", "Welchen Auspuff hat der BMW?", "Danke Anna."]
        #expect(AnswerEngine.isIntroduced("Ruben", in: talk))
        #expect(AnswerEngine.isIntroduced("Markus", in: talk))
        #expect(AnswerEngine.isIntroduced("Anna", in: talk))
        #expect(!AnswerEngine.isIntroduced("Paris", in: talk))
        #expect(!AnswerEngine.isIntroduced("BMW", in: talk))
        #expect(!AnswerEngine.isIntroduced("Tom", in: talk))
        #expect(AnswerEngine.introducesItself("Laura", in: ["So first of all, I'm Laura and I'm the project manager."]))
        #expect(!AnswerEngine.introducesItself("David", in: ["So that's David, Andrew and Craig, isn't it?"]), "named by someone else")
        #expect(!AnswerEngine.isIntroduced("émon", in: talk), "a line that merely starts with a word and a comma")
    }
}

@Suite struct DrawingsAndStacks {
    private func card(_ id: UInt64, replaces: UInt64? = nil, _ text: String, _ status: SessionCore.Card.Status = .finished) -> SessionCore.Card {
        var card = SessionCore.Card(start: CardStart(
            generationID: id, kind: .fast, style: .answer, triggerSegment: 1, sourceCard: replaces, contextVersion: 0, mappingVersion: 0))
        card.text = text
        card.status = status
        return card
    }

    @Test func aBlockKeepsItsEarlierVersionsUnderIt() {
        let blocks = CardBlocks.blocks(from: [
            card(1, "**Karte**\nerste Fassung", .superseded),
            card(2, "**Stern**\nSVG"),
            card(3, replaces: 1, "**Karte**\nzweite Fassung", .superseded),
            card(4, replaces: 3, "**Karte**\ndritte Fassung"),
            card(5, "**Weg**\nverworfen", .cancelled),
        ])
        #expect(blocks.map(\.id) == [1, 2], "one block per subject, in the order they came up")
        #expect(blocks[0].versions.map(\.id) == [1, 3, 4])
        #expect(blocks[0].current.text.contains("dritte"))
        #expect(blocks[1].versions.count == 1)
    }

    @Test func anSVGIsDrawnAndCannotAct() {
        let star = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"10mm\" viewBox=\"0 0 100 100\">\n  <polygon points=\"50,0 61,35\" onclick=\"steal()\"/>\n<script>alert(1)</script><image href=\"https://x.example/a.png\"/></svg>"
        let parts = CardChart.split("**Stern**\nAls Vorlage.\n```svg\n\(star)\n```")
        #expect(parts.drawing == star, "a complete SVG is drawn as well as shown")
        #expect(CardChart.split("**Code**\n```swift\nlet a = 1\n```").drawing == nil)
        let safe = CardDrawingView.harmless(star)
        #expect(!safe.contains("script") && !safe.contains("onclick") && !safe.contains("x.example") && !safe.contains("<image"))
        #expect(safe.contains("<polygon points=\"50,0 61,35\"/>"))
        #expect(CardDrawingView.page(star).contains("default-src 'none'"))
        #expect(CardDrawingView.harmless("<svg width=\"40\" height=\"20\"><rect/></svg>").contains("viewBox=\"0 0 40 20\""))
    }

    @Test func anAddressInsideCodeStays() {
        let card = "**Stern**\nSiehe https://unknown.example/x und das.\n```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\">\n  <rect/>\n</svg>\n```"
        let kept = LinkContext.keepingOnlyLinks(to: [], in: card)
        #expect(kept.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(kept.contains("\n  <rect/>"), "and the code keeps its indentation")
        #expect(!kept.contains("unknown.example"), "prose still loses an address nobody gave")
    }
}

@MainActor
@Suite struct DraftsAppearWhileWritten {
    @Test func aNewCardIsShownLineByLine() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        struct Slow: ModelClient {
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                AsyncThrowingStream { continuation in
                    Task {
                        for piece in ["CAP-Theorem\n", "**Konsistenz oder Verfügbarkeit**", " bei Netzpartition.\n", "Nicht beides zugleich."] {
                            continuation.yield(.text(piece))
                            try? await Task.sleep(for: .milliseconds(40))
                        }
                        continuation.finish()
                    }
                }
            }
        }
        let talk = AnswerEngine(client: Slow(), settings: settings)
        var events: [String] = []
        var text = ""
        talk.emit = { event in
            switch event {
            case .cardStarted: events.append("start")
            case .cardDelta(_, let piece): events.append("delta"); text += piece
            case .cardFinished: events.append("finish")
            default: break
            }
        }
        talk.heard(TranscriptSegment(segmentID: 1, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: "Was sagt das CAP Theorem aus", startMs: 0, endMs: 0), isMine: false)
        await talk.idle()
        #expect(events == ["start", "delta", "delta", "finish", "delta"] || events == ["start", "delta", "delta", "delta", "finish"] || events.filter { $0 == "delta" }.count >= 2, "the title came before the rest")
        #expect(events.filter { $0 == "start" }.count == 1, "one card, written in pieces")
        #expect(text == "**CAP-Theorem**\n**Konsistenz oder Verfügbarkeit** bei Netzpartition.\nNicht beides zugleich.")
    }
}

/// Holds a reply back until the test lets it go on.
private final class Gate: Sendable {
    private let pair = AsyncStream.makeStream(of: Void.self)
    func open() {
        pair.continuation.yield()
        pair.continuation.finish()
    }
    func wait() async { for await _ in pair.stream { break } }
}

/// One reply per request, in order: the first pieces are sent at once, the rest when the gate opens.
private final class GatedScript: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(first: [String], rest: [String])]
    private var held = false
    let gate = Gate()

    init(_ replies: [(first: [String], rest: [String])]) { self.replies = replies }

    /// A reply has sent its first pieces and waits at the gate.
    var holding: Bool { lock.withLock { held } }

    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        let silent: (first: [String], rest: [String]) = (["NO_ANSWER"], [])
        let reply = lock.withLock { replies.isEmpty ? silent : replies.removeFirst() }
        return AsyncThrowingStream { continuation in
            Task { [gate] in
                for piece in reply.first { continuation.yield(.text(piece)) }
                if !reply.rest.isEmpty {
                    self.lock.withLock { self.held = true }
                    await gate.wait()
                    for piece in reply.rest { continuation.yield(.text(piece)) }
                }
                continuation.finish()
            }
        }
    }
}

@MainActor
@Suite struct UpdatesAppearWhileWritten {
    private let base = "**iPhone**\nErschien 2007."
    private let added = "In Deutschland kam es im November 2007 über die Telekom in den Handel."
    private let last = "Preis damals: 399 Euro mit Vertrag."

    private func segment(_ id: UInt64, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            segmentID: id, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: text, startMs: 0, endMs: 0)
    }

    private func text(of card: UInt64, in events: [ServerEvent]) -> String {
        events.reduce(into: "") { if case .cardDelta(card, let piece) = $1 { $0 += piece } }
    }

    private func started(_ events: [ServerEvent]) -> [CardStart] {
        events.compactMap { event -> CardStart? in
            if case .cardStarted(let start) = event { return start }
            return nil
        }
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The first card, then a second sentence whose reply is held at the gate after `first`.
    private func talk(update first: [String], streamDrafts: Bool = true) async -> (AnswerEngine, GatedScript, () -> [ServerEvent]) {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        settings.system.agents.streamDrafts = streamDrafts
        let script = GatedScript([(["iPhone\nErschien 2007."], []), (first, [last])])
        let engine = AnswerEngine(client: script, settings: settings)
        final class Box { var events: [ServerEvent] = [] }
        let box = Box()
        engine.emit = { box.events.append($0) }
        engine.heard(segment(1, "Wann ist das iPhone erschienen"), isMine: false)
        await engine.idle()
        engine.heard(segment(2, "Und wann kam das iPhone nach Deutschland"), isMine: false)
        return (engine, script, { box.events })
    }

    @Test func anUpdateThatOnlyAddsIsWrittenIntoItsBlock() async {
        let (engine, script, events) = await talk(update: ["UPDATE 1\niPhone\nErschien 2007.\n", added + "\n"])
        await until { events().contains(.cardSuperseded(generationID: 1, by: 2)) }
        // The model has not finished: its last line is still behind the gate.
        #expect(script.holding)
        #expect(text(of: 2, in: events()) == base + "\n" + added, "the block as it stood and the first whole new line")
        #expect(started(events()).last?.sourceCard == 1, "a version of the same block")
        #expect(!events().contains(.cardFinished(generationID: 2)), "not finished while the model writes")
        script.gate.open()
        await engine.idle()
        let all = events()
        #expect(text(of: 2, in: all) == base + "\n" + added + "\n" + last)
        #expect(text(of: 1, in: all) == base, "the earlier version keeps its text")
        #expect(started(all).map(\.generationID) == [1, 2], "one block, two versions: no card beside it")
        #expect(all.filter { $0 == .cardFinished(generationID: 2) }.count == 1)
        #expect(all.filter { if case .cardSuperseded = $0 { true } else { false } } == [.cardSuperseded(generationID: 1, by: 2)])
    }

    /// The update line in Markdown, as in the interview of 16 November 2026: the same block,
    /// written while the reply arrives, and no card titled "UPDATE 1" beside it.
    @Test func anAddingUpdateWithAMarkdownUpdateLineIsWrittenIntoItsBlock() async {
        for header in ["**UPDATE 1**", "**UPDATE**"] {
            let (engine, script, events) = await talk(update: [header + "\niPhone\nErschien 2007.\n", added + "\n"])
            await until { events().contains(.cardSuperseded(generationID: 1, by: 2)) }
            #expect(script.holding, "\(header)")
            #expect(text(of: 2, in: events()) == base + "\n" + added, "\(header): the block as it stood and the first whole new line")
            #expect(started(events()).last?.sourceCard == 1, "\(header): a version of the same block")
            #expect(!events().contains(.cardFinished(generationID: 2)), "\(header): not finished while the model writes")
            script.gate.open()
            await engine.idle()
            let all = events()
            #expect(text(of: 2, in: all) == base + "\n" + added + "\n" + last, "\(header)")
            #expect(text(of: 1, in: all) == base, "\(header): the earlier version keeps its text")
            #expect(started(all).map(\.generationID) == [1, 2], "\(header): one block, two versions")
            #expect(all.filter { $0 == .cardFinished(generationID: 2) }.count == 1, "\(header)")
            #expect(all.filter { if case .cardSuperseded = $0 { true } else { false } } == [.cardSuperseded(generationID: 1, by: 2)], "\(header)")
        }
    }

    @Test func anUpdateThatChangesALineWaitsForTheWholeReply() async {
        let changed = "Erschien am 29. Juni 2007 in den USA."
        let (engine, script, events) = await talk(update: ["UPDATE 1\niPhone\n" + changed + "\n", added + "\n"])
        await until { script.holding }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(started(events()).map(\.generationID) == [1], "half a replacement is not shown")
        #expect(!events().contains { if case .cardSuperseded = $0 { true } else { false } })
        script.gate.open()
        await engine.idle()
        let all = events()
        #expect(all.contains(.cardSuperseded(generationID: 1, by: 2)))
        #expect(started(all).map(\.generationID) == [1, 2])
        #expect(text(of: 2, in: all) == "**iPhone**\n" + changed + "\n" + added + "\n" + last)
        #expect(text(of: 1, in: all) == base)
    }

    @Test func withStreamingOffAnAddingUpdateWaitsToo() async {
        let (engine, script, events) = await talk(update: ["UPDATE 1\niPhone\nErschien 2007.\n", added + "\n"], streamDrafts: false)
        await until { script.holding }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(started(events()).map(\.generationID) == [1])
        #expect(!events().contains { if case .cardSuperseded = $0 { true } else { false } })
        script.gate.open()
        await engine.idle()
        let all = events()
        #expect(all.contains(.cardSuperseded(generationID: 1, by: 2)))
        #expect(started(all).map(\.generationID) == [1, 2])
        #expect(text(of: 2, in: all) == base + "\n" + added + "\n" + last)
    }
}

@Suite struct SystemConfiguration {
    private func place() -> (URL, UserDefaults) {
        let file = FileManager.default.temporaryDirectory.appending(path: "system-\(UUID().uuidString).json")
        return (file, UserDefaults(suiteName: "system-\(UUID().uuidString)")!)
    }

    @Test func theFileIsWrittenOnceAndHoldsEveryPrompt() throws {
        let (file, memory) = place()
        defer { try? FileManager.default.removeItem(at: file) }
        let first = SystemConfig.load(from: file, remembering: memory)
        #expect(first.config == SystemConfig() && !first.edited && first.problem == nil)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"cardRules\"") && text.contains("\"speakerWindowSeconds\"") && text.contains("\"questionPauseSeconds\""))
        #expect(text.contains("{NOTHING}"), "placeholders stay in the file and are filled when a prompt is sent")
        #expect(SystemConfig.filled("reply {NOTHING} or {UPDATE} in {LANGUAGE}", language: .de) == "reply NO_ANSWER or UPDATE in German")
    }

    @Test func aChangedFileIsUsedAndKeepsWhatItDoesNotName() throws {
        let (file, memory) = place()
        defer { try? FileManager.default.removeItem(at: file) }
        _ = SystemConfig.load(from: file, remembering: memory)
        try #"{"scheduler": {"pauseSeconds": 0.5}, "agents": {"web": false}, "prompts": {"gate": "Say YES."}, "unknown": 1}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let changed = SystemConfig.load(from: file, remembering: memory)
        #expect(changed.edited && changed.problem == nil)
        #expect(changed.config.scheduler.pauseSeconds == 0.5 && changed.config.scheduler.minimumWords == 4)
        #expect(!changed.config.agents.web && changed.config.agents.merge)
        #expect(changed.config.prompts.gate == "Say YES." && changed.config.prompts.merge == SystemConfig().prompts.merge)
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        let broken = SystemConfig.load(from: file, remembering: memory)
        #expect(broken.config == SystemConfig() && broken.problem != nil, "a broken file never stops a conversation")
        try #"{"scheduler": {"pauseSeconds": "soon"}}"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(SystemConfig.load(from: file, remembering: memory).problem != nil)
        SystemConfig.reset(file: file, remembering: memory)
        #expect(!SystemConfig.load(from: file, remembering: memory).edited)
    }

    /// docs/system.default.json is the built-in configuration for reading in the repository.
    /// After changing a default, write it again: ios/Tools/transcribe-check/.build/release/check system > docs/system.default.json
    @Test func theCopyInDocsIsTheBuiltInConfiguration() throws {
        let copy = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/system.default.json")
        guard let text = try? String(contentsOf: copy, encoding: .utf8) else { return }  // not in a checkout
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == SystemConfig().json)
    }

    @MainActor @Test func thePromptsThatAreSentAreTheOnesInTheFile() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        settings.system.prompts.cardRules = "RULES FROM THE FILE. Say {NOTHING} when there is nothing. Write in {LANGUAGE}."
        final class Spy: ModelClient, @unchecked Sendable {
            var systems: [String] = []
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                systems.append(system)
                return AsyncThrowingStream { $0.yield(.text("NO_ANSWER")); $0.finish() }
            }
        }
        let spy = Spy()
        let talk = AnswerEngine(client: spy, settings: settings)
        talk.heard(TranscriptSegment(segmentID: 1, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: "Wie funktioniert eigentlich Backpressure genau", startMs: 0, endMs: 0), isMine: false)
        await talk.idle()
        #expect(spy.systems == ["RULES FROM THE FILE. Say NO_ANSWER when there is nothing. Write in German."])
    }
}

@MainActor
@Suite struct ABlockGrows {
    @Test func answersAboutTheSameThingAreCollected() {
        let block = "**Klinge beim Cricut Joy**\n**Ja – Klinge inklusive.**\nNach dem Zeichnen: Stift herausnehmen, Klinge einsetzen.\n\nQuellen: [help.cricut.com](https://help.cricut.com/a)"
        let more = "**Cricut Joy: Klingenwechsel**\n**Kein festes Wechselintervall** – abhängig von der Nutzung.\nNach dem Zeichnen: Stift herausnehmen und Klinge einsetzen.\n\nQuellen: [cricut.com](https://cricut.com/b)\n\n```chart\ntitle: x\nA: 1\nB: 2\n```"
        let grown = AnswerEngine.aggregate(block, with: more, sourcesLabel: "Quellen")
        #expect(grown.hasPrefix("**Klinge beim Cricut Joy**\n**Ja – Klinge inklusive.**\nNach dem Zeichnen: Stift herausnehmen, Klinge einsetzen.\n**Kein festes Wechselintervall** – abhängig von der Nutzung."), "what it said stays, the new answer is added, a line said twice is not")
        #expect(grown.contains("Quellen: [help.cricut.com](https://help.cricut.com/a) · [cricut.com](https://cricut.com/b)"))
        #expect(grown.hasSuffix("```chart\ntitle: x\nA: 1\nB: 2\n```"), "the chart comes last")
        #expect(grown.components(separatedBy: "Quellen:").count == 2, "one sources line")
    }

    /// The talk about the blade of a cutting machine, 15 November 2026: three questions about
    /// one thing made three boxes. They are one block now, and each answer adds to it.
    @Test func threeQuestionsAboutOneThingMakeOneBlock() async {
        var settings = AnswerEngine.Settings()
        settings.drafters = ["a"]
        settings.pause = .milliseconds(10)
        final class Script: ModelClient, @unchecked Sendable {
            var replies = [
                "Klinge beim Cricut Joy\n**Ja – Klinge inklusive.**",
                "Cricut Joy: Klinge wechseln\n**Ja, die Klinge ist austauschbar.**\nDie Halterung bleibt.",
                "Cricut Joy: Klingenwechsel\n**Kein festes Wechselintervall** – je nach Material.",
            ]
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                let reply = replies.isEmpty ? "NO_ANSWER" : replies.removeFirst()
                return AsyncThrowingStream { $0.yield(.text(reply)); $0.finish() }
            }
        }
        let talk = AnswerEngine(client: Script(), settings: settings)
        var texts: [UInt64: String] = [:]
        var replaced = 0
        talk.emit = { event in
            if case .cardDelta(let id, let text) = event { texts[id, default: ""] += text }
            if case .cardSuperseded = event { replaced += 1 }
        }
        for (index, line) in ["Der Cricut Joy hat ja auch eine Klinge oder", "Die Klinge kann man ersetzen oder nicht", "Wie oft müsste man so etwas machen"].enumerated() {
            talk.heard(TranscriptSegment(segmentID: UInt64(index + 1), isFinal: true, revision: 1, voice: 1, speaker: .speaker(1), text: line, startMs: 0, endMs: 0), isMine: false)
            await talk.idle()
        }
        #expect(texts.count - replaced == 1, "one block on the table")
        let block = texts[texts.keys.max() ?? 0] ?? ""
        #expect(block.contains("Klinge inklusive") && block.contains("austauschbar") && block.contains("Kein festes Wechselintervall"))
        #expect(block.hasPrefix("**Klinge beim Cricut Joy**"), "the block keeps its title")
    }
}
