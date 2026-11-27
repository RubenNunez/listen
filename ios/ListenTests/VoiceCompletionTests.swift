import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct VoiceSetupTransfer {
    private func package(prompt: String? = nil) -> SetupPackage {
        var topic = Topic(name: "Synthetic portable setup")
        topic.system = "voice-assistant"; topic.notes = "Synthetic optional briefing"
        topic.links = ["https://example.com/selected"]
        var system = ListenSystem.builtIns.first { $0.id == "voice-assistant" }!
        if let prompt { system.configuration?.conversation?.prompt = prompt }
        return SetupPackage(topic: topic, system: SystemPackage(system: system, defaults: SystemConfig()))
    }
    @Test func fileAndCompactLinkPreserveTheFullSystemWithoutTopicIdentityOrBriefingByDefault() throws {
        let original = package(prompt: "Synthetic instructions: clarify the request before answering.")
        for restored in [try SetupPackage.read(original.data()), try SetupPackage.read(link: original.link())] {
            #expect(restored.system.system.configuration == original.system.system.configuration)
            #expect(restored.system.system.blocks == original.system.system.blocks)
            #expect(restored.topic.id != original.topic.id && restored.topic.notes.isEmpty)
            #expect(restored.topic.links == original.topic.links && !restored.topic.evaluation)
            #expect(restored.system.system.configuration?.conversation?.limitModelRequests == false)
        }
        let raw = try JSONSerialization.jsonObject(with: original.data()) as! [String: Any]
        #expect(Set(raw.keys) == ["format", "version", "topic", "system"])
        #expect((raw["topic"] as? [String: Any])?["id"] == nil)
    }
    @Test func changedBaselinesMalformedLinksAndUnknownFieldsDoNotImport() throws {
        let original = package()
        let link = try original.link()
        #expect(throws: (any Error).self) { try SetupPackage.read(link: URL(string: link.absoluteString + "&p=duplicate")!) }
        #expect(throws: (any Error).self) { try SetupPackage.read(link: URL(string: link.absoluteString + "#fragment")!) }
        var root = try JSONSerialization.jsonObject(with: original.data()) as! [String: Any]
        root["credentials"] = ["synthetic": "not-a-real-secret"]
        #expect(throws: (any Error).self) { try SetupPackage.read(JSONSerialization.data(withJSONObject: root)) }
        let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        var base64 = components.queryItems![0].value!.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        var compact = try JSONSerialization.jsonObject(with: Data(base64Encoded: base64)!) as! [String: Any]
        compact["fingerprint"] = "different"
        let changed = try JSONSerialization.data(withJSONObject: compact).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(throws: (any Error).self) { try SetupPackage.read(link: URL(string: "listen://setup?p=" + changed)!) }
    }
    @Test func largeInstructionsUseTheFileWithoutTruncatingPrompts() throws {
        let prompt = (0..<2000).map { "Synthetic instruction \($0): \(UUID().uuidString)" }.joined(separator: "\n").prefix(25_000)
        let original = package(prompt: String(prompt))
        #expect(throws: (any Error).self) { try original.link() }
        #expect(try SetupPackage.read(original.data()).system.system.configuration?.conversation?.prompt == String(prompt))
    }
    @Test func addingATopicPreservesExistingDataAndRejectsStaleOrCorruptStores() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "topics.json")
        let store = TopicStore(file: file)
        store.upsert(Topic(name: "Synthetic existing"))
        let before = try Data(contentsOf: file)
        let source = package().topic
        let added = try store.installSetup(source, system: "synthetic-import")
        #expect(added.id != source.id && added.system == "synthetic-import")
        #expect(store.topics.contains { $0.name == "Synthetic existing" })
        #expect(try Data(contentsOf: file.appendingPathExtension("backup")) == before)
        let stale = TopicStore(file: file)
        store.upsert(Topic(name: "Synthetic newer"))
        let newer = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try stale.installSetup(source, system: "synthetic-import") }
        #expect(try Data(contentsOf: file) == newer)
        try Data("corrupt synthetic data".utf8).write(to: file)
        let corrupt = TopicStore(file: file)
        #expect(throws: (any Error).self) { try corrupt.installSetup(source, system: "synthetic-import") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "corrupt synthetic data")
    }
}

@Suite struct VoiceEvidenceAndHistory {
    @Test func selectedEvidenceIsRelevantBoundedAndLabelledAsData() {
        let context = AssistantContext(material: MaterialIndex(passages: [
            .init(source: "synthetic.md", text: "The synthetic actuator uses a Modbus interface."),
            .init(source: "unrelated.md", text: "Blueberry recipes and cooking ingredients.")], overview: "Synthetic selected material"),
            earlier: "Synthetic earlier note", pages: [.init(url: "https://example.com", title: "Selected page", text: String(repeating: "a", count: 3000))])
        let value = context.evidence(for: "Which Modbus interface?").object!
        #expect(value["role"]?.string == "untrusted_topic_evidence")
        guard case let .array(passages)? = value["passages"], case let .array(pages)? = value["pages"] else { Issue.record("Missing evidence lists"); return }
        #expect(passages.count == 1)
        #expect(value["earlierNotes"]?.string == "Synthetic earlier note")
        #expect(pages.first?.object?["text"]?.string?.count == 1500)
    }
    @Test func recordedVoiceEventsSeekWithoutInferenceOrToolDispatch() {
        let data = Data("""
        {"kind":"voice_reply","t":3,"text":"Synthetic reply"}
        {"kind":"voice_user","t":1,"text":"Synthetic request"}
        {"kind":"voice_operation","t":2,"capability":"home.light","state":"outcomeUnknown(routeLost)"}
        {"kind":"voice_reply","t":-1,"text":"invalid time"}
        {"kind":"unrelated","t":4,"text":"ignored"}
        """.utf8)
        let history = AssistantHistory(data: data)
        #expect(history.entries.map(\.title) == ["Request", "Action", "Reply"])
        #expect(history.checkpoint(at: 4) == 3 && history.checkpoint(at: 1) == 1 && history.checkpoint(at: 0) == 0)
        #expect(history.entries[1].text.contains("outcomeUnknown"))
    }
    private struct SilentModel: ModelClient {
        func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
            AsyncThrowingStream { _ in }
        }
    }
    @Test func summaryDeadlineFinishesEvenWithoutProviderOutput() async {
        var failed = false
        do {
            for try await _ in AssistantDeadlineClient(base: SilentModel(), timeout: .milliseconds(20)).stream(model: "synthetic", system: "synthetic", user: "synthetic", maxTokens: 20) {}
        } catch { failed = true }
        #expect(failed)
    }
}
