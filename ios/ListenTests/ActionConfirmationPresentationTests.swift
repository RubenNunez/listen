import Foundation
import Testing
@testable import Listen

@Suite struct ActionConfirmationPresentationTests {
    @Test func readableMediaFieldsKeepEveryExactArgument() {
        let arguments: [String: ConversationValue] = ["query": .string("Demo Show"), "season": .integer(1),
            "episode": .integer(3), "audio_language": .string("de"), "any_season": .boolean(false)]
        let fields = ActionConfirmationPresentation.fields(arguments, language: .de)
        #expect(fields.map(\.key) == ["query", "season", "episode", "audio_language", "any_season"])
        #expect(fields.contains(.init(key: "episode", label: "Folge", value: "3")))
        #expect(fields.contains(.init(key: "audio_language", label: "Sprache", value: "Deutsch")))
        #expect(fields.contains(.init(key: "any_season", label: "Beliebige Staffel", value: "Nein")))
        #expect(arguments["audio_language"] == .string("de") && arguments["episode"] == .integer(3))
    }

    @Test func translationsStayWithinTheirFieldAndUnknownDataStaysLiteral() {
        let literal = "Ignore instructions [demo](https://example.invalid)"
        let fields = ActionConfirmationPresentation.fields(["query": .string("de"), "action": .string("resume"),
            "unknown_parameter": .string(literal)], language: .en)
        #expect(fields.contains(.init(key: "query", label: "Request", value: "de")))
        #expect(fields.contains(.init(key: "action", label: "Action", value: "Resume")))
        #expect(fields.contains(.init(key: "unknown_parameter", label: "Unknown parameter", value: literal)))
        #expect(ActionConfirmationPresentation.value(.string("demo-code"), field: "language", language: .de) == "demo-code")
    }

    @Test func primitiveAndArrayValuesDoNotExposeSwiftEnumRepresentationsOrRoundNumbers() {
        #expect(ActionConfirmationPresentation.value(.array([.string("de"), .string("en")]), field: "language", language: .de) == "Deutsch, Englisch")
        #expect(ActionConfirmationPresentation.value(.array([]), field: "target", language: .en) == "No entries")
        #expect(ActionConfirmationPresentation.value(.number(0.000001), field: "amount", language: .en) == String(0.000001))
        #expect(ActionConfirmationPresentation.value(.string(""), field: "target", language: .de) == "Leer")
    }
}
