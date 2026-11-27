import Compression
import Foundation

/// Reads ZIP archives as Listen writes them (stored or deflated entries, below 4 GB): enough to
/// open a `.listen` file again without a library.
enum ZipArchive {
    struct Entry: Equatable {
        var path: String
        var method: UInt16
        var compressed: Int
        var size: Int
        /// Where the entry's local header starts.
        var header: Int
    }

    enum Failure: Error, Equatable {
        case notAZip
        case damaged
        case unsupported(String)
    }

    /// The entries, from the archive's central directory.
    static func entries(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw Failure.notAZip }
        var end: Int?
        var index = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while index >= lowest {
            if u32(data, index) == 0x0605_4B50 {
                end = index
                break
            }
            index -= 1
        }
        guard let end else { throw Failure.notAZip }
        let count = Int(u16(data, end + 10))
        let offset = Int(u32(data, end + 16))
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw Failure.unsupported("ZIP64") }
        var entries: [Entry] = []
        var position = offset
        for _ in 0..<count {
            guard position + 46 <= data.count, u32(data, position) == 0x0201_4B50 else { throw Failure.damaged }
            let compressed = Int(u32(data, position + 20)), size = Int(u32(data, position + 24))
            let header = Int(u32(data, position + 42))
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, header != 0xFFFF_FFFF else { throw Failure.unsupported("ZIP64") }
            let name = Int(u16(data, position + 28)), extra = Int(u16(data, position + 30)), comment = Int(u16(data, position + 32))
            guard position + 46 + name <= data.count else { throw Failure.damaged }
            let start = data.startIndex + position + 46
            entries.append(Entry(
                path: String(decoding: data[start..<start + name], as: UTF8.self), method: u16(data, position + 10),
                compressed: compressed, size: size, header: header))
            position += 46 + name + extra + comment
        }
        return entries
    }

    /// What one entry holds, unpacked.
    static func contents(of entry: Entry, in data: Data, maximumSize: Int = 256 * 1024 * 1024) throws -> Data {
        guard entry.size >= 0, entry.compressed >= 0, entry.size <= maximumSize, entry.compressed <= maximumSize else {
            throw Failure.unsupported("entry exceeds the import size limit")
        }
        let local = entry.header
        guard local >= 0, data.count >= 30, local <= data.count - 30, u32(data, local) == 0x0403_4B50 else { throw Failure.damaged }
        let start = local + 30 + Int(u16(data, local + 26)) + Int(u16(data, local + 28))
        guard start + entry.compressed <= data.count else { throw Failure.damaged }
        let packed = data[data.startIndex + start..<data.startIndex + start + entry.compressed]
        switch entry.method {
        case 0:
            guard entry.compressed == entry.size else { throw Failure.damaged }
            return Data(packed)
        case 8:
            guard entry.size > 0 else { return Data() }
            guard entry.compressed > 0 else { throw Failure.damaged }
            var unpacked = Data(count: entry.size)
            let written = unpacked.withUnsafeMutableBytes { target in
                packed.withUnsafeBytes { source in
                    // COMPRESSION_ZLIB is raw DEFLATE, the method ZIP uses.
                    compression_decode_buffer(
                        target.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                        source.bindMemory(to: UInt8.self).baseAddress!, entry.compressed, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.damaged }
            return unpacked
        default:
            throw Failure.unsupported("method \(entry.method)")
        }
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
