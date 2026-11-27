import SwiftUI

struct RouterAccountSection: View {
    var store = RouterStore.shared
    @State private var editing: SavedRouter?

    var body: some View {
        Section {
            ForEach(store.routers) { router in
                Button { editing = router } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(router.name.isEmpty ? "Listen Router" : router.name)
                            Text(router.enabled ? "Used for model requests" : "Paired · model requests off")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            NavigationLink("Pair with a router") { RouterLinkSheet(store: store) }
                .disabled(store.problem != nil)
                .accessibilityIdentifier("router.pair")
            if let problem = store.problem { Text(problem).foregroundStyle(.red) }
        } header: { Text("Your Listen Router") } footer: {
            Text("Connect the official tools on your own computer. Pairing and model use are separate. This connection sends text; router audio and voice actions are not available yet.")
        }
        .sheet(item: $editing) { RouterSettingsSheet(store: store, router: $0) }
    }
}

private struct RouterLinkSheet: View {
    let store: RouterStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var proposal: RouterLink?
    @State private var failure: String?
    @State private var scanning = false
    @State private var openedScanner = false
    @State private var showsManualEntry = false
    @State private var scannedCode: String?

    var body: some View {
        Form {
            #if !targetEnvironment(macCatalyst)
            Section {
                Button("Scan router code", systemImage: "qrcode.viewfinder") { startScanning() }
                    .accessibilityIdentifier("router.scan")
            }
            #endif
            Section {
                #if targetEnvironment(macCatalyst)
                linkEntry
                #else
                DisclosureGroup("Paste a pairing link instead", isExpanded: $showsManualEntry) {
                    linkEntry
                }
                #endif
            } footer: {
                #if targetEnvironment(macCatalyst)
                Text("Open your own Listen Router and copy its pairing link here. The code renews itself.")
                #else
                Text("Open your own Listen Router and scan its QR code. The code renews itself.")
                #endif
            }
            if let failure {
                Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("router.failure") }
            }
        }
        .navigationTitle("Add router")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task {
            #if !targetEnvironment(macCatalyst)
            guard !openedScanner else { return }
            openedScanner = true
            startScanning()
            #endif
        }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            guard let code = scannedCode else { return }
            scannedCode = nil
            review(code)
        }) {
            QRScanner(title: "Scan router code", manualEntry: { showsManualEntry = true }) {
                scannedCode = $0
            }
        }
        .sheet(item: $proposal) { RouterPairSheet(link: $0, store: store) }
    }

    @ViewBuilder private var linkEntry: some View {
        TextField("Paste the router's pairing link", text: $text, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("router.link")
        Button("Review pairing") { review(text) }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("router.review")
    }

    private func startScanning() {
        failure = nil
        scannedCode = nil
        scanning = true
    }

    private func review(_ code: String) {
        do { proposal = try RouterLink.parse(code); failure = nil }
        catch { failure = error.localizedDescription }
    }
}

struct RouterPairSheet: View {
    let link: RouterLink
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: RouterPairing
    @State private var scanning = false
    @State private var scannedCode: String?

    init(link: RouterLink, store: RouterStore = .shared) {
        self.link = link
        _pairing = State(initialValue: RouterPairing(link: link, store: store))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Router address") {
                    Picker("Connect using", selection: Binding(get: { pairing.selectedHost }, set: { pairing.selectHost($0) })) {
                        ForEach(pairing.link.hosts.indices, id: \.self) {
                            Text(verbatim: "\(pairing.link.hosts[$0]):\(pairing.link.port)").tag($0)
                        }
                    }
                    .disabled(pairing.phase != .review)
                }
                Section("Certificate fingerprint") {
                    Text(pairing.link.fingerprintForDisplay).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("Compare these groups with the fingerprint below the QR code on your computer.")
                }
                Section {
                    if pairing.phase == .paired {
                        Label("Paired · model requests are off", systemImage: "checkmark.circle")
                        Button("Done") { dismiss() }
                    } else {
                        Button("Pair this device") {
                            pairing.pair(deviceName: UIDevice.current.name)
                        }
                        .disabled(!pairing.canPair)
                    }
                    if pairing.phase == .pairing { ProgressView("Pairing") }
                    if let failure = pairing.failure { Text(failure.reason).foregroundStyle(.red) }
                    #if !targetEnvironment(macCatalyst)
                    if pairing.phase != .paired {
                        Button("Scan a new code", systemImage: "qrcode.viewfinder") { scannedCode = nil; scanning = true }
                            .disabled(pairing.phase == .pairing)
                            .accessibilityIdentifier("router.rescan")
                    }
                    #endif
                } footer: {
                    Text("Pairing stores a device token locally. You choose separately whether a topic's model requests may use this router. It does not enable tools or wider permissions on that computer.")
                }
            }
            .navigationTitle("Pair Listen Router")
            .onChange(of: link) { _, link in pairing.review(link) }
            .interactiveDismissDisabled(pairing.phase == .pairing)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pairing.phase == .paired ? "Done" : "Cancel") { dismiss() }
                        .disabled(pairing.phase == .pairing)
                }
            }
            .fullScreenCover(isPresented: $scanning, onDismiss: {
                guard let code = scannedCode else { return }
                scannedCode = nil
                pairing.review(code)
            }) {
                QRScanner(title: "Scan router code") { scannedCode = $0 }
            }
        }
    }
}

private struct RouterSettingsSheet: View {
    let store: RouterStore
    let router: SavedRouter
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var model: String
    @State private var usesCodex: Bool
    @State private var failure: String?

    init(store: RouterStore, router: SavedRouter) {
        self.store = store
        self.router = router
        _enabled = State(initialValue: router.enabled)
        _model = State(initialValue: router.model)
        _usesCodex = State(initialValue: router.usesCodex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: "\(router.address.host):\(router.address.port)")
                    switch store.states[router.id] ?? .unchecked {
                    case .unchecked: Text("Connection not checked")
                    case .checking: ProgressView("Checking router")
                    case .failed(let error): Text(error.reason).foregroundStyle(.red)
                    case .connected(let status):
                        Text("Connected · router \(status.routerVersion)")
                        ForEach(status.tools.indices, id: \.self) { index in
                            let tool = status.tools[index]
                            LabeledContent(tool.tool == .codex ? "Codex" : "Claude", value:
                                !tool.found ? "Not installed" : !tool.enabled ? "Off on router" : tool.signedIn == .yes ? "Account accepted" : tool.signedIn == .no ? "Sign in on router" : "Account not checked")
                        }
                    }
                    Button("Check connection") { Task { await store.refresh(router.id) } }
                        .disabled(store.states[router.id] == .checking)
                } header: { Text("Connection") }
                Section {
                    Toggle("Use for model requests", isOn: $enabled)
                    Picker("Tool", selection: $usesCodex) {
                        Text("Claude").tag(false)
                        Text("Codex").tag(true)
                    }
                    TextField("Model (empty uses router default)", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Joins the drafts and provides the main model from the next conversation. Explicit system model preferences take priority; existing web checks continue. Codex and command access must be enabled by you on the router; Listen cannot switch them on. Voice/audio is not connected through this route.")
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                Section {
                    Button("Forget on this device", role: .destructive) {
                        Task {
                            do { try await store.remove(router.id); dismiss() }
                            catch { failure = error.localizedDescription }
                        }
                    }
                } footer: { Text("Also remove this device in the router's window to revoke its pairing there.") }
            }
            .navigationTitle(router.name.isEmpty ? "Listen Router" : router.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try store.configure(router.id, enabled: enabled, model: model, usesCodex: usesCodex); dismiss() }
                        catch { failure = error.localizedDescription }
                    }
                }
            }
            .task { await store.refresh(router.id) }
        }
    }
}
