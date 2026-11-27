import Foundation
import SwiftUI

/// Read-only projection. Opening/playing a recording never creates a session or calls tools.
struct AssistantHistory: Sendable {
    struct Entry: Identifiable, Sendable {
        var id: Int
        var at: Double
        var title: String
        var text: String
    }
    var entries: [Entry] = []
    var unavailable = false

    init() {}
    init(data: Data) {
        guard data.count <= 64_000_000 else { unavailable = true; return }
        for (index, line) in data.split(separator: 10).enumerated() {
            guard entries.count < 20_000 else { unavailable = true; break }
            guard line.count <= 65_536,
                  let value = try? JSONDecoder().decode(HarnessValue.self, from: Data(line)).object,
                  let kind = value["kind"]?.string, let at = value["t"]?.numeric,
                  at.isFinite, at >= 0, at <= 7 * 86_400 else { continue }
            let title: String, text: String
            switch kind {
            case "voice_user": title = "Request"; text = value["text"]?.string ?? ""
            case "voice_reply": title = "Reply"; text = value["text"]?.string ?? ""
            case "voice_route":
                title = "Routing"
                text = [value["tier"]?.string ?? "", value["model"]?.string ?? "", value["state"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            case "voice_forecast":
                title = "Preparation"
                func count(_ key: String, maximum: Int) -> Int {
                    guard let number = value[key]?.numeric, let integer = Int(exactly: number), (0...maximum).contains(integer) else { return 0 }
                    return integer
                }
                text = (value["state"]?.string ?? "") + " · \(count("hint_count", maximum: 2)) follow-ups · \(count("filler_count", maximum: 3)) waiting phrases"
            case "model_request":
                title = "Model request"
                text = [value["agent"]?.string ?? "", value["model"]?.string ?? ""].joined(separator: " · ")
            case "usage":
                title = "Model result"
                text = [value["model"]?.string ?? "", value["outcome"]?.string ?? ""].joined(separator: " · ")
            case "voice_operation":
                title = "Action"
                text = [value["capability"]?.string ?? value["id"]?.string ?? "", value["state"]?.string ?? ""].joined(separator: " · ")
            case "mcp_request", "mcp_result":
                title = kind == "mcp_request" ? "MCP request" : "MCP result"
                text = [value["server"]?.string ?? "", value["tool"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? value["method"]?.string ?? "",
                        value["outcome"]?.string ?? "started"].filter { !$0.isEmpty }.joined(separator: " · ")
            case "voice_playback": title = "Playback"; text = value["state"]?.string ?? ""
            case "voice_error": title = "Error"; text = value["message"]?.string ?? ""
            default: continue
            }
            guard !text.isEmpty else { continue }
            entries.append(Entry(id: index, at: at, title: title, text: String(text.prefix(8000))))
        }
        entries.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
    }
    init(folder: URL) {
        let file = folder.appending(path: "events.jsonl")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000_000,
              let data = try? Data(contentsOf: file) else { self.init(); unavailable = true; return }
        self.init(data: data)
    }
    func checkpoint(at time: Double) -> Int {
        guard time.isFinite else { return 0 }
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].at <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

struct AssistantReplayView: View {
    let history: AssistantHistory
    let controller: ReplayController
    @State private var count = 0
    @State private var observer: UUID?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Label("Recorded voice conversation", systemImage: "waveform").font(.headline)
                Text("Recorded input audio and observed events. Actions are never run again.")
                    .font(.caption).foregroundStyle(.secondary)
                if history.unavailable { Text("Some history could not be loaded.").foregroundStyle(.orange) }
                ForEach(history.entries.prefix(count)) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button(String(format: "%d:%02d", Int(entry.at) / 60, Int(entry.at) % 60)) { controller.seek(to: entry.at) }
                                .font(.caption.monospacedDigit())
                        }
                        Text(entry.text).textSelection(.enabled)
                    }
                }
            }.padding(20)
        }
        .defaultScrollAnchor(.bottom)
        .onAppear {
            observer = controller.observeTime { time, _ in
                let next = history.checkpoint(at: time)
                if next != count { count = next }
            }
        }
        .onDisappear { if let observer { controller.removeTimeObserver(observer) }; observer = nil }
    }
}
