import Foundation
import Testing
@testable import Listen

@Suite struct LocalModelTextTests {
    @Test func cumulativeSnapshotsNeverRepeatAlreadyEmittedWords() throws {
        var text = LocalModelText()
        let snapshots = ["Guten", "Guten Morgen", "Guten Morgen.", "Guten Morgen."]
        let deltas = try snapshots.map { try text.delta($0) }
        #expect(deltas == ["Guten", " Morgen", ".", ""])
        #expect(deltas.joined() == "Guten Morgen.")
    }

    @Test func unicodeBoundariesDoNotDropCombiningMarksOrEmoji() throws {
        var text = LocalModelText()
        let snapshots = ["e", "e\u{301}", "e\u{301} 😊", "e\u{301} 😊!"]
        let deltas = try snapshots.map { try text.delta($0) }
        #expect(deltas.joined() == "é 😊!")
    }

    @Test func aRewrittenSnapshotIsNotSplicedIntoSpokenText() throws {
        var text = LocalModelText()
        #expect(try text.delta("One answer") == "One answer")
        #expect(throws: LocalModelText.RewrittenSnapshot.self) { try text.delta("Another answer") }
        #expect(try text.delta("One answer.") == ".")
    }
}

@Suite struct AssistantReplyTextTests {
    @Test func quotedSentencesCanReachSpeechBeforeTheFollowingSentenceFinishes() throws {
        for (first, tail) in [("Sie erklärt: „Ein Actor schützt seinen Zustand.“", " Danach prüfst du die Annahmen erneut."),
                              ("She asks: \"Are you sure?!\"", " Then she waits."),
                              ("Das ist möglich (unter diesen Bedingungen.)", " Der Rest folgt gleich.")] {
            var reply = AssistantReplyText()
            for character in first { #expect(try reply.append(String(character)).isEmpty) }
            #expect(try reply.append(String(tail.prefix(5))) == [first])
            _ = try reply.append(String(tail.dropFirst(5)))
            #expect(try reply.finish().text == first + tail)
            #expect(SpokenReply.sentences(first + tail) == [first, String(tail.dropFirst())])
        }
    }

    @Test func stablePromptPrefixesKeepEveryContextValueAndDoNotDependOnDictionaryOrder() throws {
        let topic: HarnessValue = .object(["notes": .string("Approved context with \"quotes\" and ä."), "name": .string("Synthetic")])
        let messages: HarnessValue = .array([.object(["text": .string("Latest question?"), "role": .string("user")])])
        let first: HarnessValue = .object(["messages": messages, "evidence": .null, "tools": .array([]), "topic": topic, "future_flag": .bool(true)])
        let second: HarnessValue = .object(["future_flag": .bool(true), "topic": topic, "tools": .array([]), "evidence": .null, "messages": messages])
        let encoded = try VoiceTurnInput.encode(first)
        #expect(try JSONDecoder().decode(HarnessValue.self, from: Data(encoded.utf8)) == first)
        #expect(try VoiceTurnInput.encode(second) == encoded)
        #expect(encoded.hasPrefix(#"{"topic":{"name":"Synthetic","notes":"#))
        #expect(try #require(encoded.range(of: #""tools":"#)).lowerBound < #require(encoded.range(of: #""messages":"#)).lowerBound)
        var changed = try #require(first.object); changed["messages"] = .array([.string("A different question.")])
        let next = try VoiceTurnInput.encode(.object(changed))
        #expect(encoded.split(separator: "\"messages\"", maxSplits: 1).first == next.split(separator: "\"messages\"", maxSplits: 1).first)
    }

    @Test func invalidStructuredRepliesNeverPublishBeforeValidation() throws {
        var reply = AssistantReplyText()
        let early = try reply.append(#"{"calls":[],"speech":"The light is on. "#)
        #expect(early.isEmpty, "A JSON prefix does not prove the complete decision is valid.")
        _ = try reply.append(#"","calls":[{"tool":"home.light","arguments":{"on":true}}]}"#)
        #expect(throws: (any Error).self) { try reply.finish() }
    }

    @Test func completeSentencesAreAvailableWhileTheReplyIsStillOpen() throws {
        var reply = AssistantReplyText()
        #expect(try reply.append("Die Antwort ist kurz.").isEmpty)
        #expect(try reply.append(" Der nächste Satz") == ["Die Antwort ist kurz."])
        #expect(try reply.append(" kommt später. ") == ["Der nächste Satz kommt später."])
        let end = try reply.finish()
        #expect(end.text == "Die Antwort ist kurz. Der nächste Satz kommt später.")
        #expect(end.remaining.isEmpty)
    }

    @Test func datesDecimalsAndAbbreviationsKeepTheirContext() throws {
        var reply = AssistantReplyText()
        #expect(try reply.append("Dr. Meier kommt am 21. ").isEmpty)
        #expect(try reply.append("November. Es kostet 12.") == ["Dr. Meier kommt am 21. November."])
        #expect(try reply.append("50 Franken. ") == ["Es kostet 12.50 Franken."])
        #expect(try reply.finish().remaining.isEmpty)
    }

    @Test func numbersAndUnpunctuatedAnswersAreNotDropped() throws {
        for text in ["42", "Ja", "  Guten\nMorgen  "] {
            var reply = AssistantReplyText()
            #expect(try reply.append(text).isEmpty)
            let result = try reply.finish()
            #expect(result.remaining == [result.text])
            #expect(!result.text.isEmpty)
        }
    }

    @Test func legacyJSONIsNeverReadOutBeforeValidation() throws {
        var reply = AssistantReplyText()
        let json = #"{"speech":"Ich kann dir helfen.","calls":[]}"#
        for character in json { #expect(try reply.append(String(character)).isEmpty) }
        let result = try reply.finish()
        #expect(result.text == "Ich kann dir helfen." && result.remaining == [result.text])
    }

    @Test func aCallsFirstReplyWaitsForCompleteValidation() throws {
        var reply = AssistantReplyText(speaksText: false)
        let json = #"{"calls": [], "speech": "Er sagte \"Grüezi\" und ging.\nDanach: Caf\u00e9 \ud83d\ude00. Ende"}"#
        var sentences: [String] = []
        // One character at a time, so escapes and surrogate pairs are cut at every point.
        for character in json { sentences += try reply.append(String(character)) }
        #expect(sentences.isEmpty)
        let end = try reply.finish()
        #expect(end.text == #"Er sagte "Grüezi" und ging. Danach: Café 😀. Ende"#)
        #expect(end.remaining == [end.text])
    }

    @Test func aJSONReplyThatProposesCallsIsNeverSpokenEarly() throws {
        var reply = AssistantReplyText()
        let json = #"{"calls":[{"tool":"home.light","arguments":{"on":true}}],"speech":"Erledigt. Das Licht ist an. "}"#
        for character in json { #expect(try reply.append(String(character)).isEmpty) }
        #expect(throws: (any Error).self) { try reply.finish() }
    }

    @Test func plainTextWaitsWhereTheReplyMustBeJSON() throws {
        var reply = AssistantReplyText(speaksText: false)
        #expect(try reply.append("Das Licht ist an. Sonst noch etwas? ").isEmpty)
    }

    @Test func aStructuredReplyIsDeliveredWholeAfterValidation() throws {
        var reply = AssistantReplyText(speaksText: false)
        #expect(try reply.append(#"{"calls":[],"speech":"Erster Satz. Zwei"#).isEmpty)
        #expect(try reply.append(#"ter Satz."}"#).isEmpty)
        #expect(try reply.finish().remaining == ["Erster Satz. Zweiter Satz."])
    }

    @Test func structuredCallsAndAmbiguousJSONCannotBypassTheToolGate() throws {
        for json in [
            #"{"speech":"Done.","calls":[{"tool":"home.light","arguments":{"on":true}}]}"#,
            #"{"speech":"one","speech":"two","calls":[]}"#,
            #"{"speech":"unfinished""#,
            #"{"calls":[],"speech":"one","calls":[{"tool":"home.light","arguments":{"on":true}}]}"#,
        ] {
            var reply = AssistantReplyText()
            #expect(try reply.append(json).isEmpty)
            #expect(throws: (any Error).self) { try reply.finish() }
        }
    }

    @Test func emptyAndOversizedRepliesFailInsteadOfQueueingUnboundedSpeech() throws {
        var empty = AssistantReplyText()
        #expect(try empty.append("  \n ").isEmpty)
        #expect(throws: MCPFailure.invalidResponse) { try empty.finish() }
        var large = AssistantReplyText()
        #expect(throws: MCPFailure.tooLarge) { try large.append(String(repeating: "a", count: 2001)) }
    }
}

@MainActor private final class ReplyVoiceDouble: AssistantSpeechFailureReporting {
    var failed: ((ConversationResponseID) -> Void)?
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var utterances: [(String, ConversationResponseID)] = []
    func speak(_ text: String, response: ConversationResponseID, language: Language) { utterances.append((text, response)) }
    func stop() { if let last = utterances.last { cancelled?(last.1) } }
}

@MainActor @Suite struct AssistantReplySpeechTests {
    @Test func aReportedVoiceFailureIsDistinctFromAnIntentionalStop() {
        let voice = ReplyVoiceDouble(), speech = AssistantReplySpeech(output: voice)
        let failed = ConversationResponseID("failed"), stopped = ConversationResponseID("stopped")
        var failures: [ConversationResponseID] = [], cancellations: [ConversationResponseID] = []
        speech.failed = { failures.append($0) }; speech.cancelled = { cancellations.append($0) }
        speech.begin(response: failed, language: .en); speech.append("First sentence.", response: failed)
        voice.failed?(failed)
        speech.append("Dropped late audio.", response: failed)
        speech.begin(response: stopped, language: .en); speech.append("Next sentence.", response: stopped)
        speech.stop(); voice.failed?(stopped)
        #expect(failures == [failed] && cancellations == [stopped])
        #expect(voice.utterances.map(\.0) == ["First sentence.", "Next sentence."])
    }

    @Test func aGapInModelOutputDoesNotFinishTheLogicalReply() throws {
        let voice = ReplyVoiceDouble(), response = ConversationResponseID("reply")
        let speech = AssistantReplySpeech(output: voice)
        var started: [ConversationResponseID] = [], finished: [ConversationResponseID] = []
        speech.began = { started.append($0) }; speech.finished = { finished.append($0) }
        speech.begin(response: response, language: .de)
        speech.append("Der erste Satz.", response: response)
        let first = try #require(voice.utterances.first?.1)
        voice.began?(first); voice.finished?(first)
        #expect(finished.isEmpty, "the model has not closed the reply yet")
        speech.append("Der zweite Satz.", response: response)
        let second = try #require(voice.utterances.last?.1)
        voice.began?(second)
        speech.complete(response: response)
        #expect(finished.isEmpty, "the second sentence is still playing")
        voice.finished?(second)
        voice.finished?(second)
        #expect(started == [response] && finished == [response])
    }

    @Test func stoppingDropsQueuedSentencesAndLateCallbacks() throws {
        let voice = ReplyVoiceDouble(), speech = AssistantReplySpeech(output: voice)
        let old = ConversationResponseID("old"), fresh = ConversationResponseID("fresh")
        var finished: [ConversationResponseID] = [], cancelled: [ConversationResponseID] = []
        speech.finished = { finished.append($0) }; speech.cancelled = { cancelled.append($0) }
        speech.begin(response: old, language: .en)
        speech.append("Old first.", response: old)
        speech.append("Old queued.", response: old)
        speech.stop()
        speech.begin(response: fresh, language: .en)
        speech.append("New reply.", response: fresh)
        speech.complete(response: fresh)
        voice.finished?(old); voice.cancelled?(old)
        speech.append("Late old text.", response: old)
        voice.began?(fresh); voice.finished?(fresh)
        #expect(voice.utterances.map(\.0) == ["Old first.", "New reply."])
        #expect(cancelled == [old] && finished == [fresh])
    }

    @Test func queuedSentencesAreGroupedForTheVoicesLookAhead() throws {
        let voice = ReplyVoiceDouble(), speech = AssistantReplySpeech(output: voice)
        let response = ConversationResponseID("reply")
        speech.begin(response: response, language: .en)
        speech.append("One.", response: response)
        speech.append("Two.", response: response)
        speech.append("Three.", response: response)
        voice.finished?(response)
        #expect(voice.utterances.map(\.0) == ["One.", "Two. Three."])
        speech.stop()
    }

    @Test func emptyOrNeverStartedAudioIsNotAcknowledgedAsHeard() {
        for text in ["", "Never started."] {
            let voice = ReplyVoiceDouble(), speech = AssistantReplySpeech(output: voice)
            let response = ConversationResponseID("reply")
            var finished = false, cancelled = false
            speech.finished = { _ in finished = true }; speech.cancelled = { _ in cancelled = true }
            speech.speak(text, response: response, language: .en)
            voice.finished?(response)
            #expect(!finished && cancelled)
        }
    }
}

extension AssistantReplyTextTests {
    @Test func anIsolatedGreetingWaitsForUsefulWordsButShortAnswersDoNot() throws {
        var reply = AssistantReplyText()
        #expect(try reply.append("Hey listen! ").isEmpty)
        #expect(try reply.append("Die Stadt heißt Cape Suzette. ") == ["Hey listen! Die Stadt heißt Cape Suzette."])
        #expect(try reply.finish().remaining.isEmpty)
        var short = AssistantReplyText()
        #expect(try short.append("Ja. ") == ["Ja."])
        var only = AssistantReplyText()
        _ = try only.append("Entschuldige. ")
        #expect(try only.finish().remaining == ["Entschuldige."])
    }
}
