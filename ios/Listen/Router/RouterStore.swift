import Foundation
import Observation

struct SavedRouter: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var address: RouterAddress
    var enabled = false
    var model = ""
    var usesCodex = false
    var secretAccount: String { "router.\(id.uuidString)" }
}

/// Installation bindings, kept apart from portable systems. Pairing never enables inference.
@MainActor @Observable
final class RouterStore {
    static let shared = RouterStore()
    enum State: Equatable {
        case unchecked, checking, connected(Listen_Router_V1_StatusResponse), failed(RouterFailure)
    }
    private(set) var routers: [SavedRouter] = []
    private(set) var states: [UUID: State] = [:]
    private(set) var problem: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var original: Data?
    @ObservationIgnored private var writable = true
    @ObservationIgnored private let readSecret: (String) -> String?
    @ObservationIgnored private let writeSecret: (String, String) throws -> Void
    @ObservationIgnored private let deleteSecret: (String) -> Void
    @ObservationIgnored private var clients: [String: RouterModelClient] = [:]
    @ObservationIgnored private var statusChecks: [UUID: UUID] = [:]
    @ObservationIgnored let connect: @Sendable (RouterAddress, String) -> any RouterRPC

    private struct Document: Codable { var version = 1; var routers: [SavedRouter] }

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Listen/routers.json"),
         readSecret: @escaping (String) -> String? = { Keychain.get($0) },
         writeSecret: @escaping (String, String) throws -> Void = { try Keychain.set($1, for: $0) },
         deleteSecret: @escaping (String) -> Void = { Keychain.remove($0) },
         connect: @escaping @Sendable (RouterAddress, String) -> any RouterRPC = { RouterConnection(address: $0, token: $1) }) {
        self.file = file
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        self.deleteSecret = deleteSecret
        self.connect = connect
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                original = data
                let saved = try JSONDecoder().decode(Document.self, from: data)
                guard saved.version == 1, saved.routers.count <= 16,
                      Set(saved.routers.map(\.id)).count == saved.routers.count,
                      saved.routers.filter(\.enabled).count <= 1 else { throw RouterFailure.storage }
                for router in saved.routers {
                    _ = try RouterLink.parse("listen://pair?host=\(router.address.host)&port=\(router.address.port)&code=ABCDEFGH&fp=\(router.address.fingerprint)")
                    guard router.name.count <= 128, Self.validModel(router.model) else { throw RouterFailure.storage }
                }
                routers = saved.routers
            }
        } catch {
            writable = false
            problem = "Saved routers could not be read. The original file has been preserved."
        }
    }

    /// Called only after an idle, explicit device migration has committed.
    func reloadAfterTransfer() {
        statusChecks.removeAll()
        for client in clients.values { Task { await client.session.invalidate() } }
        clients.removeAll()
        let fresh = RouterStore(file: file, readSecret: readSecret, writeSecret: writeSecret, deleteSecret: deleteSecret, connect: connect)
        routers = fresh.routers; original = fresh.original; writable = fresh.writable; problem = fresh.problem
        states = [:]
    }

    var active: SavedRouter? { routers.first(where: \.enabled) }

    private static func validModel(_ model: String) -> Bool {
        model.count <= 200 && !model.contains("://") && model.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func save(_ next: [SavedRouter]) throws {
        guard writable else { throw RouterFailure.storage }
        do {
            let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            guard current == original else { throw RouterFailure.storage }
            let data = try JSONEncoder().encode(Document(routers: next))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let original { try original.write(to: file.appendingPathExtension("backup"), options: .atomic) }
            try data.write(to: file, options: .atomic)
            original = data
            routers = next
        } catch { throw RouterFailure.storage }
    }

    /// Called only from the explicit Pair action after the proposal was displayed.
    func pair(_ link: RouterLink, host: String? = nil, deviceName: String) async throws {
        guard writable, routers.count < 16 else { throw RouterFailure.storage }
        let host = host ?? link.hosts.first ?? ""
        guard link.hosts.contains(host) else { throw RouterFailure.invalidLink }
        try Task.checkCancellation()
        let address = RouterAddress(host: host, port: link.port, fingerprint: link.fingerprint)
        // Pair is a one-time exchange: never retry on another address after ambiguous failure.
        let response = try await connect(address, "").pair(code: link.code, deviceName: deviceName)
        guard response.deviceToken.count == 64, response.deviceToken.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RouterFailure.invalidResponse
        }
        let router = SavedRouter(name: String(response.routerName.prefix(128)), address: address)
        do { try writeSecret(router.secretAccount, response.deviceToken) }
        catch { throw RouterFailure.storage }
        do { try save(routers + [router]) }
        catch { deleteSecret(router.secretAccount); throw error }
        // Pairing is complete once the binding is saved. A health check has its own
        // deadline and belongs to the connection view, not the one-time exchange.
    }

    func refresh(_ id: UUID) async {
        guard !Task.isCancelled, let router = routers.first(where: { $0.id == id }) else { return }
        let check = UUID()
        statusChecks[id] = check
        let previous = states[id] == .checking ? State.unchecked : (states[id] ?? .unchecked)
        defer { if statusChecks[id] == check { statusChecks[id] = nil } }
        guard let token = readSecret(router.secretAccount) else { states[id] = .failed(.unpaired); return }
        states[id] = .checking
        do {
            let status = try await connect(router.address, token).status()
            guard statusChecks[id] == check, routers.contains(where: { $0.id == id }) else { return }
            states[id] = Task.isCancelled ? previous : .connected(status)
        } catch {
            guard statusChecks[id] == check, routers.contains(where: { $0.id == id }) else { return }
            let failure = RouterConnection.failure(error)
            states[id] = failure == .cancelled ? previous : .failed(failure)
        }
    }

    func configure(_ id: UUID, enabled: Bool, model: String, usesCodex: Bool) throws {
        guard Self.validModel(model), routers.contains(where: { $0.id == id }) else { throw RouterFailure.storage }
        var next = routers
        for index in next.indices {
            if next[index].id == id {
                next[index].enabled = enabled
                next[index].model = model
                next[index].usesCodex = usesCodex
            } else if enabled { next[index].enabled = false }
        }
        try save(next)
    }

    func remove(_ id: UUID) async throws {
        guard let router = routers.first(where: { $0.id == id }) else { return }
        try save(routers.filter { $0.id != id })
        deleteSecret(router.secretAccount)
        statusChecks[id] = nil
        states[id] = nil
        for key in clients.keys.filter({ $0.hasPrefix("\(id)/") }) {
            if let client = clients.removeValue(forKey: key) { await client.session.invalidate() }
        }
    }

    func client(topic: UUID) -> RouterModelClient? {
        guard let router = active, let token = readSecret(router.secretAccount) else { return nil }
        let key = "\(router.id)/\(topic)/\(router.usesCodex)/\(router.model)"
        if let client = clients[key] { return client }
        let id = router.id
        let client = RouterModelClient(session: RouterModelSession(rpc: connect(router.address, token), topic: topic,
            tool: router.usesCodex ? .codex : .claude, failed: { [weak self] failure in
                guard failure != .cancelled else { return }
                await self?.markFailed(id, failure: failure)
            }))
        clients[key] = client
        return client
    }

    private func markFailed(_ id: UUID, failure: RouterFailure) {
        if routers.contains(where: { $0.id == id }) {
            statusChecks[id] = nil
            states[id] = .failed(failure)
        }
    }
}
