import CryptoKit
import Darwin
import Foundation
@preconcurrency import Network
import Observation

/// Length-bounded transport. The pairing protocol authenticates claims and encrypts
/// both credentials and acknowledgements before they enter this socket.
final class KeyTransferChannel: @unchecked Sendable {
    private let connection: NWConnection
    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: DispatchQueue(label: "Listen.key-transfer.connection"))
    }
    convenience init(host: String, port: UInt16) {
        self.init(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
    }
    func close() { connection.cancel() }
    func send(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= KeyTransferCrypto.maximumFrame else { throw KeyTransferFailure.invalid }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if error != nil { done.resume(throwing: KeyTransferFailure.unavailable) }
                    else { done.resume() }
                })
            }
        } onCancel: { self.close() }
    }
    func receive(maximum: Int = KeyTransferCrypto.maximumFrame) async throws -> Data {
        let header = try await read(4)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximum else { throw KeyTransferFailure.invalid }
        return try await read(Int(count))
    }
    private func read(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let maximum = count - buffer.count
            let data: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { done in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                        guard error == nil, let data, !data.isEmpty else { done.resume(throwing: KeyTransferFailure.unavailable); return }
                        done.resume(returning: data)
                    }
                }
            } onCancel: { self.close() }
            buffer.append(data)
        }
        return buffer
    }
    static func addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }
        var result: [String: Int] = [:], entry = pointer
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let name = String(cString: current.pointee.ifa_name)
            if KeyTransferCrypto.Ticket.localAddress(value) { result[value] = name.hasPrefix("en") ? 0 : 1 }
        }
        return result.keys.sorted { result[$0] == result[$1] ? $0 < $1 : result[$0]! < result[$1]! }
    }
}

@MainActor @Observable final class KeyTransferSender {
    enum Phase: Equatable { case idle, starting, showing, connected, lapsed }
    private(set) var phase = Phase.idle
    /// The code on screen while `showing`. It stays set until the session ends.
    private(set) var code: String?
    /// When the code on screen appeared and when the next one replaces it.
    private(set) var renewal: ClosedRange<Date>?
    private(set) var verification: String?
    private(set) var waitingDevice: String?
    private(set) var status = "Copy your Listen setup to your iPhone."
    private(set) var progress: Double?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var rotation: KeyTransferRotation
    /// The claimed ticket. Tickets nobody has claimed live in `rotation`.
    @ObservationIgnored private var ticket: KeyTransferCrypto.Ticket?
    @ObservationIgnored private var pending: (KeyTransferChannel, KeyTransferCrypto.Claim, SymmetricKey)?
    @ObservationIgnored private var channels: [KeyTransferChannel] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var selected: [TransferAPI] = []
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var setup: DeviceSetupMigration.Plan?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private let secrets: KeyTransferSecrets
    @ObservationIgnored private let timing: KeyTransferTiming
    init(secrets: KeyTransferSecrets = .live, policy: KeyTransferRotation.Policy = .init(), timing: KeyTransferTiming = .init()) {
        self.secrets = secrets; self.timing = timing; rotation = .init(policy: policy)
    }

    func start(host: String, providers: Set<TransferAPI>, setup: DeviceSetupMigration.Plan? = nil) throws {
        cancel()
        guard KeyTransferCrypto.Ticket.localAddress(host), !providers.isEmpty || setup != nil else { throw KeyTransferFailure.unavailable }
        self.setup = setup
        selected = providers.sorted { $0.rawValue < $1.rawValue }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        phase = .starting
        status = "Preparing a local transfer…"
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard self.rotation.phase == .stopped, let port = listener.port?.rawValue else { return }
                    self.rotation.start(host: host, port: port, now: self.timing.now())
                    self.show()
                case .failed: self.cancel(); self.status = "The local transfer could not start. Check Local Network access."
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.receive(connection)
            }
        }
        listener.start(queue: DispatchQueue(label: "Listen.key-transfer.listener"))
    }
    /// Puts the rotation's current ticket on screen.
    private func show() {
        guard let entry = rotation.current, let deadline = rotation.deadline, let code = try? entry.ticket.code() else { return }
        self.code = code
        renewal = Date(timeIntervalSince1970: entry.issued)...Date(timeIntervalSince1970: max(entry.issued, deadline))
        phase = .showing; status = "Scan this code in Listen on your iPhone."
        schedule()
    }
    private func schedule() {
        timer?.cancel(); timer = nil
        guard let deadline = rotation.deadline else { return }
        let timing = timing
        timer = Task { [weak self] in
            do { try await timing.sleep(max(0, deadline - timing.now().timeIntervalSince1970)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }
    private func tick() {
        switch rotation.advance(now: timing.now()) {
        case .renewed: show()
        case .lapsed: cancel(); phase = .lapsed; status = "No iPhone connected. Show a new code to continue."
        case .expired: cancel(); status = "Code expired. Create a new one."
        case .timedOut: cancel(); status = "Transfer timed out. The Mac setup is unchanged."
        case .none: schedule()
        }
    }
    private func receive(_ connection: NWConnection) {
        guard rotation.phase == .showing, pending == nil, !sending, channels.count < 4 else { connection.cancel(); return }
        let channel = KeyTransferChannel(connection)
        channels.append(channel)
        Task { [weak self] in
            let timeout = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { channel.close() } }
            do {
                let claim: KeyTransferCrypto.Claim = try KeyTransferCrypto.decode(await channel.receive(maximum: KeyTransferCrypto.maximumClaim))
                guard let self, channels.contains(where: { $0 === channel }), pending == nil, !sending else { throw KeyTransferFailure.refused }
                // Only the ticket on screen, or the one before it during its grace, is known here.
                let now = timing.now()
                guard let entry = rotation.entry(for: claim.id, now: now) else { throw KeyTransferFailure.refused }
                try entry.ticket.validate(now: now)
                let key = try KeyTransferCrypto.key(privateKey: entry.privateKey, peer: claim.publicKey, ticket: entry.ticket)
                try claim.validate(ticket: entry.ticket, key: key)
                guard rotation.claim(claim.id, now: now) != nil else { throw KeyTransferFailure.refused }
                timeout.cancel()
                ticket = entry.ticket; pending = (channel, claim, key)
                phase = .connected; renewal = nil
                verification = KeyTransferCrypto.verification(key); waitingDevice = claim.device
                status = "Compare the code on both devices, then approve the transfer."
                schedule()
            } catch { timeout.cancel(); channel.close(); self?.channels.removeAll { $0 === channel } }
        }
    }
    func approve() {
        guard let (channel, claim, key) = pending, let ticket, !sending else { return }
        sending = true
        let approvedProviders = selected, setup = self.setup
        operation = Task {
            do {
                guard self.ticket?.id == ticket.id else { return }
                try ticket.validate(now: timing.now())
                rotation.approve(now: timing.now()); schedule()
                let keys = try approvedProviders.compactMap { provider -> KeyTransferCrypto.Key? in
                    guard let value = secrets.read(provider) else {
                        if setup != nil { return nil }
                        throw KeyTransferFailure.storage
                    }
                    return .init(provider: provider, value: value)
                }
                let sentProviders = Set(keys.map(\.provider))
                let payload = KeyTransferCrypto.Bundle(id: ticket.id, keys: keys, setup: setup?.manifest)
                try payload.validate(ticket: ticket)
                status = setup == nil ? "Sending API keys…" : "Copying your setup…"
                try await channel.send(KeyTransferCrypto.seal(payload, key: key, claim: claim, purpose: "keys"))
                if let setup {
                    let ready: KeyTransferCrypto.Ack = try KeyTransferCrypto.open(await channel.receive(), key: key, claim: claim, purpose: "ready")
                    guard ready.id == ticket.id, ready.stage == "ready", ready.imported.isEmpty else { throw KeyTransferFailure.invalid }
                    try await DeviceSetupMigration.send(setup, channel: channel, key: key, claim: claim) { [weak self] done, total in
                        await self?.updateProgress(done, total: total, id: ticket.id)
                    }
                    try await channel.send(KeyTransferCrypto.seal(KeyTransferCrypto.Ack(id: ticket.id, imported: [], stage: "filesComplete"), key: key, claim: claim, purpose: "filesComplete"))
                }
                let ack: KeyTransferCrypto.Ack = try KeyTransferCrypto.open(await channel.receive(), key: key, claim: claim, purpose: "ack")
                guard self.ticket?.id == ticket.id else { return }
                guard ack.id == ticket.id, Set(ack.imported).count == ack.imported.count,
                      Set(ack.imported).isSubset(of: sentProviders),
                      setup == nil ? !ack.imported.isEmpty : (ack.stage == "complete" && Set(ack.imported) == sentProviders) else { throw KeyTransferFailure.invalid }
                cancel(); status = setup == nil ? "Imported on the iPhone. Keys remain on this Mac." : "Setup copied to your iPhone. Everything remains on this Mac."
            } catch {
                guard self.ticket?.id == ticket.id else { return }
                cancel(); status = "The transfer was not confirmed. Check the iPhone before trying again."
            }
        }
    }
    private func updateProgress(_ done: Int64, total: Int64, id: UUID) {
        guard ticket?.id == id else { return }
        progress = total > 0 ? Double(done) / Double(total) : 1
    }
    func cancel() {
        operation?.cancel(); operation = nil; setup = nil; progress = nil
        timer?.cancel(); timer = nil; rotation.stop()
        listener?.cancel(); listener = nil
        channels.forEach { $0.close() }; channels.removeAll()
        pending = nil; ticket = nil; code = nil; renewal = nil; verification = nil; waitingDevice = nil; selected = []; sending = false
        phase = .idle
    }
}

@MainActor @Observable final class KeyTransferReceiver {
    private(set) var providers: [TransferAPI] = []
    private(set) var verification: String?
    private(set) var status = "Scan the transfer code shown by Listen on your Mac."
    private(set) var ready = false
    private(set) var progress: Double?
    @ObservationIgnored private var payload: KeyTransferCrypto.Bundle?
    @ObservationIgnored private var channel: KeyTransferChannel?
    @ObservationIgnored private var claim: KeyTransferCrypto.Claim?
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let secrets: KeyTransferSecrets
    @ObservationIgnored private let makeChannel: @Sendable (String, UInt16) -> KeyTransferChannel
    @ObservationIgnored private var expires = 0.0
    @ObservationIgnored private let installSetup: @MainActor (URL, DeviceSetupMigration.Manifest) throws -> Void
    init(secrets: KeyTransferSecrets = .live,
         makeChannel: @escaping @Sendable (String, UInt16) -> KeyTransferChannel = { KeyTransferChannel(host: $0, port: $1) },
         installSetup: @escaping @MainActor (URL, DeviceSetupMigration.Manifest) throws -> Void = { _ = try DeviceSetupMigration.install(stage: $0, manifest: $1) }) {
        self.secrets = secrets; self.makeChannel = makeChannel; self.installSetup = installSetup
    }

    func scan(_ code: String, copySetup: Bool = false, imported: @escaping @MainActor () -> Void = {}) {
        cancel()
        operation = Task {
            do {
                let ticket = try KeyTransferCrypto.Ticket.read(code)
                expires = ticket.expires
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let key = try KeyTransferCrypto.key(privateKey: privateKey, peer: ticket.publicKey, ticket: ticket)
                var claim = KeyTransferCrypto.Claim(id: ticket.id, publicKey: privateKey.publicKey.rawRepresentation,
                    nonce: KeyTransferCrypto.random(), device: "iPhone")
                claim.proof = Data(HMAC<SHA256>.authenticationCode(for: try claim.authenticatedData(), using: key))
                let channel = makeChannel(ticket.host, ticket.port)
                self.channel = channel; self.claim = claim; self.key = key
                verification = KeyTransferCrypto.verification(key)
                status = "Compare this code with your Mac and approve there."
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(1, ticket.expires - Date().timeIntervalSince1970))) } catch { return }
                    guard !Task.isCancelled, self?.claim?.id == ticket.id else { return }
                    self?.cancel(); self?.status = "Code expired. Create a new one on the Mac."
                }
                try await channel.send(KeyTransferCrypto.encode(claim))
                let payload: KeyTransferCrypto.Bundle = try KeyTransferCrypto.open(await channel.receive(), key: key, claim: claim, purpose: "keys")
                try ticket.validate()
                try payload.validate(ticket: ticket)
                try Task.checkCancellation()
                if let manifest = payload.setup {
                    guard copySetup else { throw KeyTransferFailure.refused }
                    expiry?.cancel()
                    expiry = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                        guard self?.claim?.id == ticket.id else { return }
                        self?.cancel(); self?.status = "Transfer timed out. Your previous setup is unchanged."
                    }
                    status = "Copying your setup…"; progress = 0
                    try await channel.send(KeyTransferCrypto.seal(KeyTransferCrypto.Ack(id: ticket.id, imported: [], stage: "ready"), key: key, claim: claim, purpose: "ready"))
                    let stage = try await DeviceSetupMigration.receive(manifest, channel: channel, key: key, claim: claim) { [weak self] done, total in
                        await self?.updateProgress(done, total: total, id: ticket.id)
                    }
                    defer { try? FileManager.default.removeItem(at: stage) }
                    let complete: KeyTransferCrypto.Ack = try KeyTransferCrypto.open(await channel.receive(), key: key, claim: claim, purpose: "filesComplete")
                    guard complete.id == ticket.id, complete.stage == "filesComplete", complete.imported.isEmpty else { throw KeyTransferFailure.invalid }
                    try Task.checkCancellation()
                    guard self.claim?.id == ticket.id else { throw KeyTransferFailure.refused }
                    status = "Saving your setup…"
                    let written = try secrets.install(payload.keys) { try installSetup(stage, manifest) }
                    imported()
                    do {
                        try await channel.send(KeyTransferCrypto.seal(KeyTransferCrypto.Ack(id: ticket.id, imported: written, stage: "complete"), key: key, claim: claim, purpose: "ack"))
                    } catch {
                        guard self.claim?.id == ticket.id else { return }
                        cancel(); status = "Setup saved here. The Mac did not receive confirmation."; return
                    }
                    guard self.claim?.id == ticket.id else { return }
                    cancel(); status = "Your Mac setup has been copied to this device."
                } else {
                    guard !copySetup else { throw KeyTransferFailure.invalid }
                    self.payload = payload; providers = payload.keys.map(\.provider); ready = true
                    status = "Choose which API keys to save on this iPhone."
                }
            } catch {
                guard !Task.isCancelled else { return }
                cancel(); status = (error as? KeyTransferFailure)?.errorDescription ?? "The transfer could not be verified."
            }
        }
    }
    private func updateProgress(_ done: Int64, total: Int64, id: UUID) {
        guard claim?.id == id else { return }
        progress = total > 0 ? Double(done) / Double(total) : 1
    }
    func install(_ selected: Set<TransferAPI>, imported: (TransferAPI) -> Void) {
        guard ready, let payload, let channel, let claim, let key, !selected.isEmpty else { return }
        guard Date().timeIntervalSince1970 < expires else { cancel(); status = KeyTransferFailure.expired.errorDescription!; return }
        let keys = payload.keys.filter { selected.contains($0.provider) }
        guard !keys.isEmpty, Set(keys.map(\.provider)) == selected else { status = KeyTransferFailure.invalid.errorDescription!; return }
        let written: [TransferAPI]
        do {
            written = try secrets.install(keys)
        } catch {
            status = KeyTransferFailure.storage.errorDescription!; return
        }
        ready = false; self.payload = nil
        for provider in written { imported(provider) }
        let importedProviders = written
        Task {
            do { try await channel.send(KeyTransferCrypto.seal(KeyTransferCrypto.Ack(id: payload.id, imported: importedProviders), key: key, claim: claim, purpose: "ack")) }
            catch {
                guard self.claim?.id == payload.id else { return }
                cancel(); status = "Keys were saved here, but the Mac did not receive confirmation."; return
            }
            guard self.claim?.id == payload.id else { return }
            cancel(); status = "API keys saved on this iPhone."
        }
    }
    func cancel() {
        operation?.cancel(); operation = nil; expiry?.cancel(); expiry = nil
        channel?.close(); channel = nil; payload = nil; claim = nil; key = nil; providers = []; ready = false; verification = nil; expires = 0; progress = nil
    }
}
