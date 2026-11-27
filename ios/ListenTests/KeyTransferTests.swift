import CryptoKit
import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct LocalAPIKeyTransfer {
    private func wait(_ ready: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Synthetic local transfer did not complete")
    }
    @Test func qrContainsOnlyPairingAndPayloadRequiresBothEphemeralKeysAndCapability() throws {
        let desktop = Curve25519.KeyAgreement.PrivateKey(), phone = Curve25519.KeyAgreement.PrivateKey()
        let ticket = KeyTransferCrypto.Ticket(id: UUID(), host: "192.168.1.2", port: 12345,
            publicKey: desktop.publicKey.rawRepresentation, secret: KeyTransferCrypto.random(), expires: Date().timeIntervalSince1970 + 120)
        let read = try KeyTransferCrypto.Ticket.read(ticket.code())
        #expect(read.id == ticket.id)
        let phoneKey = try KeyTransferCrypto.key(privateKey: phone, peer: ticket.publicKey, ticket: ticket)
        let desktopKey = try KeyTransferCrypto.key(privateKey: desktop, peer: phone.publicKey.rawRepresentation, ticket: ticket)
        var claim = KeyTransferCrypto.Claim(id: ticket.id, publicKey: phone.publicKey.rawRepresentation,
            nonce: KeyTransferCrypto.random(), device: "Synthetic phone")
        claim.proof = Data(HMAC<SHA256>.authenticationCode(for: try claim.authenticatedData(), using: phoneKey))
        try claim.validate(ticket: ticket, key: desktopKey)
        #expect(KeyTransferCrypto.verification(phoneKey) == KeyTransferCrypto.verification(desktopKey))
        let payload = KeyTransferCrypto.Bundle(id: ticket.id, keys: [.init(provider: .openAI, value: "synthetic-api-key-for-tests")])
        let ciphertext = try KeyTransferCrypto.seal(payload, key: desktopKey, claim: claim, purpose: "keys")
        let restored: KeyTransferCrypto.Bundle = try KeyTransferCrypto.open(ciphertext, key: phoneKey, claim: claim, purpose: "keys")
        #expect(restored.keys[0].value == "synthetic-api-key-for-tests")
        #expect(!String(decoding: try KeyTransferCrypto.encode(ticket), as: UTF8.self).contains("synthetic-api-key"))
        var corrupt = ciphertext; corrupt[corrupt.count - 1] ^= 1
        #expect(throws: (any Error).self) { let _: KeyTransferCrypto.Bundle = try KeyTransferCrypto.open(corrupt, key: phoneKey, claim: claim, purpose: "keys") }
        #expect(throws: (any Error).self) { let _: KeyTransferCrypto.Bundle = try KeyTransferCrypto.open(ciphertext, key: phoneKey, claim: claim, purpose: "ack") }
        let wrongKey = SymmetricKey(size: .bits256)
        #expect(throws: (any Error).self) { let _: KeyTransferCrypto.Bundle = try KeyTransferCrypto.open(ciphertext, key: wrongKey, claim: claim, purpose: "keys") }
        claim.device = "Changed label"
        #expect(throws: (any Error).self) { try claim.validate(ticket: ticket, key: desktopKey) }
    }
    @Test func externalAddressesExpiredCodesAndOAuthKindsAreRejected() throws {
        for address in ["example.com", "8.8.8.8", "127.0.0.1", "010.1.2.3", "192.168.1.999", "192.168.1.1/other"] {
            #expect(!KeyTransferCrypto.Ticket.localAddress(address))
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let expired = KeyTransferCrypto.Ticket(id: UUID(), host: "10.1.2.3", port: 1,
            publicKey: key.publicKey.rawRepresentation, secret: KeyTransferCrypto.random(), expires: Date().timeIntervalSince1970 - 1)
        #expect(throws: (any Error).self) { try KeyTransferCrypto.Ticket.read(expired.code()) }
        for kind in ["chatGPT", "gitHub", "codex", "session_token"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(TransferAPI.self, from: Data(("\"" + kind + "\"").utf8)) }
        }
    }
    @Test func realLoopbackSocketWaitsForApprovalAndClosesAfterOneConfirmedImport() async throws {
        var reads = 0, destination: [TransferAPI: String] = [:]
        let source = KeyTransferSecrets(read: { _ in reads += 1; return "synthetic-transfer-key" }, write: { _, _ in }, remove: { _ in })
        let storage = KeyTransferSecrets(read: { destination[$0] }, write: { destination[$0] = $1 }, remove: { destination[$0] = nil })
        let sender = KeyTransferSender(secrets: source)
        let receiver = KeyTransferReceiver(secrets: storage, makeChannel: { _, port in KeyTransferChannel(host: "127.0.0.1", port: port) })
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        let code = try #require(sender.code)
        receiver.scan(code)
        try await wait { sender.waitingDevice != nil }
        #expect(reads == 0 && destination.isEmpty && !receiver.ready)
        #expect(sender.verification == receiver.verification)
        sender.approve()
        try await wait { receiver.ready }
        #expect(reads == 1 && destination.isEmpty)
        receiver.install([.openAI]) { _ in }
        try await wait { sender.code == nil }
        #expect(destination[.openAI] == "synthetic-transfer-key")
        #expect(sender.status.contains("Imported") && receiver.status.contains("saved"))
    }
    @Test func failedStorageRestoresEarlierProviderValues() {
        var values: [TransferAPI: String] = [.openAI: "synthetic-existing-key"]
        let storage = KeyTransferSecrets(read: { values[$0] }, write: { provider, value in
            if provider == .deepSeek { throw KeyTransferFailure.storage }; values[provider] = value
        }, remove: { values[$0] = nil })
        #expect(throws: KeyTransferFailure.storage) { try storage.install([
            .init(provider: .openAI, value: "synthetic-new-key"), .init(provider: .deepSeek, value: "synthetic-second-key")]) }
        #expect(values == [.openAI: "synthetic-existing-key"])
    }
    @Test func cancellingAnApprovedExchangeCannotCancelTheNextTransferCode() async throws {
        let source = KeyTransferSecrets(read: { _ in "synthetic-transfer-key" }, write: { _, _ in }, remove: { _ in })
        let sender = KeyTransferSender(secrets: source)
        let receiver = KeyTransferReceiver(secrets: source, makeChannel: { _, port in KeyTransferChannel(host: "127.0.0.1", port: port) })
        defer { sender.cancel(); receiver.cancel() }
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        let old = try #require(sender.code)
        receiver.scan(old)
        try await wait { sender.waitingDevice != nil }
        sender.approve()
        try await wait { receiver.ready }
        sender.cancel(); receiver.cancel()
        try sender.start(host: "10.1.2.3", providers: [.openAI])
        try await wait { sender.code != nil }
        #expect(sender.code != old && sender.waitingDevice == nil)
    }
}
