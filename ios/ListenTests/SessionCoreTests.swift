import Foundation
import Testing

@testable import Listen

private typealias Command = SessionCore.Command

/// Drives a core and numbers the server envelopes it is fed.
private struct Harness {
    var core = SessionCore()
    var seq: UInt64 = 0

    @discardableResult
    mutating func send(_ input: SessionCore.Input) -> [Command] {
        core.handle(input)
    }

    @discardableResult
    mutating func server(_ event: ServerEvent) -> [Command] {
        seq += 1
        return core.handle(.envelope(Envelope(v: 1, seq: seq, event: event)))
    }

    /// A session that reached `listening` the normal way.
    static func listening() -> Harness {
        var harness = Harness()
        harness.send(.start(language: .de))
        harness.send(.microphonePermission(true))
        harness.send(.transportConnected)
        harness.server(.state(.listening, reason: nil))
        return harness
    }

    mutating func finishedCard(_ id: UInt64, text: String = "Antwort") {
        server(.cardStarted(CardStart(
            generationID: id, kind: .fast, style: .answer, triggerSegment: 1, sourceCard: nil,
            contextVersion: 0, mappingVersion: 0)))
        server(.cardDelta(generationID: id, text: text))
        server(.cardFinished(generationID: id))
    }
}

private func segment(_ id: UInt64, _ text: String, final isFinal: Bool, speaker: SpeakerLabel = .speaker(1)) -> ServerEvent {
    .transcript(TranscriptSegment(
        segmentID: id, isFinal: isFinal, revision: 1, voice: 1, speaker: speaker, text: text,
        startMs: 0, endMs: 100))
}

@Suite struct StartAndStop {
    @Test func captureStartsOnlyAfterTheBackendListens() {
        var harness = Harness()
        #expect(harness.send(.start(language: .en)) == [.requestMicrophonePermission])
        #expect(harness.send(.microphonePermission(true)) == [.connect])
        #expect(harness.send(.transportConnected) == [
            .send(.hello(protocolVersion: 1)),
            .send(.start(language: .en, contextVersion: 0)),
        ])
        #expect(harness.core.phase == .starting)
        #expect(!harness.core.isCapturing)

        #expect(harness.server(.state(.listening, reason: nil)) == [.startCapture, .keepScreenAwake(true)])
        #expect(harness.core.phase == .listening)
        #expect(harness.core.forwardsAudio)
    }

    @Test func deniedMicrophoneReturnsToIdle() {
        var harness = Harness()
        harness.send(.start(language: .de))
        #expect(harness.send(.microphonePermission(false)).isEmpty)
        #expect(harness.core.phase == .idle)
        #expect(harness.core.notice == .microphoneDenied)
    }

    @Test func pauseStopsCaptureBeforeTellingTheBackend() {
        var harness = Harness.listening()
        #expect(harness.send(.pause) == [.stopCapture, .send(.pause(reason: .user)), .keepScreenAwake(false)])
        #expect(harness.core.phase == .pausedByUser)
        #expect(!harness.core.forwardsAudio)
    }

    @Test func stopEndsCaptureFirstFromEveryActivePhase() {
        var paused = Harness.listening()
        paused.send(.pause)
        var interrupted = Harness.listening()
        interrupted.send(.audioInterrupted(.audioSession))
        var reconnecting = Harness.listening()
        reconnecting.send(.transportDisconnected)
        var speaking = Harness.listening()
        speaking.finishedCard(1)
        speaking.send(.readAloud(cardID: 1))

        for var harness in [Harness.listening(), paused, interrupted, reconnecting, speaking] {
            let wasSpeaking = harness.core.phase == .speakingAloud(cardID: 1)
            let commands = harness.send(.stop)
            #expect(commands.firstIndex(of: .stopCapture) == (wasSpeaking ? 1 : 0))
            #expect(commands.contains(.disconnect))
            #expect(commands.contains(.discardBufferedAudio))
            #expect(harness.core.phase == .review)
            #expect(!harness.core.isCapturing && !harness.core.forwardsAudio)
        }
    }

    @Test func doneClearsTheSession() {
        var harness = Harness.listening()
        harness.server(segment(1, "Hallo", final: true))
        harness.send(.stop)
        #expect(!harness.core.lines.isEmpty)
        harness.send(.done)
        #expect(harness.core.phase == .idle)
        #expect(harness.core.lines.isEmpty && harness.core.cards.isEmpty)
    }
}

@Suite struct Interruptions {
    @Test func anInterruptionPausesAndNeverResumesByItself() {
        var harness = Harness.listening()
        #expect(harness.send(.audioInterrupted(.audioSession)) == [
            .stopCapture, .send(.pause(reason: .interrupted)), .keepScreenAwake(false),
        ])
        #expect(harness.core.phase == .interrupted(.audioSession))

        // Nothing the system or the backend does restarts capture.
        let later: [[Command]] = [
            harness.server(.state(.paused, reason: .interrupted)),
            harness.server(segment(1, "spät", final: true)),
            harness.send(.transportDisconnected),
            harness.send(.transportConnected),
            harness.send(.speechFinished),
            harness.send(.reconnectTimedOut),
        ]
        #expect(!later.joined().contains(.startCapture))
        #expect(harness.core.phase == .interrupted(.audioSession))

        #expect(harness.send(.resume) == [.send(.resume), .startCapture, .keepScreenAwake(true)])
        #expect(harness.core.phase == .listening)
    }

    @Test func leavingTheForegroundInterrupts() {
        var harness = Harness.listening()
        harness.send(.leftForeground)
        #expect(harness.core.phase == .interrupted(.leftForeground))
    }

    @Test func aUserPauseIsNotOverwrittenByAnInterruption() {
        var harness = Harness.listening()
        harness.send(.pause)
        #expect(harness.send(.leftForeground).isEmpty)
        #expect(harness.core.phase == .pausedByUser)
    }
}

@Suite struct Reconnect {
    @Test func aLostSocketBuffersThenCatchesUp() {
        var harness = Harness.listening()
        harness.server(segment(1, "Hallo", final: true))

        #expect(harness.send(.transportDisconnected) == [.reconnect, .scheduleReconnectTimeout])
        #expect(harness.core.phase == .reconnecting)
        #expect(harness.core.isCapturing && harness.core.buffersAudio && !harness.core.forwardsAudio)

        #expect(harness.send(.transportConnected) == [
            .cancelReconnectTimeout,
            .send(.hello(protocolVersion: 1)),
            .send(.resumeFrom(lastServerSeq: 2)),
            .flushBufferedAudio,
        ])
        #expect(harness.core.phase == .listening)
    }

    @Test func aReconnectThatTakesTooLongBecomesAnInterruption() {
        var harness = Harness.listening()
        harness.send(.transportDisconnected)
        #expect(harness.send(.reconnectTimedOut) == [.stopCapture, .discardBufferedAudio, .keepScreenAwake(false)])
        #expect(harness.core.phase == .interrupted(.connectionLost))

        // Resuming without a socket reconnects first.
        #expect(harness.send(.resume) == [
            .reconnect, .scheduleReconnectTimeout, .startCapture, .keepScreenAwake(true),
        ])
        #expect(harness.core.phase == .reconnecting)
    }

    @Test func aPauseWhileDisconnectedIsSentOnceTheSocketReturns() {
        var harness = Harness.listening()
        harness.send(.transportDisconnected)
        harness.send(.pause)
        #expect(harness.send(.transportConnected) == [
            .send(.hello(protocolVersion: 1)),
            .send(.resumeFrom(lastServerSeq: 1)),
            .send(.pause(reason: .user)),
        ])
    }

    @Test func replayedEnvelopesAreAppliedOnce() {
        var harness = Harness.listening()
        harness.finishedCard(1, text: "Antwort")
        let duplicate = Envelope(v: 1, seq: harness.seq - 1, event: .cardDelta(generationID: 1, text: "Antwort"))
        harness.send(.envelope(duplicate))
        #expect(harness.core.cards.first?.text == "Antwort")
    }
}

@Suite struct TranscriptAndCards {
    @Test func partialsAreReplacedAndFinalsNeverChange() {
        var harness = Harness.listening()
        harness.server(segment(1, "Können", final: false))
        harness.server(segment(1, "Können Sie", final: false))
        #expect(harness.core.lines.count == 1)
        harness.server(segment(1, "Können Sie das erklären?", final: true))
        harness.server(segment(1, "Können", final: false))
        #expect(harness.core.lines == [
            SessionCore.Line(id: "s1", content: .speech(TranscriptSegment(
                segmentID: 1, isFinal: true, revision: 1, voice: 1, speaker: .speaker(1),
                text: "Können Sie das erklären?", startMs: 0, endMs: 100)))
        ])
    }

    @Test func lostAudioLeavesAVisibleMarker() {
        var harness = Harness.listening()
        harness.server(.audioGap(firstMissingSeq: 3, frames: 30))
        #expect(harness.core.lines.map(\.content) == [.audioGap(frames: 30)])
    }

    @Test func transcriptAndCardsAreBounded() {
        var harness = Harness.listening()
        for id in 1...UInt64(SessionCore.maxLines + 20) {
            harness.server(segment(id, "Zeile", final: true))
        }
        for id in 1...UInt64(SessionCore.maxCards + 3) {
            harness.finishedCard(id)
        }
        #expect(harness.core.lines.count == SessionCore.maxLines)
        #expect(harness.core.cards.count == SessionCore.maxCards)
        #expect(harness.core.cards.last?.id == UInt64(SessionCore.maxCards + 3))
    }

    @Test func aSupersededCardKeepsItsTextAndIsMarked() {
        var harness = Harness.listening()
        harness.server(.cardStarted(CardStart(
            generationID: 1, kind: .fast, style: .answer, triggerSegment: 1, sourceCard: nil,
            contextVersion: 0, mappingVersion: 0)))
        harness.server(.cardDelta(generationID: 1, text: "Mit begrenzten "))
        harness.server(.cardSuperseded(generationID: 1, by: 2))
        #expect(harness.core.cards.first?.status == .superseded)
        #expect(harness.core.cards.first?.text == "Mit begrenzten ")
    }

    @Test func manyVersionsKeepOtherSubjectsAndAStableBlockIdentity() {
        var harness = Harness.listening()
        harness.finishedCard(1)
        harness.finishedCard(2)
        var before: UInt64 = 1
        for id in UInt64(3)...20 {
            harness.server(.cardStarted(CardStart(generationID: id, kind: .fast, style: .answer,
                triggerSegment: 1, sourceCard: before, contextVersion: 0, mappingVersion: 0)))
            harness.server(.cardDelta(generationID: id, text: "Alpha\nA useful revision."))
            harness.server(.cardFinished(generationID: id))
            harness.server(.cardSuperseded(generationID: before, by: id))
            before = id
        }
        #expect(harness.core.cards.contains { $0.id == 2 })
        #expect(harness.core.cards.last?.start.blockID == 1)
        #expect(harness.core.cards.count == SessionCore.maxVersionsPerBlock + 1)
        #expect(CardBlocks.blocks(from: harness.core.cards).map(\.id) == [1, 2])
    }

    @Test func answersSitDirectlyUnderTheQuestionThatTriggeredThem() {
        var harness = Harness.listening()
        harness.server(segment(1, "Wie setzen Sie Backpressure um?", final: true))
        harness.server(segment(2, "Mit begrenzten Warteschlangen.", final: true, speaker: .me))
        harness.finishedCard(7)  // triggered by segment 1, arrives after segment 2
        harness.server(.cardStarted(CardStart(
            generationID: 8, kind: .fast, style: .answer, triggerSegment: 2, sourceCard: nil,
            contextVersion: 0, mappingVersion: 0)))
        harness.server(.cardSuperseded(generationID: 8, by: 9))
        #expect(harness.core.timeline.map(\.id) == ["s1", "c7", "s2"], "empty superseded cards are hidden")
    }

    @Test func mappingTurnsAutomaticSuggestionsOn() {
        var harness = Harness.listening()
        #expect(!harness.core.automaticSuggestionsOn)
        #expect(harness.send(.thisIsMe(voice: 2)) == [.send(.mapSpeaker(voice: 2, isMe: true))])
        harness.server(.speakerMapping(version: 1, meVoice: 2))
        #expect(harness.core.automaticSuggestionsOn)
    }

    @Test func anExhaustedBudgetIsShown() {
        var harness = Harness.listening()
        harness.server(.budget(spentNanoUSD: 3, limitNanoUSD: 3, exhausted: true))
        #expect(harness.core.notice == .budgetExhausted)
    }
}

@Suite struct ReadingAloud {
    @Test func theBackendIsPausedBeforeTheVoiceStarts() {
        var harness = Harness.listening()
        harness.finishedCard(1, text: "Mit begrenzten Warteschlangen.")
        #expect(harness.send(.readAloud(cardID: 1)) == [
            .send(.pause(reason: .appSpeaking)), .speak("Mit begrenzten Warteschlangen."),
        ])
        #expect(harness.core.phase == .speakingAloud(cardID: 1))
        #expect(!harness.core.forwardsAudio, "the app's own voice must not be forwarded")

        #expect(harness.send(.speechFinished) == [.send(.resume)])
        #expect(harness.core.phase == .listening)
    }

    @Test func readingCanBeStoppedAndNeedsAListeningSession() {
        var harness = Harness.listening()
        harness.finishedCard(1)
        harness.send(.readAloud(cardID: 1))
        #expect(harness.send(.stopReadingAloud) == [.stopSpeaking, .send(.resume)])

        harness.send(.pause)
        #expect(harness.send(.readAloud(cardID: 1)).isEmpty)
        #expect(harness.send(.readAloud(cardID: 99)).isEmpty)
    }
}

/// A sentence's voice is the speaker model's first guess until the next sentence's analysis.
@MainActor @Suite struct FirstGuessVoices {
    private func voiced(_ id: UInt64, voice: UInt32?, pending: Bool, revision: Int = 1) -> ServerEvent {
        var line = TranscriptSegment(segmentID: id, isFinal: true, revision: revision, voice: voice,
                                     speaker: voice.map { .speaker(Int($0)) } ?? .unknown, text: "Satz \(id)",
                                     startMs: id * 1000, endMs: id * 1000 + 900)
        line.voicePending = pending
        return .transcript(line)
    }

    @Test func aFirstGuessBringsInNoOneNewAndIsCountedOnceSettled() {
        var harness = Harness.listening()
        harness.server(voiced(1, voice: 1, pending: false))
        harness.server(voiced(2, voice: 3, pending: true))
        #expect(SessionModel.participants(in: harness.core, names: [:]).map(\.id) == [1])
        #expect(SessionModel.speakerCount(in: harness.core) == 1)
        // The next analysis settles it: now it is someone.
        harness.server(voiced(2, voice: 3, pending: false, revision: 2))
        #expect(SessionModel.participants(in: harness.core, names: [:]).map(\.id) == [1, 3])
        #expect(SessionModel.participants(in: harness.core, names: [:]).last?.isSpeaking == true)
        #expect(SessionModel.speakerCount(in: harness.core) == 2)
    }

    @Test func aFirstGuessForSomeoneKnownMarksWhoSpokeLast() {
        var harness = Harness.listening()
        harness.server(voiced(1, voice: 1, pending: false))
        harness.server(voiced(2, voice: 2, pending: false))
        harness.server(voiced(3, voice: 1, pending: true))
        let people = SessionModel.participants(in: harness.core, names: [:])
        #expect(people.map(\.id) == [1, 2] && people.first?.isSpeaking == true)
    }

    @Test func theFlagStaysOnTheDeviceAndMessagesWithoutItDecode() throws {
        let json = #"{"segment_id":4,"is_final":true,"revision":1,"voice":2,"speaker":{"kind":"speaker","n":2},"text":"x","start_ms":0,"end_ms":10}"#
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
        #expect(decoded.voice == 2 && !decoded.voicePending)
    }
}
