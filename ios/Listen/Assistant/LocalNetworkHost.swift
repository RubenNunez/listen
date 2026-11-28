import Foundation
import Darwin

/// Cleartext MCP is restricted to local destinations explicitly entered by the owner.
/// This check does no DNS lookup and never rewrites an endpoint or follows a redirect.
enum LocalNetworkHost {
    static func accepts(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
           let values = ipv4(parts) { return privateIPv4(values) }
        if host.contains(":") {
            let address = String(host.split(separator: "%", maxSplits: 1)[0])
            var bytes = [UInt8](repeating: 0, count: 16)
            guard address.withCString({ inet_pton(AF_INET6, $0, &bytes) }) == 1 else { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if bytes[0] & 0xfe == 0xfc || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return privateIPv4(Array(bytes.suffix(4)).map(Int.init))
            }
            return false
        }
        // Reject alternate numeric IP spellings (integer, octal, hex, shortened IPv4).
        guard !(host.first?.isNumber ?? false), parts.count == 1 || parts.last == "local" else { return false }
        return parts.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private static func ipv4(_ parts: [Substring]) -> [Int]? {
        let values = parts.compactMap { Int($0) }
        return values.count == 4 && values.allSatisfy { (0...255).contains($0) } ? values : nil
    }
    private static func privateIPv4(_ values: [Int]) -> Bool {
        let a = values[0], b = values[1]
        return a == 127 || a == 10 || a == 192 && b == 168 || a == 172 && (16...31).contains(b) || a == 169 && b == 254
    }
}
