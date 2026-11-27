import Foundation
import Observation

struct MCPToolPermission: Codable, Equatable, Identifiable, Sendable {
    /// Portable symbolic capability; the installation binds it to this server/tool.
    var id: String
    var tool: String
    var withoutConfirmation = false
}

struct MCPServerBinding: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var endpoint: URL
    var revision = MCPRevision.current
    var permissions: [MCPToolPermission] = []
    var secretAccount: String { "mcp.\(id.uuidString)" }
}

struct AssistantTool: Sendable {
    var capability: ConversationCapabilityID
    var descriptor: MCPTool
    var client: MCPClient
    var standing: Bool
    var binding: MCPServerBinding? = nil
    var registered: RegisteredConversationTool? {
        guard let fields = descriptor.fields else { return nil }
        return .init(id: capability, fields: fields, required: descriptor.required, execute: { [client, descriptor] request in
            await client.call(descriptor, arguments: request.arguments)
        })
    }
}

@MainActor @Observable
final class MCPStore {
    static let shared = MCPStore()
    private(set) var servers: [MCPServerBinding] = []
    private(set) var problem: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var original: Data?
    @ObservationIgnored private let readSecret: (String) -> String?
    @ObservationIgnored private let writeSecret: (String, String) throws -> Void
    @ObservationIgnored private let deleteSecret: (String) -> Void
    @ObservationIgnored let makeClient: @Sendable (MCPServerBinding, String?) throws -> MCPClient
    private struct Saved: Codable { var version = 1; var servers: [MCPServerBinding] }

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Listen/mcp.json"),
         readSecret: @escaping (String) -> String? = { Keychain.get($0) },
         writeSecret: @escaping (String, String) throws -> Void = { try Keychain.set($1, for: $0) },
         deleteSecret: @escaping (String) -> Void = { Keychain.remove($0) },
         makeClient: @escaping @Sendable (MCPServerBinding, String?) throws -> MCPClient = { try MCPClient(endpoint: $0.endpoint, revision: $0.revision, token: $1) }) {
        self.file = file
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        self.deleteSecret = deleteSecret
        self.makeClient = makeClient
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                original = data
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.version == 1 else { throw MCPFailure.invalidResponse }
                try Self.validate(saved.servers)
                servers = saved.servers
            } catch { problem = "Saved MCP connections could not be read. Their original file is preserved." }
        }
    }

    func reloadAfterTransfer() {
        let fresh = MCPStore(file: file, readSecret: readSecret, writeSecret: writeSecret, deleteSecret: deleteSecret, makeClient: makeClient)
        servers = fresh.servers; original = fresh.original; problem = fresh.problem
    }

    private static func validate(_ servers: [MCPServerBinding]) throws {
        guard servers.count <= 16, Set(servers.map(\.id)).count == servers.count else { throw MCPFailure.tooLarge }
        var aliases = Set<String>()
        for server in servers {
            guard MCPClient.validEndpoint(server.endpoint), !server.name.isEmpty, server.name.count <= 80,
                  server.permissions.count <= 128, Set(server.permissions.map(\.tool)).count == server.permissions.count else { throw MCPFailure.endpoint }
            for permission in server.permissions {
                guard permission.id.wholeMatch(of: /[A-Za-z0-9_.-]{1,100}/) != nil,
                      aliases.insert(permission.id).inserted, !permission.tool.isEmpty, permission.tool.count <= 128 else { throw MCPFailure.invalidResponse }
            }
        }
    }

    func save(_ server: MCPServerBinding, newToken: String? = nil) throws {
        guard problem == nil else { throw MCPFailure.invalidResponse }
        let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == original else { throw MCPFailure.invalidResponse }
        var next = servers.filter { $0.id != server.id }
        next.append(server)
        try Self.validate(next)
        let previousToken = readSecret(server.secretAccount)
        let changedEndpoint = servers.first(where: { $0.id == server.id }).map { $0.endpoint != server.endpoint } ?? false
        let replacementToken = newToken ?? (changedEndpoint ? "" : nil)
        if let newToken = replacementToken {
            guard newToken.utf8.count <= 4096, newToken.utf8.allSatisfy({ (32...126).contains($0) }) else { throw MCPFailure.authentication }
            if newToken.isEmpty { deleteSecret(server.secretAccount) }
            else { try writeSecret(server.secretAccount, newToken) }
        }
        do { try persist(next) }
        catch {
            if replacementToken != nil {
                if let previousToken { try? writeSecret(server.secretAccount, previousToken) }
                else { deleteSecret(server.secretAccount) }
            }
            throw error
        }
    }

    private func persist(_ next: [MCPServerBinding]) throws {
        let data = try JSONEncoder().encode(Saved(servers: next))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original { try original.write(to: file.appendingPathExtension("backup"), options: .atomic) }
        try data.write(to: file, options: .atomic)
        original = data
        servers = next
    }

    func remove(_ id: UUID) throws {
        guard problem == nil, let server = servers.first(where: { $0.id == id }) else { return }
        let current = try Data(contentsOf: file)
        guard current == original else { throw MCPFailure.invalidResponse }
        try persist(servers.filter { $0.id != id })
        deleteSecret(server.secretAccount)
    }

    /// Native confirmation only: remember this resolved server/tool, not another
    /// destination or a capability whose installation binding changed meanwhile.
    func allowWithoutConfirmation(_ tool: AssistantTool) throws {
        guard problem == nil, let binding = tool.binding,
              let serverIndex = servers.firstIndex(where: { $0.id == binding.id }),
              servers[serverIndex].endpoint == binding.endpoint,
              servers[serverIndex].revision == binding.revision,
              let permissionIndex = servers[serverIndex].permissions.firstIndex(where: {
                  $0.id == tool.capability.rawValue && $0.tool == tool.descriptor.name
              }) else { throw MCPFailure.invalidResponse }
        let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == original else { throw MCPFailure.invalidResponse }
        var next = servers
        next[serverIndex].permissions[permissionIndex].withoutConfirmation = true
        try persist(next)
    }

    func discover(_ server: MCPServerBinding, token: String? = nil) async throws -> [MCPTool] {
        let sameEndpoint = servers.first(where: { $0.id == server.id })?.endpoint == server.endpoint
        return try await makeClient(server, token ?? (sameEndpoint ? readSecret(server.secretAccount) : nil)).listTools()
    }

    /// A fresh session resolves only the capabilities named by its selected system.
    func resolve(_ requested: [String]) async -> (tools: [AssistantTool], missing: [String]) {
        var result: [AssistantTool] = [], missing = Set(requested)
        for server in servers {
            let selected = server.permissions.filter { requested.contains($0.id) }
            guard !selected.isEmpty else { continue }
            do {
                let client = try makeClient(server, readSecret(server.secretAccount))
                if let run = RunRecorder.assistantOutput {
                    await client.observe { [weak run] kind, fields in
                        await MainActor.run {
                            var recorded: [String: Any] = fields.mapValues { $0 as Any }
                            recorded["server"] = server.name
                            run?.logModelEvent(kind, recorded)
                        }
                    }
                }
                let catalogue = try await client.listTools()
                for permission in selected {
                    guard let tool = catalogue.first(where: { $0.name == permission.tool }), tool.fields != nil else { continue }
                    result.append(.init(capability: .init(permission.id), descriptor: tool, client: client, standing: permission.withoutConfirmation, binding: server))
                    missing.remove(permission.id)
                }
            } catch { /* Missing requirements stay unavailable; no alternative route is enabled. */ }
        }
        return (result, missing.sorted())
    }
}
