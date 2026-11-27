import Foundation

// Quiet, standalone validation of the exact production writer; no app, model, microphone
// or speaker is opened. From the repo root:
// swiftc -O -parse-as-library ios/Listen/Assistant/VoiceTraceWriter.swift \
//   ios/Tools/bench-voice-trace.swift -o /tmp/listen-trace-bench
// /tmp/listen-trace-bench
// In the development layout use ios/Listen/Core/Assistant/VoiceTraceWriter.swift instead.
@main struct VoiceTraceBench {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func rows(_ file: URL) throws -> [[String: Any]] {
        try Data(contentsOf: file).split(separator: 10).map {
            guard let row = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else {
                throw Failure(message: "Invalid JSON row")
            }
            return row
        }
    }
    static func synchronous(_ record: Data, to file: URL) throws {
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record + Data([10]))
        } else { try (record + Data([10])).write(to: file) }
    }
    static func milliseconds(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let concurrentFile = directory.appendingPathComponent("concurrent.jsonl")
        let sentinel = Data("{\"id\":-1}".utf8)
        try (sentinel + Data([10])).write(to: concurrentFile)
        let concurrent = VoiceTraceWriter(file: concurrentFile)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<100 { concurrent.append(Data("{\"id\":\(worker * 100 + index)}".utf8)) }
        }
        await concurrent.drain()
        let records = try rows(concurrentFile)
        let ids = records.compactMap { $0["id"] as? Int }
        try require(records.count == 801 && Set(ids) == Set(-1..<800), "Concurrent records were lost or overwritten")

        let overflowFile = directory.appendingPathComponent("overflow.jsonl")
        let overflow = VoiceTraceWriter(file: overflowFile, capacity: 1)
        for _ in 0..<10 { overflow.append(sentinel) }
        await overflow.drain()
        let lost = try rows(overflowFile)
        try require(lost.count == 1 && lost[0]["kind"] as? String == "voice_trace_dropped"
                    && lost[0]["count"] as? Int == 10, "Overflow was not explicitly accounted for")

        let missingDirectory = directory.appendingPathComponent("missing")
        let recoveryFile = missingDirectory.appendingPathComponent("trace.jsonl")
        let recovery = VoiceTraceWriter(file: recoveryFile)
        recovery.append(sentinel)
        await recovery.drain()
        try FileManager.default.createDirectory(at: missingDirectory, withIntermediateDirectories: true)
        await recovery.drain()
        let recovered = try rows(recoveryFile)
        try require(recovered.count == 1 && recovered[0]["count"] as? Int == 1, "I/O failure was not accounted for after recovery")

        let payload = Data("{\"kind\":\"synthetic\",\"state\":\"ready\",\"chars\":100,\"t\":1.0}".utf8)
        var synchronousTimes: [Double] = [], callerTimes: [Double] = [], drainedTimes: [Double] = []
        for sample in 0..<9 {
            let baseline = directory.appendingPathComponent("baseline-\(sample).jsonl")
            var start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 { try synchronous(payload, to: baseline) }
            synchronousTimes.append(milliseconds(start))

            let file = directory.appendingPathComponent("async-\(sample).jsonl")
            let writer = VoiceTraceWriter(file: file)
            start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 { writer.append(payload) }
            callerTimes.append(milliseconds(start))
            await writer.drain()
            drainedTimes.append(milliseconds(start))
            try require(try rows(file).count == 100, "Benchmark records were lost")
        }
        let result: [String: Any] = ["checks_passed": 3, "samples": 9, "events_per_sample": 100,
            "baseline_sync_ms_p50": synchronousTimes.sorted()[4], "caller_ms_p50": callerTimes.sorted()[4],
            "drained_ms_p50": drainedTimes.sorted()[4],
            "scope": "Trace writer only, pre-serialized synthetic rows. Caller admission and complete writes are distinct. No voice latency claim."]
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: resultData, as: UTF8.self))
    }
}
