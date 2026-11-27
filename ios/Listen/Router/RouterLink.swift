import Foundation

/// An untrusted, owner-selected pairing proposal. Parsing never connects or pairs.
struct RouterLink: Equatable, Identifiable, Sendable {
    var id: String { fingerprint }
    let hosts: [String]
    let port: Int
    let code: String
    let fingerprint: String

    /// The same four-character groups shown below the router window's QR code.
    var fingerprintForDisplay: String {
        let characters = Array(fingerprint)
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }.joined(separator: " ")
    }

    static func parse(_ text: String) throws -> Self {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, let url = URLComponents(string: text),
              url.scheme == "listen", url.host == "pair", url.user == nil, url.password == nil,
              url.port == nil, url.path.isEmpty, url.fragment == nil,
              let items = url.queryItems, items.count == 4,
              Set(items.map(\.name)) == ["host", "port", "code", "fp"] else { throw RouterFailure.invalidLink }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let hosts = (fields["host"] ?? "").components(separatedBy: ",")
        let fingerprint = (fields["fp"] ?? "").lowercased()
        let code = (fields["code"] ?? "").uppercased()
        guard (1...8).contains(hosts.count), Set(hosts).count == hosts.count,
              hosts.allSatisfy(validHost), let port = Int(fields["port"] ?? ""), (1...65535).contains(port),
              code.count == 8, code.allSatisfy({ "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) }),
              fingerprint.count == 64, fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RouterFailure.invalidLink
        }
        return Self(hosts: hosts, port: port, code: code, fingerprint: fingerprint)
    }

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58].contains($0)
        } && host != "." && host != ".." && !host.hasPrefix("-")
    }
}

enum RouterFailure: Error, LocalizedError, ModelFailure, Equatable {
    case invalidLink, unpaired, unreachable, otherCertificate, expiredCode, wrongCode, disabledTool
    case limit, cancelled, interrupted, invalidResponse, storage
    case remote

    var reason: String {
        switch self {
        case .invalidLink: "This is not a valid Listen Router pairing link."
        case .unpaired: "Pair this device with the router again."
        case .unreachable: "Listen Router is unreachable. Check its connection."
        case .otherCertificate: "This is not the router you paired. Check its fingerprint."
        case .expiredCode: "The pairing code expired. Scan the code in your Listen Router again."
        case .wrongCode: "The router refused the pairing code."
        case .disabledTool: "This tool is unavailable or switched off on the router."
        case .limit: "The router or its model account reached a limit."
        case .cancelled: "The router request was cancelled."
        case .interrupted: "The router response ended before completion."
        case .invalidResponse: "The router returned an unsupported response."
        case .storage: "The router pairing could not be saved on this device."
        case .remote: "The router could not complete this request."
        }
    }
    var errorDescription: String? { reason }
}
