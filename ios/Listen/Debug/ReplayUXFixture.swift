import Foundation

#if DEBUG
/// Synthetic, local-only UI/performance fixture. No microphone, model or account is used.
enum ReplayUXFixture {
    static func make(seconds: Int = 120, root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let seconds = min(3600, max(10, seconds))
        let folder = root.appending(path: "listen-replay-ux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var events: [[String: Any]] = []
        var prior: [Int: Int] = [:]
        for second in 0..<seconds {
            let id = second + 1, t = Double(second)
            events.append(["t": t + 0.5, "kind": "sentence", "id": id, "start_ms": second * 1000,
                           "end_ms": second * 1000 + 500, "voice": second % 2 + 1,
                           "text": "Synthetic sentence \(id) about bounded queues."])
            if second % 3 == 0 {
                events.append(["t": t + 0.55, "kind": "model_request", "request_id": "synthetic-\(id)",
                               "agent": "draft", "model": "fixture", "sentence": id,
                               "instructions": "Recorded synthetic event. Never executed.", "input": "Synthetic fixture."])
                var usage: [String: Any] = ["t": t + 0.7, "kind": "usage", "request_id": "synthetic-\(id)",
                                           "outcome": "completed", "response": "A synthetic historical response."]
                if second % 15 != 3 { usage["input_tokens"] = 10; usage["output_tokens"] = 5 }
                events.append(usage)
            }
            if second % 10 == 0 {
                let block = second / 10 % 5 + 1
                events.append(["t": t + 0.75, "kind": "card_started", "card": id, "sentence": id, "layer": "fast"])
                events.append(["t": t + 0.8, "kind": "card_text", "card": id,
                               "text": "Queue \(block)\n**Limit \(id) items** and wait for capacity.\nSynthetic revision \(id)."])
                events.append(["t": t + 0.85, "kind": "landed", "card": id, "block": block, "version": second / 50 + 1])
                if let previous = prior[block] {
                    events.append(["t": t + 0.85, "kind": "card_replaced", "card": previous, "by": id])
                }
                prior[block] = id
            }
        }
        events.append(["t": Double(seconds), "kind": "state", "state": "fixture ended"])
        let lines = try events.sorted { ($0["t"] as! Double) < ($1["t"] as! Double) }.map {
            try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }
        var data = Data()
        for line in lines { data.append(line); data.append(10) }
        try data.write(to: folder.appending(path: "events.jsonl"), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["topic": "Replay UX synthetic", "language": "en"])
            .write(to: folder.appending(path: "run.json"), options: .atomic)
        return folder
    }
}
#endif
