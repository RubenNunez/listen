import SwiftUI

struct MCPAccountSection: View {
    var store = MCPStore.shared
    var body: some View {
        Section {
            ForEach(store.servers) { server in
                NavigationLink { MCPServerEditor(store: store, original: server) } label: {
                    LabeledContent(server.name, value: "\(server.permissions.count) tools enabled")
                }.tint(.primary)
            }
            NavigationLink("Add MCP server") {
                MCPServerEditor(store: store, original: .init(name: "", endpoint: URL(string: "https://localhost/mcp")!))
            }
                .disabled(store.problem != nil)
            if let problem = store.problem { Text(problem).foregroundStyle(.red) }
        } header: { Text("Voice assistant tools") } footer: {
            Text("Connect your own service over HTTPS or use HTTP on your local network. Choose its tools here, then add their capability IDs to a Voice assistant system. Each use asks for confirmation unless you explicitly allow it beforehand.")
        }
    }
}

private struct MCPServerEditor: View {
    let store: MCPStore
    let original: MCPServerBinding
    @State private var draft: MCPServerBinding
    @State private var endpoint: String
    @State private var token = ""
    @State private var clearToken = false
    @State private var tools: [MCPTool] = []
    @State private var failure: String?
    @State private var checking = false
    @Environment(\.dismiss) private var dismiss

    init(store: MCPStore, original: MCPServerBinding) {
        self.store = store
        self.original = original
        _draft = State(initialValue: original)
        _endpoint = State(initialValue: original.name.isEmpty ? "" : original.endpoint.absoluteString)
    }

    private func permission<T>(_ tool: String, _ key: WritableKeyPath<MCPToolPermission, T>, fallback: T) -> Binding<T> {
        Binding(get: { draft.permissions.first(where: { $0.tool == tool })?[keyPath: key] ?? fallback }, set: { value in
            guard let index = draft.permissions.firstIndex(where: { $0.tool == tool }) else { return }
            draft.permissions[index][keyPath: key] = value
        })
    }

    var body: some View {
        Form {
            Section("Your server") {
                TextField("Name", text: $draft.name)
                TextField("MCP endpoint", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if URL(string: endpoint)?.scheme == "http" {
                    Text("HTTP sends the server token and tool data unencrypted on your local network.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Protocol version", selection: $draft.revision) {
                    ForEach(MCPRevision.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                SecureField("Server token (optional)", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if store.servers.contains(where: { $0.id == original.id }) {
                    Toggle("Remove saved token", isOn: $clearToken)
                    Text("An empty token field keeps the existing token. Changing the endpoint clears it.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Check server and list tools") {
                    checking = true
                    failure = nil
                    Task {
                        defer { checking = false }
                        do {
                            guard let url = URL(string: endpoint), MCPClient.validEndpoint(url) else { throw MCPFailure.endpoint }
                            draft.endpoint = url
                            tools = try await store.discover(draft, token: clearToken ? "" : (token.isEmpty ? nil : token))
                        } catch { failure = (error as? MCPFailure)?.errorDescription ?? "The MCP connection could not be checked." }
                    }
                }.disabled(checking)
                if checking { ProgressView("Checking your server") }
            }
            Section {
                ForEach(tools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(tool.name, isOn: Binding(get: { draft.permissions.contains(where: { $0.tool == tool.name }) }, set: { enabled in
                            if enabled {
                                let alias = "mcp-\(draft.id.uuidString.prefix(8).lowercased()).\(tool.name)"
                                draft.permissions.append(.init(id: alias, tool: tool.name))
                            } else { draft.permissions.removeAll { $0.tool == tool.name } }
                        })).disabled(tool.fields == nil && !draft.permissions.contains(where: { $0.tool == tool.name }))
                        if !tool.description.isEmpty { Text(tool.description).font(.caption).foregroundStyle(.secondary) }
                        if tool.fields == nil { Text("Unavailable: this tool needs a schema or MCP feature not supported by this build.").font(.caption).foregroundStyle(.orange) }
                    }
                }
                ForEach(draft.permissions.map(\.tool), id: \.self) { tool in
                    VStack(alignment: .leading) {
                        Text(tool).font(.subheadline.weight(.semibold))
                        TextField("Capability ID for a system", text: permission(tool, \.id, fallback: ""))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Allow without asking each time", isOn: permission(tool, \.withoutConfirmation, fallback: false))
                        Button("Remove permission", role: .destructive) { draft.permissions.removeAll { $0.tool == tool } }
                    }
                }
            } header: { Text("Tools you allow") } footer: {
                Text("A capability ID is a local binding, not a credential. Only systems naming that ID can request it. Tool descriptions are supplied by your server. Changes apply to the next assistant session.")
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            if store.servers.contains(where: { $0.id == original.id }) {
                Button("Remove this connection", role: .destructive) {
                    do { try store.remove(original.id); dismiss() }
                    catch { failure = "The connection could not be removed. Reopen this view." }
                }
            }
        }
        .navigationTitle("MCP server")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        guard let url = URL(string: endpoint), MCPClient.validEndpoint(url) else { throw MCPFailure.endpoint }
                        draft.endpoint = url
                        try store.save(draft, newToken: clearToken ? "" : (token.isEmpty ? nil : token))
                        dismiss()
                    } catch { failure = (error as? MCPFailure)?.errorDescription ?? "Could not save. Reopen this view if connections changed elsewhere." }
                }.disabled(checking)
            }
        }
    }
}

struct VoiceAssistantSettingsSection: View {
    let system: ListenSystem
    let store: SystemStore
    private func binding<T>(_ key: WritableKeyPath<VoiceAssistantConfiguration, T>) -> Binding<T> {
        Binding(get: { system.configuration?.conversation?[keyPath: key] ?? VoiceAssistantConfiguration()[keyPath: key] }, set: { value in
            var system = system
            var config = system.configuration ?? SystemConfig()
            var conversation = config.conversation ?? VoiceAssistantConfiguration()
            conversation[keyPath: key] = value
            config.conversation = conversation
            system.configuration = config
            store.update(system)
        })
    }
    /// Web search by the answering model itself. Offered where the model's connection has
    /// it; a model named here for another connection shows it as unavailable instead.
    @ViewBuilder private var webSearch: some View {
        let model = system.configuration?.conversation?.model ?? ""
        let unavailable = !model.isEmpty && VoiceAssistantConfiguration.webSearchModel(model) == nil
        Toggle("Let the model search the web", isOn: binding(\.webSearch))
            .disabled(unavailable && system.configuration?.conversation?.webSearch != true)
            .accessibilityIdentifier("voice.webSearch")
        Text(unavailable
            ? "Unavailable for this model: only a model reached through the ChatGPT sign-in (chatgpt/…) can search the web. Nothing is searched on another connection."
            : "The model decides when to search, through the ChatGPT sign-in and its plan. A search takes a few seconds; Listen then says that it is looking it up, and shows the pages the answer cites. With another connection, replies come without search and the talk screen says so.")
            .font(.caption).foregroundStyle(unavailable ? .orange : .secondary)
    }

    var body: some View {
        Section {
            // One choice and one write: turning a system of roles into an assistant on the way
            // to spoken cards would switch its writer and what depends on it off.
            Picker("Conversational voice", selection: Binding<VoiceAnswerSource?>(get: {
                system.configuration?.conversation.flatMap { $0.enabled ? $0.answerSource : nil }
            }, set: { source in
                var next = system.configuration?.conversation ?? VoiceAssistantConfiguration()
                next.enabled = source != nil
                if let source { next.answerSource = source }
                binding(\.self).wrappedValue = next
            })) {
                Text("Off").tag(VoiceAnswerSource?.none)
                Text("One model with tools").tag(VoiceAnswerSource?.some(.assistant))
                Text("This system's roles, spoken").tag(VoiceAnswerSource?.some(.harness))
            }
            .accessibilityIdentifier("voice.answerSource")
            if system.speaksCards {
                Toggle("Speak finished cards", isOn: binding(\.speakReplies))
                if system.configuration?.conversation?.speakReplies != false {
                    TalkBackSettings(configuration: binding(\.self))
                }
                Toggle("Allow audio recording", isOn: binding(\.recordAudio))
                Text("The roles, prompts, account, budget and decisions of this system answer as they do on screen, with research where the system has it; they are asked to write sentences a voice can say. The first accepted answer is said at once, sentence by sentence. While it is said, the main model is asked what it is missing; what it or research adds follows as a short addition, and a correction is said as one. Code, drawings, charts and sources are shown, not read. No tool is offered or run. Listen does not hear while it speaks. Talk with Listen speaks any topic this way without this switch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if system.isVoiceAssistant {
                TextField("Model (empty uses the topic's main model)", text: binding(\.model))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Choose Luna, Sol or Astra by complexity", isOn: binding(\.adaptiveRouting))
                if system.configuration?.conversation?.adaptiveRouting == true {
                    TextField("Simple tasks model", text: binding(\.simpleModel)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Complex tasks model", text: binding(\.complexModel)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("JEV chooses among these models and the main model above. Unavailable routing is recorded and uses the configured main model. Tool permissions stay separate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Prepare likely follow-ups and waiting phrases", isOn: binding(\.prepareFollowups))
                    .disabled(system.configuration?.conversation?.adaptiveRouting != true)
                if system.configuration?.conversation?.prepareFollowups == true {
                    Text("After a substantive answer, one bounded read-only call prepares up to two follow-up perspectives and three waiting phrases. JEV can select them on the next turn. New speech cancels unfinished preparation; speculative material is never a verified source or an action.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Fast opening alongside the main model", isOn: binding(\.parallelOpening))
                if system.configuration?.conversation?.parallelOpening == true {
                    TextField("Fast model (empty uses an attached draft model)", text: binding(\.openingModel))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Both models start together. JEV reviews the context-specific opening before speech. The main model keeps research and tool decisions. Short turns skip the extra calls; all calls count toward the request limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Speak replies", isOn: binding(\.speakReplies))
                if system.configuration?.conversation?.speakReplies != false {
                    TalkBackSettings(configuration: binding(\.self))
                }
                Toggle("Allow audio recording", isOn: binding(\.recordAudio))
                webSearch
                Toggle("Keep a session note", isOn: binding(\.keepNotes))
                Toggle("Limit model requests per session", isOn: binding(\.limitModelRequests))
                if system.configuration?.conversation?.limitModelRequests == true {
                    Stepper("Model requests per session: \(system.configuration?.conversation?.maximumTurns ?? 40)", value: binding(\.maximumTurns), in: 1...200)
                }
                Stepper("Tool calls per session: \(system.configuration?.conversation?.maximumToolCalls ?? 32)", value: binding(\.maximumToolCalls), in: 1...256)
                TextField("Capability IDs, separated by commas", text: Binding(get: {
                    (system.configuration?.conversation?.toolIDs ?? []).joined(separator: ", ")
                }, set: { binding(\.toolIDs).wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                TextField("Assistant instructions", text: binding(\.prompt), axis: .vertical).lineLimit(4...12)
            }
        } header: { Text("Voice assistant") } footer: {
            Text("Uses on-device recognition, your selected model and native speech. The microphone is gated during speech; tap Interrupt and wait for Listening before speaking again. Recording requires both this permission and Account's recording switch. Configure external tools under Account; importing a system grants no tool access. Router agents retain the permissions you gave them in the router app.")
        }
    }
}
