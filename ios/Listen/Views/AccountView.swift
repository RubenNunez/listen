import SwiftUI

/// Daily settings lead to connections and voice setup; detailed tuning stays in Advanced.
struct AccountView: View {
    let accounts: AccountStore
    let topics: TopicStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Connector?
    @State private var advanced = false
    @AppStorage(RunRecorder.settingKey) private var recordRuns = true

    var body: some View {
        @Bindable var accounts = accounts
        NavigationStack {
            Form {
                Section {
                    NavigationLink { KeyTransferView(accounts: accounts) } label: {
                        #if targetEnvironment(macCatalyst)
                        Label("Transfer to iPhone", systemImage: "qrcode")
                        #else
                        Label("Copy from Mac", systemImage: "qrcode.viewfinder")
                        #endif
                    }
                    .accessibilityIdentifier("settings.deviceTransfer")
                } footer: { Text("Your Listen setup, together in one transfer.") }
                Section("You") { TextField("Your name", text: $accounts.name).textContentType(.name) }
                Section("Connections") {
                    NavigationLink {
                        Form {
                            Section {
                                ForEach(Connector.allCases) { connector in
                                    ConnectorRow(connector: connector, status: accounts.status[connector] ?? .notConnected) { editing = connector }
                                }
                            } header: { Text("Services") } footer: {
                                Text("Connect your own accounts. Answer cards send conversation text to model services; audio for those requests stays on this device. " + keyStorageNote)
                            }
                            RouterAccountSection()
                            MCPAccountSection()
                        }.navigationTitle("Connections")
                    } label: { Label("Manage connections", systemImage: "point.3.connected.trianglepath.dotted") }
                    .accessibilityIdentifier("settings.connections")
                }
                Section {
                    NavigationLink {
                        VoiceQuickStartView(topics: topics)
                    } label: { Label("Voice quick start", systemImage: "waveform") }
                    .accessibilityIdentifier("settings.voice")
                }
                Section {
                    Toggle("Keep recordings on this device", isOn: $recordRuns)
                } footer: { Text("Recordings contain what people said. They stay on this device unless you transfer or export them.") }
                Section {
                    Button("Advanced", systemImage: "slider.horizontal.3") { advanced = true }
                    NavigationLink { LegalView() } label: { Label("Licenses and notices", systemImage: "doc.text") }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $advanced) { AdvancedAccountView(accounts: accounts) }
            .sheet(item: $editing) { connector in
                switch connector.access {
                case .apiKey: KeySheet(connector: connector, accounts: accounts)
                case .signIn:
                    if connector == .chatGPT { ChatGPTSheet(accounts: accounts) } else { OpenRouterSheet(accounts: accounts) }
                case .deviceCode: GitHubSheet(accounts: accounts)
                case .unavailable: EmptyView()
                }
            }
        }
    }

    private var keyStorageNote: String {
        Keychain.usesFile
            ? "This build is not signed for the Keychain: keys are kept in a file only you can read, in Application Support."
            : "Keys live in the Keychain of this device."
    }
}

/// Infrequent device, routing and storage controls. Connections have one home.
private struct AdvancedAccountView: View {
    let accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var runCount = 0
    @State private var noteCount = 0
    @State private var countsLoaded = false
    private enum Removal {
        case notes, recordings
        var title: String { self == .notes ? "Delete all conversation notes?" : "Delete recordings?" }
        var message: String {
            self == .notes
                ? "Deletes saved conversation notes and card history on this device. Topic files and instructions stay. This cannot be undone."
                : "Deletes recognized recordings and their run logs on this device. Other files and exports stay. This cannot be undone."
        }
    }
    @State private var removal: Removal?
    @State private var removalFailure: String?
    @State private var removing = false
    @AppStorage("myFigure") private var myFigure = Figure.fox.rawValue
    @AppStorage(JevClient.enabledKey) private var jevDecisions = false

    var body: some View {
        @Bindable var accounts = accounts
        NavigationStack {
            Form {
                Section("Your voice marker") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your figure").font(.subheadline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                            ForEach(Figure.allCases) { figure in
                                Button { myFigure = figure.rawValue } label: {
                                    SpeakerFigure(figure: figure, style: .sticker, size: 52)
                                        .padding(6)
                                        .background(
                                            (Figure(rawValue: myFigure) ?? .fox) == figure ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                                            in: .rect(cornerRadius: 14))
                                        .overlay {
                                            if (Figure(rawValue: myFigure) ?? .fox) == figure {
                                                RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: 2)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(figure.title)
                                .accessibilityAddTraits((Figure(rawValue: myFigure) ?? .fox) == figure ? .isSelected : [])
                            }
                        }
                        Text("Marks your own voice in every conversation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle("Use Jev for context decisions", isOn: $jevDecisions)
                        .disabled(accounts.status[.jev]?.isConnected != true)
                    LabeledContent("Decision model", value: JevClient.model)
                } header: { Text("Context decisions") } footer: {
                    Text("Optional routing for relevance, card topics and research. Connect Jev in Settings → Connections first. When enabled, recent conversation text, captured topic context and candidate cards go to TypeSafe; audio stays on this device. Applies from the next conversation. Saving a key does not enable routing. If Jev is unavailable, the normal answer path continues.")
                }
                Section {
                    NavigationLink { SetupTransferView() } label: { Label("Import or export a preset", systemImage: "square.and.arrow.up") }
                }
                Section("On this device") {
                    LabeledContent("Transcription", value: "Apple, on device")
                    LabeledContent("Second pass", value: "Whisper \(SystemConfig.load().config.voice.whisperModel), on device")
                    LabeledContent("Speakers", value: "Pyannote, on device")
                }
                Section {
                    #if targetEnvironment(macCatalyst)
                    Button("Open cards.md") {
                        _ = Instructions.load(topic: nil)
                        UIApplication.shared.open(Instructions.file)
                    }
                    #endif
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("How cards should look is written in a Markdown file you can edit: how short, what deserves a card, when to draw a chart. It applies from the next conversation. A topic can add its own rules in a file named instructions.md in its folder.")
                }
                Section {
                    LabeledContent("Notes", value: countsLoaded ? "\(noteCount)" : "Loading…")
                    #if targetEnvironment(macCatalyst)
                    Button("Show folder") { UIApplication.shared.open(TopicSandbox.root) }
                        .disabled(noteCount == 0)
                    #endif
                    Button("Delete all notes", role: .destructive) {
                        removal = .notes
                    }
                    .disabled(noteCount == 0 || removing)
                } header: {
                    Text("Topic folders")
                } footer: {
                    Text("After a conversation, the cards Listen showed, who was there and, with a model attached, a short summary are kept as a Markdown note in the topic's folder on this device. The next conversation in that topic starts from them. No transcript and no sound is kept there.")
                }
                Section {
                    LabeledContent("Recordings", value: countsLoaded ? "\(runCount)" : "Loading…")
                    #if targetEnvironment(macCatalyst)
                    Button("Show folder") { UIApplication.shared.open(RunRecorder.folder) }
                        .disabled(runCount == 0)
                    #endif
                    Button("Delete recordings", role: .destructive) {
                        removal = .recordings
                    }
                    .disabled(runCount == 0 || removing)
                } header: {
                    Text("Recordings")
                } footer: {
                    Text("Each conversation is kept on this device as sound plus a log of what every layer did: transcript, times, cards, cost. It contains what other people said. Listen never uploads it.")
                }
            }
            .navigationTitle("Advanced")
            .confirmationDialog(removal?.title ?? "Delete saved data?", isPresented: Binding(
                get: { removal != nil }, set: { if !$0 { removal = nil } }),
                titleVisibility: .visible, presenting: removal) { requested in
                Button("Delete", role: .destructive) {
                    removing = true
                    let roots = RunRecorder.searchFolders, topicRoot = TopicSandbox.root
                    Task {
                        defer { removing = false }
                        do {
                            switch requested {
                            case .notes: try await RecordingLibrary.shared.clearConversationNotes(root: topicRoot)
                            case .recordings: try await RecordingLibrary.shared.deleteRecordings(roots: roots)
                            }
                        } catch { removalFailure = "Some saved data could not be removed. Files that could not be deleted have been kept." }
                        if let counts = try? await RecordingLibrary.shared.storageCounts(roots: roots, topicRoot: topicRoot) {
                            runCount = counts.runs; noteCount = counts.notes
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { requested in Text(requested.message) }
            .alert("Could not delete saved data", isPresented: Binding(
                get: { removalFailure != nil }, set: { if !$0 { removalFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(removalFailure ?? "") }
            .task {
                if let counts = try? await RecordingLibrary.shared.storageCounts(roots: RunRecorder.searchFolders, topicRoot: TopicSandbox.root), !Task.isCancelled {
                    runCount = counts.runs; noteCount = counts.notes; countsLoaded = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct ConnectorRow: View {
    let connector: Connector
    let status: AccountStore.Status
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(connector == .elevenLabs ? "ElevenLabs · voice unavailable" : connector.title).font(.body.weight(.semibold))
                Text(note).font(.footnote).foregroundStyle(noteStyle)
            }
            Spacer(minLength: 8)
            if case .unavailable = connector.access {
                Text("Unavailable").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            } else if status == .checking {
                ProgressView()
            } else {
                Button(status.isConnected ? "Manage" : (connector.access == .apiKey ? "Add key" : "Sign in"), action: open)
                    .accessibilityLabel("\(status.isConnected ? "Manage" : (connector.access == .apiKey ? "Add key" : "Sign in")) \(connector.title)")
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var note: String {
        if case .unavailable(let reason) = connector.access { return reason }
        switch status {
        case .notConnected: return connector.detail
        case .connected: return connector == .jev ? "Key saved · enable decisions separately" : "Connected · not checked in this session"
        case .checking: return "Checking"
        case .accepted: return connector == .jev ? "Key accepted · optional decision routing" : "Connected · accepted by \(connector.title)"
        case .rejected(let message), .unchecked(let message): return message
        }
    }

    private var noteStyle: Color {
        switch status {
        case .accepted: .green
        case .rejected: .red
        default: .secondary
        }
    }
}

private struct KeySheet: View {
    let connector: Connector
    let accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    private var isConnected: Bool { accounts.status[connector]?.isConnected == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    if connector == .jev {
                        Text("Store your TypeSafe API key for optional structured decisions. Saving checks account access without sending conversation text or audio. Enable conversation routing separately in Account. An accepted key does not establish decision accuracy.")
                    } else {
                        Text("\(connector.detail). The key is stored on this device. Saving asks \(connector.title) once whether the key is valid; that request is free.")
                    }
                }
                if isConnected {
                    Section {
                        Button("Check again") {
                            Task { await accounts.check(connector) }
                            dismiss()
                        }
                        Button("Disconnect", role: .destructive) {
                            accounts.disconnect(connector)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(connector.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let secret = key
                        Task { await accounts.connect(connector, secret: secret) }
                        dismiss()
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct GitHubSheet: View {
    let accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("gitHubClientID") private var clientID = ""
    @State private var code: GitHubDeviceFlow.Code?
    @State private var message: String?
    @State private var waiting: Task<Void, Never>?

    private var isConnected: Bool { accounts.status[.gitHub]?.isConnected == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID of your GitHub App", text: $clientID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Listen has no GitHub App of its own. Register one in your GitHub settings with device flow enabled and read-only repository access, then paste its client ID. This sign-in has not been completed against GitHub yet.")
                }
                if let code {
                    Section("Enter this code on GitHub") {
                        Text(code.userCode)
                            .font(.title.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Button("Open \(code.verificationURI)") {
                            if let url = URL(string: code.verificationURI) { openURL(url) }
                        }
                        Label("Waiting for you to confirm", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Button("Sign in with a code") { start() }
                            .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
                if isConnected {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            accounts.disconnect(.gitHub)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onDisappear { waiting?.cancel() }
    }

    private func start() {
        message = nil
        let flow = GitHubDeviceFlow(clientID: clientID.trimmingCharacters(in: .whitespaces))
        waiting = Task {
            do {
                let code = try await flow.requestCode()
                self.code = code
                let token = try await flow.waitForToken(code)
                await accounts.connect(.gitHub, secret: token)
                dismiss()
            } catch let failure as GitHubDeviceFlow.Failure {
                code = nil
                message = failure.message
            } catch {
                code = nil
            }
        }
    }
}

/// Sign in with ChatGPT and use of the ChatGPT plan, following OpenAI's
/// guidelines for wording: "Continue with ChatGPT", a confirmation on first
/// use, the plan named where it is used, and a link to manage usage.
private struct ChatGPTSheet: View {
    let accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var account = ChatGPT.Credentials.load()
    @State private var models: [(slug: String, name: String)] = []
    @State private var alsoAsked = UserDefaults.standard.stringArray(forKey: ChatGPT.alsoAskedKey) ?? []
    @State private var message: String?
    @State private var attempt: Task<Void, Never>?
    @State private var isWaiting = false
    @State private var justSignedIn = false
    /// The sign-in page of the running attempt, to copy into another browser.
    @State private var link: URL?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                if let account, account.allowsPlan {
                    if justSignedIn {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("You're using your ChatGPT plan").font(.headline)
                                Text("Cards in Listen are written with usage included in your ChatGPT plan. You can review and limit it in ChatGPT's settings.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("Got it") { justSignedIn = false }.listenPrimaryAction()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section {
                        LabeledContent("Account", value: account.email ?? "Signed in")
                        if models.isEmpty {
                            LabeledContent("Model", value: account.model ?? "none")
                        } else {
                            Picker("Model", selection: Binding(
                                get: { account.model ?? models[0].slug },
                                set: { choose($0) })
                            ) {
                                ForEach(models, id: \.slug) { Text($0.name).tag($0.slug) }
                            }
                        }
                        Button("Manage usage") { openURL(ChatGPT.usage) }
                    } header: {
                        Text("Using ChatGPT plan")
                    } footer: {
                        Text("This model writes the checked card with web search and combines the drafts.")
                    }
                    if models.count > 1 {
                        Section {
                            ForEach(models.filter { $0.slug != account.model }, id: \.slug) { model in
                                Toggle(model.name, isOn: Binding(
                                    get: { alsoAsked.contains(model.slug) },
                                    set: { on in
                                        if on { alsoAsked.append(model.slug) } else { alsoAsked.removeAll { $0 == model.slug } }
                                        UserDefaults.standard.set(alsoAsked, forKey: ChatGPT.alsoAskedKey)
                                    }))
                            }
                        } header: {
                            Text("Asked at the same time")
                        } footer: {
                            Text("Smaller models answer faster. Each one switched on writes a draft for the same moment; the first useful draft is shown at once, then the drafts become one card. More models use more of your plan.")
                        }
                    }
                    Section {
                    } footer: {
                        Text("What is said goes to OpenAI as text when Listen asks for a card; sound never leaves this device. On Plus, the five-hour limit is shared with ChatGPT itself and every other app using your plan.")
                    }
                    Section {
                        Button("Sign out", role: .destructive) { signOut() }
                    }
                } else {
                    Section {
                        if !isWaiting {
                            Button("Continue with ChatGPT") { signIn() }
                        } else if let link {
                            // The link is shown, not opened: the user picks the browser.
                            Text(link.absoluteString)
                                .font(.caption.monospaced())
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Button(copied ? "Link copied" : "Copy link") {
                                UIPasteboard.general.url = link
                                copied = true
                            }
                            #if targetEnvironment(macCatalyst)
                            Button("Open in the default browser") { openURL(link) }
                            #endif
                            HStack {
                                ProgressView()
                                Text("Waiting for you to sign in…").foregroundStyle(.secondary)
                            }
                            Button("Cancel", role: .cancel) { attempt?.cancel() }
                        } else {
                            ProgressView()
                        }
                    } footer: {
                        #if targetEnvironment(macCatalyst)
                        Text("Gives you a link to auth.openai.com. Copy it into the browser where you are signed in to ChatGPT, or open it in your default browser; any browser on this device works while this sheet is waiting. You sign in there and allow Listen to use your ChatGPT Plus or Pro plan; Listen never sees your password. OpenAI offers this for apps that run on your own device. This sign-in was built from OpenAI's documentation and has not been completed from Listen yet.")
                        #else
                        Text("Opens auth.openai.com in a sign-in sheet over Listen; a ChatGPT login in Safari is reused. You sign in there and allow Listen to use your ChatGPT Plus or Pro plan; Listen never sees your password. Keep Listen in front until it is done: the answer comes back to this app on this device. OpenAI offers this for apps that run on your own device. This sign-in was built from OpenAI's documentation and has not been completed from Listen yet.")
                        #endif
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task { await loadModels() }
        .onDisappear { attempt?.cancel() }
    }

    private func signIn() {
        message = nil
        isWaiting = true
        link = nil
        copied = false
        attempt = Task {
            let flow = ChatGPTSignIn()
            do {
                #if targetEnvironment(macCatalyst)
                account = try await flow.run { link = $0 }
                #else
                // iOS suspends Listen behind Safari and the listener dies, so the page opens over Listen.
                account = try await flow.run(page: .system()) { link = $0 }
                #endif
                justSignedIn = true
                await loadModels()
            } catch let failure as ChatGPT.Failure {
                message = failure.message
            } catch is CancellationError {
            } catch {
                message = "The sign-in did not finish."
            }
            flow.stop()
            isWaiting = false
            link = nil
            accounts.refresh(.chatGPT)
        }
    }

    private func loadModels() async {
        guard account?.allowsPlan == true, let token = try? await ChatGPTSession.shared.accessToken() else { return }
        do {
            models = try await ChatGPT.models(accessToken: token)
            if account?.model == nil, let first = models.first { choose(first.slug) }
        } catch let failure as ChatGPT.Failure {
            message = failure.message
        } catch {}
    }

    private func choose(_ slug: String) {
        // Read again: the session may have renewed the tokens in the meantime.
        guard var current = ChatGPT.Credentials.load() else { return }
        current.model = slug
        try? current.save()
        account = current
    }

    private func signOut() {
        Task {
            let confirmed = await ChatGPTSession.shared.signOut()
            account = nil
            accounts.refresh(.chatGPT)
            message = confirmed ? nil : "Signed out here. OpenAI did not confirm it; you can disconnect Listen in ChatGPT's settings."
        }
    }
}

private struct OpenRouterSheet: View {
    let accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var flow = OpenRouterSignIn()
    @State private var pasted = ""
    @State private var message: String?
    @State private var waiting: Task<Void, Never>?
    @State private var isWaiting = false

    private var isConnected: Bool { accounts.status[.openRouter]?.isConnected == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(isWaiting ? "Waiting for the browser…" : "Sign in with OpenRouter") { signIn() }
                        .disabled(isWaiting)
                } footer: {
                    Text("Opens openrouter.ai in the browser. You sign in there; Listen receives a key for your account and stores it on this device. Requests are paid from your OpenRouter credit. This sign-in has not been completed against OpenRouter yet.")
                }
                Section {
                    Button("Show a code instead") { openURL(flow.authorizationURL(callback: nil)) }
                    TextField("Code from the page", text: $pasted)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Use this code") { finish(with: pasted) }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("If the browser does not come back")
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
                if isConnected {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            accounts.disconnect(.openRouter)
                            dismiss()
                        }
                    } footer: {
                        Text("This removes the key from this device. To revoke it, delete it in your OpenRouter settings.")
                    }
                }
            }
            .navigationTitle("OpenRouter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onDisappear {
            waiting?.cancel()
            flow.stop()
        }
    }

    private func signIn() {
        message = nil
        isWaiting = true
        waiting = Task {
            do {
                let (callback, code) = try await flow.listen()
                openURL(flow.authorizationURL(callback: callback))
                let received = await withTaskCancellationHandler { await code.value } onCancel: { code.cancel() }
                flow.stop()
                isWaiting = false
                if let received { finish(with: received) }
            } catch let failure as OpenRouterSignIn.Failure {
                isWaiting = false
                message = failure.message
            } catch {
                isWaiting = false
            }
        }
    }

    private func finish(with code: String) {
        message = nil
        Task {
            do {
                let key = try await flow.key(for: code)
                await accounts.connect(.openRouter, secret: key)
                dismiss()
            } catch let failure as OpenRouterSignIn.Failure {
                message = failure.message
            } catch {}
        }
    }
}
