import SwiftUI

/// The owner can inspect and extend the local collection. Opening this screen
/// plays nothing and makes no model request.
struct ConversationReactionView: View {
    let language: Language
    @State private var bank = ConversationReactionBank.shared
    @State private var text = ""
    @State private var kind = ConversationReaction.Kind.neutral
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Short reactions are selected for the situation, with recent wording avoided. The collection stays on this device. General openings from fully played replies can join it; use counts do not mean a quality rating.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Add a reaction") {
                    Picker("Situation", selection: $kind) {
                        ForEach(ConversationReaction.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(language == .de ? "Zum Beispiel: Ich denke kurz nach." : "For example: Let me think briefly.", text: $text)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("reaction.newPhrase")
                    Button("Add to collection") {
                        if bank.add(text, language: language, kind: kind) { text = ""; problem = nil }
                        else { problem = "Use a new, short general reaction without names, facts, links or action results. Research wording belongs to Research. The collection holds up to 64 additions." }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("reaction.add")
                    if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                    if let error = bank.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                ForEach(ConversationReaction.Kind.allCases, id: \.self) { category in
                    Section(category.title) {
                        ForEach(bank.entries.filter { $0.language == language && $0.kind == category }) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.text)
                                Text(label(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                if entry.origin != .bundled {
                                    Button("Remove", role: .destructive) { bank.remove(entry) }
                                }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Conversation reactions")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func label(_ entry: ConversationReactionBank.Entry) -> String {
        let origin = switch entry.origin {
        case .bundled: "Included"
        case .owner: "Added by you"
        case .playedReply: "Collected from a played reply"
        }
        return origin + " · " + String(bank.count(for: entry)) + " uses"
    }
}
