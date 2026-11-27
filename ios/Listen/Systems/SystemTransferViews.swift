import SwiftUI
import UniformTypeIdentifiers

struct SystemPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SystemPasteView: View {
    let accept: (SystemPackage) -> Void
    @State private var text = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste the complete system JSON returned by your LLM or copied from Listen.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $text).font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("systems.pasteEditor")
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(20).frame(minWidth: 320, minHeight: 360)
            .navigationTitle("Paste system JSON")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Paste", systemImage: "doc.on.clipboard") { text = UIPasteboard.general.string ?? "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review import") {
                        do { accept(try SystemPackage.read(Data(text.utf8))) }
                        catch { self.error = error.localizedDescription }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("systems.reviewImport")
                }
            }
        }
    }
}

struct SystemImportView: View {
    let package: SystemPackage
    let store: SystemStore
    let capabilities: SystemCapabilities
    let installed: (ListenSystem) -> Void
    @State private var replace = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(package.system.name, systemImage: package.system.symbol).font(.headline)
                    Text(package.system.summary).foregroundStyle(.secondary)
                    let status = capabilities.status(of: package.system)
                    Label(status.text, systemImage: status.ready ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(status.ready ? .green : .orange)
                }
                if let existing = store.system(package.system.id) {
                    Section("Import as") {
                        Picker("Import as", selection: $replace) {
                            Text("A new system").tag(false)
                            Text("Update \(existing.name)").tag(true)
                        }
                        Text(replace ? "Only this system will be updated, from the next conversation. The previous file is backed up." : "A new copy is added. Your existing systems are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("What will be imported") {
                    Text("The building blocks, their instructions, model preferences, timings and rules belong to this system.")
                    Text("Accounts, credentials and topic material stay on this device.").foregroundStyle(.secondary)
                    Text("Model IDs are preferences. This preview checks connected accounts, not access to each specified model.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) { SystemGraph(system: package.system).padding(.vertical, 8) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .frame(minWidth: 340, minHeight: 440)
            .navigationTitle("Review system")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(replace ? "Update system" : "Add system") {
                        do { installed(try store.install(package, replace: replace)) }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("systems.install")
                }
            }
        }
    }
}

struct SystemLLMView: View {
    let package: SystemPackage
    let paste: () -> Void
    @State private var copied = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Design your system in conversation", systemImage: "sparkles").font(.headline)
                    Text("Copy a complete template into Claude or another LLM. Discuss what you need, then bring the finished system back here.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Label("1. Copy the template and paste it into your LLM.", systemImage: "doc.on.doc")
                    Label("2. Clarify the purpose, output and available models together.", systemImage: "bubble.left.and.bubble.right")
                    Label("3. Paste its finished JSON here to review and add the system.", systemImage: "square.and.arrow.down")
                }
                Section {
                    Button(copied ? "Template copied" : "Copy LLM template", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        do { UIPasteboard.general.string = try package.llmTemplate(); copied = true }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("systems.copyTemplate")
                    Button("Paste finished system", systemImage: "doc.on.clipboard", action: paste)
                } footer: {
                    Text("The template describes this app's supported building blocks and includes the complete starting system. No accounts or credentials are exported.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .frame(minWidth: 340, minHeight: 440)
            .navigationTitle("Create with an LLM")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Edit the system's own settings. The JSON editor uses the same complete package as import;
/// prompt editing is a convenient view of that definition, not a separate set of instructions.
struct SystemSettingsView: View {
    let system: ListenSystem
    let store: SystemStore
    @State private var prompts: [String: String]
    @State private var json: String
    @State private var usesJSON = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(system: ListenSystem, store: SystemStore) {
        self.system = system; self.store = store
        let package = store.package(for: system)
        let data = try? package.data()
        _json = State(initialValue: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
        let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(package.system.configuration!.prompts)) as? [String: String]
        _prompts = State(initialValue: object ?? [:])
    }

    var body: some View {
        NavigationStack {
            Group {
                if usesJSON {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Edit the complete system definition, including prompts, timings, model IDs and rules.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $json).font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("systems.definitionEditor")
                        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(16)
                } else {
                    List {
                        Section {
                            ForEach(prompts.keys.sorted(), id: \.self) { key in
                                NavigationLink(key) {
                                    SystemPromptEditor(name: key, text: Binding(get: { prompts[key] ?? "" }, set: { prompts[key] = $0 }))
                                }
                            }
                        } header: { Text("This system's instructions") }
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .frame(minWidth: 360, minHeight: 440)
            .navigationTitle(system.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if !usesJSON {
                        Button("Full definition", systemImage: "curlybraces") {
                            do { json = String(decoding: try currentPackage().data(), as: UTF8.self); usesJSON = true }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            let package = usesJSON ? try SystemPackage.read(Data(json.utf8)) : try currentPackage()
                            guard package.system.id == system.id else { throw SystemPackageError(message: "Keep this system's ID when editing. Use Import to add another system.") }
                            _ = try store.install(package, replace: true)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func currentPackage() throws -> SystemPackage {
        var copy = store.package(for: system).system
        var config = copy.configuration!
        config.prompts = try JSONDecoder().decode(SystemConfig.Prompts.self, from: JSONSerialization.data(withJSONObject: prompts))
        copy.configuration = config
        return store.package(for: copy)
    }
}

private struct SystemPromptEditor: View {
    let name: String
    @Binding var text: String
    var body: some View {
        TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding(12)
            .navigationTitle(name)
    }
}
