import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A recorded conversation as one file, `<date> <topic>.listen`: a ZIP archive (registered as
/// `com.meowop.listen.conversation`, conforming to ZIP, so the Finder and any unzip tool open it,
/// also when renamed to .zip) of files a person or another model can work with, beside the raw
/// log. Nothing in Listen is moved or changed; this is not the topic export (`TopicExport`).
/// On the Mac it is written straight into Downloads. Listen opens the type: a file whose
/// conversation is not on this device is unpacked into the runs folder and replayed.
///
///     <name>/
///       README.md                what is in it and how far to trust it
///       manifest.json            format, version, the run's facts, every file with its size
///       summary.md               the summary Listen wrote at the end, when there is one
///       transcript.md            every sentence: time, who, final text
///       transcript-hearings.md   per sentence: Apple's live text, the Swiss German model's, the final
///       cards.md                 the cards as they ended, then every version in time order
///       decisions.md             per sentence: the decision service's judgement and each round
///       forecasts.md             the cards prepared in advance
///       raw/                     events.jsonl (every request with prompt and reply), run.json,
///                                sides.bin, the topic's material, audio.wav only when asked for
///
/// The format is versioned; a later version adds files, it does not reinterpret them.
enum ConversationFile {
    static let format = "listen-conversation"
    static let version = 1
    static let fileExtension = "listen"
    static let type = UTType(exportedAs: "com.meowop.listen.conversation", conformingTo: .zip)

    struct Sentence: Equatable {
        var id: Int
        var start: Double
        var end: Double
        var text: String
        var voice: Int?
    }

    struct Card: Equatable {
        var id: Int
        var t: Double
        var sentence: Int?
        var text = ""
        var block: Int
        var how = ""
    }

    /// What a run's log says, gathered for the pack.
    struct Reading {
        var topic = ""
        var audioSeconds = 0.0
        var first: [Int: String] = [:]
        var final: [Int: Sentence] = [:]
        /// The Swiss German model's own text and what became of it ("taken", "not taken", …).
        var dialect: [Int: (fate: String, text: String)] = [:]
        /// The side the speaker step went by: "call app" or "microphone".
        var heardBy: [Int: String] = [:]
        var me: Int?
        /// Log time minus sound time, to place cards on the sound's clock.
        var offset = 0.0
        var cards: [Card] = []
        var decisions: [Int: [String]] = [:]
        var forecasts: [String] = []
        var requests: [String: Int] = [:]
        var tokens: [String: Int] = [:]
        var events = 0

        var sentences: [Sentence] { final.keys.sorted().compactMap { final[$0] } }
        var blocks: [(block: Int, cards: [Card])] {
            var order: [Int] = []
            var by: [Int: [Card]] = [:]
            for card in cards {
                if by[card.block] == nil { order.append(card.block) }
                by[card.block, default: []].append(card)
            }
            return order.map { ($0, by[$0] ?? []) }
        }
    }

    // MARK: Reading the log

    static func read(_ run: URL) throws -> Reading {
        let meta = TopicExport.meta(run) ?? [:]
        var reading = Reading(topic: meta["topic"] as? String ?? "", audioSeconds: number(meta["audio_seconds"]) ?? 0)
        let data = try Data(contentsOf: run.appending(path: "events.jsonl"))
        var placed = false
        var cards: [Int: Card] = [:]
        var order: [Int] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let kind = event["kind"] as? String else { continue }
            reading.events += 1
            let t = number(event["t"]) ?? 0
            switch kind {
            case "sentence":
                guard let id = integer(event["id"]) else { continue }
                let sentence = Sentence(
                    id: id, start: (number(event["start_ms"]) ?? 0) / 1000, end: (number(event["end_ms"]) ?? 0) / 1000,
                    text: event["text"] as? String ?? "", voice: integer(event["voice"]))
                if reading.first[id] == nil { reading.first[id] = sentence.text }
                reading.final[id] = sentence
                if !placed {
                    reading.offset = t - sentence.end
                    placed = true
                }
            case "layer":
                guard let id = integer(event["sentence"]), let name = event["name"] as? String,
                      let detail = event["detail"] as? String else { continue }
                if name.hasPrefix("2b") {
                    let parts = detail.split(separator: ": ", maxSplits: 1, omittingEmptySubsequences: false)
                    reading.dialect[id] = (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
                } else if name.hasPrefix("2 · Speaker") {
                    reading.heardBy[id] = detail.contains("app's sound") ? "call app" : detail.contains("microphone") ? "microphone" : nil
                }
            case "me":
                reading.me = integer(event["voice"])
            case "card_started":
                guard let id = integer(event["card"]) else { continue }
                if cards[id] == nil { order.append(id) }
                cards[id] = Card(id: id, t: t, sentence: integer(event["sentence"]), block: integer(event["block_id"]) ?? id)
            case "card_text":
                guard let id = integer(event["card"]) else { continue }
                cards[id]?.text += event["text"] as? String ?? ""
            case "landed":
                guard let id = integer(event["card"]) else { continue }
                if let block = integer(event["block"]) { cards[id]?.block = block }
                cards[id]?.how = event["how"] as? String ?? ""
            case "context", "round":
                guard let id = integer(event["sentence"]) else { continue }
                var parts = [event["phase"] as? String ?? kind, event["state"] as? String ?? ""]
                if let useful = number(event["usefulness"]) {
                    parts.append(String(format: "useful %.2f · research %.2f", useful, number(event["research"]) ?? 0)
                                 + ((event["change"] as? String).map { " · " + $0 } ?? ""))
                }
                reading.decisions[id, default: []].append(parts.filter { !$0.isEmpty }.joined(separator: " · "))
            case "forecast":
                if let prepared = event["cards"] as? [String], !prepared.isEmpty {
                    let after = integer(event["sentence"]).map { " after #\($0)" } ?? ""
                    reading.forecasts.append("\(clock(t - reading.offset))\(after): " + prepared.joined(separator: "; "))
                }
            case "model_request":
                reading.requests[event["agent"] as? String ?? "?", default: 0] += 1
            case "usage":
                reading.tokens[event["model"] as? String ?? "?", default: 0] +=
                    (integer(event["input_tokens"]) ?? 0) + (integer(event["output_tokens"]) ?? 0)
            default:
                break
            }
        }
        reading.cards = order.compactMap { cards[$0] }
        return reading
    }

    /// The microphone's and the app's loudness per 100 ms (`sides.bin`), nil for frames without sides.
    static func sides(_ run: URL) -> [(mine: Double, theirs: Double)?] {
        guard let data = try? Data(contentsOf: run.appending(path: "sides.bin")) else { return [] }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 3, by: 4).map { index in
            let mine = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let theirs = UInt16(bytes[index + 2]) | UInt16(bytes[index + 3]) << 8
            guard mine != 0xFFFF, theirs != 0xFFFF else { return nil }
            return (Double(mine) / 65_534, Double(theirs) / 65_534)
        }
    }

    /// Which side carried a stretch of sound, from the loudness: the microphone, the call app, or both.
    static func side(from start: Double, to end: Double, in sides: [(mine: Double, theirs: Double)?]) -> String? {
        var mine = 0.0, theirs = 0.0
        let first = max(0, Int(start * 10)), last = min(sides.count - 1, Int(end * 10))
        guard first <= last else { return nil }
        for frame in sides[first...last] {
            guard let frame, max(frame.mine, frame.theirs) >= 0.004 else { continue }
            mine += frame.mine * frame.mine
            theirs += frame.theirs * frame.theirs
        }
        guard mine + theirs > 0 else { return nil }
        let share = mine / (mine + theirs)
        return share >= 0.8 ? "microphone" : share <= 0.2 ? "call app" : "both"
    }

    // MARK: The files

    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Who said a sentence: the voice ("me" for the voice taken for the microphone) and the side.
    static func who(_ sentence: Sentence, in reading: Reading, sides: [(mine: Double, theirs: Double)?]) -> (voice: String, side: String?) {
        let voice = sentence.voice.map { $0 == reading.me ? "me" : "voice \($0)" } ?? "voice ?"
        let side = reading.heardBy[sentence.id] ?? side(from: sentence.start, to: sentence.end, in: sides)
        return (voice, side)
    }

    static func transcript(_ reading: Reading, sides: [(mine: Double, theirs: Double)?]) -> String {
        var lines = [
            "# Transcript · \(reading.topic)", "",
            "Final text of every sentence. Who: the speaker model's voice number (\"me\" is the voice it took for the microphone) and, in a call, which side carried the sound. The side is measured; the voice numbers are guesses.",
            "",
        ]
        for sentence in reading.sentences {
            let who = who(sentence, in: reading, sides: sides)
            lines.append("[\(clock(sentence.start))] **\(who.voice)\(who.side.map { ", " + $0 } ?? "")**: \(sentence.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func hearings(_ reading: Reading) -> String {
        var lines = [
            "# Hearings per sentence", "",
            "Apple: the live text. Swiss German: the dialect model's own text (it may hold words of the neighbouring sentence) and whether it was taken. Final: what Listen kept after the vote.",
            "",
        ]
        for sentence in reading.sentences {
            lines.append("## #\(sentence.id) · \(clock(sentence.start))")
            lines.append("- Apple: \(reading.first[sentence.id] ?? "")")
            if let dialect = reading.dialect[sentence.id] { lines.append("- Swiss German (\(dialect.fate)): \(dialect.text)") }
            lines.append("- Final: \(sentence.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func cards(_ reading: Reading) -> String {
        var lines = ["# Cards", "", "## As they ended", ""]
        for (block, cards) in reading.blocks {
            lines += ["### Block \(block) · \(cards.count) version\(cards.count == 1 ? "" : "s")", "",
                      cards.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", ""]
        }
        lines += ["## Every version in time order", ""]
        for card in reading.cards {
            let trigger = card.sentence.flatMap { reading.final[$0]?.text } ?? ""
            lines += ["### \(clock(card.t - reading.offset)) · card \(card.id) · block \(card.block)\(card.how.isEmpty ? "" : " · " + card.how)",
                      card.sentence.map { "After #\($0): \(trigger)" } ?? "", "",
                      card.text.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        }
        return lines.joined(separator: "\n")
    }

    static func decisions(_ reading: Reading) -> String {
        var lines = ["# Decisions", "", "Per sentence: the decision service's judgement and what each round did.", ""]
        for sentence in reading.sentences {
            guard let items = reading.decisions[sentence.id], !items.isEmpty else { continue }
            lines.append("## #\(sentence.id) · \(clock(sentence.start)) · \(sentence.text.prefix(90))")
            lines += items.map { "- " + $0 }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func forecasts(_ reading: Reading) -> String {
        (["# Forecasts", "", "Cards Listen prepared for the moments it expected next.", ""] + reading.forecasts.map { "- " + $0 })
            .joined(separator: "\n") + "\n"
    }

    /// From when on the end summary saw the conversation: it is written from the lines the app
    /// still holds (`SessionCore.maxLines`), cut to their last 8,000 characters. Nil when it saw all.
    static func summarySeesFrom(_ reading: Reading) -> Double? {
        let sentences = reading.sentences
        var length = 0
        var seen: Sentence?
        for sentence in sentences.suffix(SessionCore.maxLines).reversed() {
            length += sentence.text.count + 10
            if length > 8000 { break }
            seen = sentence
        }
        guard let seen, seen.id != sentences.first?.id else { return nil }
        return seen.start
    }

    static func readme(_ reading: Reading, run: String, summary: Bool, sound: Bool, sides: [(mine: Double, theirs: Double)?]) -> String {
        let voices = Set(reading.final.values.compactMap(\.voice)).count
        var lines = [
            "# \(reading.topic.isEmpty ? "Conversation" : reading.topic) · \(run)", "",
            "\(clock(reading.audioSeconds)) of sound · \(reading.final.count) sentences · \(reading.cards.count) card versions in \(reading.blocks.count) blocks · \(reading.requests.values.reduce(0, +)) model requests.",
            "",
            "A Listen conversation file (`.\(fileExtension)`, a ZIP archive). Start with `transcript.md`; the other files explain what Listen did and why.",
            "",
            "## Files", "",
        ]
        if summary {
            if let from = summarySeesFrom(reading) {
                lines.append("- `summary.md`: Listen's own summary at the end. It saw the conversation only from \(clock(from)) on; for the whole conversation, work from the transcript.")
            } else {
                lines.append("- `summary.md`: Listen's own summary at the end.")
            }
        }
        lines += [
            "- `transcript.md`: the conversation, sentence by sentence.",
            "- `transcript-hearings.md`: the hearings of every sentence, for words that were misheard.",
            "- `cards.md`: what Listen showed, as it ended and version by version.",
            "- `decisions.md`: why a moment got a card or not.",
            "- `forecasts.md`: the cards it prepared in advance.",
            "- `raw/events.jsonl`: everything, one JSON event per line, including every model request with its prompt and reply.",
            "- `raw/run.json`, `raw/sides.bin`: the run's facts; the microphone's and the call app's loudness per 100 ms (two little-endian UInt16, RMS × 65,534).",
            "- `raw/material/`: the topic's files.",
        ]
        if sound { lines.append("- `raw/audio.wav`: the sound, 16 kHz mono.") }
        lines += [
            "", "## How far to trust it", "",
            "- Speech recognition misses and garbles words, Swiss German most; compare the hearings before quoting.",
            "- Voices: the speaker model heard \(voices) voices; the numbers are guesses, one person can have several."
                + (sides.isEmpty ? "" : " The side of a call (microphone or call app) is measured and is the reliable part."),
            "- Cards are model output; a card with sources was checked on the web, the others were not.",
        ]
        if !sound { lines.append("- The sound is not in this file; it stays in Listen.") }
        if !reading.requests.isEmpty {
            lines += ["", "## Model requests", ""]
            lines += reading.requests.sorted { $0.value > $1.value }.map { "- \($0.key): \($0.value)" }
            lines += ["", "Tokens by model: " + reading.tokens.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")]
        }
        var speaking: [String: Double] = [:]
        for sentence in reading.sentences {
            speaking[who(sentence, in: reading, sides: sides).side ?? "side unknown", default: 0] += sentence.end - sentence.start
        }
        if speaking.keys.contains(where: { $0 != "side unknown" }) {
            lines += ["", "## Speaking time by side", ""] + speaking.sorted { $0.value > $1.value }.map { "- \($0.key): \(clock($0.value))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Writing

    /// The file's name without extension: "2026-11-19 09-58 XML QR Meeting".
    static func name(of run: URL, topic: String) -> String {
        let stamp = String(run.lastPathComponent.prefix(16)).replacingOccurrences(of: "_", with: " ")
        let cleaned = topic.map { "/:\\".contains($0) ? "-" : $0 }
        return ([stamp] + (topic.isEmpty ? [] : [String(cleaned)])).joined(separator: " ")
    }

    /// Writes the pack as a folder `<name>` inside `parent`. `topic` is the topic's own folder
    /// (`TopicSandbox.folder`), for its summary note and material.
    @discardableResult
    static func pack(run: URL, topic: URL?, sound: Bool, into parent: URL) throws -> URL {
        let manager = FileManager.default
        let reading = try read(run)
        let sides = sides(run)
        let folder = parent.appending(path: name(of: run, topic: reading.topic), directoryHint: .isDirectory)
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder.appending(path: "raw"), withIntermediateDirectories: true)

        let note = topic?.appending(path: "conversations/\(run.lastPathComponent).md")
        let summary = note.map { manager.fileExists(atPath: $0.path) } ?? false
        if summary, let note { try manager.copyItem(at: note, to: folder.appending(path: "summary.md")) }
        let texts: [(String, String)] = [
            ("README.md", readme(reading, run: run.lastPathComponent, summary: summary, sound: sound, sides: sides)),
            ("transcript.md", transcript(reading, sides: sides)),
            ("transcript-hearings.md", hearings(reading)),
            ("cards.md", cards(reading)),
            ("decisions.md", decisions(reading)),
            ("forecasts.md", forecasts(reading)),
        ]
        for (file, text) in texts { try text.write(to: folder.appending(path: file), atomically: true, encoding: .utf8) }

        var raw = ["events.jsonl", "run.json", "sides.bin"]
        if sound { raw.append("audio.wav") }
        for file in raw where manager.fileExists(atPath: run.appending(path: file).path) {
            try manager.copyItem(at: run.appending(path: file), to: folder.appending(path: "raw/\(file)"))
        }
        if let material = topic?.appending(path: "material", directoryHint: .isDirectory), manager.fileExists(atPath: material.path) {
            try manager.createDirectory(at: folder.appending(path: "raw/material"), withIntermediateDirectories: true)
            for item in (try? manager.contentsOfDirectory(at: material, includingPropertiesForKeys: nil)) ?? []
            where !item.lastPathComponent.hasPrefix(".") {
                try manager.copyItem(at: item, to: folder.appending(path: "raw/material/\(item.lastPathComponent)"))
            }
        }

        let manifest: [String: Any] = [
            "format": format, "version": version,
            "exported": ISO8601DateFormatter().string(from: .now),
            "app": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            "topic": reading.topic, "run": run.lastPathComponent,
            "audio_seconds": reading.audioSeconds, "sentences": reading.final.count,
            "cards": reading.cards.count, "blocks": reading.blocks.count, "events": reading.events,
            "with_sound": sound,
            "contents": files(in: folder).map { ["path": $0.path, "bytes": $0.bytes] },
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder.appending(path: "manifest.json"))
        return folder
    }

    /// Writes `<name>.listen` into `parent`: the pack, zipped. The folder it was made from is removed.
    static func write(run: URL, topic: URL?, sound: Bool, into parent: URL) throws -> URL {
        let folder = try pack(run: run, topic: topic, sound: sound, into: parent)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = parent.appending(path: folder.lastPathComponent + "." + fileExtension)
        try zip(folder, to: file)
        return file
    }

    /// Moves a made file into a folder, as "<name> 2.listen" when the name is taken.
    static func place(_ file: URL, in folder: URL) throws -> URL {
        let manager = FileManager.default
        let name = file.deletingPathExtension().lastPathComponent
        var target = folder.appending(path: file.lastPathComponent)
        var number = 2
        while manager.fileExists(atPath: target.path) {
            target = folder.appending(path: "\(name) \(number).\(fileExtension)")
            number += 1
        }
        try manager.moveItem(at: file, to: target)
        return target
    }

    enum OpenFailure: Error, LocalizedError {
        case notAConversation
        var errorDescription: String? { "This is not a Listen conversation." }
    }

    /// The run folder of the conversation a .listen file holds, to replay. A run already on this
    /// device (one of `runs`, by name) is used as it is; otherwise its raw files are unpacked into
    /// `root/<run>`. Only the known raw files are taken, under fixed names.
    static func open(_ file: URL, runs: [URL], into root: URL) throws -> URL {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 1024 * 1024 * 1024 else {
            throw OpenFailure.notAConversation
        }
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        let entries = try ZipArchive.entries(data)
        guard let manifest = entries.first(where: { $0.path.split(separator: "/").last == "manifest.json" && $0.path.split(separator: "/").count <= 2 }),
              let facts = try JSONSerialization.jsonObject(with: ZipArchive.contents(of: manifest, in: data, maximumSize: 1024 * 1024)) as? [String: Any],
              facts["format"] as? String == format,
              let importedVersion = facts["version"] as? NSNumber,
              CFGetTypeID(importedVersion) != CFBooleanGetTypeID(), importedVersion.doubleValue == Double(version),
              let run = facts["run"] as? String, run.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_-]{0,159}/) != nil
        else { throw OpenFailure.notAConversation }
        if let known = runs.first(where: { $0.lastPathComponent == run }),
           FileManager.default.fileExists(atPath: known.appending(path: "events.jsonl").path) {
            return known
        }
        let top = manifest.path.split(separator: "/").count == 2 ? String(manifest.path.split(separator: "/")[0]) + "/" : ""
        let target = root.appending(path: run, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: target.appending(path: "events.jsonl").path) { return target }
        let needed = ["events.jsonl", "run.json"]
        guard needed.allSatisfy({ name in entries.contains { $0.path == top + "raw/" + name } }) else { throw OpenFailure.notAConversation }
        let manager = FileManager.default
        // Extract into a fresh sibling and publish only after every entry succeeds. A damaged
        // archive must not leave a partial run that the next open mistakes for a complete one.
        guard !manager.fileExists(atPath: target.path) else { throw OpenFailure.notAConversation }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for name in needed + ["sides.bin", "audio.wav"] {
            let matches = entries.filter { $0.path == top + "raw/" + name }
            guard matches.count <= 1 else { throw OpenFailure.notAConversation }
            guard let entry = matches.first else { continue }
            let limit = name == "run.json" ? 1024 * 1024 : name == "sides.bin" ? 16 * 1024 * 1024 : name == "events.jsonl" ? 128 * 1024 * 1024 : 256 * 1024 * 1024
            try ZipArchive.contents(of: entry, in: data, maximumSize: limit).write(to: staging.appending(path: name))
        }
        try manager.moveItem(at: staging, to: target)
        return target
    }

    /// Zips a folder (the folder itself is the archive's top level), with the system's own zipper.
    static func zip(_ folder: URL, to file: URL) throws {
        var coordination: NSError?
        var failure: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
            do {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.copyItem(at: zipped, to: file)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    private static func files(in folder: URL) -> [(path: String, bytes: Int)] {
        let base = folder.resolvingSymlinksInPath().path + "/"
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var found: [(String, Int)] = []
        while let item = walker?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            let path = item.resolvingSymlinksInPath().path
            found.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : item.lastPathComponent, values.fileSize ?? 0))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}

/// The file the save dialog writes: a `.listen` made beforehand.
struct ConversationDocument: FileDocument {
    static let readableContentTypes = [ConversationFile.type]
    let file: URL

    init(file: URL) { self.file = file }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: file) }
}

/// A conversation to export: its run folder, its topic's folder, and whether the sound goes along.
struct ConversationExport: Equatable {
    var run: URL
    var topic: URL?
    var sound = false
}

/// Makes the `.listen` file of a conversation: on the Mac straight into Downloads, elsewhere it
/// asks where to save it.
struct ExportsConversation: ViewModifier {
    @Binding var request: ConversationExport?
    @State private var document: ConversationDocument?
    @State private var saved: URL?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if request != nil, document == nil {
                    ProgressView("Writing the .listen file…").padding(20).background(.regularMaterial, in: .rect(cornerRadius: 14))
                }
            }
            .task(id: request) {
                guard let request else { return }
                let parent = FileManager.default.temporaryDirectory.appending(path: "listen-export-\(UUID().uuidString)", directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    let file = try await Task.detached(priority: .userInitiated) {
                        try ConversationFile.write(run: request.run, topic: request.topic, sound: request.sound, into: parent)
                    }.value
                    #if targetEnvironment(macCatalyst)
                    saved = try ConversationFile.place(file, in: URL.downloadsDirectory)
                    try? FileManager.default.removeItem(at: parent)
                    self.request = nil
                    #else
                    document = ConversationDocument(file: file)
                    #endif
                } catch {
                    failure = error.localizedDescription
                    self.request = nil
                }
            }
            .fileExporter(
                isPresented: Binding(get: { document != nil }, set: { if !$0 { finish() } }),
                document: document, contentType: ConversationFile.type,
                defaultFilename: document?.file.deletingPathExtension().lastPathComponent
            ) { result in
                if case .failure(let error) = result { failure = error.localizedDescription }
                finish()
            }
            .alert("Saved to Downloads", isPresented: Binding(get: { saved != nil }, set: { if !$0 { saved = nil } })) {
                Button("Show in Finder") {
                    UIApplication.shared.open(URL.downloadsDirectory)
                    saved = nil
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(saved?.lastPathComponent ?? "")
            }
            .alert("The .listen file could not be written", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func finish() {
        if let folder = document?.file.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
        document = nil
        request = nil
    }
}

extension View {
    func exportsConversation(_ request: Binding<ConversationExport?>) -> some View {
        modifier(ExportsConversation(request: request))
    }
}
