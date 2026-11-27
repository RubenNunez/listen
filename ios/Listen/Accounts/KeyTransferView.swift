import CoreImage.CIFilterBuiltins
import SwiftUI

/// One device-to-device migration. Public presets remain in Advanced settings.
struct KeyTransferView: View {
    let accounts: AccountStore
    @State private var sender = KeyTransferSender()
    @State private var receiver = KeyTransferReceiver()
    @State private var preparing = false
    @State private var preparation: Task<Void, Never>?
    @State private var scanning = false
    @State private var scannedCode: String?
    @State private var failure: String?
    @State private var summary: String?
    @State private var pairingImage: (code: String, image: UIImage)?
    @State private var host = ""
    @Environment(\.scenePhase) private var phase
    private let addresses = KeyTransferChannel.addresses()

    var body: some View {
        Form {
            #if targetEnvironment(macCatalyst)
            Section {
                Text("Your settings, systems, topics, files, notes, recordings and API keys — together.")
                if let pairingImage, sender.phase != .connected {
                    // One fixed square: the code swaps, pauses and returns without moving the form.
                    let live = sender.phase == .showing && !preparing
                    VStack(spacing: 8) {
                        ZStack {
                            Image(uiImage: pairingImage.image).resizable().interpolation(.none).scaledToFit()
                                .id(pairingImage.code).transition(.opacity)
                                .blur(radius: live ? 0 : 10).opacity(live ? 1 : 0.3)
                                .accessibilityLabel("Listen setup pairing code").accessibilityHidden(!live)
                            if preparing || sender.phase == .starting { ProgressView() }
                            else if !live {
                                Button("Show a new code", systemImage: "arrow.clockwise") { prepare() }
                                    .listenPrimaryAction().disabled(host.isEmpty)
                            }
                        }
                        .padding(12).background(.white)
                        ProgressView(timerInterval: sender.renewal ?? Date.distantPast...Date.distantPast, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                            .tint(.secondary).opacity(live ? 1 : 0)
                            .accessibilityLabel("Time until the code renews itself")
                    }
                    .frame(maxWidth: 320)
                } else if preparing || sender.phase == .starting { ProgressView("Preparing your setup…") }
                else if sender.phase == .idle || sender.phase == .lapsed {
                    Button(sender.phase == .lapsed ? "Show a new code" : "Show transfer code", systemImage: "qrcode") { prepare() }
                        .listenPrimaryAction().disabled(host.isEmpty)
                }
                if let summary { Text(summary).font(.footnote).foregroundStyle(.secondary) }
                Text(sender.status).foregroundStyle(.secondary)
                if let verification = sender.verification {
                    Text(verification).font(.largeTitle.monospacedDigit())
                    Text("Does this code match your iPhone?").font(.subheadline)
                    Button("Copy everything to iPhone") { sender.approve() }.listenPrimaryAction()
                        .disabled(sender.progress != nil)
                }
                if let progress = sender.progress { ProgressView(value: progress) }
                if sender.code != nil { Button("Cancel", role: .cancel) { cancel() } }
            } header: { Text("Move to iPhone") } footer: {
                Text("On your iPhone, open Listen → Settings → Copy from Mac. Keep both apps open on the same network. The Mac keeps its setup.")
            }
            if addresses.count > 1 {
                Section {
                    DisclosureGroup("Network options") {
                        Picker("Mac address", selection: $host) { ForEach(addresses, id: \.self) { Text($0).tag($0) } }
                    }
                }
            }
            #else
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Copy your Listen setup").font(.headline)
                    Button { scanning = true } label: {
                        Label("Scan Mac code", systemImage: "qrcode.viewfinder")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .listenPrimaryAction()
                    .controlSize(.large)
                    .disabled(receiver.verification != nil || scanning)
                    .accessibilityIdentifier("transfer.scan")
                    Text("Open Listen on your Mac, then Settings → Transfer to iPhone.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
            }
            Section {
                Text(receiver.status).foregroundStyle(.secondary)
                if let verification = receiver.verification {
                    Text(verification).font(.largeTitle.monospacedDigit())
                        .minimumScaleFactor(0.7).lineLimit(1)
                        .accessibilityLabel("Verification code: \(verification)")
                }
                if let progress = receiver.progress { ProgressView(value: progress) }
                if receiver.verification != nil { Button("Cancel", role: .cancel) { receiver.cancel() } }
            } footer: {
                Text("Scan the code in Listen on your Mac and approve there. This device takes over the Mac setup; its previous topics, files and settings are backed up first. Keep both apps open on the same network.")
            }
            #endif
            Section {
                Text("ChatGPT and GitHub need a separate sign-in on this device. Router pairing and tool-service credentials are device-specific and must be connected again.").font(.footnote).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }
        .navigationTitle("Transfer setup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if host.isEmpty { host = addresses.first ?? "" } }
        .onChange(of: host) { _, _ in pairingImage = nil; sender.cancel() }
        .task(id: sender.code) {
            guard let code = sender.code, pairingImage?.code != code else { return }
            // Keep QR rasterization out of body updates and off the UI thread. The code
            // on screen stays until its successor is drawn, then the two cross-fade.
            let image = await Task.detached(priority: .userInitiated) { Self.qr(code) }.value
            guard !Task.isCancelled, sender.code == code, sender.phase == .showing else { return }
            withAnimation(.easeInOut(duration: 0.35)) { pairingImage = image.map { (code, $0) } }
        }
        .onChange(of: sender.phase) { _, phase in if phase == .idle || phase == .connected { pairingImage = nil } }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            if let code = scannedCode {
                scannedCode = nil
                receiver.scan(code, copySetup: true) {
                    accounts.name = UserDefaults.standard.string(forKey: "accountName") ?? ""
                    for connector in Connector.allCases { accounts.refresh(connector) }
                }
            }
        }) { QRScanner { scannedCode = $0 } }
        .onChange(of: phase) { _, phase in if phase == .background { cancel() } }
        .onDisappear { cancel() }
    }

    private func prepare() {
        preparing = true; failure = nil
        preparation = Task {
            do {
                let topics = TopicStore()
                if !FileManager.default.fileExists(atPath: TopicStore.defaultFile.path) { topics.select(topics.selected) }
                let systems = SystemStore()
                guard systems.storageProblem == nil else { throw KeyTransferFailure.storage }
                _ = SystemConfig.load()
                let preferences = DeviceSetupMigration.preferences(), runs = RunRecorder.runs()
                let inventory = Task.detached(priority: .userInitiated) {
                    try DeviceSetupMigration.prepare(support: .applicationSupportDirectory, runs: runs, preferences: preferences)
                }
                let plan = try await withTaskCancellationHandler { try await inventory.value } onCancel: { inventory.cancel() }
                try Task.checkCancellation()
                summary = "\(topics.topics.count) topics · \(systems.systems.count) systems · \(ByteCountFormatter.string(fromByteCount: plan.manifest.bytes, countStyle: .file))"
                let providers = Set(TransferAPI.allCases)
                try sender.start(host: host, providers: providers, setup: plan)
            } catch {
                pairingImage = nil
                if !Task.isCancelled { failure = "The setup could not be prepared. Check that the stored topics, systems and files are readable." }
            }
            preparing = false
        }
    }
    private func cancel() { preparation?.cancel(); preparation = nil; preparing = false; pairingImage = nil; sender.cancel(); receiver.cancel() }
    nonisolated private static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
