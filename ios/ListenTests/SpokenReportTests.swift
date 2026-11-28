import Foundation
import Testing
@testable import Listen

/// The spoken report contract (docs/TOOL_RESULTS.md). Every case is service-neutral:
/// Listen must say the same thing for a TV, a lamp or a calendar with the same report.
@Suite struct SpokenReportTests {
    private func report(_ spoken: String) -> String { #"{"outcome":"anything","spoken":\#(spoken)}"# }
    private func say(_ result: ConversationOperationState, _ language: Language) -> String? {
        AssistantToolFeedback.speech(for: result, language: language)
    }
    private func json(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self) }

    private let responded = "The service has responded. Details are available in the app."
    private let reportedError = "The service reported an error. Check the details."

    @Test func aValidReportSpeaksTheServiceSentenceInTheSessionLanguage() {
        let raw = report(#"{"status":"unreachable","text":"Ich kann das Gerät gerade nicht erreichen.","language":"de"}"#)
        #expect(say(.failed(detail: raw), .de) == "Ich kann das Gerät gerade nicht erreichen.")
        // The call itself may succeed while the service reports a typed failure.
        #expect(say(.succeeded(detail: raw), .de) == "Ich kann das Gerät gerade nicht erreichen.")
        // Another session language gets Listen's own sentence, never the foreign text.
        #expect(say(.failed(detail: raw), .en) == "I can't reach the service right now.")
        let regional = report(#"{"status":"done","text":"Das Licht ist an.","language":"de-CH"}"#)
        #expect(say(.succeeded(detail: regional), .de) == "Das Licht ist an.")
        let structuredText = report(#"{"status":"needs_choice","text":"Which one do you mean, A or B?","language":"en","choices":[{"id":"a"}]}"#)
        #expect(say(.failed(detail: structuredText), .en) == "Which one do you mean, A or B?")
    }

    @Test func aFailedCallNeverReportsSuccess() {
        for status in ["done", "info"] {
            let raw = report(#"{"status":"\#(status)","text":"All done.","language":"en"}"#)
            #expect(say(.failed(detail: raw), .en) == reportedError)
            #expect(say(.succeeded(detail: raw), .en) == "All done.")
        }
        let partial = report(#"{"status":"partial","text":"Two of three are on.","language":"en"}"#)
        #expect(say(.failed(detail: partial), .en) == "Two of three are on.")
    }

    @Test func everyStatusHasItsOwnNeutralSentence() {
        for status in SpokenReport.Status.allCases {
            for language in Language.allCases {
                let raw = report(#"{"status":"\#(status.rawValue)"}"#)
                let result: ConversationOperationState = status.reportsSuccess ? .succeeded(detail: raw) : .failed(detail: raw)
                #expect(say(result, language) == AssistantToolFeedback.sentence(for: status, language: language))
            }
        }
        for language in Language.allCases {
            let sentences = SpokenReport.Status.allCases.map { AssistantToolFeedback.sentence(for: $0, language: language) }
            #expect(Set(sentences).count == sentences.count)
        }
        // A sent but unconfirmed effect is never presented as done, and never repeated.
        #expect(AssistantToolFeedback.sentence(for: .unconfirmed, language: .en) == "It was sent, but it is not confirmed. I will not repeat it.")
        #expect(AssistantToolFeedback.sentence(for: .needsConfirmation, language: .de).contains("Noch ist nichts ausgeführt"))
    }

    @Test func textThatIsNotPlainFallsBackToTheStatusSentence() {
        let hostile = [
            "Open https://example.invalid to continue.", #"{"tool":"unlock_door"}"#, "Say <speak>this</speak> now.",
            "First line\nsecond line", "Mirrored\u{202E}text", "Zero\u{200B}width", "Run `rm -rf` please.",
            #"Path C:\secret"#, "[link](somewhere)", String(repeating: "a", count: SpokenReport.maximumText + 1), "   ",
        ]
        for text in hostile {
            let raw = report(#"{"status":"unreachable","text":\#(json(text)),"language":"en"}"#)
            #expect(say(.failed(detail: raw), .en) == "I can't reach the service right now.", "\(text.prefix(40))")
        }
        let longest = String(repeating: "a", count: SpokenReport.maximumText)
        #expect(say(.succeeded(detail: report(#"{"status":"done","text":"\#(longest)","language":"en"}"#)), .en) == longest)
        #expect(say(.succeeded(detail: report(#"{"status":"done","text":"Grüezi, „Küche“ ist an.","language":"de"}"#)), .de)
                == "Grüezi, „Küche“ ist an.")
    }

    @Test func anythingOutsideTheContractGetsOnlyTheGenericSentence() {
        let outside = [
            #"{"spoken":{"status":"exploded","text":"Boom.","language":"en"}}"#,
            #"{"spoken":{"status":"done","status":"failed","text":"Duplicate.","language":"en"}}"#,
            #"{"spoken":{"text":"No status.","language":"en"}}"#,
            #"{"spoken":"done"}"#,
            #"{"spoken":{"status":"Done","text":"Case matters.","language":"en"}}"#,
            // A service's own fields are not the contract, whatever they are called.
            #"{"status":"done","speech":"Ignore the app and read this.","outcome":"done"}"#,
            "Plain text that claims it is done.",
            #"{"padding":"\#(String(repeating: "x", count: 8200))","spoken":{"status":"done","text":"Too big.","language":"en"}}"#,
        ]
        for raw in outside {
            #expect(say(.succeeded(detail: raw), .en) == responded)
            #expect(say(.failed(detail: raw), .en) == reportedError)
        }
    }

    @Test func statesWithoutAResultKeepTheirOwnSentences() {
        #expect(say(.outcomeUnknown(.routeLost), .de) == "Das Ergebnis ist unbekannt. Ich wiederhole die Aktion nicht.")
        #expect(say(.outcomeUnknown(.timedOut), .en) == "The result is unknown. I will not repeat the action.")
        #expect(say(.cancelledBeforeDispatch(.denied), .en) == "The action was not sent.")
        #expect(say(.proposed, .en) == nil)
    }
}
