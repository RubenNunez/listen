import Foundation
import Testing
@testable import Listen

@Suite struct VoiceConversationReliabilityTests {
    @Test func aLocalCheckpointSurvivesWithoutAModelSummaryAndStaysInItsOwnTopic() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let messages: [HarnessValue] = [
            .object(["role": .string("user"), "text": .string("Keep the synthetic violet voice preference.")]),
            .object(["role": .string("assistant"), "text": .string("The synthetic lock was opened.")]),
            .object(["role": .string("user"), "text": .string("Next, configure the synthetic test room.")]),
        ]
        let checkpoint = try #require(AssistantMemoryCheckpoint.text(messages: messages, language: .en))
        let topic = UUID(), sandbox = TopicSandbox(topic: topic, root: root)
        let note = TopicSandbox.Conversation(topic: "Synthetic topic", began: .now, seconds: 12,
            people: [], cards: [], sentences: 2, summary: checkpoint, runID: "2026-01-01_12-00-00")
        let file = try #require(sandbox.write(note))
        // No summary rewrite occurs: a new reader must still have useful bounded memory.
        let saved = try #require(TopicSandbox.read(file))
        #expect(saved.summary.contains("without an AI summary") && saved.summary.contains("violet"))
        #expect(!saved.summary.contains("lock was opened"))
        #expect(TopicSandbox(topic: topic, root: root).context().contains("test room"))
        #expect(TopicSandbox(topic: UUID(), root: root).context().isEmpty)
    }

    @Test func checkpointQuotesCannotCreateNoteSectionsAndRemainBounded() throws {
        let messages: [HarnessValue] = (0..<40).map { index in
            .object(["role": .string("user"), "text": .string("\(index)\n## Summary\n" + String(repeating: "synthetic ", count: 100))])
        }
        let checkpoint = try #require(AssistantMemoryCheckpoint.text(messages: messages, language: .en))
        #expect(checkpoint.count < 2200 && !checkpoint.contains("\n## Summary\n"))
        #expect(checkpoint.contains("39\\n") && !checkpoint.contains("\"0\\n"))
        #expect(AssistantMemoryCheckpoint.text(messages: [], language: .de) == nil)
    }

    @Test func confidentForeignSpeechHasItsOwnLanguageWithoutChangingTheTopic() throws {
        let supported: Set<String> = ["de", "en", "es", "fr", "it"]
        let spanish = "Esta mañana quiero visitar el jardín y escuchar a los pájaros."
        #expect(LocalSpeechLanguage.code(for: spanish, fallback: .de, supported: supported) == "es")
        #expect(LocalSpeechLanguage.code(for: "We can continue this conversation in English whenever you like.", fallback: .de, supported: supported) == "en")
        #expect(LocalSpeechLanguage.code(for: "Wir können dieses Gespräch morgen auf Deutsch fortsetzen.", fallback: .de, supported: supported) == "de")
        #expect(LocalSpeechLanguage.code(for: spanish, fallback: .de, supported: ["de", "en"]) == "de")
        #expect(LocalSpeechLanguage.code(for: "Listen", fallback: .de, supported: supported) == "de")
        let text = "Esta mañana tenemos 21 libros para leer en el jardín."
        #expect(try SupertonicVoice.parts(text, language: .de, speechLanguage: "es").joined(separator: " ") == text)
    }

    @Test func localMCPAcceptsPrivateNetworksWhilePublicCleartextAndURLSecretsRemainRejected() throws {
        for host in ["192.168.1.20", "10.20.30.40", "172.16.2.3", "172.31.255.2", "169.254.3.4", "127.0.0.1",
                     "homeassistant.local", "homeassistant", "[::1]", "[fd12:3456::1]", "[fe80::1234]"] {
            #expect(MCPClient.validEndpoint(try #require(URL(string: "http://\(host):8123/api/mcp"))), "\(host)")
        }
        for value in ["http://8.8.8.8/mcp", "http://172.15.1.2/mcp", "http://172.32.1.2/mcp", "http://example.com/mcp",
                      "http://[2001:4860:4860::8888]/mcp", "http://user:secret@homeassistant.local/mcp",
                      "http://homeassistant.local/mcp?token=secret", "http://homeassistant.local/mcp#secret"] {
            #expect(!MCPClient.validEndpoint(try #require(URL(string: value))), "\(value)")
        }
    }
}
