import Foundation
import Testing

@testable import Listen

/// The same files are checked byte for byte by the Rust protocol crate
/// (backend/crates/protocol/tests/fixtures.rs).
@Suite struct WireFixtures {
    private static func lines(_ name: String) throws -> [Data] {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: repository.appending(path: "fixtures/protocol/\(name)"), encoding: .utf8)
        return text.split(separator: "\n").map { Data($0.utf8) }
    }

    @Test func everyServerEnvelopeDecodes() throws {
        let envelopes = try Self.lines("server_envelopes.jsonl").map {
            try JSONDecoder().decode(Envelope.self, from: $0)
        }
        #expect(envelopes.map(\.seq) == Array(1...13))
        #expect(envelopes[0].event == .state(.paused, reason: .interrupted))
        #expect(envelopes[1].event == .transcript(TranscriptSegment(
            segmentID: 3, isFinal: true, revision: 2, voice: 1, speaker: .speaker(1),
            text: "Wie testen Sie das?", startMs: 100, endMs: 900)))
        #expect(envelopes[2].event == .transcript(TranscriptSegment(
            segmentID: 4, isFinal: false, revision: 1, voice: nil, speaker: .unknown,
            text: "Ähm", startMs: 1000, endMs: 1200)))
        #expect(envelopes[3].event == .speakerMapping(version: 1, meVoice: 2))
        #expect(envelopes[4].event == .audioGap(firstMissingSeq: 3, frames: 3))
        #expect(envelopes[5].event == .cardStarted(CardStart(
            generationID: 2, kind: .deep, style: .technicalDetail, triggerSegment: 3, sourceCard: 1,
            contextVersion: 7, mappingVersion: 1)))
        #expect(envelopes[6].event == .cardDelta(generationID: 2, text: "Mit einem Lasttest."))
        #expect(envelopes[7].event == .cardFinished(generationID: 2))
        #expect(envelopes[8].event == .cardSuperseded(generationID: 2, by: 3))
        #expect(envelopes[9].event == .cardCancelled(generationID: 3))
        #expect(envelopes[10].event == .cardError(generationID: 3, code: .modelProvider))
        #expect(envelopes[11].event == .budget(spentNanoUSD: 1_000_000, limitNanoUSD: 3_000_000_000, exhausted: false))
        #expect(envelopes[12].event == .error(.replayGap))
    }

    @Test func everyClientEventEncodesToTheFixture() throws {
        let events: [ClientEvent] = [
            .hello(protocolVersion: 1),
            .start(language: .de, contextVersion: 7),
            .pause(reason: .appSpeaking),
            .resume,
            .stop,
            .helpNow,
            .cardAction(generationID: 3, action: .technicalDetail),
            .mapSpeaker(voice: 2, isMe: true),
            .resumeFrom(lastServerSeq: 41),
        ]
        let fixtures = try Self.lines("client_events.jsonl")
        #expect(fixtures.count == events.count)
        for (event, fixture) in zip(events, fixtures) {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? NSDictionary
            let expected = try JSONSerialization.jsonObject(with: fixture) as? NSDictionary
            #expect(encoded == expected, "\(event)")
        }
    }

    @Test func unknownServerEventsAreRejected() {
        let json = Data(#"{"v":1,"seq":1,"event":{"type":"run_shell","cmd":"ls"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Envelope.self, from: json) }
    }

    @Test func audioFrameHeaderIsBigEndian() {
        let frame = AudioFrame(seq: 0x0102_0304, captureMs: 5, pcm: Data([9, 8]))
        #expect(Array(frame.encoded()) == [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 5, 9, 8])
    }
}
