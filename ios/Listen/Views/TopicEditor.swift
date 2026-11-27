import SwiftUI
import UniformTypeIdentifiers

struct TopicEditor: View {
    @State var topic: Topic
    let isNew: Bool
    let onSave: (Topic) throws -> Void

    @State private var newRepository = ""
    @State private var newLink = ""
    /// What the file dialog may pick while it is open: files or a folder.
    @State private var importing: [UTType]?
    @State private var materialItems: [URL] = []
    @State private var materialIndex = MaterialIndex()
    @State private var reading = false
    @State private var saveFailure: String?
    @State private var systems = SystemStore()
    @Environment(\.dismiss) private var dismiss

    /// Interview is stored as no choice, so topics made before systems keep working as before.
    private var system: Binding<String> {
        Binding(get: { topic.system ?? ListenSystem.defaultID },
                set: { topic.system = $0 == ListenSystem.defaultID ? nil : $0 })
    }

    private var material: TopicMaterial { TopicMaterial(topic: topic.id) }

    private var canAddRepository: Bool {
        Topic.isValidRepository(newRepository) && !topic.repositories.contains(newRepository)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Topic") {
                    TextField("Name", text: $topic.name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("topic.name")
                    Picker("Language", selection: $topic.language) {
                        Text("Deutsch").tag(Language.de)
                        Text("English").tag(Language.en)
                    }
                    Picker("System", selection: system) {
                        ForEach(systems.systems.filter(\.isRunnable)) { choice in
                            Label(choice.name, systemImage: choice.symbol).tag(choice.id)
                        }
                    }
                }
                Section {
                    TextField("Goal, role, facts about you…", text: $topic.notes, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Briefing")
                } footer: {
                    Text("Stored on this device and given to the models with every question.")
                }
                Section {
                    ForEach(topic.links, id: \.self) { link in
                        Label(link, systemImage: "link").lineLimit(1).truncationMode(.middle)
                    }
                    .onDelete { topic.links.remove(atOffsets: $0) }
                    HStack {
                        TextField("https://…", text: $newLink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(addLink)
                        Button("Add", action: addLink).disabled(!canAddLink)
                    }
                } header: {
                    Text("Links")
                } footer: {
                    Text("Up to \(LinkContext.most) pages. Listen reads them when a conversation starts and gives the beginning of each to the models. Cards can link back to these pages, and to no others.")
                }
                Section {
                    ForEach(materialItems, id: \.self) { item in
                        let folder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        Label(item.lastPathComponent, systemImage: folder ? "folder" : "doc.text").lineLimit(1).truncationMode(.middle)
                    }
                    .onDelete { offsets in
                        let chosen = offsets.map { materialItems[$0] }
                        let material = material
                        reading = true
                        Task {
                            await Task.detached { chosen.forEach(material.remove) }.value
                            refreshMaterial()
                        }
                    }
                    HStack {
                        Button("Add files…", systemImage: "doc.badge.plus") { importing = [.item] }
                        Button("Add folder…", systemImage: "folder.badge.plus") { importing = [.folder] }
                        if reading { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("Files and folders")
                } footer: {
                    Text(materialFooter)
                }
                Section {
                    ForEach(topic.repositories, id: \.self) { repository in
                        Label(repository, systemImage: "shippingbox")
                    }
                    .onDelete { topic.repositories.remove(atOffsets: $0) }
                    HStack {
                        TextField("owner/repository", text: $newRepository)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addRepository)
                        Button("Add", action: addRepository).disabled(!canAddRepository)
                    }
                } header: {
                    Text("Context repositories")
                } footer: {
                    Text("Only listed for now. Nothing is read from GitHub until a GitHub connection is set up.")
                }
            }
            .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                          allowedContentTypes: importing ?? [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                let material = material
                reading = true
                Task {
                    await Task.detached { material.add(urls) }.value
                    refreshMaterial()
                }
            }
            .onAppear(perform: refreshMaterial)
            .navigationTitle(isNew ? "New topic" : "Edit topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // A topic that was never saved keeps no files.
                        if isNew { material.removeAll() }
                        dismiss()
                    }
                    .accessibilityIdentifier("topic.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        topic.name = topic.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        do { try onSave(topic); dismiss() }
                        catch {
                            saveFailure = (error as? SystemPackageError)?.message
                                ?? "Listen could not write this topic to the device. Your edits are still here. Try again."
                        }
                    }
                    .disabled(topic.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("topic.save")
                }
            }
            .alert("Could not save topic", isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(saveFailure ?? "") }
        }
    }

    private var materialFooter: String {
        var text = "Copied into this topic on this device: text, Markdown, code, CSV, JSON, HTML, RTF and PDF, up to \(TopicMaterial.mostFiles) files. When a conversation starts, an overview and the passages that match what is being said go to the models you connected; the names in them help Listen hear those words."
        let files = Set(materialIndex.passages.map(\.source)).count
        if files > 0 {
            text += "\nRead: \(files) file\(files == 1 ? "" : "s"), \(materialIndex.passages.count) passages."
            if !materialIndex.terms.isEmpty { text += " Names: " + materialIndex.terms.prefix(12).joined(separator: ", ") + "." }
        }
        if let hints = materialIndex.preparedHints, !hints.isEmpty { text += "\nPrepared answers: \(hints.count). Selected and reviewed when context decisions are enabled." }
        return text
    }

    private func refreshMaterial() {
        materialItems = material.items
        materialIndex = material.index
        reading = false
    }

    private var canAddLink: Bool {
        let link = newLink.trimmingCharacters(in: .whitespaces)
        return Topic.isValidLink(link) && !topic.links.contains(link) && topic.links.count < LinkContext.most
    }

    private func addLink() {
        guard canAddLink else { return }
        topic.links.append(newLink.trimmingCharacters(in: .whitespaces))
        newLink = ""
    }

    private func addRepository() {
        guard canAddRepository else { return }
        topic.repositories.append(newRepository)
        newRepository = ""
    }
}
