import SwiftUI

/// Every recorded conversation on this device, newest first: the user's own and
/// the scripted or replayed ones used for testing. Tap one to go through it again.
struct HistoryView: View {
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var loading = true
    @State private var failed = false
    @State private var exporting: ConversationExport?

    typealias Entry = RecordingLibrary.Entry

    static func when(_ name: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = parser.date(from: name) else { return name }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView("Loading conversations…")
                } else if failed {
                    Text("Conversations could not be read. Close History and try again.").foregroundStyle(.secondary)
                } else if entries.isEmpty {
                    Text("No recorded conversations yet. You can enable recordings in Settings.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    Button {
                        dismiss()
                        open(entry.folder)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.topic.isEmpty ? "Conversation" : entry.topic).font(.body.weight(.semibold))
                                Spacer()
                                Text(Self.when(entry.folder.lastPathComponent)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.first.isEmpty ? "Nothing was heard." : entry.first).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(Int(entry.seconds) / 60):\(String(format: "%02d", Int(entry.seconds) % 60)) · \(entry.sentences) sentences · \(entry.cards) cards · \(entry.language.uppercased())")
                                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Export as .listen…", systemImage: "doc.zipper") { export(entry, sound: false) }
                        Button("Export as .listen with sound…", systemImage: "waveform") { export(entry, sound: true) }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .exportsConversation($exporting)
        .task {
            loading = true; failed = false
            do {
                let loaded = try await RecordingLibrary.shared.history(roots: RunRecorder.searchFolders)
                guard !Task.isCancelled else { return }
                entries = loaded; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true; loading = false
            }
        }
    }

    /// The topic's folder goes along for its summary note and material, found by the run's topic name.
    private func export(_ entry: Entry, sound: Bool) {
        let topic = TopicStore().topics.first { $0.name == entry.topic }
        exporting = ConversationExport(run: entry.folder, topic: topic.map { TopicSandbox(topic: $0.id).folder }, sound: sound)
    }
}
