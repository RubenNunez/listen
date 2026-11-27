@preconcurrency import WhisperKit
import Foundation
import SpeakerKit

// `check diarize-json <canonical.wav> <output.json>`: exact model segments for
// scoring against an independent reference, without forcing a speaker count.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "diarize-json" {
    let path = CommandLine.arguments[2]
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    func u16(_ at: Int) -> UInt16 { bytes.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self)) } }
    func u32(_ at: Int) -> UInt32 { bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) } }
    guard bytes.count >= 44, String(data: bytes[0..<4], encoding: .ascii) == "RIFF",
          String(data: bytes[8..<12], encoding: .ascii) == "WAVE",
          String(data: bytes[12..<16], encoding: .ascii) == "fmt ", u32(16) == 16,
          u16(20) == 1, u16(22) == 1, u32(24) == 16_000, u16(34) == 16,
          String(data: bytes[36..<40], encoding: .ascii) == "data",
          Int(u32(40)) == bytes.count - 44 else {
        FileHandle.standardError.write(Data("Expected canonical 44-byte-header 16 kHz mono 16-bit PCM\n".utf8))
        exit(2)
    }
    let samples = bytes.dropFirst(44).withUnsafeBytes {
        $0.bindMemory(to: Int16.self).map { Float($0) / 32_768 }
    }
    let kit = try await SpeakerKit()
    let began = Date()
    let result = try await kit.diarize(audioArray: samples)
    let output: [String: Any] = [
        "input": URL(fileURLWithPath: path).lastPathComponent,
        "audio_seconds": Double(samples.count) / 16_000,
        "compute_seconds": Date().timeIntervalSince(began),
        "mode": "whole recording, default options, no speaker count supplied",
        "segments": result.segments.map { segment -> [String: Any] in
            ["start": Double(segment.startTime), "end": Double(segment.endTime),
             "speaker": segment.speaker.speakerId.map { String($0) } as Any? ?? NSNull()]
        },
    ]
    try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    print("Wrote \(result.segments.count) diarization segments")
    exit(0)
}

// `check system`: the built-in configuration as the app writes it to system.json.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "system" {
    print(SystemConfig().json)
    exit(0)
}
// `check distances <file.wav>...`: how far apart the model's speakers are within one run.
// Used to tell a real second person from one voice the model split in two.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "distances" {
    let kit = try await SpeakerKit()
    for path in CommandLine.arguments.dropFirst(2) {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path)).dropFirst(44)
        let samples = bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32_768 } }
        let result = try await kit.diarize(audioArray: samples)
        let ids = result.speakerCentroidEmbeddings.keys.sorted()
        var pairs: [String] = []
        for a in ids { for b in ids where a < b { pairs.append("\(a)-\(b): " + String(format: "%.3f", result.centroidCosineDistance(between: a, and: b) ?? -1)) } }
        print(URL(fileURLWithPath: path).lastPathComponent, "speakers", ids.count, pairs.joined(separator: "  "))
    }
    exit(0)
}
// `check speakers <file.wav> <truth.rttm> [offset seconds]`: how well the speaker model tells
// the people of a recording apart, against who really spoke (RTTM), for several settings.
// The share is of the time in which exactly one person speaks, in steps of 0.1 s, with every
// voice of the model counted for the person it was heard for most.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "speakers" {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])).dropFirst(44)
    let samples = bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32_768 } }
    let offset = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 0 : 0
    let length = Double(samples.count) / 16_000
    var truth: [(Double, Double, String)] = []
    for line in try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count > 7, let start = Double(parts[3]), let lasts = Double(parts[4]) else { continue }
        truth.append((start - offset, start + lasts - offset, String(parts[7])))
    }
    let steps = Int(length * 10)
    // Who speaks in each step; nil for silence or for several at once.
    let real: [String?] = (0..<steps).map { step in
        let t = (Double(step) + 0.5) / 10
        let now = Set(truth.filter { $0.0 <= t && t < $0.1 }.map(\.2))
        return now.count == 1 ? now.first : nil
    }
    let kit = try await SpeakerKit()
    let variants: [(String, PyannoteDiarizationOptions?)] = [
        ("default", nil),
        ("threshold 0.6", PyannoteDiarizationOptions(clusterDistanceThreshold: 0.6)),
        ("threshold 0.7", PyannoteDiarizationOptions(clusterDistanceThreshold: 0.7)),
        ("threshold 0.8", PyannoteDiarizationOptions(clusterDistanceThreshold: 0.8)),
        ("min cluster 5", PyannoteDiarizationOptions(minClusterSize: 5)),
    ]
    print(String(format: "%.0f s of sound, %d people, one person speaking in %.0f s of it", length, Set(truth.map(\.2)).count, Double(real.compactMap { $0 }.count) / 10))
    for (name, options) in variants {
        let result = try await kit.diarize(audioArray: samples, options: options)
        var pairs: [String: [Int: Int]] = [:]
        var silent = 0
        for step in 0..<steps {
            guard let person = real[step] else { continue }
            let t = Float((Double(step) + 0.5) / 10)
            let voices = result.segments.filter { $0.startTime <= t && t < $0.endTime }.compactMap(\.speaker.speakerId)
            guard let voice = voices.first else {
                silent += 1
                continue
            }
            pairs[person, default: [:]][voice, default: 0] += 1
        }
        let voices = Set(pairs.values.flatMap(\.keys))
        let right = voices.reduce(0) { sum, voice in sum + (pairs.values.map { $0[voice] ?? 0 }.max() ?? 0) }
        let total = pairs.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        print(String(format: "  %@: %d voices, %.1f%% of the speech in a voice that stands for its speaker, %.0f s of speech heard as silence",
            name, voices.count, 100 * Double(right) / Double(max(total, 1)), Double(silent) / 10))
    }
    exit(0)
}
// `check voices <file.wav> <events.jsonl> <truth.rttm> [offset] [shortest voice] [same voice distance] [after]`:
// the app's own assignment of voices to sentences, replayed without waiting: the sentences of a
// recorded run are given to the refiner one after the other, each with the sound up to its end
// (and `after` seconds beyond it), as in a conversation. Says how many sentences end in a voice that
// stands for their speaker, and how many had such a voice when they were first shown ("live").
if CommandLine.arguments.count > 4, CommandLine.arguments[1] == "voices" {
    let args = CommandLine.arguments
    let bytes = try Data(contentsOf: URL(fileURLWithPath: args[2])).dropFirst(44)
    let samples = bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32_768 } }
    let offset = args.count > 5 ? Double(args[5]) ?? 0 : 0
    var voice = SystemConfig.Voice()
    voice.whisper = false
    voice.swissGerman = false
    if args.count > 6, let value = Double(args[6]) { voice.shortestVoiceSeconds = value }
    if args.count > 7, let value = Double(args[7]) { voice.sameVoiceDistance = value }
    let after = args.count > 8 ? Double(args[8]) ?? 0 : 0
    var truth: [(Double, Double, String)] = []
    for line in try String(contentsOfFile: args[4], encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count > 7, let start = Double(parts[3]), let lasts = Double(parts[4]) else { continue }
        truth.append((start - offset, start + lasts - offset, String(parts[7])))
    }
    // The last state of every sentence in the run: where it lies in the sound.
    var spans: [UInt64: (Double, Double)] = [:]
    for line in try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n") {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], event["kind"] as? String == "sentence",
            let id = (event["id"] as? NSNumber)?.uint64Value, let from = (event["start_ms"] as? NSNumber)?.doubleValue,
            let to = (event["end_ms"] as? NSNumber)?.doubleValue
        else { continue }
        spans[id] = (from / 1000, to / 1000)
    }
    let refiner = WhisperRefiner(language: .en, glossary: "", voice: voice)
    await refiner.prepare { _ in }
    var assigned: [UInt64: UInt32] = [:]
    var live: [UInt64: UInt32] = [:]
    // What a sentence shows when its voice is given only by the run after its own.
    var next: [UInt64: UInt32] = [:]
    var previous: UInt64?
    for (id, span) in spans.sorted(by: { $0.key < $1.key }) {
        let end = min(samples.count, Int(span.1 * 16_000))
        let start = min(end, Int(span.0 * 16_000))
        guard end > start else { continue }
        let heard = min(samples.count, end + Int(after * 16_000))
        let request = RefineRequest(segmentID: id, window: Array(samples[0..<heard]), windowStart: 0, sentence: start..<end, heard: "")
        for (sentence, found) in await refiner.voices(for: request).found { assigned[sentence] = found }
        live[id] = assigned[id]
        if let previous { next[previous] = assigned[previous] }
        previous = id
    }
    if let previous { next[previous] = assigned[previous] }
    /// `stands`: sentences in a voice that stands for their speaker (several voices may stand for one
    /// person). `right`: one voice per person and one person per voice, as a reader sees them: a person
    /// split into two voices, or a voice for someone who never spoke, is wrong for the extra voice.
    func score(_ assigned: [UInt64: UInt32]) -> (pairs: [String: [UInt32: Int]], stands: Int, right: Int, total: Int) {
        var pairs: [String: [UInt32: Int]] = [:]
        for (id, span) in spans {
            guard let found = assigned[id] else { continue }
            var share: [String: Double] = [:]
            for turn in truth {
                let overlap = min(span.1, turn.1) - max(span.0, turn.0)
                if overlap > 0 { share[turn.2, default: 0] += overlap }
            }
            guard let person = share.max(by: { $0.value < $1.value })?.key else { continue }
            pairs[person, default: [:]][found, default: 0] += 1
        }
        let voices = Set(pairs.values.flatMap(\.keys))
        let stands = voices.reduce(0) { sum, one in sum + (pairs.values.map { $0[one] ?? 0 }.max() ?? 0) }
        var ranked = pairs.flatMap { person, found in found.map { (person: person, voice: $0.key, count: $0.value) } }
        ranked.sort { $0.count != $1.count ? $0.count > $1.count : ($0.person, $0.voice) < ($1.person, $1.voice) }
        var people = Set<String>(), taken = Set<UInt32>(), right = 0
        for pair in ranked where !people.contains(pair.person) && !taken.contains(pair.voice) {
            people.insert(pair.person); taken.insert(pair.voice); right += pair.count
        }
        return (pairs, stands, right, pairs.values.reduce(0) { $0 + $1.values.reduce(0, +) })
    }
    let final = score(assigned), shown = score(live), later = score(next)
    let voices = Set(final.pairs.values.flatMap(\.keys))
    print(String(format: "shortest voice %.1f s, same voice below %.2f: %d voices, %d of %d sentences in a voice that stands for their speaker", voice.shortestVoiceSeconds, voice.sameVoiceDistance, voices.count, final.stands, final.total))
    print(String(format: "one voice per person, %.1f s heard after each sentence: at the end %d of %d; when first shown %d of %d, %d without a voice yet; one run later %d of %d", after, final.right, final.total, shown.right, shown.total, final.total - shown.total, later.right, later.total))
    for (person, found) in final.pairs.sorted(by: { $0.key < $1.key }) {
        print("  \(person): " + found.sorted { $0.key < $1.key }.map { "voice \($0.key) × \($0.value)" }.joined(separator: ", "))
    }
    exit(0)
}
// `check diarize <file.wav>...`: what the speaker model hears in a whole recording at once,
// with its default settings and with others, to see what it can tell apart at best.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "diarize" {
    let kit = try await SpeakerKit()
    for path in CommandLine.arguments.dropFirst(2) {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path)).dropFirst(44)
        let all = bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32_768 } }
        let speech = WhisperRefiner.withoutSilence(all)
        print("==", path, String(format: "%.0f s, %.0f s without silence", Double(all.count) / 16_000, Double(speech.samples.count) / 16_000))
        let variants: [(String, [Float], PyannoteDiarizationOptions?)] = [
            ("default", all, nil),
            ("no silence", speech.samples, nil),
            ("threshold 0.5", all, PyannoteDiarizationOptions(clusterDistanceThreshold: 0.5)),
            ("threshold 0.4", all, PyannoteDiarizationOptions(clusterDistanceThreshold: 0.4)),
            ("two speakers", all, PyannoteDiarizationOptions(numberOfSpeakers: 2)),
        ]
        for (name, samples, options) in variants {
            let result = try await kit.diarize(audioArray: samples, options: options)
            let ids = result.speakerCentroidEmbeddings.keys.sorted()
            var pairs: [String] = []
            for a in ids { for b in ids where a < b { pairs.append("\(a)-\(b): " + String(format: "%.2f", result.centroidCosineDistance(between: a, and: b) ?? -1)) } }
            var time: [Int: Float] = [:]
            for segment in result.segments { time[segment.speaker.speakerId ?? -1, default: 0] += segment.endTime - segment.startTime }
            print(" ", name, "| speakers", time.sorted { $0.key < $1.key }.map { "\($0.key): " + String(format: "%.0f s", $0.value) }.joined(separator: ", "), "| distances", pairs.joined(separator: " "))
            if name == "default" || name == "two speakers" {
                print("   ", result.segments.map { "\($0.speaker.speakerId ?? -1)@" + String(format: "%.0f-%.0f", $0.startTime, $0.endTime) }.joined(separator: " "))
            }
        }
    }
    exit(0)
}
// `check dialect <audio.raw>...`: loads the Swiss German model alone, says how long that took, and
// writes each file (16 kHz mono 16-bit, at most its first 30 s) with it.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "dialect" {
    let began = Date()
    let kit = try await WhisperKit(WhisperKitConfig(
        modelFolder: WhisperRefiner.dialectFolder.path, verbose: false, logLevel: .error, download: false))
    print(String(format: "loaded after %.1f s", Date().timeIntervalSince(began)))
    for path in CommandLine.arguments.dropFirst(2) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16_000 * 2 * 30)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Float($0) / 32_768 } }
        let started = Date()
        let results = try await kit.transcribe(
            audioArray: samples, decodeOptions: DecodingOptions(language: "de", skipSpecialTokens: true, withoutTimestamps: true))
        print(String(format: "%.1f s of sound in %.2f s:", Double(samples.count) / 16_000, Date().timeIntervalSince(started)),
              results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    exit(0)
}

// `check dialect-primed <run folder> <glossary> <out.json> [sentences]`: the Swiss German model on
// every sentence of a recorded run, once as the app runs it and once with the topic's terms as its
// prompt (as Whisper gets them), to measure whether the terms help it.
if CommandLine.arguments.count > 4, CommandLine.arguments[1] == "dialect-primed" {
    let run = URL(fileURLWithPath: CommandLine.arguments[2])
    let glossary = CommandLine.arguments[3]
    let limit = CommandLine.arguments.count > 5 ? Int(CommandLine.arguments[5]) ?? Int.max : Int.max
    let bytes = try Data(contentsOf: run.appending(path: "audio.wav")).dropFirst(44)
    let samples = bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32_768 } }
    var first: [Int: String] = [:]
    var final: [Int: (start: Int, end: Int, text: String)] = [:]
    for line in try String(contentsOf: run.appending(path: "events.jsonl"), encoding: .utf8).split(separator: "\n")
    where line.contains("\"kind\":\"sentence\"") {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = (event["id"] as? NSNumber)?.intValue else { continue }
        let text = event["text"] as? String ?? ""
        if first[id] == nil { first[id] = text }
        final[id] = ((event["start_ms"] as? NSNumber)?.intValue ?? 0, (event["end_ms"] as? NSNumber)?.intValue ?? 0, text)
    }
    let began = Date()
    let kit = try await WhisperKit(WhisperKitConfig(
        modelFolder: WhisperRefiner.dialectFolder.path, verbose: false, logLevel: .error, download: false))
    print(String(format: "loaded after %.1f s", Date().timeIntervalSince(began)))
    let prompt = kit.tokenizer.map { tokenizer in
        tokenizer.encode(text: " " + glossary).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.suffix(200).map { $0 }
    }
    let plain = DecodingOptions(language: "de", skipSpecialTokens: true, withoutTimestamps: true)
    var primed = plain
    primed.promptTokens = prompt
    var rows: [[String: Any]] = []
    for id in final.keys.sorted().prefix(limit) {
        let sentence = final[id]!
        // 0.2 s on both sides, as the app cuts it.
        let from = max(0, sentence.start * 16 - 3200), to = min(samples.count, sentence.end * 16 + 3200)
        guard to > from + 1600 else { continue }
        let window = Array(samples[from..<to])
        func hear(_ options: DecodingOptions) async -> String {
            let results = (try? await kit.transcribe(audioArray: window, decodeOptions: options)) ?? []
            return Correction.trimDialect(results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                                          to: first[id] ?? "")
        }
        let without = await hear(plain)
        let with = await hear(primed)
        rows.append(["id": id, "start": Double(sentence.start) / 1000, "apple": first[id] ?? "", "final": sentence.text,
                     "plain": without, "primed": with])
        if rows.count % 50 == 0 { print("\(rows.count) sentences, \(Int(Date().timeIntervalSince(began))) s") }
    }
    try JSONSerialization.data(withJSONObject: ["glossary": glossary, "prompt_tokens": prompt?.count ?? 0, "rows": rows],
                               options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
    print("wrote \(rows.count) sentences")
    exit(0)
}

// `check summary <de|en> <transcript.txt>`: the end-of-conversation summary from the model on this Mac.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "summary" {
    var settings = AnswerEngine.Settings()
    settings.language = Language(rawValue: CommandLine.arguments[2])!
    settings.merger = LocalModelClient.model
    let engine = await AnswerEngine(client: RoutedClient(local: LocalModelClient(), remote: nil), settings: settings)
    let began = Date()
    let summary = await engine.summarise(try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8))
    print(summary ?? "no summary")
    print(String(format: "%.1f s", Date().timeIntervalSince(began)))
    exit(0)
}

// `check cards <de|en> <cases.txt>`: what the output side shows for written conversations, against
// what it should show. Blocks are separated by empty lines; a block starts with CARD or NONE (what
// is expected), then the sentences. Only the model on this Mac unless OPENROUTER_API_KEY is set.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "cards" {
    let language = Language(rawValue: CommandLine.arguments[2])!
    let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
    let blocks = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        .components(separatedBy: "\n\n").map { $0.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") } }
        .filter { $0.count >= 2 }
    var passed = 0
    for block in blocks {
        var settings = AnswerEngine.Settings()
        settings.language = language
        settings.pause = .milliseconds(20)
        settings.namer = nil
        if key == nil {
            settings.drafters = [LocalModelClient.model]
            settings.merger = LocalModelClient.model
        }
        if ProcessInfo.processInfo.environment["LISTEN_GATE"] != "off" { settings.gated = [LocalModelClient.model] }
        let engine = await AnswerEngine(
            client: RoutedClient(local: LocalModelClient(), remote: key.map { OpenRouterClient(key: $0) }), settings: settings)
        // LISTEN_LINK=<address>: the page is read and given as the topic's link.
        if let link = ProcessInfo.processInfo.environment["LISTEN_LINK"] {
            let pages = await LinkContext.load([link])
            print("       page: \(pages.first.map { "\($0.title) · \($0.text.count) characters" } ?? "not readable")")
            await MainActor.run { engine.pages = pages }
        }
        final class Shown: @unchecked Sendable { var cards: [String] = [] }
        let shown = Shown()
        await MainActor.run {
            engine.emit = { event in if case .cardDelta(_, let text) = event { shown.cards.append(text) } }
        }
        let began = Date()
        for (index, sentence) in block.dropFirst().enumerated() {
            await engine.heard(
                TranscriptSegment(
                    segmentID: UInt64(index + 1), isFinal: true, revision: 1, voice: 1, speaker: .speaker(1),
                    text: sentence, startMs: 0, endMs: 0), isMine: false)
            await engine.idle()
        }
        // LISTEN_ACT=shorter|explain|technical_detail: also ask for that version of the first card.
        if let action = ProcessInfo.processInfo.environment["LISTEN_ACT"].flatMap(CardAction.init(rawValue:)), !shown.cards.isEmpty {
            _ = await engine.act(action, on: 1)
            await engine.idle()
        }
        let wantsCard = block[0].hasPrefix("CARD")
        let ok = wantsCard == !shown.cards.isEmpty
        if ok { passed += 1 }
        print("\(ok ? "ok  " : "FAIL") want \(wantsCard ? "card" : "none") · \(String(format: "%.1f s", Date().timeIntervalSince(began))) · \(block.dropFirst().joined(separator: " / "))")
        for card in shown.cards { print("       | " + card.replacingOccurrences(of: "\n", with: "\n       | ")) }
    }
    print("\(passed) of \(blocks.count) as expected")
    exit(0)
}

let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let language = Language(rawValue: CommandLine.arguments[2])!
// Third argument: words the second stage should expect ("-" switches that stage off).
let glossary = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
// The output side runs with the model on this Mac only: free, and no account is needed.
var settings = AnswerEngine.Settings()
// With OPENROUTER_API_KEY in the environment the cloud models are asked too; the key is never stored.
let cloudKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
if cloudKey == nil {
    settings.drafters = [LocalModelClient.model]
    settings.merger = LocalModelClient.model
} else if LocalModelClient.isAvailable {
    settings.drafters.insert(LocalModelClient.model, at: 0)
}
settings.language = language
settings.namer = LocalModelClient.isAvailable ? LocalModelClient.model : nil
settings.userName = ProcessInfo.processInfo.environment["LISTEN_USER"] ?? ""
print("local model available:", LocalModelClient.isAvailable)
let transport = LocalTransport(
    language: language, refiner: glossary == "-" ? nil : WhisperRefiner(language: language, glossary: glossary),
    answers: LocalModelClient.isAvailable
        ? AnswerEngine(client: RoutedClient(local: LocalModelClient(), remote: cloudKey.map { OpenRouterClient(key: $0) }), settings: settings) : nil)
var modelsReady = glossary == "-"
var listening = false
var failed = false
let began = Date()
func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(began)) }
transport.onEvent = { event in
    switch event {
    case .connected: print(stamp(), "connected")
    case .disconnected: print(stamp(), "disconnected"); failed = true
    case .envelope(let envelope):
        switch envelope.event {
        case .speakerMapping(_, let me): print(stamp(), "ME     ", me.map { "voice \($0)" } ?? "nobody")
        case .state(let state, _): print(stamp(), "STATE", state.rawValue); if state == .listening { listening = true }
        case .transcript(let segment):
            let who = (segment.voice.map { "voice \($0)" } ?? "-") + (segment.voicePending ? ", first guess" : "")
            print(stamp(), segment.isFinal ? (segment.revision > 1 && segment.voice != nil ? "REFINED" : "FINAL  ") : "partial", "#\(segment.segmentID)", "[\(who)]", segment.text)
        case .error(let code): print(stamp(), "ERROR", code.rawValue)
        case .cardStarted(let start): print(stamp(), "CARD   ", "#\(start.generationID)", "for sentence", start.triggerSegment ?? 0)
        case .cardDelta(let id, let text): print(stamp(), "CARD   ", "#\(id)", text.replacingOccurrences(of: "\n", with: " / "))
        case .cardSuperseded(let id, let by): print(stamp(), "CARD   ", "#\(id) replaced by #\(by)")
        case .budget(let spent, _, _): print(stamp(), "SPENT  ", String(format: "%.5f USD", Double(spent) / 1e9))
        default: break
        }
    }
}
transport.onStatus = { text in
    print(stamp(), "STATUS", text)
    if text.hasPrefix("Whisper"), !text.contains("loading") { modelsReady = true }
}
transport.onNames = { names in print(stamp(), "NAMES  ", names.sorted { $0.key < $1.key }.map { "voice \($0.key) = \($0.value)" }.joined(separator: ", ")) }
transport.onTrace = { trace in
    guard trace.steps.count > 2 else { return }
    if let step = trace.steps.last, step.name.hasPrefix("3") || step.name.hasPrefix("4") {
        print(stamp(), "LAYER  ", "#\(trace.id)", step.name, step.detail, step.seconds.map { String(format: "%.2fs", $0) } ?? "")
        return
    }
    print(stamp(), "LAYERS ", "#\(trace.id)", trace.steps.map { "\($0.name) \($0.detail)" + ($0.seconds.map { String(format: " %.2fs", $0) } ?? "") }.joined(separator: " | "))
}
transport.connect()
transport.send(.hello(protocolVersion: 1))
transport.send(.start(language: language, contextVersion: 0))
while !listening, !failed, Date().timeIntervalSince(began) < 180 { try await Task.sleep(for: .milliseconds(100)) }
guard listening else { print("never started listening"); exit(1) }
while !modelsReady, Date().timeIntervalSince(began) < 600 { try await Task.sleep(for: .milliseconds(100)) }
let startedAudio = Date()
var seq: UInt32 = 0
var offset = 0
let silence = Data(count: 3200)
while offset + 3200 <= raw.count {
    seq += 1
    transport.sendAudio(AudioFrame(seq: seq, captureMs: 0, pcm: Data(raw[offset..<(offset + 3200)])))
    offset += 3200
    try await Task.sleep(for: .milliseconds(100))
}
print(stamp(), "audio done after", String(format: "%.1fs", Date().timeIntervalSince(startedAudio)))
for _ in 0..<200 { seq += 1; transport.sendAudio(AudioFrame(seq: seq, captureMs: 0, pcm: silence)); try await Task.sleep(for: .milliseconds(100)) }
transport.send(.stop)
try await Task.sleep(for: .seconds(1))
