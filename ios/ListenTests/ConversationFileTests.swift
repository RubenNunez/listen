import Foundation
import Testing
@testable import Listen

@Suite struct ConversationFiles {
    /// A small recorded call: two sentences from the call app, one from the microphone, a card in two versions.
    private func run() throws -> (run: URL, topic: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "conversation-\(UUID().uuidString)")
        let run = root.appending(path: "2026-11-19_09-58-55")
        let topic = root.appending(path: "topic")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topic.appending(path: "conversations"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topic.appending(path: "material"), withIntermediateDirectories: true)
        let events: [[String: Any]] = [
            ["kind": "sentence", "id": 1, "start_ms": 0, "end_ms": 2000, "t": 3.0, "text": "Grüezi mitenand", "voice": NSNull()],
            ["kind": "sentence", "id": 1, "start_ms": 0, "end_ms": 2000, "t": 4.0, "text": "Grüezi miteinander", "voice": 2],
            ["kind": "layer", "name": "2b · Swiss German", "sentence": 1, "detail": "taken, the others struggled: Grüezi miteinander", "t": 4.0],
            ["kind": "layer", "name": "2 · Speaker", "sentence": 1, "detail": "voice 2, by the app's sound", "t": 4.0],
            ["kind": "sentence", "id": 2, "start_ms": 2500, "end_ms": 4000, "t": 5.5, "text": "Wie läuft der Dispatcher?", "voice": 7],
            ["kind": "me", "voice": 7, "t": 5.6],
            ["kind": "round", "sentence": 2, "state": "starts", "t": 5.6],
            ["kind": "context", "sentence": 2, "phase": "route", "state": "answer", "usefulness": 0.81, "research": 0.2, "change": "add_fact", "t": 5.7],
            ["kind": "model_request", "agent": "decision", "input": "…", "t": 5.6],
            ["kind": "usage", "model": "typesafe/jev-1.14.0", "input_tokens": 100, "output_tokens": 20, "t": 5.7],
            ["kind": "card_started", "card": 1, "block_id": 1, "sentence": 2, "t": 7.0],
            ["kind": "card_text", "card": 1, "text": "**Dispatcher**\n\n- first", "t": 7.0],
            ["kind": "landed", "card": 1, "block": 1, "how": "a new block", "t": 7.0],
            ["kind": "card_started", "card": 2, "block_id": 1, "sentence": 3, "t": 9.0],
            ["kind": "card_text", "card": 2, "text": "**Dispatcher**\n\n- second", "t": 9.0],
            ["kind": "landed", "card": 2, "block": 1, "how": "a new version", "t": 9.0],
            ["kind": "sentence", "id": 3, "start_ms": 5000, "end_ms": 6000, "t": 7.0, "text": "Er archiviert alles.", "voice": 4],
            ["kind": "forecast", "sentence": 2, "cards": ["f0 Archiv"], "t": 6.0],
        ]
        let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: run.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
        try #"{"topic":"QR Meeting","audio_seconds":6.0}"#.write(to: run.appending(path: "run.json"), atomically: true, encoding: .utf8)
        // 6 s of sides: the app loud for the first 2 s, the microphone for the next 2, then the app.
        var sides = Data()
        for frame in 0..<60 {
            let mine: UInt16 = (20..<40).contains(frame) ? 9000 : 10
            let theirs: UInt16 = (20..<40).contains(frame) ? 10 : 9000
            for value in [mine, theirs] { sides.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
        }
        try sides.write(to: run.appending(path: "sides.bin"))
        try "# QR Meeting\n\n## Summary\n\n- Dispatcher".write(
            to: topic.appending(path: "conversations/2026-11-19_09-58-55.md"), atomically: true, encoding: .utf8)
        try "Material".write(to: topic.appending(path: "material/briefing.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: topic.appending(path: "material/.listen-index.json"), atomically: true, encoding: .utf8)
        return (run, topic)
    }

    @Test func theLogIsReadIntoSentencesCardsAndDecisions() throws {
        let reading = try ConversationFile.read(try run().run)
        #expect(reading.topic == "QR Meeting")
        #expect(reading.sentences.map(\.text) == ["Grüezi miteinander", "Wie läuft der Dispatcher?", "Er archiviert alles."])
        #expect(reading.first[1] == "Grüezi mitenand", "the first hearing is kept beside the final one")
        #expect(reading.dialect[1]?.fate == "taken, the others struggled")
        #expect(reading.me == 7 && reading.heardBy[1] == "call app")
        #expect(reading.blocks.count == 1 && reading.blocks[0].cards.map(\.id) == [1, 2])
        #expect(reading.decisions[2] == ["round · starts", "route · answer · useful 0.81 · research 0.20 · add_fact"])
        #expect(reading.requests == ["decision": 1] && reading.tokens == ["typesafe/jev-1.14.0": 120])
        #expect(abs(reading.offset - 1) < 0.001)
    }

    @Test func theTranscriptSaysWhoAndOnWhichSide() throws {
        let made = try run()
        let reading = try ConversationFile.read(made.run)
        let transcript = ConversationFile.transcript(reading, sides: ConversationFile.sides(made.run))
        #expect(transcript.contains("[0:00] **voice 2, call app**: Grüezi miteinander"))
        // No speaker step for these two: the side comes from the loudness.
        #expect(transcript.contains("[0:02] **me, microphone**: Wie läuft der Dispatcher?"))
        #expect(transcript.contains("[0:05] **voice 4, call app**: Er archiviert alles."))
        #expect(ConversationFile.clock(3725) == "1:02:05" && ConversationFile.clock(65) == "1:05")
    }

    @Test func thePackHoldsTheReadableFilesTheRawLogAndTheMaterial() throws {
        let made = try run()
        let parent = made.run.deletingLastPathComponent().appending(path: "out")
        let folder = try ConversationFile.pack(run: made.run, topic: made.topic, sound: false, into: parent)
        #expect(folder.lastPathComponent == "2026-11-19 09-58 QR Meeting")
        let files = Set(try FileManager.default.subpathsOfDirectory(atPath: folder.path))
        for file in ["README.md", "manifest.json", "summary.md", "transcript.md", "transcript-hearings.md", "cards.md",
                     "decisions.md", "forecasts.md", "raw/events.jsonl", "raw/run.json", "raw/sides.bin", "raw/material/briefing.md"] {
            #expect(files.contains(file), "\(file)")
        }
        #expect(!files.contains("raw/audio.wav") && !files.contains("raw/material/.listen-index.json"))
        let cards = try String(contentsOf: folder.appending(path: "cards.md"), encoding: .utf8)
        #expect(cards.contains("### Block 1 · 2 versions\n\n**Dispatcher**\n\n- second"), "a block shows how it ended")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json"))) as? [String: Any]
        #expect(manifest?["format"] as? String == "listen-conversation" && manifest?["sentences"] as? Int == 3)
        let contents = (manifest?["contents"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
        #expect(contents.contains("transcript.md") && contents.contains("raw/material/briefing.md"))
    }

    @Test func theFileIsAZipNamedListen() throws {
        let made = try run()
        let parent = made.run.deletingLastPathComponent().appending(path: "out")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = try ConversationFile.write(run: made.run, topic: made.topic, sound: false, into: parent)
        #expect(file.pathExtension == "listen")
        let head = try FileHandle(forReadingFrom: file).read(upToCount: 2)
        #expect(head == Data("PK".utf8))
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "2026-11-19 09-58 QR Meeting").path), "only the file stays")
        #expect(ConversationFile.type.conforms(to: .zip))
    }

    @Test func openingAFileUnpacksItsConversationOrFindsTheOneHere() throws {
        let made = try run()
        let parent = made.run.deletingLastPathComponent().appending(path: "out")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = try ConversationFile.write(run: made.run, topic: made.topic, sound: false, into: parent)
        // On this device already: that run is replayed, nothing is unpacked.
        #expect(try ConversationFile.open(file, runs: [made.run], into: parent) == made.run)
        // From elsewhere: the raw files come into the runs folder under the run's name.
        let elsewhere = parent.appending(path: "runs")
        let opened = try ConversationFile.open(file, runs: [], into: elsewhere)
        #expect(opened.lastPathComponent == "2026-11-19_09-58-55" && opened.deletingLastPathComponent().path == elsewhere.path)
        for name in ["events.jsonl", "run.json", "sides.bin"] {
            #expect(try Data(contentsOf: opened.appending(path: name)) == Data(contentsOf: made.run.appending(path: name)), "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: opened.appending(path: "audio.wav").path))
        #expect(try ConversationFile.read(opened).final.count == 3)
    }

    @Test func aZipThatIsNoConversationIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-\(UUID().uuidString)/notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try String(repeating: "Notizen ", count: 200).write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let zip = folder.deletingLastPathComponent().appending(path: "notes.listen")
        try ConversationFile.zip(folder, to: zip)
        let data = try Data(contentsOf: zip)
        let entries = try ZipArchive.entries(data)
        let text = try #require(entries.first { $0.path.hasSuffix("a.txt") })
        #expect(String(decoding: try ZipArchive.contents(of: text, in: data), as: UTF8.self) == String(repeating: "Notizen ", count: 200))
        #expect(throws: ConversationFile.OpenFailure.self) { try ConversationFile.open(zip, runs: [], into: folder) }
        #expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive.entries(Data("not a zip at all, not at all".utf8)) }
    }

    @Test func aSavedFileKeepsTheOneBefore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var placed: [String] = []
        for _ in 0..<2 {
            let made = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/Talk.listen")
            try FileManager.default.createDirectory(at: made.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("PK".utf8).write(to: made)
            placed.append(try ConversationFile.place(made, in: folder).lastPathComponent)
        }
        #expect(placed == ["Talk.listen", "Talk 2.listen"])
    }

    @Test func theReadmeSaysWhenTheSummarySawOnlyTheEnd() throws {
        var reading = ConversationFile.Reading(topic: "Long")
        for id in 1...400 {
            reading.final[id] = .init(id: id, start: Double(id) * 6, end: Double(id) * 6 + 5, text: String(repeating: "word ", count: 12))
        }
        let from = try #require(ConversationFile.summarySeesFrom(reading))
        #expect(from > 6 * 100, "it saw at most the last lines the app holds")
        reading.final = reading.final.filter { $0.key <= 20 }
        #expect(ConversationFile.summarySeesFrom(reading) == nil, "a short conversation was seen whole")
    }
}
