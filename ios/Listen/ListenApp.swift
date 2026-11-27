import SwiftUI

struct ListenApp: App {
    init() {
        Migration.run()
        // Remembers where a development build keeps its runs, so the history also shows them
        // when the app is started without that argument.
        _ = RunRecorder.searchFolders
        #if DEBUG
        SelfTest.runIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

#if DEBUG
/// `LISTEN_SELFTEST=keychain` in the environment: store, read and remove a
/// secret, print what happened and quit. For checking a build's signing.
/// `LISTEN_SELFTEST=history LISTEN_HISTORY_RUN=<folder>` prints visible/raw card
/// counts for a recorded run without changing it.
enum SelfTest {
    @MainActor
    static func runIfAsked() {
        if ProcessInfo.processInfo.environment["LISTEN_SELFTEST"] == "material" {
            // Explicit local import for development evaluations; no model text is interpreted.
            guard let raw = ProcessInfo.processInfo.environment["LISTEN_TOPIC_ID"], let id = UUID(uuidString: raw),
                  TopicStore().topics.contains(where: { $0.id == id }),
                  let path = ProcessInfo.processInfo.environment["LISTEN_MATERIAL_FILE"] else {
                print("Material import: an existing topic and an explicit file or folder are required")
                exit(1)
            }
            let material = TopicMaterial(topic: id)
            let copied = material.add([URL(fileURLWithPath: path)])
            print("Material import: \(copied) added, \(material.index.passages.count) passages, \(material.index.preparedHints?.count ?? 0) prepared hints")
            exit(copied > 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["LISTEN_SELFTEST"] == "jev" {
            Task { @MainActor in
                guard let key = Keychain.get(Connector.jev.rawValue) else {
                    print("Jev check: no key saved on this device")
                    exit(1)
                }
                let existing = ProcessInfo.processInfo.environment["LISTEN_JEV_PROBE"] == "existing"
                let context = DirectedContext(revision: 1, trigger: 1,
                    evidence: [.init(id: 1, text: "What is backpressure in a message queue?", who: "unknown")],
                    blocks: existing ? [.init(id: 7, text: "Backpressure\nA producer waits until the consumer has capacity.", checked: true)] : [])
                let began = Date()
                do {
                    let questions = try JSONSerialization.data(withJSONObject: JevClient.questions(for: context))
                    var response = ""
                    var usage: TokenUsage?
                    for try await chunk in JevClient(key: key).stream(model: JevClient.model,
                        system: String(decoding: questions, as: UTF8.self), user: JevClient.state(for: context), maxTokens: 0) {
                        if case .text(let text) = chunk { response += text }
                        if case .usage(let value) = chunk { usage = value }
                    }
                    let decision = try JevClient.read(Data(response.utf8), allowed: Set(context.blocks.map(\.id)))
                    let result: [String: Any] = ["model": JevClient.model, "seconds": Date().timeIntervalSince(began),
                        "usefulness": decision.usefulness, "research": decision.research,
                        "target": decision.target.map { String($0) } ?? "new", "target_probability": decision.targetProbability,
                        "reported_input_tokens": usage?.input as Any? ?? NSNull(), "reported_output_tokens": usage?.output as Any? ?? NSNull()]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                    exit(0)
                } catch {
                    print("Jev check:", (error as? any ModelFailure)?.reason ?? "unavailable")
                    exit(1)
                }
            }
            return
        }
        if ProcessInfo.processInfo.environment["LISTEN_SELFTEST"] == "history",
           let path = ProcessInfo.processInfo.environment["LISTEN_HISTORY_RUN"] {
            let opened = Date()
            let timeline = RunTimeline(folder: URL(fileURLWithPath: path))
            if ProcessInfo.processInfo.environment["LISTEN_HISTORY_PERF"] == "1" {
                let loaded = Date()
                let moments = (0..<1000).map { Double(($0 * 137) % 1000) / 999 * timeline.length }
                var reference = 0
                for moment in moments {
                    let snapshot = timeline.through(moment)
                    reference += snapshot.requests.count + snapshot.openNow + snapshot.cards.count
                }
                let projected = Date()
                var cached = 0
                for moment in moments {
                    let snapshot = timeline.statistics(at: moment)
                    cached += snapshot.requests + snapshot.openNow + snapshot.cardEvents
                }
                let finished = Date()
                let result: [String: Any] = ["run": URL(fileURLWithPath: path).lastPathComponent,
                    "lookups": moments.count, "load_ms": loaded.timeIntervalSince(opened) * 1000,
                    "projection_ms": projected.timeIntervalSince(loaded) * 1000,
                    "prepared_statistics_ms": finished.timeIntervalSince(projected) * 1000,
                    "matching_counts": reference == cached,
                    "note": "Local debug-build data lookup, not rendering FPS or acoustic latency."]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                exit(reference == cached ? 0 : 1)
            }
            let blocks = timeline.blocks(at: .greatestFiniteMagnitude)
            let result: [String: Any] = [
                "run": URL(fileURLWithPath: path).lastPathComponent,
                "blocks": blocks.map { block -> [String: Any] in
                    ["block": block.id, "raw_versions": block.versions.count,
                     "visible_pages": block.pages.count, "current": block.current.text,
                     "visible_card_ids": block.pages.map(\.id)]
                },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        }
        guard ProcessInfo.processInfo.environment["LISTEN_SELFTEST"] == "keychain" else { return }
        let account = "selftest-\(UUID().uuidString)"
        do {
            try Keychain.set("secret", for: account)
            print("keychain set: ok, read back:", Keychain.get(account) == "secret")
            Keychain.remove(account)
        } catch let failure as Keychain.Failure {
            print("keychain set failed:", failure.status)
        } catch {
            print("keychain set failed:", error)
        }
        exit(0)
    }
}
#endif

struct RootView: View {
    @State private var model = SessionModel()
    @State private var topics: TopicStore
    @State private var accounts = AccountStore()
    @State private var showsTopics = false
    @State private var appliedStartupArguments = false
    /// Why a .listen file could not be opened.
    @State private var openFailure: String?
    @State private var routerProposal: RouterLink?
    @State private var setupProposal: SetupProposal?
    #if DEBUG
    @State private var voiceChoiceFixture: AssistantVoicePickerFixture?
    @State private var spokenConversationFixture: SpokenConversationFixture?
    @State private var assistantPresentationFixture: AssistantPresentationFixture?
    #endif
    @Namespace private var orbSpace
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        _voiceChoiceFixture = State(initialValue: AssistantVoicePickerFixture.requested())
        _spokenConversationFixture = State(initialValue: SpokenConversationFixture.requested())
        _assistantPresentationFixture = State(initialValue: AssistantPresentationFixture.requested())
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-topicUXFixture"), arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            // A separate, explicitly selected test store survives test relaunches.
            // Normal topics and account data are never replaced by a UI fixture.
            let root = URL.temporaryDirectory.appending(path: "ListenTopicUITests/" + id.uuidString)
            if arguments.contains("-topicUXBlockedStore") {
                let blocked = root.appending(path: "blocked", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
                _topics = State(initialValue: TopicStore(file: blocked))
            } else {
                let file = root.appending(path: "topics.json")
                let fresh = !FileManager.default.fileExists(atPath: file.path)
                let store = TopicStore(file: file)
                if fresh, arguments.contains("-topicUXLongList") {
                    for index in 1...30 { store.upsert(Topic(name: "Synthetic seeded \(index)")) }
                }
                _topics = State(initialValue: store)
            }
        } else { _topics = State(initialValue: TopicStore()) }
        #else
        _topics = State(initialValue: TopicStore())
        #endif
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if let assistant = model.assistant, model.core.phase != .idle {
                AssistantView(model: model, assistant: assistant)
            } else {
            switch model.core.phase {
            case .idle, .starting:
                if showsTopics {
                    PrepareView(model: model, topics: topics, accounts: accounts, orbSpace: orbSpace) {
                        withAnimation(.smooth(duration: 0.6)) { showsTopics = false }
                    }
                } else {
                    StartView(model: model, accounts: accounts, topics: topics, orbSpace: orbSpace) {
                        withAnimation(.smooth(duration: 0.6)) { showsTopics = true }
                    }
                }
            case .review: ReviewView(model: model).transition(.opacity)
            default:
                // A spoken conversation shows itself inside this view (`SpokenHarnessBar`).
                ListenView(model: model).transition(.opacity)
            }
            }
        }
        // The debug timeline takes the lower half at most (its upper edge can be dragged) and
        // the app moves up into the rest: nothing is covered. It is there on every screen,
        // also on a phone.
        #if DEBUG
        .sheet(item: $voiceChoiceFixture) { $0 }
        .sheet(item: $spokenConversationFixture) { $0 }
        .sheet(item: $assistantPresentationFixture) { $0 }
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.showsTimeline {
                TimelinePanel(share: 0.5) {
                    RunTimelineView(
                        initial: model.recordingInto, live: model.recordingInto,
                        onClose: { withAnimation(.smooth(duration: 0.3)) { model.showsTimeline = false } },
                        onReplay: { run in
                            model.showsTimeline = false
                            model.replaying = run
                        })
                }
                .clipShape(.rect(topLeadingRadius: 18, topTrailingRadius: 18))
                .shadow(color: .black.opacity(0.35), radius: 18, y: -4)
                .transition(.move(edge: .bottom))
            }
        }
        .fullScreenCover(item: Binding(get: { model.replaying.map(Replay.init) }, set: { model.replaying = $0?.folder })) { replay in
            ReplayView(folder: replay.folder) { name, blocks in
                // The run's own topic when it still exists, otherwise the one that is selected.
                let topic = topics.topics.first { $0.name == name } ?? topics.selected
                topics.select(topic)
                model.carryOn(in: topic, with: blocks)
            }
        }
        // A .listen file opened from the Finder or Files: its conversation is replayed.
        .onOpenURL { url in
            if url.scheme == "listen" {
                if url.host == "setup" {
                    guard model.core.phase == .idle || model.core.phase == .review else { openFailure = "Stop listening before importing a setup."; return }
                    do { setupProposal = SetupProposal(package: try SetupPackage.read(link: url)) }
                    catch { openFailure = error.localizedDescription }
                    return
                }
                do { routerProposal = try RouterLink.parse(url.absoluteString) }
                catch { openFailure = error.localizedDescription }
                return
            }
            if url.pathExtension.lowercased() == "listen-setup" {
                guard model.core.phase == .idle || model.core.phase == .review else { openFailure = "Stop listening before importing a setup."; return }
                do { setupProposal = SetupProposal(package: try SetupPackage.read(file: url)) }
                catch { openFailure = error.localizedDescription }
                return
            }
            guard url.pathExtension.lowercased() == ConversationFile.fileExtension else { return }
            switch model.core.phase {
            case .idle, .review: break
            default:
                openFailure = "Stop listening first, then open the file again."
                return
            }
            do {
                model.replaying = try ConversationFile.open(url, runs: RunRecorder.runs(), into: RunRecorder.folder)
            } catch {
                openFailure = error.localizedDescription
            }
        }
        .sheet(item: $routerProposal) { RouterPairSheet(link: $0) }
        .sheet(item: $setupProposal) { SetupImportView(package: $0.package) }
        .onReceive(NotificationCenter.default.publisher(for: .listenSetupInstalled)) { _ in
            topics = TopicStore()
            accounts.name = UserDefaults.standard.string(forKey: "accountName") ?? ""
            for connector in Connector.allCases { accounts.refresh(connector) }
            RouterStore.shared.reloadAfterTransfer()
            MCPStore.shared.reloadAfterTransfer()
        }
        .alert("Could not open Listen", isPresented: Binding(get: { openFailure != nil }, set: { if !$0 { openFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openFailure ?? "")
        }
        .alert("Could not start listening", isPresented: Binding(get: { model.startFailure != nil }, set: { if !$0 { model.startFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.startFailure ?? "") }
        .onAppear {
            guard !appliedStartupArguments else { return }
            appliedStartupArguments = true
            #if DEBUG
            FrameProbe.shared.start()
            #endif
            // `-exportEvaluations`: exports topics and recordings of evaluation runs out of Listen once.
            if ProcessInfo.processInfo.arguments.contains("-exportEvaluations") {
                Task { print("[Listen] wrote \(await topics.exportEvaluations()) evaluation exports") }
            }
            // `-showTimeline`: opens with the timeline of the newest recorded run.
            if ProcessInfo.processInfo.arguments.contains("-showTimeline") { model.showsTimeline = true }
            // `-replay <run folder>`: opens straight into going through that run.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-replay"), arguments.indices.contains(index + 1) {
                model.replaying = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            }
            #if DEBUG
            if arguments.contains("-replayUXFixture") {
                let seconds = ProcessInfo.processInfo.environment["LISTEN_REPLAY_FIXTURE_SECONDS"].flatMap(Int.init) ?? 120
                if let folder = try? ReplayUXFixture.make(seconds: seconds) { model.replaying = folder }
            }
            if ProcessInfo.processInfo.arguments.contains("-measureModels") {
                Task {
                    await ModelSpeed.measureAndChoose()
                    exit(0)
                }
            }
            // Only the timings: writes model-speed.json and leaves which models are asked as it is.
            if ProcessInfo.processInfo.arguments.contains("-measureModelSpeed") {
                Task {
                    await ModelSpeed.record(ModelSpeed.measure())
                    exit(0)
                }
            }
            #endif
        }
        .onChange(of: AssistantLaunch.shared.request?.id, initial: true) { _, _ in
            guard let request = AssistantLaunch.shared.take() else { return }
            guard model.core.phase == .idle else { openFailure = "Stop the current conversation before starting another."; return }
            do {
                let topic = try AssistantLaunch.topic(request.topic, store: TopicStore(), systems: SystemStore())
                model.start(topic, spoken: true)
            } catch { openFailure = error.localizedDescription }
        }
        .animation(.smooth(duration: 0.35), value: model.core.phase == .review)
        .animation(.smooth(duration: 0.35), value: model.core.phase == .idle)
        .tint(.primary)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setForeground(phase == .active)
            if phase == .active { LocalVoice.preload(for: topics.selected) }
            // A finite debug-file evaluation must finish even if another window becomes active.
            // Ordinary microphone sessions pause visibly when the app leaves the foreground.
            if phase == .background, AudioCapture.scriptedFile == nil { model.send(.leftForeground) }
        }
        .onChange(of: topics.selectedID) { _, _ in
            if scenePhase == .active { LocalVoice.preload(for: topics.selected) }
        }
    }
}

/// A run that is open for going through it again.
struct Replay: Identifiable {
    let folder: URL
    var id: String { folder.path }
}
