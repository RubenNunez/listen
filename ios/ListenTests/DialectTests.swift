import Testing
@testable import Listen

@Suite struct DialectTextForItsSentence {
    // Pairs heard in a Swiss German call on 17 November 2026: what the first stage heard, and
    // what the dialect model wrote for the same stretch of sound.
    @Test func theSentenceBeforeIsCutOff() {
        let trimmed = Correction.trimDialect("Das ist wirklich falsch. Ich bin immer noch im Textflow drin, also.",
                                             to: "Ich bin immer noch im Textflow drin, also.")
        #expect(trimmed == "Ich bin immer noch im Textflow drin, also.")
    }

    @Test func surroundingSentencesAreCutOffAndTheMatchingOneStays() {
        let trimmed = Correction.trimDialect("Das läuft out of the box. Ja. Welche Modelle gibt es für Spracherkennung?",
                                             to: "gibt es für Spennung")
        #expect(trimmed == "Welche Modelle gibt es für Spracherkennung?")
    }

    @Test func oneSentenceOrNoSharedWordLeavesTheTextAlone() {
        #expect(Correction.trimDialect("Siehst du das Piano?", to: "Zäh ich das Piano") == "Siehst du das Piano?")
        let unrelated = "Ist das von dem oder von dem gesprochen. Weiss ich nicht."
        #expect(Correction.trimDialect(unrelated, to: "hey, anhand der Konversation") == unrelated)
    }

    @Test func sentencesBetweenTwoMatchingOnesStay() {
        let text = "Ich bin der Fuchs. Sorry. Ich bin immer noch am Reden."
        #expect(Correction.trimDialect(text, to: "Ich bin der Fuchs, ich bin immer noch am rede") == text)
    }
}
