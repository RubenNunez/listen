import Foundation

extension HarnessJSON {
    /// JSONDecoder accepts repeated keys. Configuration must not have two competing
    /// values, including escaped spellings of the same key. JSONDecoder still owns
    /// full syntax/value validation; this bounded scan only checks key uniqueness.
    static func checkUniqueKeys(_ data: Data) throws {
        guard data.count <= 2_000_000 else { throw HarnessProblem("$", "configuration exceeds 2 MB") }
        var scanner = KeyScanner(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw HarnessProblem("$", "invalid JSON") }
    }
}

private struct KeyScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func take(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw HarnessProblem("$", "invalid JSON") }
        index += 1
    }

    mutating func string() throws -> String {
        whitespace()
        let start = index
        try take(34)
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 {
                guard index < bytes.count else { break }
                index += 1
            } else if byte == 34 {
                guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                    throw HarnessProblem("$", "invalid JSON string")
                }
                return text
            }
        }
        throw HarnessProblem("$", "unterminated JSON string")
    }

    mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw HarnessProblem("$", "JSON nesting exceeds 64 levels") }
        whitespace()
        guard index < bytes.count else { throw HarnessProblem("$", "invalid JSON") }
        switch bytes[index] {
        case 123:
            index += 1
            whitespace()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            var keys: Set<String> = []
            while true {
                let key = try string()
                guard keys.insert(key).inserted else { throw HarnessProblem("$", "duplicate JSON key") }
                try take(58)
                try value(depth: depth + 1)
                whitespace()
                guard index < bytes.count else { throw HarnessProblem("$", "invalid JSON object") }
                if bytes[index] == 125 { index += 1; return }
                try take(44)
            }
        case 91:
            index += 1
            whitespace()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                guard index < bytes.count else { throw HarnessProblem("$", "invalid JSON array") }
                if bytes[index] == 93 { index += 1; return }
                try take(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw HarnessProblem("$", "invalid JSON scalar") }
        }
    }
}
