import Foundation
import Testing
@testable import Listen

/// A clock the test moves. `sleep` returns once the clock has passed its deadline.
private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date
    init(_ start: Date = Date()) { time = start }
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    var timing: KeyTransferTiming {
        .init(now: { self.now }, sleep: { seconds in
            let deadline = self.now + seconds
            while self.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        })
    }
}

@Suite struct KeyTransferTicketRotation {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func started(_ policy: KeyTransferRotation.Policy = .init()) -> KeyTransferRotation {
        var rotation = KeyTransferRotation(policy: policy)
        rotation.start(host: "10.1.2.3", port: 4242, now: start)
        return rotation
    }

    @Test func ticketIsReplacedByAFreshOneThatThePhoneAccepts() throws {
        var rotation = started()
        let first = try #require(rotation.current)
        #expect(rotation.deadline == start.timeIntervalSince1970 + 30)
        #expect(rotation.advance(now: start + 29.9) == .none && rotation.current?.ticket.id == first.ticket.id)
        #expect(rotation.advance(now: start + 30) == .renewed)
        let second = try #require(rotation.current)
        #expect(second.ticket.id != first.ticket.id && second.ticket.secret != first.ticket.secret
            && second.ticket.publicKey != first.ticket.publicKey)
        #expect(second.ticket.host == first.ticket.host && second.ticket.port == first.ticket.port)
        #expect(second.ticket.expires == start.timeIntervalSince1970 + 150)
        // The unchanged phone side reads both codes at the moment of the swap.
        #expect(try KeyTransferCrypto.Ticket.read(first.ticket.code(), now: start + 30).id == first.ticket.id)
        #expect(try KeyTransferCrypto.Ticket.read(second.ticket.code(), now: start + 30).id == second.ticket.id)
        #expect(try first.ticket.code().utf8.count == second.ticket.code().utf8.count)
        // Random keys contain slashes in varying numbers; the code length must not follow them.
        var lengths = Set<Int>()
        for _ in 0..<64 { lengths.insert(try #require(started().current).ticket.code().utf8.count) }
        #expect(lengths.count == 1)
    }

    @Test func replacedTicketIsAcceptedOnlyDuringItsGrace() throws {
        var rotation = started()
        let first = try #require(rotation.current).ticket.id
        #expect(rotation.advance(now: start + 30) == .renewed)
        let second = try #require(rotation.current).ticket.id
        #expect(rotation.entry(for: first, now: start + 39.9)?.ticket.id == first)
        #expect(rotation.entry(for: first, now: start + 40) == nil)
        #expect(rotation.entry(for: second, now: start + 40)?.ticket.id == second)
        #expect(rotation.entry(for: UUID(), now: start + 31) == nil)
    }

    @Test func onlyTheTicketBeforeTheCurrentOneHasAGrace() throws {
        // A grace longer than the cycle would otherwise keep two old tickets alive.
        var rotation = started(.init(renew: 30, grace: 50))
        let first = try #require(rotation.current).ticket.id
        #expect(rotation.advance(now: start + 30) == .renewed)
        let second = try #require(rotation.current).ticket.id
        #expect(rotation.advance(now: start + 60) == .renewed)
        #expect(rotation.entry(for: first, now: start + 60) == nil)
        #expect(rotation.entry(for: second, now: start + 60)?.ticket.id == second)
    }

    @Test func claimEndsRenewalAndKeepsOnlyTheClaimedTicket() throws {
        var rotation = started()
        let first = try #require(rotation.current)
        #expect(rotation.advance(now: start + 30) == .renewed)
        let second = try #require(rotation.current).ticket.id
        #expect(rotation.claim(first.ticket.id, now: start + 35)?.ticket.id == first.ticket.id)
        #expect(rotation.phase == .claimed && rotation.current?.ticket.id == first.ticket.id && rotation.previous == nil)
        #expect(rotation.entry(for: second, now: start + 35) == nil && rotation.claim(second, now: start + 35) == nil)
        // The approval deadline is the claimed ticket's own `expires`, as before renewal existed.
        #expect(rotation.deadline == first.ticket.expires)
        #expect(rotation.advance(now: start + 90) == .none && rotation.current?.ticket.id == first.ticket.id)
        #expect(rotation.advance(now: start + 120) == .expired && rotation.phase == .stopped && rotation.current == nil)
    }

    @Test func approvedCopyHasItsOwnDeadline() throws {
        var rotation = started()
        let id = try #require(rotation.current).ticket.id
        rotation.claim(id, now: start + 5)
        rotation.approve(now: start + 20)
        #expect(rotation.phase == .approved && rotation.deadline == start.timeIntervalSince1970 + 3620)
        #expect(rotation.advance(now: start + 3619) == .none)
        #expect(rotation.advance(now: start + 3620) == .timedOut && rotation.current == nil)
    }

    @Test func renewalStopsAfterTheIdleLimitAndEveryTicketLapses() throws {
        var rotation = started()
        var seen: Set<UUID> = [try #require(rotation.current).ticket.id]
        for step in 1...9 {
            #expect(rotation.advance(now: start + Double(step) * 30) == .renewed)
            seen.insert(try #require(rotation.current).ticket.id)
        }
        #expect(seen.count == 10)
        let last = try #require(rotation.current).ticket.id
        #expect(rotation.advance(now: start + 300) == .lapsed)
        #expect(rotation.phase == .lapsed && rotation.current == nil && rotation.previous == nil && rotation.deadline == nil)
        #expect(rotation.entry(for: last, now: start + 300) == nil && rotation.claim(last, now: start + 300) == nil)
        #expect(rotation.advance(now: start + 900) == .none)
    }

    @Test func stoppingDropsEveryTicket() throws {
        var rotation = started()
        #expect(rotation.advance(now: start + 30) == .renewed)
        let ids = [try #require(rotation.current).ticket.id, try #require(rotation.previous).ticket.id]
        rotation.stop()
        #expect(rotation.phase == .stopped && rotation.deadline == nil)
        for id in ids { #expect(rotation.entry(for: id, now: start + 31) == nil) }
        #expect(rotation.advance(now: start + 60) == .none && rotation.current == nil)
    }
}

/// The sender on a real loopback socket, with a clock the test moves. The short policy
/// keeps the moved clock inside the window the phone side checks against real time.
@MainActor @Suite struct KeyTransferRenewingCode {
    private let policy = KeyTransferRotation.Policy(renew: 10, grace: 5, approval: 60, idle: 35)
    private let secrets = KeyTransferSecrets(read: { _ in "synthetic-transfer-key" }, write: { _, _ in }, remove: { _ in })
    private func wait(_ ready: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Synthetic local transfer did not reach the expected state")
    }
    private func phone() -> KeyTransferReceiver {
        KeyTransferReceiver(secrets: secrets, makeChannel: { _, port in KeyTransferChannel(host: "127.0.0.1", port: port) })
    }
    /// Moves the clock one cycle and returns the code that replaced `old`.
    private func renew(_ sender: KeyTransferSender, _ clock: FakeTime, after old: String) async throws -> String {
        clock.advance(policy.renew)
        try await wait { sender.code != nil && sender.code != old }
        return try #require(sender.code)
    }

    @Test func codeRenewsItselfAndAScanOfTheReplacedCodeStillTransfers() async throws {
        let clock = FakeTime(), sender = KeyTransferSender(secrets: secrets, policy: policy, timing: clock.timing), receiver = phone()
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        let first = try #require(sender.code)
        #expect(sender.phase == .showing && sender.renewal != nil)
        let second = try await renew(sender, clock, after: first)
        #expect(sender.phase == .showing)
        // Scanned at the moment of renewal: the replaced code is inside its grace.
        receiver.scan(first)
        try await wait { sender.waitingDevice != nil }
        #expect(sender.phase == .connected && sender.verification == receiver.verification && sender.renewal == nil)
        // A connected phone ends renewal, and the transfer runs as it always did.
        clock.advance(policy.renew * 2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sender.code == second && sender.phase == .connected)
        sender.approve()
        try await wait { receiver.ready }
        receiver.install([.openAI]) { _ in }
        try await wait { sender.code == nil }
        #expect(sender.status.contains("Imported") && sender.phase == .idle)
    }

    @Test func codesOlderThanTheGraceAreRefusedWhileTheCurrentOneWorks() async throws {
        let clock = FakeTime(), sender = KeyTransferSender(secrets: secrets, policy: policy, timing: clock.timing), receiver = phone()
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        let first = try #require(sender.code)
        let second = try await renew(sender, clock, after: first)
        let third = try await renew(sender, clock, after: second)
        // Two renewals back: refused although its own grace has only just begun to matter.
        receiver.scan(first)
        try await wait { receiver.verification == nil && receiver.status.contains("could not be reached") }
        #expect(sender.waitingDevice == nil && sender.phase == .showing)
        // One renewal back, after its grace.
        clock.advance(policy.grace + 1)
        receiver.scan(second)
        try await wait { receiver.verification == nil && receiver.status.contains("could not be reached") }
        #expect(sender.waitingDevice == nil && sender.phase == .showing && sender.code == third)
        receiver.scan(third)
        try await wait { sender.waitingDevice != nil }
        #expect(sender.verification == receiver.verification)
    }

    @Test func renewalStopsAfterTheIdleLimitUntilANewCodeIsRequested() async throws {
        let clock = FakeTime(), sender = KeyTransferSender(secrets: secrets, policy: policy, timing: clock.timing), receiver = phone()
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        var last = try #require(sender.code)
        for _ in 0..<3 { last = try await renew(sender, clock, after: last) }
        clock.advance(5)
        try await wait { sender.phase == .lapsed }
        #expect(sender.code == nil && sender.renewal == nil && sender.status.contains("Show a new code"))
        // The listener is gone: the last code reaches nobody, and nothing renews any more.
        receiver.scan(last)
        clock.advance(policy.renew)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sender.waitingDevice == nil && sender.code == nil && sender.phase == .lapsed && !receiver.ready)
        receiver.cancel()
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        #expect(sender.phase == .showing && sender.code != last)
    }

    @Test func leavingTheScreenStopsRenewalAndLetsTheCodeLapse() async throws {
        let clock = FakeTime(), sender = KeyTransferSender(secrets: secrets, policy: policy, timing: clock.timing), receiver = phone()
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        let code = try #require(sender.code)
        // What the view does when it disappears or the app goes to the background.
        sender.cancel()
        #expect(sender.code == nil && sender.phase == .idle && sender.renewal == nil)
        clock.advance(policy.renew)
        receiver.scan(code)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sender.code == nil && sender.phase == .idle && sender.waitingDevice == nil && !receiver.ready)
    }
}
