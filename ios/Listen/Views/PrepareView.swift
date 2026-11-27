import SwiftUI

/// Pick what the conversation is about, then start.
struct PrepareView: View {
    let model: SessionModel
    let topics: TopicStore
    let accounts: AccountStore
    let orbSpace: Namespace.ID
    let backToOrb: () -> Void

    private struct EditingTopic: Identifiable {
        var topic: Topic
        var isNew: Bool
        var id: UUID { topic.id }
    }
    @State private var editing: EditingTopic?
    @State private var createdTopic: Topic.ID?
    @State private var showsAccount = false
    @State private var selectedBeforeSettings: Topic.ID?
    @State private var showsSystem = false
    @State private var showsHistory = false
    /// The systems, for the name each topic runs with; read again when the Systems view closes.
    @State private var systems = SystemStore()
    @State private var library = RecordingLibrary.Overview()
    @State private var libraryRevision = 0
    private struct LibraryRead: Equatable { var topics: [Topic]; var revision: Int }
    @State private var showsArchived = false
    /// A topic about to be packed into an archive, and the evaluation clean-up, waiting for a yes.
    @State private var packing: Topic?
    @State private var packingEvaluations = false
    @State private var packed: String?
    /// A recorded conversation being written as a .listen file.
    @State private var exporting: ConversationExport?

    /// Keep navigation available when a long topic list scrolls to a new item.
    private var navigationBar: some View {
        HStack(alignment: .top) {
            Button(action: backToOrb) {
                SessionOrb(model: model, isActive: model.microphoneOn, isVisible: !showsAccount && !showsSystem && !showsHistory)
                    .matchedGeometryEffect(id: "orb", in: orbSpace)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the orb")
            Spacer()
            Button("History", systemImage: "clock.arrow.circlepath") { showsHistory = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityHint("Every recorded conversation, to go through again")
            Button("Systems", systemImage: "point.3.connected.trianglepath.dotted") { showsSystem = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityHint("The systems Listen can work with, how each is wired, and what it needs")
            Button("New topic", systemImage: "plus") {
                editing = EditingTopic(topic: Topic(name: ""), isNew: true)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            ListenSettingsButton(identifier: "topics.settings") {
                selectedBeforeSettings = topics.selectedID
                showsAccount = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: CardMetrics.column + 40)
        .frame(maxWidth: .infinity)
    }

    private var starting: Bool { model.core.phase == .starting }

    var body: some View {
        VStack(spacing: 0) {
        navigationBar
        ScrollViewReader { scroll in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(showsArchived ? "Archive" : "Topics").font(.largeTitle.weight(.bold))
                    .padding(.horizontal, CardMetrics.inset)
                if showsArchived, topics.topics.contains(where: \.archived) {
                    Text("Archived topics stay in Listen with everything they hold, out of the list. Unarchive one from its menu.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, CardMetrics.inset)
                }
                ForEach(topics.topics.filter { $0.archived == showsArchived }) { topic in
                    TopicRow(topic: topic, isSelected: topic.id == topics.selectedID && !topic.archived, starting: starting,
                             systemName: systems.chosen(for: topic).name,
                             counts: library.topics[topic.id], revision: libraryRevision, canDelete: topics.topics.count > 1) {
                        topics.select(topic)
                    } onOpen: {
                        topics.select(topic)
                        model.open(topic)
                    } onStart: {
                        topics.select(topic)
                        model.start(topic)
                    } onReplay: { run in
                        model.replaying = run
                    } onArchive: {
                        withAnimation(.smooth(duration: 0.3)) { topics.setArchived(!topic.archived, topic) }
                    } onPack: {
                        packing = topic
                    } onExport: { run, sound in
                        exporting = ConversationExport(run: run, topic: TopicSandbox(topic: topic.id).folder, sound: sound)
                    } onEdit: {
                        editing = EditingTopic(topic: topic, isNew: false)
                    } onMemoryCleared: {
                        libraryRevision += 1
                    } onDelete: {
                        topics.delete(topic)
                    }
                }
                // Topics and recordings left by evaluation runs: packed away in one go.
                let leftoverCount = library.evaluations
                if leftoverCount > 0 {
                    Button {
                        packingEvaluations = true
                    } label: {
                        Label("Export evaluation topics · \(leftoverCount)", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .padding(.horizontal, CardMetrics.inset)
                    .padding(.top, 6)
                    .help("Writes topics made by evaluation runs, with their notes, files and recordings, as files into runs/exports and takes them out of Listen. Nothing is deleted.")
                }
                if let packed {
                    Text(packed).font(.caption).foregroundStyle(.secondary).padding(.horizontal, CardMetrics.inset)
                }
                // The archive: topics taken out of the list, still in Listen. Exports are not here.
                let archived = topics.topics.filter(\.archived).count
                if showsArchived, archived == 0 {
                    ContentUnavailableView {
                        Label("No archived topics", systemImage: "archivebox")
                    } description: {
                        Text("Archive a topic from its menu to take it out of the list; it stays in Listen and can come back.")
                    }
                    .padding(.vertical, 24)
                }
                Button {
                    withAnimation(.smooth(duration: 0.3)) { showsArchived.toggle() }
                } label: {
                    Label(showsArchived ? "Back to topics" : (archived == 0 ? "Archive" : "Archive · \(archived)"),
                          systemImage: showsArchived ? "chevron.left" : "archivebox")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("topics.archive")
                .padding(.horizontal, CardMetrics.inset)
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: CardMetrics.column + 40)  // 20 of margin on each side
            .frame(maxWidth: .infinity)
        }
        .onChange(of: createdTopic, initial: true) { _, id in
            if let id {
                withAnimation(.smooth(duration: 0.3)) { scroll.scrollTo(id, anchor: .center) }
            } else {
                scroll.scrollTo(topics.selectedID, anchor: .center)
            }
        }
        }
        .scrollIndicators(.hidden)
        }
        .confirmationDialog(
            "Export “\(packing?.name ?? "")” and remove it from Listen?", isPresented: Binding(get: { packing != nil }, set: { if !$0 { packing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Export") {
                guard let topic = packing else { return }
                Task {
                    let folder = await topics.export(topic)
                    packed = folder.map { "Exported to runs/exports/\($0.lastPathComponent)" } ?? "Could not export “\(topic.name)”."
                }
            }
        } message: {
            Text("The topic, its notes, its files and its recordings are written as files into runs/exports, with a manifest and checksums, for keeping and later analysis. Listen no longer shows it, also not in the archive; nothing is deleted. To only take a topic out of the list, use Archive.")
        }
        .confirmationDialog("Export the evaluation topics and remove them from Listen?", isPresented: $packingEvaluations, titleVisibility: .visible) {
            Button("Export") {
                Task {
                    let count = await topics.exportEvaluations()
                    packed = "Exported \(count) evaluation topic\(count == 1 ? "" : "s") to runs/exports."
                    libraryRevision += 1
                }
            }
        } message: {
            Text("Topics made by evaluation runs, and recordings of evaluation topics no longer in the list, are written as files into runs/exports and leave Listen. Your own topics stay. Nothing is deleted.")
        }
        .safeAreaInset(edge: .bottom) { startBar }
        .sheet(isPresented: $showsAccount, onDismiss: {
            libraryRevision += 1
            if topics.selectedID != selectedBeforeSettings { createdTopic = topics.selectedID }
        }) { AccountView(accounts: accounts, topics: topics) }
        .onReceive(NotificationCenter.default.publisher(for: .listenSetupInstalled)) { _ in systems = SystemStore(); libraryRevision += 1 }
        .sheet(isPresented: $showsSystem, onDismiss: { systems = SystemStore() }) { SystemsView(model: model, topic: topics.selected) }
        .sheet(isPresented: $showsHistory, onDismiss: { libraryRevision += 1 }) { HistoryView { run in model.replaying = run } }
        .exportsConversation($exporting)
        .sheet(item: $editing, onDismiss: { libraryRevision += 1 }) { draft in
            TopicEditor(topic: draft.topic, isNew: draft.isNew) {
                try topics.saveTopic($0)
                if draft.isNew { createdTopic = $0.id }
            }
        }
        .task(id: LibraryRead(topics: topics.topics, revision: libraryRevision)) {
            let selected = topics.topics.map { RecordingLibrary.TopicReference(id: $0.id, name: $0.name, evaluation: $0.evaluation) }
            if let loaded = try? await RecordingLibrary.shared.overview(topics: selected, roots: RunRecorder.searchFolders, topicRoot: TopicSandbox.root), !Task.isCancelled {
                library = loaded
            }
        }
    }

    private var startBar: some View {
        VStack(spacing: 10) {
            if let notice = model.core.notice {
                Label(notice.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .glassBanner()
            }
            Text(SessionModel.usesDemo
                ? "Demo: transcript and answers are scripted, audio stays on this device."
                : "Speech becomes text on this device. Only text goes to the models you attached in Account.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: CardMetrics.column + 40)
        .frame(maxWidth: .infinity)
    }
}

private struct TopicRow: View {
    let topic: Topic
    let isSelected: Bool
    var starting = false
    /// The system a conversation in this topic runs with.
    var systemName = "Interview"
    var counts: RecordingLibrary.Counts?
    var revision = 0
    var canDelete = true
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onStart: () -> Void
    var onReplay: (URL) -> Void = { _ in }
    var onArchive: () -> Void = {}
    var onPack: () -> Void = {}
    /// Writes a recorded conversation as a .listen file; true takes the sound along.
    var onExport: (URL, Bool) -> Void = { _, _ in }
    /// The recorded conversations of this topic, newest first, read when the row opens.
    @State private var conversations: [HistoryView.Entry] = []
    let onEdit: () -> Void
    var onMemoryCleared: () -> Void = {}
    let onDelete: () -> Void
    @State private var loadingConversations = false
    @State private var conversationsFailed = false
    private struct HistoryRead: Equatable { var topic: Topic; var selected: Bool; var revision: Int }

    @ViewBuilder private func exportButtons(_ run: URL) -> some View {
        Button("Export as .listen…", systemImage: "doc.zipper") { onExport(run, false) }
        Button("Export as .listen with sound…", systemImage: "waveform") { onExport(run, true) }
    }

    private var detail: String {
        var parts = [topic.language == .de ? "Deutsch" : "English", systemName]
        if !topic.repositories.isEmpty {
            parts.append(topic.repositories.count == 1 ? "1 repository" : "\(topic.repositories.count) repositories")
        }
        if !topic.links.isEmpty { parts.append(topic.links.count == 1 ? "1 link" : "\(topic.links.count) links") }
        let files = counts?.files ?? 0
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if !topic.notes.isEmpty { parts.append("briefing") }
        let earlier = counts?.notes ?? 0
        if earlier > 0 { parts.append(earlier == 1 ? "continues 1 conversation" : "continues \(earlier) conversations") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row
            // The selected topic says what can be done with it: look, or listen.
            if isSelected {
                HStack(spacing: 10) {
                    Button(action: onOpen) {
                        Label("Open", systemImage: "rectangle.stack").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("Opens this topic with its last cards, without listening yet")
                    Button(action: onStart) {
                        Label(starting ? "Starting…" : "Start listening", systemImage: "waveform")
                            .foregroundStyle(Color(.systemBackground))
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(starting)
                }
                .font(.subheadline.weight(.semibold))
                .transition(.opacity.combined(with: .move(edge: .top)))
                // The conversations held in this topic: tap one to go through it again.
                if loadingConversations {
                    ProgressView("Loading conversations…").font(.subheadline)
                } else if conversationsFailed {
                    Text("Conversations could not be read. Open History to try again.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !conversations.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(conversations.prefix(6)) { entry in
                            Button { onReplay(entry.folder) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.first.isEmpty ? "Nothing was heard" : entry.first).font(.subheadline).lineLimit(1)
                                        Text("\(HistoryView.when(entry.folder.lastPathComponent)) · \(Int(entry.seconds) / 60):\(String(format: "%02d", Int(entry.seconds) % 60)) · \(entry.cards) cards")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 7)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { exportButtons(entry.folder) }
                        }
                        if conversations.count > 6 {
                            Text("\(conversations.count - 6) more in History").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                    }
                    .transition(.opacity)
                } else {
                    Text("No recorded conversations in this topic yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
        .task(id: HistoryRead(topic: topic, selected: isSelected, revision: revision)) {
            conversations = []
            guard isSelected else { loadingConversations = false; return }
            loadingConversations = true
            conversationsFailed = false
            let selected = RecordingLibrary.TopicReference(id: topic.id, name: topic.name)
            do {
                let loaded = try await RecordingLibrary.shared.history(roots: RunRecorder.searchFolders, topic: selected)
                guard !Task.isCancelled else { return }
                conversations = loaded
                loadingConversations = false
            } catch {
                guard !Task.isCancelled else { return }
                conversationsFailed = true; loadingConversations = false
            }
        }
        .padding(.horizontal, CardMetrics.inset)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 22).strokeBorder(.primary, lineWidth: 2)
            }
        }
        .animation(.smooth(duration: 0.25), value: isSelected)
    }

    private var row: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.name).font(.body.weight(.semibold))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Menu {
                // The last recorded conversation of this topic, to go through again and carry on from.
                Button(topic.archived ? "Unarchive" : "Archive", systemImage: topic.archived ? "tray.and.arrow.up" : "archivebox", action: onArchive)
                    .accessibilityIdentifier("topic.archive")
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .accessibilityIdentifier("topic.edit")
                if let last = conversations.first {
                    Menu("Last conversation as .listen", systemImage: "doc.zipper") { exportButtons(last.folder) }
                }
                Button("Export…", systemImage: "square.and.arrow.up", action: onPack)
                // What earlier conversations left behind; the topic itself stays.
                Button("Clear memory", systemImage: "eraser") {
                    TopicSandbox(topic: topic.id).clearNotes()
                    onMemoryCleared()
                }
                .disabled((counts?.notes ?? 0) == 0)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .disabled(!canDelete)
                    .accessibilityIdentifier("topic.delete")
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Options for \(topic.name)")
        }
    }
}
