import CryptoKit
import Foundation

/// Time source of the Mac side, injectable so tests can move the clock.
struct KeyTransferTiming: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
}

/// Lifetime of the pairing tickets the Mac shows. While no phone has claimed one, the
/// ticket on screen is replaced every `renew` seconds by one with a new ID, secret and
/// key pair. Only the ticket on screen and, for `grace` seconds, the one before it can
/// be claimed. Pure state: every transition takes the time as an argument.
struct KeyTransferRotation {
    struct Policy: Sendable, Equatable {
        /// How long one ticket stays on screen.
        var renew: TimeInterval = 30
        /// How long the replaced ticket can still be claimed.
        var grace: TimeInterval = 10
        /// Written into the ticket as `expires`: the deadline for comparing the codes
        /// and approving. The phone refuses anything further ahead than 180 s.
        var approval: TimeInterval = 120
        /// Without a phone, renewal stops after this long.
        var idle: TimeInterval = 300
        /// Deadline of an approved copy.
        var transfer: TimeInterval = 3600
    }
    struct Entry {
        let ticket: KeyTransferCrypto.Ticket
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let issued: Double
    }
    enum Phase: Equatable { case stopped, showing, claimed, approved, lapsed }
    enum Change: Equatable { case none, renewed, lapsed, expired, timedOut }

    let policy: Policy
    private(set) var phase = Phase.stopped
    private(set) var current: Entry?
    private(set) var previous: Entry?
    private var previousUntil = 0.0
    private var started = 0.0
    private var transferDeadline = 0.0
    private var host = ""
    private var port: UInt16 = 0

    init(policy: Policy = .init()) { self.policy = policy }

    mutating func start(host: String, port: UInt16, now: Date) {
        stop()
        self.host = host; self.port = port
        started = now.timeIntervalSince1970
        current = issue(started); phase = .showing
    }

    /// The next moment `advance` has something to do.
    var deadline: Double? {
        switch phase {
        case .showing: current.map { min($0.issued + policy.renew, started + policy.idle) }
        case .claimed: current?.ticket.expires
        case .approved: transferDeadline
        case .stopped, .lapsed: nil
        }
    }

    mutating func advance(now: Date) -> Change {
        let time = now.timeIntervalSince1970
        switch phase {
        case .showing:
            guard let current else { return .none }
            if time >= started + policy.idle { clear(); phase = .lapsed; return .lapsed }
            if time >= previousUntil { previous = nil }
            guard time >= current.issued + policy.renew else { return .none }
            previous = current; previousUntil = time + policy.grace
            self.current = issue(time)
            return .renewed
        case .claimed:
            guard let current, time >= current.ticket.expires else { return .none }
            stop(); return .expired
        case .approved:
            guard time >= transferDeadline else { return .none }
            stop(); return .timedOut
        case .stopped, .lapsed: return .none
        }
    }

    /// The ticket a claim may use: the one on screen, or the one before it during its grace.
    func entry(for id: UUID, now: Date) -> Entry? {
        guard phase == .showing else { return nil }
        if let current, current.ticket.id == id { return current }
        if let previous, previous.ticket.id == id, now.timeIntervalSince1970 < previousUntil { return previous }
        return nil
    }

    /// A phone proved it holds this ticket. Renewal ends and every other ticket is dropped.
    @discardableResult mutating func claim(_ id: UUID, now: Date) -> Entry? {
        guard let entry = entry(for: id, now: now) else { return nil }
        current = entry; previous = nil; phase = .claimed
        return entry
    }

    mutating func approve(now: Date) {
        guard phase == .claimed else { return }
        transferDeadline = now.timeIntervalSince1970 + policy.transfer; phase = .approved
    }

    mutating func stop() { clear(); phase = .stopped }

    private mutating func clear() { current = nil; previous = nil; previousUntil = 0 }

    private func issue(_ time: Double) -> Entry {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        // Whole seconds keep the encoded length, and so the QR size, the same from ticket to ticket.
        let ticket = KeyTransferCrypto.Ticket(id: UUID(), host: host, port: port, publicKey: privateKey.publicKey.rawRepresentation,
            secret: KeyTransferCrypto.random(), expires: (time + policy.approval).rounded(.down))
        return Entry(ticket: ticket, privateKey: privateKey, issued: time)
    }
}
