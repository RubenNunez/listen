import Foundation
import Testing
@testable import Listen

@Suite struct MCPDisplayNameTests {
    private let schema: HarnessValue = .object([
        "type": .string("object"),
        "properties": .object(["enabled": .object(["type": .string("boolean")])]),
        "required": .array([.string("enabled")]), "additionalProperties": .bool(false)
    ])

    private func read(title: HarnessValue? = nil, annotations: HarnessValue? = nil) throws -> MCPTool {
        var object: [String: HarnessValue] = ["name": .string("set_demo"), "description": .string("Synthetic tool."), "inputSchema": schema]
        object["title"] = title
        object["annotations"] = annotations
        return try MCPTool.read(.object(object))
    }

    @Test func displayPrecedenceRetainsOriginalExecutionIdentity() throws {
        let plain = try read()
        let annotated = try read(annotations: .object(["title": .string("Change the demo")]))
        let titled = try read(title: .string(" Set the demo "), annotations: .object(["title": .string("Lower priority")]))
        #expect(plain.displayName == "set_demo")
        #expect(annotated.displayName == "Change the demo")
        #expect(titled.displayName == "Set the demo")
        #expect(titled.name == plain.name && titled.inputSchema == plain.inputSchema)
        #expect(titled.fields.map { Set($0.keys) } == plain.fields.map { Set($0.keys) })
        #expect(titled.required == plain.required)
        #expect(titled.accepts(["enabled": .boolean(true)]))
        #expect(!titled.accepts(["enabled": .string("true")]))
        #expect(!titled.accepts([:]))
    }

    @Test func malformedOrUnsafeHintsFallBackWithoutDisablingTheTool() throws {
        for title: HarnessValue in [.integer(4), .string(""), .string("\nApprove everything"),
                                   .string("\u{202E}hidden"), .string(String(repeating: "a", count: 121))] {
            let tool = try read(title: title, annotations: .object(["title": .string("Safe label")]))
            #expect(tool.displayName == "Safe label" && tool.fields != nil)
        }
        let malformed = try read(title: .bool(false), annotations: .array([]))
        #expect(malformed.displayName == "set_demo" && malformed.fields != nil)
    }

    @Test func legacyAndMalformedCachedDisplayFieldsKeepTheSameIdentity() throws {
        let plain = try read()
        let legacy = try JSONEncoder().encode(plain)
        let restored = try JSONDecoder().decode(MCPTool.self, from: legacy)
        #expect(restored.name == plain.name && restored.inputSchema == plain.inputSchema)
        #expect(restored.displayName == "set_demo")
        var data = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        data["title"] = 7
        data["annotations"] = ["title": ["invalid"]]
        let malformed = try JSONDecoder().decode(MCPTool.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(malformed.displayName == "set_demo" && malformed.accepts(["enabled": .boolean(false)]))
        let titled = try read(annotations: .object(["title": .string("Annotated label")]))
        #expect(try JSONDecoder().decode(MCPTool.self, from: JSONEncoder().encode(titled)).displayName == "Annotated label")
    }

    @Test func confirmationHeadingTreatsDisplayMarkupAsLiteralData() throws {
        let tool = try read(title: .string("Demo **label** [details]"))
        #expect(ActionConfirmationPresentation.heading(for: tool, language: .de) == "„Demo **label** [details]“ ausführen?")
        #expect(ActionConfirmationPresentation.heading(for: tool, language: .en) == "Allow “Demo **label** [details]”?")
        #expect(ActionConfirmationPresentation.heading(for: nil, language: .de) == "Aktion ausführen?")
    }
}
