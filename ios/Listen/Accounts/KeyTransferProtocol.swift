import CryptoKit
import Foundation

enum KeyTransferFailure: Error, LocalizedError, Equatable {
    case invalid, expired, refused, unavailable, storage
    var errorDescription: String? {
        switch self {
        case .invalid: "This transfer could not be verified. No setup was imported."
        case .expired: "This code has expired. Scan the code on the Mac again."
        case .refused: "The transfer was cancelled or not approved."
        case .unavailable: "The other device could not be reached. Keep both Listen apps open on the same network."
        case .storage: "The setup could not be saved. The previous setup has been preserved."
        }
    }
}

/// API keys only. Consumer login/session tokens and GitHub OAuth are never requested.
enum TransferAPI: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRouter, claude, openAI, gemini, deepSeek, jev, elevenLabs
    var id: String { rawValue }
    var connector: Connector { Connector(rawValue: rawValue)! }
    var title: String { connector.title }
}

@MainActor struct KeyTransferSecrets {
    var read: (TransferAPI) -> String?
    var write: (TransferAPI, String) throws -> Void
    var remove: (TransferAPI) -> Void
    static var live: KeyTransferSecrets {
        .init(read: { Keychain.get($0.rawValue) }, write: { try Keychain.set($1, for: $0.rawValue) }, remove: { Keychain.remove($0.rawValue) })
    }
    func install(_ keys: [KeyTransferCrypto.Key], commit: () throws -> Void = {}) throws -> [TransferAPI] {
        var old: [TransferAPI: String] = [:], written: [TransferAPI] = []
        do {
            for item in keys {
                if let previous = read(item.provider) { old[item.provider] = previous }
                try write(item.provider, item.value); written.append(item.provider)
            }
            try commit()
            return written
        } catch {
            for provider in written.reversed() {
                if let previous = old[provider] { try? write(provider, previous) } else { remove(provider) }
            }
            throw KeyTransferFailure.storage
        }
    }
}

enum KeyTransferCrypto {
    static let prefix = "LISTEN-PAIRKEYS/1:"
    static let maximumFrame = 4_194_304
    static let maximumClaim = 4096

    struct Ticket: Codable, Sendable {
        var version = 1
        var id: UUID
        var host: String
        var port: UInt16
        var publicKey: Data
        /// One-time QR capability, not an API key. It is never sent on the wire.
        var secret: Data
        var expires: Double
        /// Slashes in the base64 fields stay unescaped, so every ticket has the same length
        /// and a renewed QR code keeps its size. Readers accept both spellings.
        func code() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return prefix + (try encoder.encode(self)).base64EncodedString()
        }
        func validate(now: Date = .now) throws {
            guard version == 1, port > 0, Self.localAddress(host), publicKey.count == 32, secret.count == 32 else { throw KeyTransferFailure.invalid }
            guard expires > now.timeIntervalSince1970, expires <= now.timeIntervalSince1970 + 180 else { throw KeyTransferFailure.expired }
        }
        static func read(_ code: String, now: Date = .now) throws -> Ticket {
            guard code.hasPrefix(prefix), code.utf8.count <= 2500,
                  let data = Data(base64Encoded: String(code.dropFirst(prefix.count))) else { throw KeyTransferFailure.invalid }
            let ticket: Ticket = try decode(data)
            try ticket.validate(now: now)
            return ticket
        }
        static func localAddress(_ text: String) -> Bool {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
                  parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }) else { return false }
            return a == 10 || a == 192 && b == 168 || a == 172 && (16...31).contains(b) || a == 169 && b == 254
        }
    }
    struct Claim: Codable, Sendable {
        var version = 1
        var id: UUID
        var publicKey: Data
        var nonce: Data
        var device: String
        var proof: Data?
        func authenticatedData() throws -> Data { var copy = self; copy.proof = nil; return try KeyTransferCrypto.encode(copy) }
        func validate(ticket: Ticket, key: SymmetricKey) throws {
            guard version == 1, id == ticket.id, publicKey.count == 32, nonce.count == 32,
                  (1...60).contains(device.count), !device.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let proof, HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: try authenticatedData(), using: key) else { throw KeyTransferFailure.invalid }
        }
    }
    struct Key: Codable, Sendable { var provider: TransferAPI; var value: String }
    struct Bundle: Codable, Sendable {
        var id: UUID
        var keys: [Key]
        var setup: DeviceSetupMigration.Manifest? = nil
        func validate(ticket: Ticket) throws {
            guard id == ticket.id, (0...TransferAPI.allCases.count).contains(keys.count), !keys.isEmpty || setup != nil, Set(keys.map(\.provider)).count == keys.count,
                  keys.allSatisfy({ (1...4096).contains($0.value.utf8.count) && !$0.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw KeyTransferFailure.invalid }
            try setup?.validate()
        }
    }
    struct Ack: Codable, Sendable { var id: UUID; var imported: [TransferAPI]; var stage: String? = nil }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard data.count <= maximumFrame else { throw KeyTransferFailure.invalid }
        do {
            try HarnessJSON.checkUniqueKeys(data)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KeyTransferFailure.invalid }
            let expected: Set<String>
            if T.self == Ticket.self { expected = ["version", "id", "host", "port", "publicKey", "secret", "expires"] }
            else if T.self == Claim.self { expected = ["version", "id", "publicKey", "nonce", "device", "proof"] }
            else if T.self == Bundle.self {
                expected = root["setup"] == nil ? ["id", "keys"] : ["id", "keys", "setup"]
                guard let keys = root["keys"] as? [[String: Any]], keys.allSatisfy({ Set($0.keys) == ["provider", "value"] }) else { throw KeyTransferFailure.invalid }
            } else if T.self == Ack.self { expected = root["stage"] == nil ? ["id", "imported"] : ["id", "imported", "stage"] }
            else { throw KeyTransferFailure.invalid }
            guard Set(root.keys) == expected else { throw KeyTransferFailure.invalid }
            return try JSONDecoder().decode(T.self, from: data)
        }
        catch { throw KeyTransferFailure.invalid }
    }
    static func random() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func key(privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data, ticket: Ticket) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        return try privateKey.sharedSecretFromKeyAgreement(with: publicKey).hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: ticket.secret, sharedInfo: Data(("Listen API key transfer v1/" + ticket.id.uuidString).utf8), outputByteCount: 32)
    }
    static func verification(_ key: SymmetricKey) -> String {
        let bytes = Array(HMAC<SHA256>.authenticationCode(for: Data("verification".utf8), using: key))
        let value = (UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])) % 1_000_000
        return String(format: "%03d %03d", value / 1000, value % 1000)
    }
    static func seal<T: Encodable>(_ value: T, key: SymmetricKey, claim: Claim, purpose: String) throws -> Data {
        return try sealBytes(encode(value), key: key, claim: claim, purpose: purpose)
    }
    static func sealBytes(_ bytes: Data, key: SymmetricKey, claim: Claim, purpose: String) throws -> Data {
        guard let data = try AES.GCM.seal(bytes, using: key, authenticating: aad(claim, purpose)).combined else { throw KeyTransferFailure.invalid }
        return data
    }
    static func open<T: Decodable>(_ data: Data, key: SymmetricKey, claim: Claim, purpose: String) throws -> T {
        do { return try decode(openBytes(data, key: key, claim: claim, purpose: purpose)) }
        catch { throw KeyTransferFailure.invalid }
    }
    static func openBytes(_ data: Data, key: SymmetricKey, claim: Claim, purpose: String) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: aad(claim, purpose)) }
        catch { throw KeyTransferFailure.invalid }
    }
    private static func aad(_ claim: Claim, _ purpose: String) -> Data { Data((purpose + "/" + claim.id.uuidString + "/" + claim.nonce.base64EncodedString()).utf8) }
}
