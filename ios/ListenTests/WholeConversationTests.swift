import Foundation
import Testing
@testable import Listen

/// The end of a long conversation sees all of it, and names are asked for only when one is said.
@MainActor @Suite struct WholeConversation {
    private func segment(_ id: UInt64, _ text: String, voice: UInt32 = 1) -> TranscriptSegment {
        TranscriptSegment(segmentID: id, isFinal: true, revision: 1, voice: voice, speaker: .speaker(Int(voice)), text: text,
                          startMs: 0, endMs: 0)
    }

    @Test func sentencesThatLeaveTheScreenAreKept() {
        var core = SessionCore()
        _ = core.handle(.start(language: .de))
        _ = core.handle(.microphonePermission(true))
        _ = core.handle(.transportConnected)
        var seq: UInt64 = 1
        _ = core.handle(.envelope(Envelope(v: 1, seq: seq, event: .state(.listening, reason: nil))))
        let count = SessionCore.maxLines + 50
        for id in 1...UInt64(count) {
            seq += 1
            _ = core.handle(.envelope(Envelope(v: 1, seq: seq, event: .transcript(segment(id, "Satz \(id)")))))
        }
        #expect(core.lines.count == SessionCore.maxLines)
        #expect(core.allSpeech.count == count)
        #expect(core.allSpeech.first?.text == "Satz 1" && core.allSpeech.last?.text == "Satz \(count)")
    }

    @Test func aVoiceOfOneOrTwoSentencesIsNotSomeoneAtTheTable() {
        var speech: [TranscriptSegment] = []
        var id: UInt64 = 0
        for (voice, count) in [(UInt32(1), 5), (2, 30), (3, 4), (8, 1), (9, 2)] {
            for _ in 0..<count {
                id += 1
                speech.append(segment(id, "Satz \(id)", voice: voice))
            }
        }
        let people = SessionModel.everyone(in: speech, isMine: { $0.voice == 1 }, names: [9: "Anna"])
        #expect(people.map(\.id) == [1, 2, 3, 9], "voice 8 spoke once in 42 sentences; Anna is named")
        #expect(people.first?.label == .me)
        // In a short conversation every voice counts.
        #expect(SessionModel.everyone(in: Array(speech.suffix(8)), isMine: { _ in false }, names: [:]).map(\.id) == [2, 3, 8, 9])
    }

    @Test func inACallTheNoteSaysWhichSideSomeoneCameThrough() {
        let people = [
            SessionModel.Participant(id: 7, label: .me, isSpeaking: false),
            SessionModel.Participant(id: 2, label: .speaker(2), isSpeaking: false),
            SessionModel.Participant(id: 3, label: .speaker(3), isSpeaking: false, name: "Anna"),
        ]
        let table = SessionModel.atTheTable(people, call: "Microsoft Teams")
        #expect(table[0] == "You (microphone)")
        #expect(table[1].hasSuffix("(Microsoft Teams)") && table[2] == "Anna (Microsoft Teams)")
        #expect(table.last?.contains("one person can appear as two") == true)
        #expect(SessionModel.atTheTable(people, call: nil) == people.map(\.title))
    }

    @Test func aLongTranscriptKeepsItsBeginningAndItsEnd() {
        let short = (1...10).map { "Someone: line \($0)" }.joined(separator: "\n")
        #expect(AnswerEngine.summaryInput(short) == short)
        let long = (1...5000).map { "Someone: this is line number \($0) of a long meeting" }.joined(separator: "\n")
        let input = AnswerEngine.summaryInput(long)
        #expect(input.count <= 60_000)
        #expect(input.hasPrefix("Someone: this is line number 1 of"))
        #expect(input.hasSuffix("line number 5000 of a long meeting"))
        #expect(input.contains("lines left out"))
    }

    @Test func wordsAndAbbreviationsAreNoNames() {
        // Taken for names in the meeting of 19 November 2026.
        for word in ["Das", "SHP VI", "VI", "Die", "Zusammen"] {
            #expect(!AnswerEngine.looksLikeName(word), "\(word)")
        }
        #expect(!AnswerEngine.isIntroduced("Das", in: ["Das ist eigentlich nicht relevant, das."]), "the name as it is written")
        #expect(AnswerEngine.isIntroduced("Markus", in: ["danke, Markus."]))
    }

    @Test func theTalkGivesNamesAway() {
        let talk = ["Guten Tag, ich bin Anna.", "Können Sie das erklären, Markus?", "Hallo zusammen.", "Wir nutzen SFTP oder ESB, oder?",
                    "Das ist Dokumentation vor dem Thema.", "Danke, das."]
        #expect(AnswerEngine.nameCandidates(in: talk) == ["Anna", "Markus"])
    }

    @Test func namesAreAskedForOnlyWhenOneIsSaid() async {
        final class Counter: ModelClient, @unchecked Sendable {
            private let lock = NSLock()
            private var asked = 0
            var count: Int { lock.withLock { asked } }
            func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
                if model == "namer" { lock.withLock { asked += 1 } }
                return AsyncThrowingStream { continuation in
                    continuation.yield(.text(model == "namer" ? "1=Anna" : ""))
                    continuation.finish()
                }
            }
        }
        let counter = Counter()
        var settings = AnswerEngine.Settings()
        settings.drafters = []
        settings.namer = "namer"
        settings.namingEvery = 3
        settings.pause = .seconds(30)
        let engine = AnswerEngine(client: counter, settings: settings)
        // Twelve sentences of two voices and no name: nobody is asked.
        for id in 1...12 {
            engine.heard(segment(UInt64(id), "Wir reden über den Dispatcher und das Archiv \(id).", voice: UInt32(id % 2 + 1)), isMine: false)
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
        // A name is said: asked, and for the same name twice at most.
        engine.heard(segment(13, "Guten Tag, ich bin Anna.", voice: 1), isMine: false)
        for id in 14...30 {
            try? await Task.sleep(for: .milliseconds(20))
            engine.heard(segment(UInt64(id), "Und weiter \(id).", voice: UInt32(id % 2 + 1)), isMine: false)
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect((1...2).contains(counter.count))
    }
}
