import Foundation
import Testing
@testable import Listen

/// Owner-authorized device setup, not a synthetic benchmark. Disabled during normal
/// tests. The owner supplies one protected app-cache JSON file; it is always removed.
/// Only MCP initialization and discovery are performed, never a tool action.
@MainActor @Suite struct NativeLocalMCPSetup {
    private struct Input: Decodable {
        var version: Int
        var topic: UUID
        var server: MCPServerBinding
        var token: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_PROVISION_LOCAL_MCP"] == "1"))
    func installOwnerSelectedLANConnectionWithoutActions() async throws {
        #expect(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let inputFile = URL.cachesDirectory.appending(path: "listen-owner-mcp-setup.json")
        defer { try? FileManager.default.removeItem(at: inputFile) }
        let data = try Data(contentsOf: inputFile)
        try #require(data.count <= 32_768)
        try HarnessJSON.checkUniqueKeys(data)
        let input = try JSONDecoder().decode(Input.self, from: data)
        try #require(input.version == 1 && !input.token.isEmpty && input.token.utf8.count <= 4096)
        try #require(MCPClient.validEndpoint(input.server.endpoint))
        try #require(LocalNetworkHost.accepts(input.server.endpoint.host ?? ""))
        try #require(!input.server.permissions.isEmpty && input.server.permissions.count <= 32)
        // A copied setup never introduces a new standing grant.
        try #require(input.server.permissions.allSatisfy { !$0.withoutConfirmation })
        let topics = TopicStore(), systems = SystemStore(), store = MCPStore()
        try #require(topics.selectedID == input.topic && systems.storageProblem == nil && store.problem == nil)
        let topic = topics.selected
        var system = systems.chosen(for: topic)
        try #require(system.isVoiceAssistant)
        var configuration = system.configuration ?? SystemConfig()
        var voice = configuration.conversation ?? VoiceAssistantConfiguration(enabled: true)
        let names = Set(try await store.discover(input.server, token: input.token)
            .filter { $0.fields != nil }.map(\.name))
        try #require(input.server.permissions.allSatisfy { names.contains($0.tool) })
        for permission in input.server.permissions where !voice.toolIDs.contains(permission.id) {
            voice.toolIDs.append(permission.id)
        }
        try voice.validate()
        configuration.conversation = voice
        system.configuration = configuration
        try store.save(input.server, newToken: input.token)
        systems.update(system)
        try #require(systems.lastError == nil)
        let resolved = await MCPStore().resolve(input.server.permissions.map(\.id))
        try #require(resolved.missing.isEmpty)
        let plan = SessionModel.plan(for: topic, listenSystem: system)
        let answer = voice.model.isEmpty ? plan.settings.merger : voice.model
        let prefix = String(answer.split(separator: "/").first ?? "")
        let connected = prefix == "local" ? plan.hasLocal : (plan.direct[prefix] != nil || plan.key != nil)
        let status: [String: Any] = ["state": "ready", "actions_sent": 0, "answer_model": answer, "answer_connection_available": connected,
            "capabilities": resolved.tools.map { $0.capability.rawValue }.sorted(),
            "requires_confirmation": resolved.tools.allSatisfy { !$0.standing },
            "jev_key_present": Keychain.get(Connector.jev.rawValue) != nil,
            "jev_enabled": UserDefaults.standard.bool(forKey: JevClient.enabledKey),
            "adaptive_routing": voice.adaptiveRouting, "parallel_opening": voice.parallelOpening,
            "main_model": voice.model, "simple_model": voice.simpleModel, "complex_model": voice.complexModel]
        try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL.cachesDirectory.appending(path: "listen-owner-mcp-status.json"), options: .atomic)
    }
}
