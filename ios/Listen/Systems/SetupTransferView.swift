import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let listenSetup = UTType(exportedAs: "com.meowop.listen.setup", conformingTo: .json) }
extension Notification.Name { static let listenSetupInstalled = Notification.Name("ListenSetupInstalled") }
struct SetupProposal: Identifiable { let id = UUID(); let package: SetupPackage }

struct SetupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.listenSetup, .json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= SetupPackage.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SetupTransferView: View {
    @State private var topics = TopicStore()
    @State private var systems = SystemStore()
    @State private var selected: UUID?
    @State private var includeBriefing = false
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var document = SetupDocument()
    @State private var proposal: SetupProposal?
    @State private var qr: UIImage?
    @State private var link: URL?
    @State private var failure: String?
    @State private var scanning = false
    @State private var scannedCode: String?
    private var topic: Topic { topics.topics.first { $0.id == selected } ?? topics.selected }
    private func package() throws -> SetupPackage {
        guard let system = systems.system(topic.system ?? ListenSystem.defaultID) else {
            throw SystemPackageError(message: "Choose an available system before sharing this setup.")
        }
        return SetupPackage(topic: topic, system: systems.package(for: system), includeBriefing: includeBriefing)
    }

    var body: some View {
        Form {
            Section {
                Picker("Topic", selection: Binding(get: { selected ?? topics.selectedID }, set: { selected = $0; qr = nil; link = nil })) {
                    ForEach(topics.topics.filter { !$0.archived }) { Text($0.name).tag($0.id) }
                }
                Toggle("Include topic briefing", isOn: $includeBriefing).onChange(of: includeBriefing) { _, _ in qr = nil; link = nil }
                Button("Create QR code", systemImage: "qrcode") {
                    do {
                        let url = try package().link()
                        let filter = CIFilter.qrCodeGenerator()
                        filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "L"
                        guard let image = filter.outputImage,
                              let cg = CIContext().createCGImage(image.transformed(by: .init(scaleX: 8, y: 8)), from: image.extent.applying(.init(scaleX: 8, y: 8))) else {
                            throw SystemPackageError(message: "The QR code could not be generated. Share the file instead.")
                        }
                        qr = UIImage(cgImage: cg); link = url; failure = nil
                    } catch { failure = error.localizedDescription; qr = nil; link = nil }
                }
                if let qr, let link {
                    Image(uiImage: qr).resizable().interpolation(.none).scaledToFit().frame(maxWidth: 260)
                        .padding(12).background(.white).accessibilityLabel("QR code for this topic setup")
                    ShareLink("Share setup link", item: link)
                    Text("Scan with the receiving device's Camera, or open the link. Listen shows a preview before importing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Export setup file…", systemImage: "square.and.arrow.up") {
                    do { document = SetupDocument(data: try package().data()); exportsFile = true; failure = nil }
                    catch { failure = error.localizedDescription }
                }
            } header: { Text("Share a setup") } footer: {
                Text("Includes the system's instructions, model preferences, topic links and repository names. Review these before sharing. Briefing is optional. Audio, material files, notes, accounts, tokens, tool grants and router pairing are excluded. Large custom definitions use the file rather than QR.")
            }
            Section {
                Button("Scan setup code", systemImage: "qrcode.viewfinder") { scanning = true }
                Button("Import setup file…", systemImage: "square.and.arrow.down") { importsFile = true }
                Button("Paste setup link or JSON", systemImage: "doc.on.clipboard") {
                    do {
                        let text = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let package: SetupPackage
                        if text.hasPrefix("listen:"), let url = URL(string: text) { package = try SetupPackage.read(link: url) }
                        else { package = try SetupPackage.read(Data(text.utf8)) }
                        proposal = SetupProposal(package: package); failure = nil
                    } catch { failure = error.localizedDescription }
                }
            } header: { Text("Bring a setup here") } footer: {
                Text("A new topic and a separate system copy are added only after review. Connect your accounts and authorize local tool bindings on this device afterwards. Import never starts listening.")
            }
            if let failure { Section { Text(failure).foregroundStyle(.orange).textSelection(.enabled) } }
        }
        .navigationTitle("Move a setup")
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.listenSetup, .json]) { result in
            do { proposal = SetupProposal(package: try SetupPackage.read(file: result.get())) }
            catch { failure = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportsFile, document: document, contentType: .listenSetup, defaultFilename: "Listen setup") { result in
            if case .failure(let error) = result { failure = error.localizedDescription }
        }
        .sheet(item: $proposal) { SetupImportView(package: $0.package) }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            guard let value = scannedCode else { return }; scannedCode = nil
            do {
                guard let url = URL(string: value) else { throw SystemPackageError(message: "This is not a Listen setup code.") }
                proposal = SetupProposal(package: try SetupPackage.read(link: url))
            } catch { failure = error.localizedDescription }
        }) {
            QRScanner { scannedCode = $0 }
        }
    }
}

struct SetupImportView: View {
    let package: SetupPackage
    @State private var systems = SystemStore()
    @State private var topics = TopicStore()
    @State private var installed: ListenSystem?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("New topic") {
                    LabeledContent("Name", value: package.topic.name)
                    LabeledContent("Language", value: package.topic.language.rawValue)
                    LabeledContent("System", value: package.system.system.name)
                    if !package.topic.notes.isEmpty { Text(package.topic.notes).textSelection(.enabled) }
                    ForEach(package.topic.links, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    ForEach(package.topic.repositories, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
                Section("System definition") {
                    Text(package.system.system.summary)
                    let status = SystemCapabilities.current().status(of: package.system.system)
                    Label(status.text, systemImage: status.ready ? "checkmark.circle" : "exclamationmark.triangle")
                    ScrollView(.horizontal) { SystemGraph(system: package.system.system).padding(.vertical, 8) }
                    NavigationLink("Review full system JSON") {
                        ScrollView { Text((try? package.system.data()).map { String(decoding: $0, as: UTF8.self) } ?? "Unavailable").font(.caption.monospaced()).textSelection(.enabled).padding() }
                            .navigationTitle("System definition")
                    }
                }
                Section {
                    Text("Existing topics and systems are preserved. This adds a new topic and system copy. Accounts, credentials, material files and tool grants are not transferred. Instructions are configuration; importing them grants no access and runs no actions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.orange) } }
            }
            .navigationTitle("Review setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add setup") {
                        do {
                            if installed == nil { installed = try systems.install(package.system) }
                            _ = try topics.installSetup(package.topic, system: installed!.id)
                            NotificationCenter.default.post(name: .listenSetupInstalled, object: nil)
                            dismiss()
                        } catch {
                            failure = installed == nil ? error.localizedDescription : "The system copy was added, but the topic could not be saved. " + error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}
