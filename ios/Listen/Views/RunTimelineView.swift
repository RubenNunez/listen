import Accelerate
import SwiftUI
import UIKit

struct TimelineDetailSection: Identifiable, Equatable {
    var title: String
    var text: String
    var id: String { title }
}

/// What happened in one recorded conversation, read from its `events.jsonl`:
/// what was heard, what the scheduler did, which requests were open when, and
/// where each card landed. The same reading serves a finished run and the one
/// that is being recorded right now.
struct RunTimeline: Sendable {
    struct Sentence: Identifiable, Sendable { var id: Int; var start: Double; var end: Double; var text: String; var voice: Int? }
    struct Mark: Identifiable, Sendable { var id: Int; var at: Double; var sentence: Int; var text: String }
    struct Usage: Sendable {
        var request: String
        var model: String
        var tokens: TokenUsage?
        var at: Double = 0
    }
    struct Request: Identifiable, Sendable {
        var id: Int
        var agent: String
        var model: String
        /// On device, the user's plan, a router, or a key.
        var route: String
        var sentence: Int
        var start: Double
        /// Nil while it is still open.
        var end: Double?
        var result: String
        /// Which row it is drawn in, so requests that overlap lie under each other.
        var row = 0
        var requestID: String?
        var instructions: String?
        var input: String?
        var response: String?
        var outcome: String?
        var failure: String?
        var tokens: TokenUsage?
        var sources: [String] = []
        var costUSD: Double?
        var firstTextSeconds: Double?
        var isTool = false

        func details(sentences: [Sentence], cards: [Card]) -> [TimelineDetailSection] {
            if isTool {
                return [.init(title: "MCP request", text: "Server: \(agent)\nMethod: \(route)\nTool: \(model)\nID: \(requestID ?? "")\n"
                    + String(format: "Started at %.3f s", start)
                    + (end.map { String(format: "\nFinished at %.3f s · %.3f s", $0, $0 - start) } ?? "\nStill open")
                    + "\nOutcome: \(outcome ?? "pending")\nCompletion describes the RPC exchange, not independent device-state verification."),
                    .init(title: "Arguments", text: input ?? "No arguments recorded.")]
            }
            var overview = ["Agent: \(agent)", "Model: \(model)", "Route: \(route.isEmpty ? "not recorded" : route)",
                            String(format: "Out at %.3f s", start),
                            end.map { String(format: "Back at %.3f s · duration %.3f s", $0, $0 - start) } ?? "Still open",
                            "Result: \(result)"]
            if let requestID { overview.append("Request ID: \(requestID)") }
            if let outcome { overview.append("Outcome: \(outcome)") }
            if let failure { overview.append("Error: \(failure)") }
            if let firstTextSeconds { overview.append(String(format: "First text received after %.3f s (not necessarily an answer)", firstTextSeconds)) }
            if outcome == "cancelled" || outcome == "failed" { overview.append("The response below may be partial.") }
            if outcome == "prefix_selected" { overview.append("Only the first complete sentence was consumed. The remaining provider stream was cancelled; final token usage may be unavailable.") }
            var sections = [TimelineDetailSection(title: "Request", text: overview.joined(separator: "\n"))]
            if let sentence = sentences.first(where: { $0.id == self.sentence }) {
                sections.append(.init(title: "Triggering transcript", text: "#\(sentence.id) · \(sentence.text)"))
            }
            sections.append(.init(title: "Instructions", text: instructions ?? "Not recorded for this run."))
            sections.append(.init(title: "Input", text: input ?? "Not recorded for this run."))
            sections.append(.init(title: "Response", text: response.map { $0.isEmpty ? "(Empty response.)" : $0 }
                                 ?? (end == nil ? "The request has not finished. Its response is recorded when it ends." : "Not recorded for this run.")))
            var counts = ["Token counts were not reported for this request."]
            if let tokens {
                counts = ["Total: \(tokens.total.formatted())", "Input: \(tokens.input.formatted())", "Output: \(tokens.output.formatted())"]
                if let cached = tokens.cachedInput { counts.append("Cached input: \(cached.formatted()) (included in input)") }
                if let reasoning = tokens.reasoningOutput { counts.append("Reasoning output: \(reasoning.formatted()) (included in output)") }
            }
            counts.append(costUSD.map { "Reported cost: \($0.formatted(.number.precision(.fractionLength(0...8)))) USD" } ?? "Cost was not reported.")
            sections.append(.init(title: "Usage", text: counts.joined(separator: "\n")))
            if !sources.isEmpty { sections.append(.init(title: "Reported sources", text: sources.joined(separator: "\n"))) }
            let related = cards.filter { $0.sentence == sentence }
            if !related.isEmpty {
                sections.append(.init(title: "Cards for the same transcript segment", text: related.map {
                    "Card \(RunTimeline.tag($0.id)) · block \(RunTimeline.tag($0.block)) · version \($0.version)\n\($0.text)"
                }.joined(separator: "\n\n")))
            }
            return sections
        }
    }
    struct Card: Identifiable, Sendable {
        var id: Int
        var at: Double
        var block: Int
        var version: Int
        var sentence: Int
        var how: String
        var checked: Bool
        var text: String
        var evidenceSegment: Int? = nil
        var focusText: String? = nil
    }

    var sentences: [Sentence] = []
    var rounds: [Mark] = []
    /// Replies the harness did not put on the table, with its reason.
    var gates: [Mark] = []

    static let heldBack = ["said this before", "already covers", "nothing new", "later moment", "same as the card", "already on the table", "nothing to add"]

    /// A short name for a card, the same wherever it is shown.
    static func tag(_ card: Int) -> String {
        var value = (card &* 2_654_435_761) % 60_466_176  // 36^5
        var text = ""
        for _ in 0..<5 {
            text.append(Array("0123456789abcdefghijklmnopqrstuvwxyz")[value % 36])
            value /= 36
        }
        return "@" + text
    }
    var requests: [Request] = []
    var toolRequests: [Request] = []
    var audioBuffers: [Request] = []
    var voiceEvents: [Mark] = []
    /// One final usage report per actual model call, including calls that produced no card.
    var usage: [Usage] = []
    /// Keep revisions with their arrival times; replay never borrows later accounting or text.
    private var usageHistory: [Usage] = []
    private var sentenceHistory: [(at: Double, sentence: Sentence)] = []
    private var resultHistory: [(at: Double, request: Int, text: String)] = []

    struct Statistics: Equatable, Sendable {
        var sentences = 0
        var requests = 0
        var toolRequests = 0
        var openNow = 0
        var saidNothing = 0
        var heldBack = 0
        var cardEvents = 0
        var blocks = 0
        /// The usage reported up to this moment, as sums: kept as numbers and put into words
        /// only when shown (a long run has thousands of moments).
        var tokens = TokenTally()
        var tokenCountLabel: String { tokens.summary(openNow: openNow).label }
        var tokenUsageDetail: String { tokens.summary(openNow: openNow).detail }
    }

    /// The final usage reports of finished model calls, summed. A later report for the same
    /// call is taken out and put in again, so the sums never count a call twice.
    struct TokenTally: Equatable, Sendable {
        var calls = 0
        var unreported = 0
        var input = 0
        var output = 0
        var cached = 0
        var withoutCached = 0
        var reasoning = 0
        var withoutReasoning = 0

        init() {}

        init(_ usage: [Usage]) {
            for report in usage { add(report) }
        }

        mutating func add(_ report: Usage) { count(report, as: 1) }
        mutating func remove(_ report: Usage) { count(report, as: -1) }

        private mutating func count(_ report: Usage, as sign: Int) {
            calls += sign
            guard let tokens = report.tokens else {
                unreported += sign
                return
            }
            input += sign * tokens.input
            output += sign * tokens.output
            if let value = tokens.cachedInput { cached += sign * value } else { withoutCached += sign }
            if let value = tokens.reasoningOutput { reasoning += sign * value } else { withoutReasoning += sign }
        }

        /// What all reported calls used together; nil when none reported.
        var reported: TokenUsage? {
            guard calls > unreported else { return nil }
            return TokenUsage(input: input, output: output, cachedInput: withoutCached == 0 ? cached : nil,
                              reasoningOutput: withoutReasoning == 0 ? reasoning : nil)
        }

        func summary(openNow: Int) -> (label: String, detail: String) {
            guard let tokens = reported else {
                return ("—", calls == 0 ? "Token usage was not recorded for this run."
                    : "Token counts were not reported for \(calls) model calls.")
            }
            let label = (unreported > 0 || openNow > 0 ? "≥ " : "") + tokens.total.formatted()
            var lines = ["Input: \(tokens.input.formatted()) · Output: \(tokens.output.formatted())",
                         "Reported for \(calls - unreported) of \(calls) finished model calls."]
            if let cached = tokens.cachedInput { lines.append("Cached input: \(cached.formatted()) (already included in input).") }
            if let reasoning = tokens.reasoningOutput { lines.append("Reasoning output: \(reasoning.formatted()) (already included in output).") }
            if unreported > 0 { lines.append("\(unreported) calls did not report token counts; the total is incomplete.") }
            if openNow > 0 { lines.append("Requests open at the shown moment may not have reported their usage yet.") }
            return (label, lines.joined(separator: "\n"))
        }
    }
    private var statisticsHistory: [(at: Double, value: Statistics)] = []
    private var cardMoments: [Double] = []

    /// Upper bound finds the last recorded change even when scrubbing backwards.
    private static func upperBound(_ moment: Double, count: Int, time: (Int) -> Double) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if time(middle) <= moment { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func statistics(at moment: Double) -> Statistics {
        let index = Self.upperBound(moment, count: statisticsHistory.count) { statisticsHistory[$0].at }
        return index == 0 ? Statistics() : statisticsHistory[index - 1].value
    }
    func cardCheckpoint(at moment: Double) -> Int {
        Self.upperBound(moment, count: cardMoments.count) { cardMoments[$0] }
    }
    func transcriptCheckpoint(at moment: Double) -> Int {
        Self.upperBound(moment, count: sentenceHistory.count) { sentenceHistory[$0].at }
    }

    private mutating func prepareStatistics() {
        enum Change {
            case sentence(Int), opened(Int), closed(Int), result(Int, String), usage(Usage), gate, card(Int), toolOpened
        }
        var changes: [(at: Double, change: Change)] = []
        changes += sentenceHistory.map { ($0.at, .sentence($0.sentence.id)) }
        for request in requests {
            changes.append((request.start, .opened(request.id)))
            if let end = request.end { changes.append((end, .closed(request.id))) }
        }
        changes += resultHistory.map { ($0.at, .result($0.request, $0.text)) }
        changes += usageHistory.map { ($0.at, .usage($0)) }
        changes += toolRequests.map { ($0.start, .toolOpened) }
        changes += gates.map { ($0.at, .gate) }
        changes += cards.map { ($0.at, .card($0.block)) }
        changes.sort { $0.at < $1.at }
        var current = Statistics()
        var sentences: Set<Int> = [], open: Set<Int> = [], blocks: Set<Int> = []
        var results: [Int: Bool] = [:]
        var reports: [String: Usage] = [:]
        for entry in changes {
            switch entry.change {
            case .toolOpened: current.toolRequests += 1
            case .sentence(let id): sentences.insert(id); current.sentences = sentences.count
            case .opened(let id): current.requests += 1; open.insert(id)
            case .closed(let id): open.remove(id)
            case .result(let id, let text):
                current.saidNothing -= results[id] == true ? 1 : 0
                results[id] = text.contains("nothing to show")
                current.saidNothing += results[id] == true ? 1 : 0
            case .usage(let report):
                if let earlier = reports[report.request] { current.tokens.remove(earlier) }
                reports[report.request] = report
                current.tokens.add(report)
            case .gate: current.heldBack += 1
            case .card(let block): current.cardEvents += 1; blocks.insert(block); current.blocks = blocks.count
            }
            current.openNow = open.count
            // A timestamp is atomic: all events at that instant are represented together.
            if statisticsHistory.last?.at == entry.at { statisticsHistory[statisticsHistory.count - 1].value = current }
            else { statisticsHistory.append((entry.at, current)) }
        }
        cardMoments = Array(Set(cards.map(\.at) + pieces.map(\.at) + replacedAt.values.map(\.at))).sorted()
    }

    /// A local projection of recorded events, with no transport or model client involved.
    /// The full timeline remains available for navigation; its header follows this projection.
    func through(_ moment: Double) -> RunTimeline {
        var copy = self
        var heard: [Int: Sentence] = [:]
        for entry in sentenceHistory where entry.at <= moment { heard[entry.sentence.id] = entry.sentence }
        copy.sentences = heard.values.sorted { $0.id < $1.id }
        copy.usage = []
        for report in usageHistory where report.at <= moment {
            if let index = copy.usage.firstIndex(where: { $0.request == report.request }) { copy.usage[index] = report }
            else { copy.usage.append(report) }
        }
        copy.requests = requests.filter { $0.start <= moment }.map { request in
            var request = request
            if request.end.map({ $0 > moment }) ?? true {
                request.end = nil
                request.response = nil
                request.outcome = nil
                request.failure = nil
                request.tokens = nil
                request.sources = []
                request.costUSD = nil
                if let first = request.firstTextSeconds, request.start + first > moment { request.firstTextSeconds = nil }
            }
            request.result = resultHistory.last { $0.request == request.id && $0.at <= moment }?.text
                ?? (request.end == nil ? "open" : request.outcome ?? "finished")
            return request
        }
        copy.rounds = rounds.filter { $0.at <= moment }
        copy.voiceEvents = voiceEvents.filter { $0.at <= moment }
        copy.audioBuffers = audioBuffers.filter { $0.start <= moment }.map {
            var buffer = $0
            if buffer.end.map({ $0 > moment }) ?? true { buffer.end = nil; buffer.outcome = nil; buffer.result = "scheduled" }
            return buffer
        }
        copy.toolRequests = toolRequests.filter { $0.start <= moment }.map {
            var request = $0
            if request.end.map({ $0 > moment }) ?? true { request.end = nil; request.outcome = nil; request.result = "open" }
            return request
        }
        copy.gates = gates.filter { $0.at <= moment }
        copy.cards = cards.filter { $0.at <= moment }
        copy.blocks = blocks.filter { block in copy.cards.contains { $0.block == block } }
        return copy
    }

    var reportedTokens: TokenUsage? { TokenTally(usage).reported }
    var unreportedCalls: Int { usage.filter { $0.tokens == nil }.count }
    var tokenCountLabel: String { TokenTally(usage).summary(openNow: openNow).label }
    var tokenUsageDetail: String { TokenTally(usage).summary(openNow: openNow).detail }
    var cards: [Card] = []
    /// Every piece of card text with the moment it arrived, and when a card was replaced by which:
    /// enough to put the table back as it lay at any moment.
    var pieces: [(at: Double, card: Int, text: String)] = []
    var replacedAt: [Int: (at: Double, by: Int)] = [:]
    var topic = ""
    /// When the recording began, on the clock of the events.
    var soundBegins = 0.0
    /// The first card of every block, in the order the blocks came up.
    var blocks: [Int] = []
    var length: Double = 0

    var openNow: Int { requests.filter { $0.end == nil }.count }

    /// The table as it lay at a moment of the run: every block with the versions it had by then.
    func blocks(at moment: Double) -> [CardBlocks.Block] {
        var texts: [Int: String] = [:]
        for piece in pieces where piece.at <= moment { texts[piece.card, default: ""] += piece.text }
        let shown: [SessionCore.Card] = cards.filter { $0.at <= moment }.map { card in
            let before = replacedAt.first { $0.value.by == card.id && $0.value.at <= moment }?.key
            var copy = SessionCore.Card(start: CardStart(
                generationID: UInt64(card.id), kind: card.checked ? .deep : .fast, style: .answer,
                triggerSegment: UInt64(card.sentence), sourceCard: before.map { UInt64($0) }, contextVersion: 0, mappingVersion: 0,
                evidenceSegment: card.evidenceSegment.map(UInt64.init), blockID: UInt64(card.block),
                focusText: (texts[card.id] ?? "").split(separator: "\n").count >= 2 ? card.focusText : nil))
            copy.text = texts[card.id] ?? ""
            let replaced = replacedAt[card.id].map { $0.at <= moment } ?? false
            copy.status = replaced ? .superseded : .finished
            return copy
        }
        return CardBlocks.blocks(from: shown)
    }

    /// What had been heard by a moment.
    func heard(by moment: Double) -> [Sentence] {
        var heard: [Int: Sentence] = [:]
        for entry in sentenceHistory.prefix(transcriptCheckpoint(at: moment)) { heard[entry.sentence.id] = entry.sentence }
        return heard.values.sorted { $0.id < $1.id }
    }

    /// How many requests were open in each second of the run: the load, as a strip of heat.
    var load: [Int] {
        guard length > 0 else { return [] }
        let calls = requests + toolRequests
        return (0..<Int(length.rounded(.up))).map { second in
            let (from, to) = (Double(second), Double(second + 1))
            return calls.filter { $0.start < to && ($0.end ?? length) > from }.count
        }
    }
    var requestRows: Int { (requests.map(\.row).max() ?? -1) + 1 }

    init(folder: URL) {
        if let data = try? Data(contentsOf: folder.appending(path: "run.json")),
            let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            topic = meta["topic"] as? String ?? ""
        }
        guard let text = try? String(contentsOf: folder.appending(path: "events.jsonl"), encoding: .utf8) else { return }
        let events: [[String: Any]] = text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        let detailedRequests = events.contains { $0["kind"] as? String == "model_request" }
        var requestIDs: [String: Int] = [:]
        var toolIDs: [String: Int] = [:]
        var audioIDs: [Int: Int] = [:]
        var currentVoice = "Voice"
        // Where each request and each usage report is, so a long run is read in one pass
        // (searching all requests for every event took seconds on a one-hour meeting).
        var requestsBySentence: [Int: [Int]] = [:]
        var usageIndex: [String: Int] = [:]
        func appendRequest(_ request: Request) {
            requestsBySentence[request.sentence, default: []].append(requests.count)
            requests.append(request)
        }
        func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        func whole(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        // Sentences carry their place in the sound; the first one tells when the sound began on the events' clock.
        var offset: Double?
        var heard: [Int: Sentence] = [:]
        var texts: [Int: String] = [:]
        var evidenceSegments: [Int: Int] = [:]
        var focuses: [Int: String] = [:]
        var landed: [Int: (block: Int, version: Int, how: String)] = [:]
        var replaces: [Int: Int] = [:]
        var started: [(id: Int, at: Double, deep: Bool, sentence: Int)] = []
        var open: [Int] = []  // indices into requests that have no end yet
        for event in events {
            let at = number(event["t"])
            length = max(length, at)
            switch event["kind"] as? String {
            case "voice_choice": currentVoice = event["tts_voice"] as? String ?? "Voice"
            case "voice_output_buffer":
                let id = whole(event["buffer"])
                audioIDs[id] = audioBuffers.count
                audioBuffers.append(Request(id: id, agent: currentVoice, model: "Buffer \(id)",
                    route: event["player"] as? String ?? "", sentence: 0, start: at, end: nil, result: "scheduled",
                    input: event["file"] as? String,
                    response: String(format: "%.3f s PCM · %.0f Hz. Scheduling/completion receipts, not acoustic onset or proof every sample was heard.", number(event["seconds"]), number(event["sample_rate"]))))
            case "voice_output_played":
                guard let index = audioIDs[whole(event["buffer"])] else { continue }
                audioBuffers[index].end = at; audioBuffers[index].outcome = "player_finished"; audioBuffers[index].result = "player_finished"
            case "voice_output_stopped":
                for index in audioBuffers.indices where audioBuffers[index].end == nil && audioBuffers[index].route == event["player"] as? String {
                    audioBuffers[index].end = at; audioBuffers[index].outcome = "stopped"; audioBuffers[index].result = "heard prefix unknown"
                }
            case "voice_user", "voice_barge_in", "voice_backchannel", "voice_permission", "voice_operation", "voice_tool_feedback", "voice_acknowledgement", "voice_research", "voice_opening", "voice_route", "voice_forecast", "voice_playback", "voice_task_plan", "voice_task", "voice_sequence", "voice_early_action":
                let kind = event["kind"] as? String ?? ""
                let detail = [event["capability"] as? String ?? "", event["state"] as? String ?? "", event["tier"] as? String ?? "", event["task_id"] as? String ?? "",
                    event["model"] as? String ?? "", event["tools_in_turn"] as? String ?? "",
                    event["waiting_phrase"] as? String ?? "", event["text"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                voiceEvents.append(Mark(id: voiceEvents.count, at: at, sentence: 0, text: kind + " · " + detail))
            case "sentence":
                let end = number(event["end_ms"]) / 1000
                if offset == nil {
                    offset = at - end
                    soundBegins = max(0, at - end)
                }
                let id = whole(event["id"])
                let sentence = Sentence(
                    id: id, start: (offset ?? 0) + number(event["start_ms"]) / 1000, end: (offset ?? 0) + end,
                    text: event["text"] as? String ?? "", voice: (event["voice"] as? NSNumber)?.intValue)
                heard[id] = sentence
                sentenceHistory.append((at, sentence))
            case "context":
                let state = event["state"] as? String ?? ""
                let context = event["context"] as? String ?? ""
                let target = event["target"] as? String
                rounds.append(Mark(id: rounds.count, at: at, sentence: whole(event["sentence"]),
                                   text: "Context \(context): \(state)" + (target.map { " · target \($0)" } ?? "")))
            case "round":
                let state = event["state"] as? String ?? ""
                rounds.append(Mark(id: rounds.count, at: at, sentence: whole(event["sentence"]), text: state))
                // Rounds do not overlap: when one starts, drafts of the one before that never
                // answered were given up.
                if !detailedRequests, state.hasPrefix("starts") || state.hasPrefix("takes") {
                    for place in open.indices.reversed() where requests[open[place]].agent.contains("draft") {
                        requests[open[place]].end = at
                        requests[open[place]].result = "given up: a newer moment took its place"
                        resultHistory.append((at, requests[open[place]].id, requests[open[place]].result))
                        open.remove(at: place)
                    }
                }
            case "request":
                guard !detailedRequests else { continue }
                open.append(requests.count)
                appendRequest(Request(
                    id: requests.count, agent: event["agent"] as? String ?? "", model: event["model"] as? String ?? "",
                    route: event["route"] as? String ?? "", sentence: whole(event["sentence"]), start: at, end: nil, result: "open"))
            case "model_request":
                guard let id = event["request_id"] as? String, !id.isEmpty, requestIDs[id] == nil else { continue }
                requestIDs[id] = requests.count
                appendRequest(Request(
                    id: requests.count, agent: event["agent"] as? String ?? "", model: event["model"] as? String ?? "",
                    route: event["route"] as? String ?? "", sentence: whole(event["sentence"]), start: at, end: nil, result: "open",
                    requestID: id, instructions: event["instructions"] as? String, input: event["input"] as? String))
            case "mcp_request":
                guard let id = event["request_id"] as? String, !id.isEmpty, toolIDs[id] == nil else { continue }
                toolIDs[id] = toolRequests.count
                toolRequests.append(Request(id: toolRequests.count, agent: event["server"] as? String ?? "MCP",
                    model: (event["tool"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? event["method"] as? String ?? "",
                    route: event["method"] as? String ?? "", sentence: 0, start: at, end: nil, result: "open",
                    requestID: id, input: event["input"] as? String, isTool: true))
            case "mcp_result":
                guard let id = event["request_id"] as? String, let index = toolIDs[id] else { continue }
                toolRequests[index].end = at
                toolRequests[index].outcome = event["outcome"] as? String
                toolRequests[index].result = event["outcome"] as? String ?? "unknown"
            case "usage":
                guard let id = event["request_id"] as? String, !id.isEmpty else { continue }
                let report = Usage(request: id, model: event["model"] as? String ?? "", tokens: TokenUsage.read(event, responses: true), at: at)
                usageHistory.append(report)
                if let index = usageIndex[id] { usage[index] = report }
                else {
                    usageIndex[id] = usage.count
                    usage.append(report)
                }
                if let index = requestIDs[id] {
                    requests[index].end = at
                    requests[index].response = event["response"] as? String
                    requests[index].outcome = event["outcome"] as? String
                    requests[index].failure = event["failure"] as? String
                    requests[index].tokens = report.tokens
                    requests[index].sources = event["sources"] as? [String] ?? []
                    requests[index].costUSD = event["cost_usd"] as? Double
                    requests[index].firstTextSeconds = event["first_text_seconds"] as? Double ?? requests[index].firstTextSeconds
                    if requests[index].result == "open" { requests[index].result = requests[index].outcome ?? "finished" }
                }
            case "voice_first_text":
                if let id = event["request_id"] as? String, let index = requestIDs[id], requests[index].firstTextSeconds == nil {
                    requests[index].firstTextSeconds = max(0, at - requests[index].start)
                }
            case "layer":
                let name = event["name"] as? String ?? ""
                guard let kind = name.first, "345".contains(kind) else { continue }
                let detail = event["detail"] as? String ?? ""
                // The first lines of a draft are a step on the way, not the end of the request.
                if detail.hasPrefix("first lines") { continue }
                // What the harness held back although a model answered.
                if RunTimeline.heldBack.contains(where: { detail.contains($0) }) {
                    gates.append(Mark(id: gates.count, at: at, sentence: whole(event["sentence"]), text: detail))
                }
                let sentence = whole(event["sentence"])
                let agent = kind == "5" ? "web" : kind == "4" ? "merge" : "draft"
                if detailedRequests {
                    let stage = kind == "5" && name != "5 · web" ? "action" : agent
                    let model = String(name.dropFirst(4))
                    if let index = requestsBySentence[sentence]?.reversed().first(where: {
                        requests[$0].agent == stage
                            && (stage != "draft" || requests[$0].model.split(separator: "/").last.map(String.init) == model)
                    }) {
                        requests[index].result = detail
                        resultHistory.append((at, requests[index].id, detail))
                    }
                    continue
                }
                if let place = open.firstIndex(where: { requests[$0].sentence == sentence && requests[$0].agent.contains(agent) }) {
                    requests[open[place]].end = at
                    requests[open[place]].result = detail
                    resultHistory.append((at, requests[open[place]].id, detail))
                    open.remove(at: place)
                } else {
                    // A run recorded before requests were logged when they opened: its length tells when it began.
                    appendRequest(Request(
                        id: requests.count, agent: agent, model: String(name.dropFirst(4)), route: "", sentence: sentence,
                        start: at - number(event["seconds"]), end: at, result: detail))
                    resultHistory.append((at, requests.last!.id, detail))
                }
            case "card_started":
                started.append((whole(event["card"]), at, event["layer"] as? String == "deep", whole(event["sentence"])))
                if let evidence = event["evidence_segment"] as? NSNumber { evidenceSegments[whole(event["card"])] = evidence.intValue }
                focuses[whole(event["card"])] = event["focus_text"] as? String
            case "card_text":
                texts[whole(event["card"]), default: ""] += event["text"] as? String ?? ""
                pieces.append((at, whole(event["card"]), event["text"] as? String ?? ""))
            case "card_replaced":
                replaces[whole(event["by"])] = whole(event["card"])
                replacedAt[whole(event["card"])] = (at, whole(event["by"]))
            case "landed":
                landed[whole(event["card"])] = (whole(event["block"]), whole(event["version"]), event["how"] as? String ?? "")
            default: break
            }
        }
        sentences = heard.values.sorted { $0.id < $1.id }
        // Blocks: from the log when it says so, otherwise from which card replaced which.
        func root(_ card: Int) -> Int {
            var card = card
            var steps = 0
            while let before = replaces[card], steps < 100 {
                card = before
                steps += 1
            }
            return card
        }
        var versions: [Int: Int] = [:]
        for card in started.sorted(by: { $0.at < $1.at }) {
            let block = landed[card.id]?.block ?? root(card.id)
            versions[block, default: 0] += 1
            if !blocks.contains(block) { blocks.append(block) }
            cards.append(Card(
                id: card.id, at: card.at, block: block, version: landed[card.id]?.version ?? versions[block] ?? 1,
                sentence: card.sentence, how: landed[card.id]?.how ?? (replaces[card.id] == nil ? "a new block" : "a new version of its block"),
                checked: card.deep, text: texts[card.id] ?? "", evidenceSegment: evidenceSegments[card.id], focusText: focuses[card.id]))
        }
        // Rows for requests: each takes the first row that is free when it starts.
        var free: [Double] = []
        for index in requests.indices.sorted(by: { requests[$0].start < requests[$1].start }) {
            let end = requests[index].end ?? length
            let row = free.firstIndex { $0 <= requests[index].start } ?? free.count
            if row == free.count { free.append(end) } else { free[row] = end }
            requests[index].row = row
        }
        prepareStatistics()
        length += 2
    }
}

/// The strip's clock while a run is recorded. Each reading of the recording proposes when its
/// sound began on this device's clock; an earlier proposal is taken (it was read with less
/// delay). Sound that comes again after it stood still (a pause) sets the clock anew.
struct LiveClock: Equatable {
    /// The strip runs this far behind the sound, so what it shows has always been read already:
    /// a reading every half second, sound written every tenth of a second.
    static let lag = 0.9
    /// When the sound began on this device's clock, as the readings tell it.
    private(set) var origin: Date?
    /// How much sound the last reading had found, in seconds of the strip.
    private var heard = 0.0
    /// Where the strip stood when the clock was set anew: sound that comes again after a pause
    /// does not throw it back, it waits there until the clock has caught up.
    private var floor = 0.0

    /// Takes a reading: `heard` is how far the sound reaches now.
    mutating func keep(heard: Double, at now: Date) {
        defer { self.heard = heard }
        let proposed = now.addingTimeInterval(-heard)
        guard let origin, heard >= self.heard else {
            // The first reading, or another run.
            self.origin = proposed
            floor = 0
            return
        }
        // A paused recording brings no sound. Proposals from it only say that time went on:
        // taken, they threw the strip back by the lag every second (17 November 2026).
        guard heard > self.heard else { return }
        if proposed.timeIntervalSince(origin) < 1 {
            if proposed < origin { self.origin = proposed }
        } else {
            floor = time(at: now, heard: self.heard)
            self.origin = proposed
        }
    }

    /// The moment the strip shows: the clock, `lag` behind the sound that has been read,
    /// never beyond it.
    func time(at date: Date, heard: Double) -> Double {
        guard let origin else { return heard }
        return max(0, min(max(floor, date.timeIntervalSince(origin) - Self.lag), heard))
    }
}

/// The timeline of a run, as an instrument: dark, time running to the right, one
/// lane per kind of event, nothing lying over anything else. Point at an event or
/// click to select it, then use Open details to read it in full.
struct RunTimelineView: View {
    /// The run to open first; nil for the newest one.
    var initial: URL?
    /// The run that is being recorded right now, when there is one: it is read again as it grows.
    var live: URL?
    /// Closes the panel.
    var onClose: () -> Void = {}
    /// Opens the selected run to go through it in time.
    var onReplay: ((URL) -> Void)?
    /// One replay controller owns clock, gestures and follow; nil for a live/debug timeline.
    var replay: ReplayController?
    /// A replay shares its immutable reading instead of parsing the same recording twice.
    var snapshot: RunTimeline?
    @State private var folder: URL?
    @State private var timeline = RunTimeline(folder: URL(fileURLWithPath: "/dev/null"))
    @State private var lanes: [(name: String, note: String, rows: [[Item]])] = []
    @State private var recordedLoad: [Int] = []
    @State private var hovered: Item?
    @State private var pinned: Item?
    @State private var inspected: Item?
    @State private var detailsExpanded = false
    @State private var runs: [URL] = []
    /// The loudest sample of every twentieth of a second of the recording, for the signal under "Heard".
    @State private var peaks: [Float] = []
    /// How many bytes of the recording have been read into `peaks`, and of which run.
    @State private var peaksRead = 44
    @State private var peaksOf: URL?
    /// While a run is recorded: the clock the strip moves on with, every frame, instead of in
    /// steps of a reading (a half-second animation per reading stopped and started again,
    /// 16 November 2026).
    @State private var liveClock = LiveClock()
    /// Where the strip is scrolled; while a run is recorded it follows the clock. Kept in an object
    /// of its own: written on every frame, it must not make this whole view be worked out again
    /// (as `@State` it did, 25–65 times a second, and the strip stuttered more as the run grew).
    @State private var scroll = StripScroll()
    @State private var followsLive = true
    @State private var stripWidth: CGFloat = 0
    @State private var visibleBucket = 0
    @State private var nearLiveEdge = true
    /// How many bytes of the run's events were read, so an unchanged run is not laid out again.
    @State private var eventsRead = -1
    /// The reading under way, so opening another run ends it.
    @State private var loading: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// What decides whether the shown run is read again as it grows. When any of it changes,
    /// the reading that was going on ends and a new one begins if it is still called for.
    private struct Poll: Equatable {
        var folder: URL?
        var live: URL?
        var active: Bool
    }

    nonisolated private static let peakSamples = 800  // a twentieth of a second at 16 kHz

    /// The loudest sample of every twentieth of a second of the recording from byte `offset`
    /// on, and how far that reached. Safe away from the main thread.
    nonisolated private static func signal(in folder: URL, from offset: Int) -> (peaks: [Float], read: Int) {
        guard let file = try? FileHandle(forReadingFrom: folder.appending(path: "audio.wav")) else { return ([], offset) }
        defer { try? file.close() }
        try? file.seek(toOffset: UInt64(offset))
        guard let data = try? file.readToEnd(), data.count >= peakSamples * 2 else { return ([], offset) }
        let whole = data.count / (peakSamples * 2)
        var peaks = [Float](repeating: 0, count: whole)
        // Accelerate, not a loop over every sample: an hour of sound took about 3 s that way in a debug build.
        var block = [Float](repeating: 0, count: peakSamples)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<whole {
                vDSP_vflt16(samples.baseAddress! + index * peakSamples, 1, &block, 1, vDSP_Length(peakSamples))
                var peak: Float = 0
                vDSP_maxmgv(block, 1, &peak, vDSP_Length(peakSamples))
                peaks[index] = peak / 32_768
            }
        }
        return (peaks, offset + whole * peakSamples * 2)
    }

    nonisolated private static func eventsSize(in folder: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: folder.appending(path: "events.jsonl").path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// One thing on the timeline.
    struct Item: Identifiable, Equatable {
        var id: String
        var start: Double
        /// Nil for a moment; a duration for something that lasted.
        var end: Double?
        var label: String
        var tint: Color
        var filled = true
        var title: String
        var text: String
        var sections: [TimelineDetailSection] = []
    }

    nonisolated private static let pointsPerSecond: CGFloat = 46
    private var scale: CGFloat { Self.pointsPerSecond }
    private let rowHeight: CGFloat = 26
    private let labelWidth: CGFloat = 118
    private var rulerHeight: CGFloat {
        44
    }

    // Keep one viewport ahead and behind. Only bucket changes rebuild event views.
    private var visiblePixels: ClosedRange<CGFloat> {
        max(0, CGFloat(visibleBucket) * 256 - 512)...(CGFloat(visibleBucket) * 256 + max(800, stripWidth) + 512)
    }

    private func visible(_ row: [Item]) -> ArraySlice<Item> {
        let indices = TimelineCulling.indices(count: row.count, lower: visiblePixels.lowerBound, upper: visiblePixels.upperBound,
            left: { x(row[$0].start) }, right: { x(row[$0].start) + width(row[$0]) })
        return row[indices]
    }

    private var visibleTicks: [Int] {
        let first = max(0, Int(visiblePixels.lowerBound / scale) / 5 * 5)
        let last = min(Int(timeline.length), Int(visiblePixels.upperBound / scale) + 5)
        return first <= last ? Array(stride(from: first, through: last, by: 5)) : []
    }

    private func x(_ time: Double) -> CGFloat { CGFloat(time) * scale }

    /// Opens the shown run. The reading itself happens away from the main thread: a one-hour
    /// meeting (36 MB of events, an hour of sound) held the panel and the app still for seconds
    /// (20 November 2026). A run whose events did not change is not read again.
    private func load() {
        runs = RunRecorder.runs().reversed()
        if folder == nil { folder = initial ?? live ?? runs.first }
        guard folder != nil else { return }
        loading?.cancel()
        loading = Task { await read() }
    }

    /// What one reading of a recorded run yields, worked out away from the main thread.
    private struct Reading: Sendable {
        var timeline: RunTimeline
        var lanes: [(name: String, note: String, rows: [[Item]])]
        var load: [Int]
    }

    /// A run that is still being recorded is read again away from the main thread, which draws
    /// (and runs the harness): reading and laying out the whole run there twice a second made
    /// the strip stutter. Unchanged events are not laid out again.
    private func poll() async {
        guard let folder, folder == live else { return }
        await read()
    }

    /// Reads what the shown run gained: the new part of its sound, and its events when they grew.
    private func read() async {
        guard let folder else { return }
        let from = peaksOf == folder ? peaksRead : 44
        let known = eventsRead
        let snapshot = self.snapshot
        let (signal, size, reading) = await Task.detached(priority: .userInitiated) { () -> ((peaks: [Float], read: Int), Int, Reading?) in
            let signal = Self.signal(in: folder, from: from)
            let size = Self.eventsSize(in: folder)
            guard size != known else { return (signal, size, nil) }
            let timeline = snapshot ?? RunTimeline(folder: folder)
            return (signal, size, Reading(timeline: timeline, lanes: Self.lanes(for: timeline), load: timeline.load))
        }.value
        guard !Task.isCancelled, folder == self.folder else { return }
        if peaksOf != folder {
            peaks = []
            peaksOf = folder
            peaksRead = 44
        }
        // Another reading may have taken the same stretch of sound meanwhile: it is not added twice.
        if peaksRead == from {
            if !signal.peaks.isEmpty { peaks += signal.peaks }
            peaksRead = signal.read
        }
        if let reading, eventsRead == known {
            timeline = reading.timeline
            lanes = reading.lanes
            recordedLoad = reading.load
            eventsRead = size
        }
        if folder == live { keepTime() }
    }

    /// Whether the strip follows its head: the present while recording, the playhead in a replay.
    private var following: Bool { folder == live ? followsLive : (replay?.follows == true) }

    /// Attached again by the button: the strip glides back to the head, then follows it.
    private func attach() {
        scroll.glide = (from: scroll.offset, start: .now)
        if folder == live { followsLive = true } else { replay?.attachFollow() }
    }

    /// How wide the strip is laid out. While recording it has a few seconds of room ahead of the
    /// clock: it is laid out again only when a reading brings something new.
    private var stripContentWidth: CGFloat { max(700, x(max(timeline.length, folder == live ? heardUpTo + 3 : 0)) + 140) }

    /// A scroll position the strip can actually reach. A request beyond the end is never
    /// fulfilled: animated, it was asked for again and again and held the main thread.
    private func reachable(_ offset: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, stripContentWidth - stripWidth))
    }

    /// Where following moves the strip on a given frame, or nil while it does not follow.
    /// Where the head of a run being recorded is on the strip at a moment, or nil while the strip
    /// does not follow it.
    private var followHead: (@MainActor (Date) -> CGFloat)? {
        guard folder == live, followsLive else { return nil }
        return { @MainActor date in x(liveTime(at: date)) }
    }

    /// The end of the sound read so far, on the strip's clock.
    private var heardUpTo: Double { timeline.soundBegins + Double(peaks.count) / 20 }

    /// Ties the strip's clock to the sound that has been read.
    private func keepTime() { liveClock.keep(heard: heardUpTo, at: Date()) }

    /// The moment the strip shows while a run is recorded.
    private func liveTime(at date: Date) -> Double { liveClock.time(at: date, heard: heardUpTo) }

    /// How wide an item is drawn: as long as it lasted, but wide enough to read its label.
    private func width(_ item: Item) -> CGFloat { Self.width(item) }

    nonisolated private static func width(_ item: Item) -> CGFloat {
        let text = CGFloat(item.label.count) * 6.1 + 16
        return max(item.end.map { CGFloat($0 - item.start) * pointsPerSecond - 2 } ?? 0, min(text, 340))
    }

    /// Puts items into rows so that none lies over another.
    nonisolated private static func rows(_ items: [Item]) -> [[Item]] {
        var rows: [[Item]] = []
        var ends: [CGFloat] = []
        for item in items.sorted(by: { $0.start < $1.start }) {
            let from = CGFloat(item.start) * pointsPerSecond
            let row = ends.firstIndex { $0 + 4 <= from } ?? ends.count
            if row == ends.count {
                ends.append(from + width(item))
                rows.append([item])
            } else {
                ends[row] = from + width(item)
                rows[row].append(item)
            }
        }
        return rows
    }

    nonisolated private static func lanes(for timeline: RunTimeline) -> [(name: String, note: String, rows: [[Item]])] {
        let seconds = { (value: Double) in String(format: "%.1f s", value) }
        let heard = timeline.sentences.map { sentence in
            Item(id: "s\(sentence.id)", start: sentence.start, end: sentence.end, label: "#\(sentence.id) \(sentence.text)", tint: .gray,
                 title: "Heard · sentence #\(sentence.id)" + (sentence.voice.map { " · voice \($0)" } ?? ""),
                 text: sentence.text + "\n\nSpoken from \(seconds(sentence.start)) to \(seconds(sentence.end)).")
        }
        let scheduler = timeline.rounds.map { mark in
            let held = mark.text.contains("waits") || mark.text.contains("held back")
            return Item(id: "r\(mark.id)", start: mark.at, end: nil, label: "#\(mark.sentence) \(mark.text)", tint: held ? .orange : .blue, filled: !held,
                        title: "Scheduler · for sentence #\(mark.sentence) at \(seconds(mark.at))", text: mark.text)
        }
        let requests = timeline.requests.map { request in
            let end = request.end ?? timeline.length
            let quiet = request.result.contains("nothing to show")
            let given = request.result.hasPrefix("given up")
            let tint: Color = request.end == nil ? .orange : given || request.outcome == "failed" ? .red
                : quiet || request.outcome == "cancelled" ? .gray : request.agent == "voice-fast" ? .cyan
                : ["voice-opening-review", "voice-route"].contains(request.agent) ? .yellow
                : request.agent == "voice-forecast" ? .blue : request.agent == "web" ? .teal : .purple
            let route = request.route.isEmpty ? "" : "\(request.route) · "
            return Item(
                id: "q\(request.id)", start: request.start, end: end,
                label: "\(request.agent) → \(route)\(request.model) · \(request.end == nil ? "open" : seconds(end - request.start))", tint: tint,
                filled: !(quiet || given),
                title: "Request · \(request.agent) → \(route)\(request.model) · for sentence #\(request.sentence)",
                text: "Out at \(seconds(request.start)), " + (request.end == nil ? "still open." : "back after \(seconds(end - request.start)).") + "\nResult: \(request.result)",
                sections: request.details(sentences: timeline.sentences, cards: timeline.cards))
        }
        let gates = timeline.gates.map { mark in
            Item(id: "g\(mark.id)", start: mark.at, end: nil, label: "#\(mark.sentence) held back: \(mark.text)", tint: .yellow, filled: false,
                 title: "Harness · a reply for sentence #\(mark.sentence) was not shown", text: mark.text)
        }
        let tools = timeline.toolRequests.map { request in
            Item(id: "mcp\(request.id)", start: request.start, end: request.end ?? timeline.length,
                 label: "\(request.agent) → \(request.model) · \(request.end.map { seconds($0 - request.start) } ?? "open")", tint: .mint,
                 title: "MCP · \(request.agent) → \(request.model)", text: "Outcome: \(request.outcome ?? "pending")",
                 sections: request.details(sentences: [], cards: []))
        }
        let audio = timeline.audioBuffers.map { buffer in
            Item(id: "pcm\(buffer.id)", start: buffer.start, end: buffer.end ?? timeline.length,
                 label: "\(buffer.agent) · \(buffer.model) · \(buffer.outcome ?? "queued")", tint: buffer.outcome == "stopped" ? .orange : .blue,
                 title: "Generated speech · \(buffer.agent) · \(buffer.model)",
                 text: (buffer.response ?? "") + "\n" + (buffer.input ?? "") + "\n" + buffer.result)
        }
        let voice = timeline.voiceEvents.map { event in
            Item(id: "voice\(event.id)", start: event.at, end: nil, label: String(event.text.prefix(110)), tint: .yellow,
                 title: "Conversation event", text: event.text)
        }
        let cards = timeline.cards.map { card in
            let title = card.text.split(separator: "\n").first.map { $0.replacingOccurrences(of: "**", with: "") } ?? ""
            let verb = card.version == 1 ? "created" : "updated to v\(card.version)"
            return Item(
                id: "c\(card.id)", start: card.at, end: nil,
                label: "\(RunTimeline.tag(card.block)) \(verb)\(card.checked ? " ✓" : "") · \(title)", tint: card.checked ? .green : .indigo,
                title: "Card \(RunTimeline.tag(card.id)) · block \(RunTimeline.tag(card.block)) · version \(card.version) · \(card.checked ? "checked" : "draft") · for sentence #\(card.sentence)",
                text: "Landed as: \(card.how)\n\n\(card.text)")
        }
        // One lane per block, so a block's versions read along one line.
        let blocks = timeline.blocks.map { block in rows(cards.filter { item in timeline.cards.first { "c\($0.id)" == item.id }?.block == block }) }
        return [
            ("Heard", "what the listening stages wrote", rows(heard)),
            ("Scheduler", "when a round starts or waits", rows(scheduler)),
            ("Requests", "every call to a model, out and back", rows(requests)),
            ("MCP", "actual tool and discovery exchanges", rows(tools)),
            ("Voice events", "turns, permission and interruption decisions", rows(voice)),
            ("Voice output", "queued PCM and player completion, not acoustic capture", rows(audio)),
            ("Harness", "replies it held back, and why", rows(gates)),
            ("Cards", "created and updated, one line per block", blocks.flatMap { $0 }),
        ]
    }

    var body: some View {
        #if DEBUG
        let _ = FrameProbe.isOn ? FrameProbe.shared.bodies += 1 : ()
        #endif
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if folder.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                // Nothing recorded yet, or the run shown was moved away (exported out of Listen).
                ContentUnavailableView {
                    Label(folder == nil ? "No recorded conversation yet" : "This run is not here any more", systemImage: "waveform")
                } description: {
                    Text(folder == nil
                         ? "Each conversation is recorded on this device; its timeline shows what Listen heard, asked and showed."
                         : "It was moved, for example exported out of Listen (runs/exports).")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    // Lane names stay where they are while time scrolls by.
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: rulerHeight)
                        Text("Load").font(.caption.weight(.semibold)).frame(height: 30, alignment: .leading)
                        ForEach(lanes, id: \.name) { lane in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lane.name).font(.caption.weight(.semibold))
                                Text(lane.note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(height: height(of: lane.rows), alignment: .topLeading)
                            .padding(.top, 5)
                        }
                    }
                    .frame(width: labelWidth, alignment: .leading)
                    .padding(.leading, 16)
                    ScrollViewReader { strip in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Inside the strip, so the scroll view above it is the strip's own.
                            StripScrollFinder(scroll: scroll).frame(width: 0, height: 0)
                            ticks
                            heat
                            ForEach(lanes, id: \.name) { lane in
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(lane.rows.enumerated()), id: \.offset) { _, row in
                                        ZStack(alignment: .topLeading) {
                                            ForEach(visible(row)) { item in box(item).offset(x: x(item.start)) }
                                        }
                                        .frame(height: 22, alignment: .topLeading)
                                    }
                                }
                                .frame(height: height(of: lane.rows), alignment: .topLeading)
                                .padding(.top, 5)
                                .background(alignment: .topLeading) {
                                    // The sound itself lies behind what was heard: where the signal is, someone spoke.
                                    if lane.name == "Heard" { signal(height: height(of: lane.rows) + 5) }
                                }
                                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
                            }
                        }
                        // While recording, a few seconds of room ahead of the clock: the strip is laid out
                        // again only when a reading brings something new, and moves every frame meanwhile.
                        .frame(width: stripContentWidth, alignment: .topLeading)
                        .contentShape(.rect)
                        .overlay(alignment: .topLeading) {
                            // Where time is now, on a run that is still being recorded.
                            if folder == live {
                                // Moved by the clock on every frame, not by the last event that was read.
                                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: scenePhase != .active)) { context in
                                    Rectangle().fill(.red.opacity(0.8)).frame(width: 2)
                                        .overlay(alignment: .top) {
                                            Text("now ▸").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                                                .fixedSize().offset(x: 22, y: 4)
                                        }
                                        .offset(x: x(liveTime(at: context.date)))
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .background(alignment: .topLeading) {
                            ForEach(visibleTicks, id: \.self) { second in
                                Rectangle().fill(.white.opacity(0.06)).frame(width: 1).offset(x: x(Double(second)))
                            }
                        }
                    }
                    // Only where the strip opens: anchored on later size changes too, it moved itself each time a
                    // reading made it longer, which the live follow would take for the reader's scrolling.
                    .defaultScrollAnchor(folder == live ? .trailing : .leading, for: .initialOffset)
                    .modifier(StripScrollPosition(scroll: scroll, bound: folder != live))
                    .accessibilityIdentifier("timeline.horizontal")
                    .overlay(alignment: .topLeading) {
                        if let replay {
                            ReplayPlayhead(replay: replay, scroll: scroll, scale: scale, rulerHeight: rulerHeight)
                                .clipped()
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, width in stripWidth = width }
                    .onScrollGeometryChange(for: Int.self, of: {
                        Int(max(0, $0.contentOffset.x + $0.contentInsets.leading) / 256)
                    }) { _, bucket in visibleBucket = bucket }
                    // Only the viewport/control observes offsets; lane layout never reads them.
                    .onScrollGeometryChange(for: TimelineViewport.self, of: {
                        TimelineViewport(offset: $0.contentOffset.x + $0.contentInsets.leading,
                                         width: $0.containerSize.width, content: $0.contentSize.width)
                    }) { _, viewport in scroll.record(viewport) }
                    // At the very end, not merely close to it: the head runs about 160 points before the
                    // end, and a reader who went back a little must stay where they went (17 November 2026).
                    .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.x + $0.containerSize.width >= $0.contentSize.width - 24 }) { _, near in
                        nearLiveEdge = near
                    }
                    .background {
                        if let replay {
                            ReplayFollowUpdates(replay: replay, scroll: scroll, scale: scale,
                                                width: stripWidth, contentWidth: stripContentWidth)
                        } else if let head = followHead, scenePhase == .active {
                            LiveFollow(scroll: scroll, head: head, width: stripWidth, reachable: { reachable($0) }) { followsLive = false }
                        }
                    }
                    // Only an explicit Follow action reattaches a replay after manual interaction.
                    .onScrollPhaseChange { old, phase in
                        if phase == .interacting || phase == .tracking {
                            replay?.detachFollow("scroll \(old) → \(phase), user=\(scroll.position.isPositionedByUser)")
                            followsLive = false
                        }
                        guard phase == .idle, old != .idle else { return }
                        // Scrolled to the very end: follow again, as the Live button does.
                        if folder == live, nearLiveEdge, !followsLive { attach() }
                    }
                    }
                }
            }
            // The grip's immediate native recognizer owns its contact. Disabling ancestor
            // scroll views during that contact would cancel the very gesture being tracked.
            .overlay(alignment: .bottomTrailing) {
                // Shown only while detached, as the jump-to-latest control in Messages: one tap glides
                // back to the head and follows it again.
                ZStack {
                    if (folder == live || replay != nil), !following {
                        Button(action: attach) {
                            Label(folder == live ? "Live" : "Playhead", systemImage: folder == live ? "arrow.right.to.line" : "scope")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .help(folder == live ? "Follow the recording again. Scrolling to the end does the same."
                              : "Follow the playhead again. Manual dragging and scrolling keep it detached.")
                        .accessibilityLabel(folder == live ? "Follow the recording again" : "Follow the playhead again")
                        .accessibilityIdentifier("timeline.follow")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(12)
                .animation(.smooth(duration: 0.25), value: following)
            }
            .overlay {
                // A long run takes a moment to read; the strip stays usable meanwhile.
                if eventsRead < 0 {
                    ProgressView("Reading this run…").controlSize(.small).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            detailPanel
            }
        }
        .background(Color(white: 0.09))
        .foregroundStyle(.white)
        // An instrument, not a page of the app: always dark, like a debugger's timeline.
        // Only the panel: the app behind it keeps its own appearance.
        .environment(\.colorScheme, .dark)
        .sheet(item: $inspected) { item in
            // A live request can finish while its inspector is open.
            let current = self.lanes.flatMap(\.rows).flatMap { $0 }.first { $0.id == item.id } ?? item
            TimelineEventDetail(item: current)
        }
        .onAppear {
            #if DEBUG
            FrameProbe.shared.start()
            #endif
            load()
        }
        // Back in front: what was written meanwhile is read at once.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { load() }
        }
        .task(id: Poll(folder: folder, live: live, active: scenePhase == .active)) {
            // The run that is still being written is read again every half second, as long as
            // it is the one shown and the scene is in front.
            guard scenePhase == .active, let live, folder == live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                // Cancelled while asleep: nothing is read any more.
                guard !Task.isCancelled else { return }
                await poll()
            }
        }
    }

    /// The recording as a signal: one stroke per twentieth of a second, as tall as it was loud,
    /// on the same time axis as everything else.
    private func signal(height: CGFloat) -> some View {
        let samples = peaks
        let loudest = max(samples.max() ?? 0, 0.05)
        let step = scale / 20
        let totalWidth = x(Double(samples.count) / 20)
        let tiles = Int(ceil(totalWidth / 512))
        let first = min(tiles, max(0, Int((visiblePixels.lowerBound - x(timeline.soundBegins)) / 512)))
        let last = min(tiles, max(first, Int(ceil((visiblePixels.upperBound - x(timeline.soundBegins)) / 512))))
        return ZStack(alignment: .topLeading) {
            ForEach(first..<last, id: \.self) { tile in
                Canvas { context, size in
                    var path = Path()
                    let from = CGFloat(tile) * 512
                    let begin = min(samples.count, max(0, Int(from / step)))
                    let end = min(samples.count, Int(ceil((from + 512) / step)))
                    for index in begin..<end {
                        let reach = max(0.5, CGFloat(samples[index] / loudest) * (size.height / 2 - 2))
                        let at = CGFloat(index) * step - from
                        path.move(to: CGPoint(x: at, y: size.height / 2 - reach))
                        path.addLine(to: CGPoint(x: at, y: size.height / 2 + reach))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.38)), lineWidth: max(1, step - 0.8))
                }
                .frame(width: 512, height: height)
                .clipped()
                .offset(x: CGFloat(tile) * 512)
            }
        }
        .frame(width: totalWidth, height: height, alignment: .topLeading)
        // What is read is drawn when it is read; while recording, the clock uncovers it frame by
        // frame, so the sound flows in instead of arriving in half-second blocks.
        .mask(alignment: .leading) {
            if folder == live {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: scenePhase != .active)) { context in
                    Rectangle().frame(width: max(0, x(liveTime(at: context.date) - timeline.soundBegins)))
                }
            } else {
                Rectangle()
            }
        }
        .offset(x: x(timeline.soundBegins))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func height(of rows: [[Item]]) -> CGFloat { CGFloat(max(1, rows.count)) * rowHeight + 8 }

    private var header: some View {
        Group {
            if sizeClass == .compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        closeButton
                        runTitle
                        Spacer(minLength: 0)
                        runPicker
                        tokenCounter
                    }
                    ScrollView(.horizontal) { counters }.scrollIndicators(.hidden)
                }
            } else {
                HStack(spacing: 20) {
                    closeButton
                    runTitle
                    if let onReplay, let folder, replay == nil {
                        // Icons of a fixed size, like Close: squeezed by the counters, a titled button
                        // wrapped its title into a tall empty capsule (18 November 2026).
                        Button("Replay", systemImage: "play.fill") { onReplay(folder) }
                            .labelStyle(.iconOnly).buttonStyle(.bordered).fixedSize()
                            .help("Go through this run again")
                    }
                    Divider().frame(height: 28)
                    counters
                    Spacer()
                    runPicker
                    tokenCounter
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly).buttonStyle(.bordered).fixedSize()
    }

    private var runTitle: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(folder?.lastPathComponent ?? "No run").font(.subheadline.weight(.semibold).monospacedDigit())
                ReplayMomentContent(replay: replay, fallback: timeline.length) { moment in
                    Text(folder == live ? "being recorded now" : replay != nil ? String(format: "recorded events through %.1f s", moment) : "recorded run")
                        .font(.caption2).foregroundStyle(folder == live ? .red : .secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: 340, alignment: .leading)
    }

    private var counters: some View {
            ReplayMomentContent(replay: replay, fallback: timeline.length) { moment in
                let shown = timeline.statistics(at: moment)
                HStack(spacing: 20) {
            stat("\(shown.sentences)", "sentences")
            stat("\(shown.requests)", "requests")
            if !timeline.toolRequests.isEmpty { stat("\(shown.toolRequests)", "MCP calls") }
            stat("\(shown.openNow)", "open now", strong: shown.openNow > 0)
            stat("\(shown.saidNothing)", "said nothing")
            stat("\(shown.heldBack)", "held back")
            stat("\(shown.cardEvents)", "card events")
            stat("\(shown.blocks)", "blocks")
                }
            }
    }

    private var tokenCounter: some View {
        ReplayMomentContent(replay: replay, fallback: timeline.length) { moment in
            let shown = timeline.statistics(at: moment)
            VStack(alignment: .trailing, spacing: 1) {
                Text(shown.tokenCountLabel)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("tokens").font(.caption2).foregroundStyle(.secondary)
            }
            // Reserve the entire column, including the lower-bound prefix. It never
            // displaces the counters to its left when usage becomes incomplete.
            .frame(width: 132, alignment: .trailing)
            .layoutPriority(1)
            .help(shown.tokenUsageDetail)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("timeline.tokens")
            .accessibilityLabel("Token usage")
            .accessibilityValue("\(shown.tokenCountLabel) tokens. \(shown.tokenUsageDetail)")
        }
    }

    @ViewBuilder private var runPicker: some View {
            if replay == nil { Menu {
                ForEach(runs.prefix(60), id: \.self) { run in
                    Button(run == live ? "\(run.lastPathComponent) · now" : run.lastPathComponent) {
                        folder = run
                        pinned = nil
                        hovered = nil
                        eventsRead = -1
                        load()
                    }
                }
            } label: {
                Label("Runs", systemImage: "clock.arrow.circlepath")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Open another run")
            }
    }

    private func stat(_ value: String, _ label: String, strong: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(strong ? .orange : .white)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    private var ticks: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleTicks, id: \.self) { second in
                Text("\(second / 60):" + String(format: "%02d", second % 60))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .offset(x: x(Double(second)) + 3, y: 4)
            }
        }
        .frame(width: stripContentWidth, height: rulerHeight, alignment: .topLeading)
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .local) { point in replay?.seek(to: Double(point.x / scale)) }
        .accessibilityIdentifier("replay.ruler")
    }

    /// Load: one cell per second, hotter the more requests were open in it.
    private var heat: some View {
        let load = recordedLoad
        let most = max(1, load.max() ?? 1)
        return ZStack(alignment: .topLeading) {
            ForEach(min(load.count, max(0, Int(visiblePixels.lowerBound / scale)))..<min(load.count, Int(visiblePixels.upperBound / scale) + 1), id: \.self) { second in
                let open = load[second]
                Rectangle()
                    .fill(open == 0 ? Color.white.opacity(0.05)
                        : Color(hue: 0.13 - 0.13 * Double(open) / Double(most), saturation: 0.85, brightness: 0.95).opacity(0.4 + 0.6 * Double(open) / Double(most)))
                    .frame(width: scale - 1, height: 16)
                    .overlay { if open > 0 { Text("\(open)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(.black.opacity(0.8)) } }
                    .offset(x: x(Double(second)), y: 7)
            }
        }
        .frame(height: 30, alignment: .topLeading)
    }

    private func box(_ item: Item) -> some View {
        let chosen = pinned?.id == item.id
        return Button {
            pinned = item
            detailsExpanded = true
        } label: {
            Text(item.label)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .frame(width: width(item), height: 22, alignment: .leading)
                .background(item.tint.opacity(item.filled ? 0.30 : 0.10), in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(chosen ? .white : item.tint.opacity(0.85), lineWidth: chosen ? 2 : 1))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hovered = item } else if hovered?.id == item.id { hovered = nil } }
        .accessibilityLabel(item.title)
        .accessibilityHint("Selects this event. Use Open details for the full inspection.")
        .help("Select this event")
    }

    /// The event under the pointer, or the one that was clicked.
    private var detailPanel: some View {
        let item = hovered ?? pinned
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    detailsExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                        Text(item?.title ?? "Event details").lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(detailsExpanded ? "Hide event details" : "Show event details")
                .help("Point at an event for a preview; click to select it. Use Open details for the full inspection.")
                if let item {
                    Button("Open details", systemImage: "arrow.up.left.and.arrow.down.right") { inspected = item }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .padding(.trailing, 16)
                }
            }
            if detailsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let item {
                            Text(item.text).font(.footnote.monospaced()).textSelection(.enabled)
                        } else {
                            Text("Point at an event for a preview; click to select it. Use Open details for the full inspection.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .frame(height: item == nil ? 44 : 100)
            }
        }
        .background(Color(white: 0.13))
    }
}

/// Recorded text is rendered verbatim: model output is never executed or interpreted as UI.
private struct TimelineEventDetail: View {
    let item: RunTimelineView.Item
    @Environment(\.dismiss) private var dismiss

    private var sections: [TimelineDetailSection] {
        item.sections.isEmpty ? [.init(title: "Event", text: item.text)] : item.sections
    }

    private var document: String {
        ([item.title] + sections.map { "\($0.title)\n\($0.text)" }).joined(separator: "\n\n")
    }

    private func heading(_ section: TimelineDetailSection) -> some View {
        HStack {
            Text(section.title).font(.headline)
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = section.text }
                .font(.caption).buttonStyle(.bordered)
                .accessibilityLabel("Copy \(section.title)")
        }
    }

    private func text(_ section: TimelineDetailSection) -> some View {
        Text(verbatim: section.text)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text(item.title).font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            if ["Instructions", "Input"].contains(section.title), section.text != "Not recorded for this run." {
                                DisclosureGroup {
                                    text(section).padding(.top, 8)
                                } label: {
                                    heading(section)
                                }
                                .tint(.secondary)
                            } else {
                                heading(section)
                                text(section)
                            }
                        }
                        .padding(16)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("Event details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(white: 0.1), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy all", systemImage: "doc.on.doc") { UIPasteboard.general.string = document }
                }
            }
        }
        .frame(idealWidth: 860, idealHeight: 700)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }
}

extension Transaction {
    /// A change that is there at once: it carries no animation, and the animations set on
    /// the views it reaches (`.animation(_:value:)`) do not take it up either.
    static var withoutAnyAnimation: Transaction {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return transaction
    }
}

/// The timeline as the lower panel of a screen. Its upper edge is a grip: dragging it
/// makes the panel taller or lower, following the hand at once. It never takes more than
/// half of the height there is, so what lies above it stays usable, and it does not get
/// lower than it can be read, unless half of the height is less than that.
struct TimelinePanel<Content: View>: View {
    /// The share of the height the panel takes until it is dragged.
    var share: CGFloat
    var content: Content
    /// The height the hand asked for; nil until the grip was dragged. Kept as asked, so a
    /// window that grows again gives the panel back what a smaller one could not.
    @State private var wanted: CGFloat?
    /// The height the panel has on the screen right now.
    @State private var shown: CGFloat = 0
    /// The height the panel had when the grip was taken; nil while nobody holds it.
    @GestureState private var draggedFrom: CGFloat? = nil

    /// Below this there is no room for the grip, the header, the ruler with the load and a
    /// lane or two above the folded details.
    static var least: CGFloat { 220 }
    /// Never more than this share of the height there is.
    static var mostShare: CGFloat { 0.5 }

    /// How tall the panel is. The upper limit wins over the lower one on a small window.
    static func height(wanted: CGFloat?, share: CGFloat, of available: CGFloat) -> CGFloat {
        min(max(least, wanted ?? available * share), available * mostShare)
    }

    init(share: CGFloat, @ViewBuilder content: () -> Content) {
        self.share = share
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            grip
            content
        }
        .containerRelativeFrame(.vertical) { available, _ in Self.height(wanted: wanted, share: share, of: available) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown = $0 }
    }

    private var gripHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        28
        #else
        44
        #endif
    }

    private var grip: some View {
        Capsule().fill(.white.opacity(draggedFrom == nil ? 0.35 : 0.7))
            .frame(width: 40, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: gripHeight)
            .background(Color(white: 0.09))
            .contentShape(.rect)
            .gesture(
                // Read in the screen's coordinates: the grip itself moves with the edge it drags.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($draggedFrom) { _, from, _ in
                        if from == nil { from = shown }
                    }
                    .onChanged { drag in
                        // Before the first movement the start is not stored yet: it is the height now.
                        let from = draggedFrom ?? shown
                        withTransaction(.withoutAnyAnimation) { wanted = from - drag.translation.height }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Timeline height")
            .accessibilityIdentifier("timeline.resize")
            .accessibilityValue("\(Int(shown)) points")
            .accessibilityAdjustableAction { direction in
                withTransaction(.withoutAnyAnimation) { wanted = shown + (direction == .increment ? 40 : -40) }
            }
    }
}

/// The strip's scroll position, applied in a modifier of its own. It changes on every frame
/// while a run is recorded; read in the timeline's body, each frame worked out the whole strip
/// again, every box and button, and a recording with the timeline open stood still at full
/// load (17 November 2026). Here only this modifier depends on it.
private struct StripScrollPosition: ViewModifier {
    let scroll: StripScroll
    /// While a run is recorded the live follow moves the platform scroll view itself. Bound to
    /// SwiftUI's position as well, SwiftUI wrote its own idea of the position back on every frame
    /// and the two pulled against each other: 99 % CPU in a live call (19 November 2026).
    let bound: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if bound { content.scrollPosition(Bindable(scroll).position) } else { content }
    }
}

/// While a run is recorded, keeps the strip moving with the clock on every frame, the head about
/// 160 points before the right edge. The offset is set on the platform scroll view directly:
/// through SwiftUI's scroll position, every frame worked the whole strip out again and a long
/// recording with the timeline open slowed down until macOS ended the app (17 November 2026); a
/// page-by-page follow avoided that but did not flow (18 November 2026).
private struct LiveFollow: View {
    var scroll: StripScroll
    var head: @MainActor (Date) -> CGFloat
    var width: CGFloat
    var reachable: @MainActor (CGFloat) -> CGFloat
    /// The reader moved the strip themselves: it stands elsewhere than it was put. A wheel or a
    /// trackpad does not always report a scroll phase; this sees every kind of scrolling.
    var detach: @MainActor () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            Color.clear.onChange(of: context.date, initial: true) { _, date in
                if scroll.glide == nil, let placed = scroll.placed, abs(scroll.offset - placed) > 3 {
                    detach()
                    return
                }
                var x = reachable(head(date) - width + 160)
                // Attached again by the button: a short eased glide from where the reader was, done
                // here frame by frame. An animated scroll request instead was reported back as the
                // reader's own scrolling and detached and attached the strip in a loop.
                if let glide = scroll.glide {
                    let t = min(1, max(0, date.timeIntervalSince(glide.start)) / 0.35)
                    let eased = t * t * (3 - 2 * t)
                    x = glide.from + (x - glide.from) * eased
                    if t >= 1 { scroll.glide = nil }
                }
                scroll.follow(max(0, x))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Finds the platform scroll view that holds the strip, so the live follow can move it without
/// a SwiftUI update. Placed inside the strip; the nearest scroll view above it is the strip's.
private struct StripScrollFinder: UIViewRepresentable {
    let scroll: StripScroll

    final class Finder: UIView {
        weak var scroll: StripScroll?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if scroll?.platform == nil { find() }
        }
        func find() {
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            scroll?.platform = view as? UIScrollView
        }
    }

    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.isUserInteractionEnabled = false
        view.scroll = scroll
        return view
    }

    func updateUIView(_ view: Finder, context: Context) {
        view.scroll = scroll
        view.find()
    }
}

/// The strip's scroll position, read only by the scroll view itself.
@MainActor @Observable
final class StripScroll {
    var position = ScrollPosition(idType: String.self)
    /// Where the strip was last scrolled to, and a glide back to the head under way. Not read by
    /// any view's body.
    @ObservationIgnored var offset: CGFloat = 0
    @ObservationIgnored var glide: (from: CGFloat, start: Date)?
    /// The platform scroll view of the strip, and where the live follow last put it.
    @ObservationIgnored weak var platform: UIScrollView?
    @ObservationIgnored private(set) var placed: CGFloat?
    private(set) var contentWidth: CGFloat = 0
    @ObservationIgnored private var viewportWidth: CGFloat = 0
    @ObservationIgnored private var viewportListeners: [UUID: () -> Void] = [:]
    @ObservationIgnored private var requested: CGFloat?
    @ObservationIgnored var followDiagnostic = ""

    func record(_ viewport: TimelineViewport) {
        offset = viewport.offset
        if contentWidth != viewport.content || viewportWidth != viewport.width { requested = nil }
        viewportWidth = viewport.width
        contentWidth = viewport.content
        if let requested, abs(requested - offset) < 0.5 { self.requested = nil }
        for listener in Array(viewportListeners.values) { listener() }
    }
    /// Where the strip is going: the offset last sent, until the strip reports it reached it.
    /// A request that went far astray (a hand took the strip meanwhile) no longer counts.
    var target: CGFloat {
        guard let requested, abs(requested - offset) < max(1, viewportWidth) else { return offset }
        return requested
    }
    func request(_ offset: CGFloat) {
        guard offset.isFinite, viewportWidth > 0 else { return }
        let target = min(max(0, offset), max(0, contentWidth - viewportWidth))
        guard abs(target - self.offset) > 0.25,
              requested.map({ abs($0 - target) > 0.25 }) ?? true else { return }
        requested = target
        withTransaction(.withoutAnyAnimation) { position.scrollTo(x: target) }
    }
    /// The live follow's move, every frame: straight on the platform scroll view, which SwiftUI
    /// reports back like any scroll, without working out the strip again.
    func follow(_ offset: CGFloat) {
        guard offset.isFinite, viewportWidth > 0 else { return }
        let target = min(max(0, offset), max(0, contentWidth - viewportWidth))
        // Until the platform scroll view is found (the first layout), the strip waits.
        guard let platform else {
            placed = nil
            return
        }
        let x = target - platform.adjustedContentInset.left
        if abs(platform.contentOffset.x - x) > 0.1 { platform.setContentOffset(CGPoint(x: x, y: platform.contentOffset.y), animated: false) }
        placed = target
        self.offset = target
    }

    func observeViewport(_ listener: @escaping () -> Void) -> UUID {
        let id = UUID()
        viewportListeners[id] = listener
        return id
    }
    func removeViewportObserver(_ id: UUID) { viewportListeners[id] = nil }
}


/// A geometry sample is one value, so observers never see a new offset with an old width.
struct TimelineViewport: Equatable {
    var offset: CGFloat
    var width: CGFloat
    var content: CGFloat
}
