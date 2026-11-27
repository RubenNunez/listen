import Foundation

/// Meeting text remains evidence. The ledger stores only candidates accepted by typed review;
/// neither transcript text nor a model's JSON is executable configuration.
enum MeetingKind: String, CaseIterable, Sendable {
    case decision, task, openQuestion = "open_question", information, none

    static let table: [Self] = [.decision, .task, .openQuestion]

    func title(_ language: Language) -> String {
        switch (self, language) {
        case (.decision, .de): "Entscheide"
        case (.task, .de): "Aufgaben"
        case (.openQuestion, .de): "Offene Punkte"
        case (.information, .de): "Informationen"
        case (.decision, _): "Decisions"
        case (.task, _): "Tasks"
        case (.openQuestion, _): "Open points"
        case (.information, _): "Information"
        case (.none, _): ""
        }
    }
}

struct MeetingEvidence: Equatable, Sendable {
    var id: UInt64
    var text: String
    var speaker: String?

    var state: String { "[#\(id)] [\(speaker ?? "unknown")] \(text)" }

    static func transcript(_ text: String) -> [Self] {
        text.split(separator: "\n").enumerated().compactMap { index, line in
            let pieces = line.split(separator: ":", maxSplits: 1)
            let speaker = pieces.count == 2 ? String(pieces[0]).trimmingCharacters(in: .whitespaces) : nil
            let body = String(pieces.last ?? line).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return Self(id: 1_000_000_000 + UInt64(index), text: body, speaker: speaker)
        }
    }
}

struct MeetingCandidate: Equatable, Sendable {
    var text: String
    var quote: String
    var source: UInt64
    var owner: String?
    var due: String?

    static func contains(_ phrase: String, in text: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return text.range(of: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func read(_ reply: String, evidence: [MeetingEvidence], context: [MeetingEvidence], limit: Int) throws -> [Self] {
        guard let data = reply.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], array.count <= limit else {
            throw MeetingFailure(reason: "Invalid meeting candidate array")
        }
        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        return array.compactMap { object in
            guard let text = object["text"] as? String, let quote = object["quote"] as? String,
                  let number = object["source"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let source = UInt64(number.stringValue), let line = byID[source],
                  !text.trimmingCharacters(in: .whitespaces).isEmpty, text.count <= 400,
                  !text.contains("\n"), !text.contains("\r"), !text.contains("```"), quote.count >= 3,
                  line.text.contains(quote) else { return nil }
            var owner = object["owner"] as? String
            if owner == "speaker" {
                owner = line.speaker.flatMap { knownSpeaker($0) ? $0 : nil }
            } else if let proposed = owner {
                if proposed.count > 80 || !context.contains(where: { contains(proposed, in: $0.text) }) { owner = nil }
            }
            let due = (object["due"] as? String).flatMap {
                $0.count <= 100 && !$0.contains("\n") && contains($0, in: line.text) ? $0 : nil
            }
            return Self(text: text.trimmingCharacters(in: .whitespaces), quote: quote, source: source, owner: owner, due: due)
        }
    }

    static func knownSpeaker(_ label: String) -> Bool {
        !["unknown", "someone", "jemand", "unbekannt", "overlap", "überlappung", "…"].contains(label.lowercased())
    }
}

struct MeetingDecision: Sendable {
    enum Change: String, CaseIterable, Sendable { case record, resolve, withdraw, none }
    var candidate: MeetingCandidate
    var kind: MeetingKind
    var target: UInt64?
    var change: Change
}

struct MeetingLedger: Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        var id: UInt64
        var kind: MeetingKind
        var text: String
        var owner: String?
        var due: String?
        var resolved = false
        var source: UInt64
        var quote: String
    }

    private(set) var items: [Item] = []
    private var nextID: UInt64 = 0
    static let maximumItems = 200

    mutating func apply(_ decision: MeetingDecision) {
        guard decision.kind != .none, decision.change != .none else { return }
        let candidate = decision.candidate
        let index = decision.target.flatMap { id in items.firstIndex { $0.id == id } }
            ?? items.firstIndex { $0.kind == decision.kind && Self.key($0.text) == Self.key(candidate.text) }
        if decision.change == .withdraw {
            if let index { items.remove(at: index) }
            return
        }
        guard decision.target == nil || index != nil else { return }
        if let index {
            var item = items[index]
            item.kind = decision.change == .resolve && decision.kind == .information ? item.kind : decision.kind
            item.text = candidate.text
            item.owner = candidate.owner
            item.due = candidate.due
            item.resolved = decision.change == .resolve
            item.source = candidate.source
            item.quote = candidate.quote
            items[index] = item
        } else if decision.change == .record, items.count < Self.maximumItems {
            nextID += 1
            items.append(Item(id: nextID, kind: decision.kind, text: candidate.text,
                owner: candidate.owner, due: candidate.due, source: candidate.source, quote: candidate.quote))
        }
    }

    /// A recogniser correction cannot leave a claim supported only by words it removed.
    mutating func discardInvalidQuotes(in revised: [MeetingEvidence]) {
        let changed = Dictionary(uniqueKeysWithValues: revised.map { ($0.id, $0.text) })
        items.removeAll { item in changed[item.source].map { !$0.contains(item.quote) } ?? false }
    }

    func block(_ kind: MeetingKind, language: Language) -> String {
        let lines = items.filter { $0.kind == kind }.map { line($0, language: language) }
        return kind.title(language) + "\n" + (lines.isEmpty
            ? (language == .de ? "Keine festgehaltenen Punkte." : "No recorded items.")
            : lines.joined(separator: "\n"))
    }

    func minutes(language: Language) -> String {
        (MeetingKind.table + (items.contains { $0.kind == .information } ? [.information] : [])).map {
            let content = block($0, language: language).split(separator: "\n", maxSplits: 1).map(String.init)
            return "### " + content[0] + "\n\n" + content[1]
        }.joined(separator: "\n\n")
    }

    private func line(_ item: Item, language: Language) -> String {
        var text = "- " + (item.resolved ? "✓ " : "") + item.text
        if item.kind == .task {
            let owner = item.owner.map { label -> String in
                if label == "me" || label == "You" { return language == .de ? "Du" : "You" }
                return language == .de ? label.replacingOccurrences(of: "voice ", with: "Stimme ") : label.replacingOccurrences(of: "voice ", with: "Voice ")
            } ?? (language == .de ? "offen" : "unassigned")
            text += language == .de ? " — Zuständig: \(owner)" : " — Owner: \(owner)"
        }
        if let due = item.due { text += language == .de ? "; Termin: \(due)" : "; Due: \(due)" }
        return text
    }

    private static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

struct MeetingFailure: ModelFailure { var reason: String }

enum MeetingReview {
    static func questions(candidates: [MeetingCandidate], existing: [MeetingLedger.Item], instructions: String) -> [String: Any] {
        var questions: [String: Any] = [:]
        var targets = ["new": "A genuinely new meeting item, not a paraphrase of an existing one."]
        for item in existing { targets["item_\(item.id)"] = "\(item.kind.rawValue): \(item.text)" }
        for (i, candidate) in candidates.enumerated() {
            questions["kind_\(i)"] = choice(Dictionary(uniqueKeysWithValues: MeetingKind.allCases.map { ($0.rawValue, $0.rawValue) }), "Evaluate candidate \(i) only. " + instructions)
            questions["supported_\(i)"] = ["type": "noul", "instructions": "Is every material claim in candidate \(i) supported by its evidence, with no invented agreement, answer or commitment?"]
            questions["target_\(i)"] = choice(targets, "Which existing item is candidate \(i) about? Reuse its id for a correction, answer or resolution. Otherwise new.")
            questions["change_\(i)"] = choice(Dictionary(uniqueKeysWithValues: MeetingDecision.Change.allCases.map { ($0.rawValue, $0.rawValue) }), "For candidate \(i): record adds/updates; resolve settles an existing item; withdraw retracts it; none ignores repetition or unsupported content.")
            var owners = ["none": "No supported owner, or the previous assignment was retracted."]
            if candidate.owner != nil { owners["proposed"] = "The proposed owner is explicitly assigned or made this first-person commitment." }
            if existing.contains(where: { $0.owner != nil }) { owners["existing"] = "The selected existing item's confirmed owner still applies, with no reassignment or retraction." }
            if owners.count > 1 { questions["owner_\(i)"] = choice(owners, "Evaluate candidate \(i) only. " + instructions) }
            var deadlines = ["none": "No supported deadline, or the previous deadline was retracted."]
            if candidate.due != nil { deadlines["proposed"] = "The proposed phrase explicitly states this item's deadline." }
            if existing.contains(where: { $0.due != nil }) { deadlines["existing"] = "The selected existing item's confirmed deadline still applies, with no correction or retraction." }
            if deadlines.count > 1 { questions["due_\(i)"] = choice(deadlines, "Evaluate candidate \(i) only. " + instructions) }
        }
        return questions
    }

    private static func choice(_ criteria: [String: String], _ instructions: String) -> [String: Any] {
        ["type": "choice", "criteria": criteria, "instructions": instructions]
    }

    static func read(_ reply: String, candidates: [MeetingCandidate], existing: [MeetingLedger.Item]) throws -> [MeetingDecision] {
        guard let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let answers = object["answers"] as? [String: [String: Any]] else { throw MeetingFailure(reason: "Invalid meeting classification") }
        func probability(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let p = number.doubleValue
            return p.isFinite && (0...1).contains(p) ? p : nil
        }
        func selected(_ name: String, allowed: Set<String>, threshold: Double = 0.8) throws -> String? {
            guard let answer = answers[name], answer["type"] as? String == "choice",
                  let key = answer["choice"] as? String, allowed.contains(key),
                  let probabilities = answer["probabilities"] as? [String: Any], Set(probabilities.keys) == allowed,
                  let chosen = probability(probabilities[key]), let confidence = probability(answer["confidence"]) else {
                throw MeetingFailure(reason: "Invalid meeting choice: \(name)")
            }
            let values = probabilities.values.compactMap(probability)
            guard values.count == probabilities.count, abs(values.reduce(0, +) - 1) <= 0.03,
                  chosen >= (values.max() ?? 0) - 0.001 else { throw MeetingFailure(reason: "Inconsistent meeting probabilities") }
            return chosen >= threshold && confidence >= 0.7 ? key : nil
        }
        let targets = Set(existing.map { "item_\($0.id)" } + ["new"])
        return try candidates.enumerated().compactMap { i, original in
            guard let supported = answers["supported_\(i)"], supported["type"] as? String == "noul",
                  let support = probability(supported["noul"]) else { throw MeetingFailure(reason: "Invalid meeting support vote") }
            let kind = try selected("kind_\(i)", allowed: Set(MeetingKind.allCases.map(\.rawValue)), threshold: 0.75)
            let target = try selected("target_\(i)", allowed: targets)
            let change = try selected("change_\(i)", allowed: Set(MeetingDecision.Change.allCases.map(\.rawValue)))
            var candidate = original
            let existingItem = target.flatMap { key in existing.first { "item_\($0.id)" == key } }
            var ownerChoices: Set<String> = ["none"]
            if original.owner != nil { ownerChoices.insert("proposed") }
            if existing.contains(where: { $0.owner != nil }) { ownerChoices.insert("existing") }
            if ownerChoices.count > 1 {
                let owner = try selected("owner_\(i)", allowed: ownerChoices, threshold: 0.85)
                candidate.owner = owner == "existing" ? existingItem?.owner : owner == "proposed" ? original.owner : nil
            }
            var dueChoices: Set<String> = ["none"]
            if original.due != nil { dueChoices.insert("proposed") }
            if existing.contains(where: { $0.due != nil }) { dueChoices.insert("existing") }
            if dueChoices.count > 1 {
                let due = try selected("due_\(i)", allowed: dueChoices, threshold: 0.85)
                candidate.due = due == "existing" ? existingItem?.due : due == "proposed" ? original.due : nil
            }
            guard support >= 0.85, let kind = kind.flatMap(MeetingKind.init(rawValue:)), kind != .none,
                  let target, let change = change.flatMap(MeetingDecision.Change.init(rawValue:)), change != .none else { return nil }
            guard target != "new" || change == .record else { return nil }
            return MeetingDecision(candidate: candidate, kind: kind,
                target: target == "new" ? nil : UInt64(target.dropFirst(5)), change: change)
        }
    }
}

/// A separate serial meeting lane. Normal answers never await it. End-of-session reconciliation
/// uses the same verified ledger, and never publishes late cards after Stop.
@MainActor
final class MeetingEngine {
    typealias Client = @MainActor (_ agent: String, _ sentence: UInt64, _ typed: Bool) -> (any ModelClient)?
    private let client: Client
    private let model: String
    private let language: Language
    private let prompts: SystemConfig.Prompts
    private let log: @MainActor (String, [String: Any]) -> Void
    var publish: ((_ kind: MeetingKind, _ text: String, _ trigger: UInt64) -> Void)?
    var spent: ((Double) -> Void)?
    private(set) var ledger = MeetingLedger()
    private var evidence: [UInt64: MeetingEvidence] = [:]
    private var processed: [UInt64: MeetingEvidence] = [:]
    private var task: Task<Void, Never>?
    private var stopped = false
    private var calls = 0
    private var rendered: [MeetingKind: String] = [:]
    private var failed = false

    init(language: Language, model: String, prompts: SystemConfig.Prompts, client: @escaping Client,
         log: @escaping @MainActor (String, [String: Any]) -> Void) {
        self.language = language; self.model = model; self.prompts = prompts; self.client = client; self.log = log
    }

    func ingest(_ lines: [MeetingEvidence], live: Bool = true) {
        guard !stopped else { return }
        for line in lines { evidence[line.id] = line }
        if evidence.count > 300 {
            for id in evidence.keys.sorted().prefix(evidence.count - 300) { evidence[id] = nil; processed[id] = nil }
            failed = true
        }
        guard live else { return }
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            while !self.stopped, !Task.isCancelled {
                let pending = self.evidence.values.filter { self.processed[$0.id] != $0 }.sorted { $0.id < $1.id }
                guard !pending.isEmpty else { return }
                let batch = Array(pending.prefix(8))
                let context = self.evidence.values.sorted { $0.id < $1.id }.suffix(40).map { $0 }
                do {
                    let decisions = try await self.evaluate(batch, context: context, final: false)
                    try Task.checkCancellation()
                    guard !self.stopped else { return }
                    guard batch.allSatisfy({ self.evidence[$0.id] == $0 }) else { continue }
                    for decision in decisions { self.ledger.apply(decision) }
                    self.ledger.discardInvalidQuotes(in: batch)
                    for line in batch { self.processed[line.id] = line }
                    self.publishChanges(trigger: batch.last!.id)
                } catch {
                    if Task.isCancelled || self.stopped { return }
                    self.failed = true
                    for line in batch { self.processed[line.id] = line }
                    self.log("meeting", ["state": "unavailable", "sentence": batch.last!.id,
                                         "reason": (error as? any ModelFailure)?.reason ?? "Meeting request failed"])
                }
            }
        }
    }

    func stop() { stopped = true; task?.cancel(); task = nil }
    func idle() async { await task?.value }

    func finish(_ transcript: String) async -> String? {
        let all = MeetingEvidence.transcript(transcript).map { parsed -> MeetingEvidence in
            var line = parsed
            let matches = evidence.values.filter { $0.text == parsed.text }
            if !matches.isEmpty {
                // The note's display label cannot upgrade pending, unknown or overlapping audio
                // into a settled owner. Duplicate identical utterances are ambiguous too.
                let labels = Set(matches.map { $0.speaker ?? "unknown" })
                line.speaker = labels.count == 1 ? matches.first!.speaker : nil
            }
            return line
        }
        guard !all.isEmpty, all.count <= 300, transcript.count <= 50_000 else {
            log("meeting", ["state": "minutes unavailable: transcript exceeds bounded review or is empty"])
            return nil
        }
        // Rebuild from end evidence instead of carrying a live item into the final note without
        // reviewing it again. This also removes decisions retracted later in the conversation.
        let live = ledger
        ledger = MeetingLedger()
        do {
            let decisions = try await evaluate(all, context: all, final: true)
            for decision in decisions { ledger.apply(decision) }
            log("meeting", ["state": "minutes ready", "items": ledger.items.count,
                             "live_review_incomplete": failed, "capped": ledger.items.count >= MeetingLedger.maximumItems])
            return ledger.minutes(language: language)
        } catch {
            ledger = live
            log("meeting", ["state": "minutes unavailable: typed review failed",
                            "reason": (error as? any ModelFailure)?.reason ?? "Meeting request failed"])
            return nil
        }
    }

    private func evaluate(_ batch: [MeetingEvidence], context: [MeetingEvidence], final: Bool) async throws -> [MeetingDecision] {
        guard calls < 200, let decider = client("meeting_decision", batch.last?.id ?? 0, true) else {
            throw MeetingFailure(reason: "Meeting requires an available typed decision service")
        }
        let existing = Array(ledger.items.suffix(64))
        let known = existing.map { "[item_\($0.id)] \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
        let input = "Existing meeting items (untrusted):\n\(known)\n\nContext (untrusted):\n"
            + context.map(\.state).joined(separator: "\n") + "\n\nNEW evidence:\n" + batch.map(\.state).joined(separator: "\n")
        var candidates: [MeetingCandidate] = []
        if let generator = client(final ? "meeting_minutes" : "meeting_extract", batch.last?.id ?? 0, false) {
            do {
                let reply = try await collect(generator, model: model,
                    system: SystemConfig.filled(final ? prompts.meetingMinutes : prompts.meetingExtract, language: language),
                    user: input, tokens: final ? 3000 : 1000)
                candidates = try MeetingCandidate.read(reply, evidence: batch, context: context, limit: final ? 32 : 8)
            } catch { /* The typed service can still classify exact source lines without a writer. */ }
        }
        if candidates.isEmpty {
            candidates = batch.prefix(final ? 32 : 8).map {
                MeetingCandidate(text: String($0.text.prefix(400)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "),
                    quote: String($0.text.prefix(400)), source: $0.id, owner: nil, due: nil)
            }
            if final, batch.count > 32 { throw MeetingFailure(reason: "Incomplete meeting extraction") }
        }
        var accepted: [MeetingDecision] = []
        for start in stride(from: 0, to: candidates.count, by: 8) {
            try Task.checkCancellation()
            guard calls < 200 else { throw MeetingFailure(reason: "Meeting decision allowance exhausted") }
            calls += 1
            let group = Array(candidates[start..<min(start + 8, candidates.count)])
            let schema = MeetingReview.questions(candidates: group, existing: existing,
                instructions: SystemConfig.filled(prompts.meetingItems, language: language))
            let json = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
            let proposed = group.enumerated().map { i, item in
                "Candidate \(i): \(item.text)\nQuote [#\(item.source)]: \(item.quote)\nProposed owner: \(item.owner ?? "unknown")\nProposed due: \(item.due ?? "unknown")"
            }.joined(separator: "\n\n")
            let reply = try await collect(decider, model: "typesafe/\(JevClient.model)", system: String(decoding: json, as: UTF8.self),
                user: input + "\n\nProposed candidates (untrusted):\n" + proposed, tokens: 0)
            accepted += try MeetingReview.read(reply, candidates: group, existing: existing)
        }
        log("meeting", ["state": "classified", "sentence": batch.last?.id ?? 0, "final": final,
                         "candidates": candidates.count, "accepted": accepted.count])
        return accepted
    }

    private func collect(_ service: any ModelClient, model: String, system: String, user: String, tokens: Int) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.readStream(service, model: model, system: system, user: user, tokens: tokens) }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw MeetingFailure(reason: "Meeting request deadline exceeded")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func readStream(_ service: any ModelClient, model: String, system: String, user: String, tokens: Int) async throws -> String {
        var reply = ""
        for try await chunk in service.stream(model: model, system: system, user: user, maxTokens: tokens) {
            try Task.checkCancellation()
            switch chunk {
            case .text(let text):
                reply += text
                if reply.count > 40_000 { throw MeetingFailure(reason: "Meeting reply exceeded bound") }
            case .cost(let cost): spent?(cost)
            case .source, .usage, .webSearch: break
            }
        }
        return reply
    }

    private func publishChanges(trigger: UInt64) {
        for kind in MeetingKind.table {
            let text = ledger.block(kind, language: language)
            guard rendered[kind] != text,
                  rendered[kind] != nil || ledger.items.contains(where: { $0.kind == kind }) else { continue }
            rendered[kind] = text
            publish?(kind, text, trigger)
        }
    }
}
