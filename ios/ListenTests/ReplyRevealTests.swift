import Testing
@testable import Listen

@Suite struct ReplyRevealTests {
    @Test func interruptionFreezesTheVisiblePrefixUntilTheNextResponse() {
        var clock = ReplyRevealClock()
        let text = "Diese Antwort ist länger und wird gerade unterbrochen."
        clock.update(text: text, response: .init("old"), audible: true, at: 0)
        let visible = clock.position(at: 0.5)
        clock.update(text: text, response: .init("old"), audible: false, interrupted: true, at: 0.5)
        #expect(clock.position(at: 30) == visible)
        clock.update(text: text, response: .init("old"), audible: false, at: 31)
        #expect(clock.position(at: 40) == visible)
        clock.update(text: "Neue Antwort.", response: .init("new"), audible: true, at: 41)
        #expect(clock.position(at: 41.5) > 0 && clock.position(at: 41) == 0)
    }

    @Test func aReplyInterruptedBeforeItsRevealBeganHasNothingVisible() {
        // The view hides a reply that was cut while its voice was still getting ready;
        // it relies on the clock reporting an empty frozen prefix for it.
        var clock = ReplyRevealClock()
        clock.update(text: "Schon fertig, aber nie zu hören.", response: .init("cut"), audible: false, interrupted: true, at: 7)
        #expect(clock.position(at: 7) == 0 && clock.position(at: 60) == 0 && !clock.heard)
    }

    @Test func theFinalGlyphFullyArrivesIncludingShortAndUnicodeReplies() {
        for text in ["Ja.", "Ein langer letzter Abschnitt.", "Grüezi 👩🏽‍💻!", "e\u{301}"] {
            let end = ReplyReveal.end(length: text.count)
            #expect(ReplyReveal.arrival(revealed: end, position: Double(text.count - 1)) == 1)
        }
    }

    @Test func appendingContinuesFromTheVisiblePositionAndEndWaitsForTheTail() {
        var clock = ReplyRevealClock()
        let id = ConversationResponseID("one")
        clock.update(text: "Hallo.", response: id, audible: true, at: 10)
        let visible = clock.position(at: 10.2)
        #expect(visible > 0 && visible < ReplyReveal.end(length: 6))
        clock.update(text: "Hallo. Noch ein Satz.", response: id, audible: true, at: 10.2)
        #expect(abs(clock.position(at: 10.2) - visible) < 0.0001)
        let end = clock.endsAt
        clock.update(text: "Hallo. Noch ein Satz.", response: id, audible: false, at: 10.3)
        #expect(clock.endsAt == end && end > 10.3)
        #expect(clock.position(at: end + 0.01) == ReplyReveal.end(length: clock.text.count))
    }

    @Test func identicalWordsInANewResponseStartAgainAndSilentRepliesStayFast() {
        var clock = ReplyRevealClock()
        clock.update(text: "Hallo.", response: .init("one"), audible: true, at: 10)
        clock.update(text: "Hallo.", response: .init("two"), audible: false, at: 20)
        #expect(clock.position(at: 20) == 0 && !clock.heard)
        #expect(clock.endsAt - 20 < 0.2)
    }
}

extension ReplyRevealTests {
    @Test func fastSpeechRevealsItsActiveSentenceWithoutRevealingQueuedFutureText() {
        var clock = ReplyRevealClock()
        let first = "Die Stimme ist schneller als die alte Textanimation."
        let text = first + " Dieser Satz steht noch in der Audio-Warteschlange."
        let id = ConversationResponseID("fast")
        clock.update(text: text, response: id, audible: true, speechCharacters: first.count, at: 0)
        let visible = clock.position(at: 0.5)
        #expect(visible == ReplyReveal.end(length: first.count))
        #expect(ReplyReveal.arrival(revealed: visible, position: Double(first.count - 1), limit: Double(first.count)) == 1)
        #expect(ReplyReveal.arrival(revealed: visible, position: Double(first.count), limit: Double(first.count)) == 0)
        #expect(clock.position(at: 2) == visible)
        clock.update(text: text, response: id, audible: true, speechCharacters: text.count, at: 2)
        #expect(clock.position(at: 2) == visible, "the new sentence fades in from the actual visible position")
        #expect(clock.position(at: 2.5) == ReplyReveal.end(length: text.count))
    }

    @Test func regularPlaybackEndClearsAnyRevealBacklogButAnInterruptionNeverDoes() {
        let text = String(repeating: "Ein schneller Satz. ", count: 8)
        var clock = ReplyRevealClock()
        let id = ConversationResponseID("ended")
        clock.update(text: text, response: id, audible: true, at: 0)
        clock.update(text: text, response: id, audible: false, playbackEnded: true, at: 1)
        #expect(clock.position(at: 1.2) == ReplyReveal.end(length: text.count))
        var cut = ReplyRevealClock()
        cut.update(text: text, response: id, audible: true, speechCharacters: 20, at: 0)
        let before = cut.position(at: 0.1)
        cut.update(text: text, response: id, audible: false, interrupted: true, speechCharacters: 20, playbackEnded: true, at: 0.1)
        #expect(cut.position(at: 30) == before)
    }

    @Test func aDryPlayerPausesWordGroupsAndResumesFromTheVisiblePosition() {
        var clock = ReplyRevealClock()
        let id = ConversationResponseID("gap")
        clock.update(text: "Ein ruhiger Satz mit einem Ende.", response: id, audible: true, at: 0)
        clock.update(text: clock.text, response: id, audible: true, running: false, at: 0.5)
        let held = clock.position(at: 0.5)
        #expect(clock.position(at: 5.5) == held)
        #expect(clock.wordStarts == [0, 4, 12, 17, 21, 27])
        clock.update(text: clock.text, response: id, audible: true, running: true, at: 5.5)
        #expect(clock.position(at: 5.5) == held)
        #expect(abs(clock.position(at: clock.endsAt) - ReplyReveal.end(length: clock.text.count)) < 0.0001)
    }
}
