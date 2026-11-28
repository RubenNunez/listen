import Foundation
import Testing
@testable import Listen

@Suite struct VoiceTurnInputTests {
    @Test func historicalEvidencePrecedesFreshObservationsAndTheCurrentDialogue() throws {
        let payload: HarnessValue = .object([
            "topic": .object(["name": .string("Synthetic")]), "tools": .array([]),
            "working_context": .object(["quote": .string("The earlier synthetic misheard label.")]),
            "recent_actions": .array([.object(["outcome": .string("confirmed_succeeded"), "name": .string("Canonical Demo")])]),
            "messages": .array([.object(["role": .string("user"), "text": .string("Okay.")])]),
            "future_evidence": .string("An unknown context field must also be retained."),
        ])
        let encoded = try VoiceTurnInput.encode(payload)
        func position(_ key: String) throws -> String.Index {
            try #require(encoded.range(of: "\"\(key)\":" )).lowerBound
        }
        #expect(try position("working_context") < position("recent_actions"))
        #expect(try position("recent_actions") < position("messages"))
        #expect(try position("future_evidence") < position("messages"))
        #expect(try JSONDecoder().decode(HarnessValue.self, from: Data(encoded.utf8)) == payload)
    }

    @Test func orderingKeepsTheStaticPrefixAndEveryUntrustedValueWithoutAddingData() throws {
        let topic: HarnessValue = .object(["name": .string("Synthetic \"quoted\" ä")])
        let first: HarnessValue = .object(["topic": topic, "tools": .array([]), "evidence": .null,
            "working_context": .string("Older context"), "messages": .array([.string("Current input")]),
            "future_flag": .bool(true)])
        var changed = try #require(first.object)
        changed["messages"] = .array([.string("New input")])
        let one = try VoiceTurnInput.encode(first), two = try VoiceTurnInput.encode(.object(changed))
        #expect(one.split(separator: "\"messages\"", maxSplits: 1).first == two.split(separator: "\"messages\"", maxSplits: 1).first)
        #expect(try JSONDecoder().decode(HarnessValue.self, from: Data(two.utf8)) == .object(changed))
        // Encoding the same fields in another order adds neither fields nor payload bytes.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(one.utf8.count == (try encoder.encode(first)).count)
    }
}
