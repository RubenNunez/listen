import SwiftUI
import UniformTypeIdentifiers

/// Availability outside the system definition. Imports never grant account or model access.
struct SystemCapabilities: Equatable {
    var decisionService: Bool
    var models: Bool
    var gitHub: Bool
    var dialectModel: Bool
    var toolIDs: Set<String> = []

    @MainActor static func current() -> SystemCapabilities {
        SystemCapabilities(
            decisionService: Keychain.get(Connector.jev.rawValue) != nil && UserDefaults.standard.bool(forKey: JevClient.enabledKey),
            models: !SessionModel.plan(for: nil).settings.drafters.isEmpty || RouterStore.shared.active != nil,
            gitHub: Keychain.get(Connector.gitHub.rawValue) != nil,
            dialectModel: WhisperRefiner.hasDialectModel,
            toolIDs: Set(MCPStore.shared.servers.flatMap { $0.permissions.map(\.id) }))
    }

    func has(_ requirement: ListenSystem.Requirement) -> Bool {
        switch requirement {
        case .decisionService: decisionService
        case .models: models
        case .gitHub: gitHub
        case .dialectModel: dialectModel
        }
    }

    func status(of system: ListenSystem) -> (text: String, ready: Bool) {
        if !system.isRunnable {
            return ("Unavailable in this build: " + system.missingBlocks.map(\.title).joined(separator: ", "), false)
        }
        let missing = system.requirements.filter { !has($0) }
        if !missing.isEmpty { return ("Needs " + missing.map(\.title).joined(separator: ", "), false) }
        if system.isVoiceAssistant {
            let missing = (system.configuration?.conversation?.toolIDs ?? []).filter { !toolIDs.contains($0) }
            if !missing.isEmpty { return ("Needs local tool bindings: " + missing.joined(separator: ", "), false) }
            return ("Configured · tools checked at start", true)
        }
        return ("Ready", true)
    }
}

struct SystemsView: View {
    let model: SessionModel
    let topic: Topic
    @State private var store = SystemStore()
    @State private var capabilities = SystemCapabilities.current()
    @State private var path: [String] = []
    @State private var sheet: TransferSheet?
    @State private var showsDefaults = false
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var document = SystemPackageDocument(data: Data())
    @State private var filename = "system.listen-system"
    @Environment(\.dismiss) private var dismiss

    private enum TransferSheet: Identifiable {
        case paste, preview(SystemPackage), llm(SystemPackage)
        var id: String {
            switch self { case .paste: "paste"; case .preview: "preview"; case .llm: "llm" }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button("New system", systemImage: "plus.circle.fill", action: create)
                        .accessibilityIdentifier("systems.new")
                    Menu {
                        Button("Import JSON file…", systemImage: "doc") { importsFile = true }
                        Button("Paste system JSON…", systemImage: "doc.on.clipboard") { sheet = .paste }
                    } label: { Label("Import system…", systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("systems.import")
                    Button("Create with an LLM…", systemImage: "sparkles") { template() }
                        .accessibilityIdentifier("systems.llm")
                } footer: {
                    Text("Create your own system, or bring a complete definition from Claude or another LLM.")
                }
                if !store.systems.filter({ !$0.builtIn }).isEmpty {
                    Section("Your systems") { rows(store.systems.filter { !$0.builtIn }) }
                }
                Section("Included") { rows(store.systems.filter(\.builtIn)) }
                Section {
                    Button("Defaults for new systems…", systemImage: "slider.horizontal.3") { showsDefaults = true }
                } footer: {
                    Text("Each system owns its prompts, models and timings. Open a system to edit, duplicate or export it. Each topic chooses its system in its settings.")
                }
                if let problem = store.storageProblem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Systems")
            .navigationDestination(for: String.self) { id in
                SystemDetail(store: store, id: id, capabilities: capabilities,
                             duplicate: duplicate, export: export, template: { template($0) })
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New system", systemImage: "plus", action: create)
                        Button("Import JSON file…", systemImage: "square.and.arrow.down") { importsFile = true }
                        Button("Paste system JSON…", systemImage: "doc.on.clipboard") { sheet = .paste }
                        Button("Create with an LLM…", systemImage: "sparkles") { template() }
                    } label: { Label("Add system", systemImage: "plus") }
                    .accessibilityIdentifier("systems.add")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(isPresented: $showsDefaults) { SystemView(model: model, topic: topic) }
        .sheet(item: $sheet) { item in
            switch item {
            case .paste: SystemPasteView { sheet = .preview($0) }
            case .preview(let package):
                SystemImportView(package: package, store: store, capabilities: capabilities) { system in
                    sheet = nil; path = [system.id]
                }
            case .llm(let package): SystemLLMView(package: package) { sheet = .paste }
            }
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: SystemPackage.maximumBytes + 1) ?? Data()
                sheet = .preview(try SystemPackage.read(data))
            } catch { store.lastError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportsFile, document: document, contentType: .json, defaultFilename: filename) { result in
            if case .failure(let error) = result { store.lastError = error.localizedDescription }
        }
        .alert("Could not save system", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
    }

    private func create() {
        do { path = [try store.create().id] } catch { store.lastError = error.localizedDescription }
    }
    private func duplicate(_ system: ListenSystem) {
        do { path = [try store.duplicate(system).id] } catch { store.lastError = error.localizedDescription }
    }
    private func export(_ system: ListenSystem) {
        do {
            document = SystemPackageDocument(data: try store.package(for: system).data())
            filename = system.id + ".listen-system"
            exportsFile = true
        } catch { store.lastError = error.localizedDescription }
    }
    private func template(_ system: ListenSystem? = nil) {
        guard let source = system ?? store.system(ListenSystem.defaultID) else { return }
        sheet = .llm(store.package(for: source))
    }

    private func rows(_ systems: [ListenSystem]) -> some View {
        ForEach(systems) { system in
            NavigationLink(value: system.id) { row(system) }
                .contextMenu {
                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(system) }
                    Button("Export system…", systemImage: "square.and.arrow.up") { export(system) }
                    Button("Copy system JSON", systemImage: "doc.on.doc") {
                        do { UIPasteboard.general.string = String(decoding: try store.package(for: system).data(), as: UTF8.self) }
                        catch { store.lastError = error.localizedDescription }
                    }
                }
        }
    }

    private func row(_ system: ListenSystem) -> some View {
        let status = capabilities.status(of: system)
        return HStack(spacing: 12) {
            Image(systemName: system.symbol).font(.title3).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(system.name).font(.headline)
                    if (topic.system ?? ListenSystem.defaultID) == system.id {
                        Text("this topic").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: .capsule)
                    }
                }
                if !system.summary.isEmpty { Text(system.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                Label(status.text, systemImage: status.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(status.ready ? .green : .orange).lineLimit(2)
            }
        }.padding(.vertical, 4)
    }
}

private struct SystemDetail: View {
    let store: SystemStore
    let id: String
    let capabilities: SystemCapabilities
    let duplicate: (ListenSystem) -> Void
    let export: (ListenSystem) -> Void
    let template: (ListenSystem) -> Void
    @State private var confirmsDelete = false
    @State private var showsSettings = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let system = store.system(id) {
            Form {
                Section {
                    if system.builtIn { Text(system.summary).foregroundStyle(.secondary) }
                    else {
                        TextField("Name", text: binding(\.name))
                        TextField("What it is for", text: binding(\.summary), axis: .vertical)
                    }
                    let status = capabilities.status(of: system)
                    Label(status.text, systemImage: status.ready ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(status.ready ? .green : .orange)
                }
                Section {
                    Button("Prompts and settings…", systemImage: "slider.horizontal.3") { showsSettings = true }
                    Button("Refine with an LLM…", systemImage: "sparkles") { template(system) }
                } footer: { Text("These instructions, model preferences and timings belong only to this system.") }
                VoiceAssistantSettingsSection(system: system, store: store)
                Section {
                    ScrollView(.horizontal) { SystemGraph(system: system).padding(.vertical, 6) }.scrollIndicators(.visible)
                } header: { Text("How it is wired") } footer: {
                    Text("Drawn from this app's supported blocks. Dashed blocks are off; orange blocks are unavailable.")
                }
                if !system.requirements.isEmpty {
                    Section("Needs") {
                        ForEach(system.requirements, id: \.self) { requirement in
                            let met = capabilities.has(requirement)
                            VStack(alignment: .leading, spacing: 2) {
                                Label(requirement.title, systemImage: met ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(met ? Color.primary : Color.orange)
                                if !met { Text(requirement.hint).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if !system.isVoiceAssistant {
                    Section {
                        ForEach(ListenSystem.Kind.allCases, id: \.self) { kind in blockRow(kind, in: system) }
                    } header: { Text("Building blocks") } footer: { Text("Changes apply from the next conversation.") }
                }
                Section {
                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(system) }
                    Button("Export system…", systemImage: "square.and.arrow.up") { export(system) }
                        .accessibilityIdentifier("systems.export")
                    if system.builtIn, store.isChanged(system) {
                        Button("Reset to how it shipped", systemImage: "arrow.counterclockwise") { store.reset(system) }
                    }
                    if !system.builtIn {
                        Button("Delete system", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .navigationTitle(system.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(system) }
                        Button("Export system…", systemImage: "square.and.arrow.up") { export(system) }
                    } label: { Label("System actions", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showsSettings) { SystemSettingsView(system: system, store: store) }
            .confirmationDialog("Delete \(system.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.delete(system)
                    if store.system(id) == nil { dismiss() }
                }
            } message: { Text("Topics that use it run with Interview.") }
        } else { ContentUnavailableView("No such system", systemImage: "questionmark") }
    }

    private func blockRow(_ kind: ListenSystem.Kind, in system: ListenSystem) -> some View {
        let dependency = kind.dependsOn.map { system.isOn($0) } ?? true
        return Toggle(isOn: Binding(get: { system.isOn(kind) }, set: { on in
            var changed = system; changed.set(kind, on); store.update(changed)
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Label(kind.title, systemImage: kind.symbol)
                Text(note(kind, dependency: dependency)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!kind.isBuilt || kind.isFixed || !dependency)
        .padding(.leading, kind.dependsOn == nil ? 0 : 18)
    }

    private func note(_ kind: ListenSystem.Kind, dependency: Bool) -> String {
        if !kind.isBuilt { return "Unavailable in this build. " + kind.detail }
        if kind.isFixed { return "Always on. " + kind.detail }
        if !dependency, let other = kind.dependsOn { return "Needs \(other.title). " + kind.detail }
        return kind.detail
    }
    private func binding(_ field: WritableKeyPath<ListenSystem, String>) -> Binding<String> {
        Binding(get: { store.system(id)?[keyPath: field] ?? "" }, set: { value in
            guard var system = store.system(id) else { return }
            // Keep interactive edits within the portable definition's limits.
            system[keyPath: field] = String(value.replacingOccurrences(of: "\n", with: " ").prefix(field == \.name ? 80 : 500))
            store.update(system)
        })
    }
}
