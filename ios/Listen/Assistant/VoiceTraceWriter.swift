import Foundation

/// File I/O stays off the caller's executor. A bounded queue prevents diagnostics from
/// retaining unbounded memory when storage stalls. Lost events are explicitly counted.
final class VoiceTraceWriter: @unchecked Sendable {
    private let file: URL
    private let queue = DispatchQueue(label: "listen.voice-trace", qos: .utility)
    private let lock = NSLock()
    private let capacity: Int
    private var pendingBytes = 0
    private var pendingRecords = 0
    private var dropped = 0

    init(file: URL, capacity: Int = 1_048_576) {
        self.file = file
        self.capacity = max(0, capacity)
    }

    /// `record` is already sanitized JSON. Queue admission does no filesystem work.
    func append(_ record: Data) {
        guard !record.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard pendingRecords < 1024, record.count <= capacity - pendingBytes else { dropped += 1; return }
        pendingBytes += record.count
        pendingRecords += 1
        queue.async { [self] in
            writeDropped()
            if !write(record) { lock.withLock { dropped += 1 } }
            lock.withLock { pendingBytes -= record.count; pendingRecords -= 1 }
        }
    }

    /// Completes after earlier writes. Concurrent producers remain allowed; no fsync is promised.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                writeDropped()
                continuation.resume()
            }
        }
    }

    private func writeDropped() {
        let count = lock.withLock { let count = dropped; dropped = 0; return count }
        guard count > 0 else { return }
        let event: [String: Any] = ["kind": "voice_trace_dropped", "count": count,
                                    "t": ProcessInfo.processInfo.systemUptime]
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys), write(data) else {
            lock.withLock { dropped += count }
            return
        }
    }

    /// Only the serial writer queue calls this. Existing records are never overwritten.
    private func write(_ record: Data) -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file, options: .withoutOverwriting)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record + Data("\n".utf8))
            return true
        } catch { return false }
    }
}
