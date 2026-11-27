#if targetEnvironment(macCatalyst)
import Foundation
import Darwin
import UIKit

@MainActor enum ListenCLI {
    private static var controller: CLIController?
    private static var launched = false
    private static var exitIsPending = false

    static func run() {
        // SDK diagnostics and legacy print calls belong to stderr. Keep a separate stdout
        // descriptor for our contract, so --json remains parseable one event per line.
        let descriptor = Darwin.dup(STDOUT_FILENO)
        guard descriptor >= 0 else { exit(1) }
        _ = Darwin.dup2(STDERR_FILENO, STDOUT_FILENO)
        Darwin.signal(SIGPIPE, SIG_IGN)
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let options = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            // Refuse a competing direct recording before even registering a terminal scene.
            var lease = options.command == .listen && !options.demo ? try RecordingLease() : nil
            let instance = CLIController(options: options, output: output, lease: lease)
            lease = nil
            controller = instance
            if options.command == .listen || options.command == .interactive {
                // Catalyst's speech/model services need their normal OS registration. A delegate
                // without a window or scene boots those services without starting the SwiftUI UI.
                _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(CLILifecycle.self))
                return
            }
            try instance.start()
        } catch {
            let data = (try? CLIOutput.line(["type": "error", "message": error.localizedDescription])) ?? Data()
            try? output.write(contentsOf: data)
            exit(2)
        }
    }

    static func didLaunch() {
        guard !launched else { return }
        launched = true
        do { try controller?.start() }
        catch { controller?.fail(error) }
    }

    static func exitCleanly(_ code: Int32) {
        guard launched else { exit(code) }
        guard !exitIsPending else { return }
        exitIsPending = true
        // A terminal scene has no UI to restore. Remove only our own scene sessions so the
        // next ordinary launch cannot restore a windowless terminal configuration as its GUI.
        for session in UIApplication.shared.openSessions where session.configuration.name == "Listen Terminal" {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            exit(code)
        }
    }
}

@MainActor final class CLILifecycle: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // A second command-line process may have no scene connection to wait for while the
        // GUI is open. The application registration itself is sufficient to start its engine.
        Task { @MainActor in ListenCLI.didLaunch() }
        return true
    }

    func application(_ application: UIApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool { false }
    func application(_ application: UIApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool { false }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Listen Terminal", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CLIScene.self
        return configuration
    }
}

/// Scene adoption is required by current Catalyst even when no window is wanted.
@MainActor final class CLIScene: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        Task { @MainActor in ListenCLI.didLaunch() }
    }
}

@MainActor final class CLIController {
    private let options: CLIArguments
    private let output: FileHandle
    private var model: SessionModel?
    private var signals: [DispatchSourceSignal] = []
    private var monitor: Task<Void, Never>?
    private var duration: Task<Void, Never>?
    private var input: Task<Void, Never>?
    private var stopping = false
    private var exiting = false
    private var lastPhase: SessionCore.Phase?
    private var statusCount = 0
    private var didStart = false
    private var preflightLease: RecordingLease?

    init(options: CLIArguments, output: FileHandle, lease: RecordingLease? = nil) {
        self.options = options; self.output = output; preflightLease = lease
    }

    func fail(_ error: any Error) {
        emit(["type": "error", "message": error.localizedDescription], human: error.localizedDescription)
        ListenCLI.exitCleanly(2)
    }

    func start() throws {
        switch options.command {
        case .help: emit(["type": "help", "text": CLIArguments.help], human: CLIArguments.help); exit(0)
        case .paths: paths(); exit(0)
        case .topics: topics(); exit(0)
        case .recordings: try recordings(); exit(0)
        case .show: try show(options.recording!); exit(0)
        case .interactive, .listen:
            Migration.run()
            model = SessionModel(interface: .terminal, lease: preflightLease)
            preflightLease = nil
            model?.onEvent = { [weak self] event in self?.heard(event) }
            installSignals()
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    self?.observe()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if options.command == .interactive {
                emit(["type": "ready", "demo": options.demo], human: "Listen terminal\(options.demo ? " · demo, no microphone or models" : "")\nType help for commands. Audio starts only after start.")
                topics()
                readInput()
            } else {
                try begin(options.topic)
                if isatty(STDIN_FILENO) != 0 { readInput() }
            }
        }
    }

    private func paths() {
        let fields = ["type": "paths", "topics": TopicStore.defaultFile.path, "systems": SystemStore.defaultFile.path,
                      "recordings": RunRecorder.folder.path, "recording_lock": RecordingLease.file.path]
        emit(fields, human: fields.keys.sorted().filter { $0 != "type" }.map { "\($0): \(fields[$0]!)" }.joined(separator: "\n"))
    }

    private func topics() {
        let store = TopicStore()
        for topic in store.topics {
            emit(["type": "topic", "id": topic.id.uuidString, "name": topic.name, "language": topic.language.rawValue,
                  "system": topic.system ?? ListenSystem.defaultID, "selected": store.selectedID == topic.id,
                  "archived": topic.archived, "evaluation": topic.evaluation],
                 human: "\(store.selectedID == topic.id ? "*" : " ") \(topic.id.uuidString)  \(topic.name) [\(topic.language.rawValue)]\(topic.archived ? " · archived" : "")")
        }
    }

    private func recordings() throws {
        let store = TopicStore()
        let topic = try options.topic.map { try CLICatalog.topic($0, in: store) }
        for folder in RunRecorder.runs().reversed() {
            guard let meta = TopicExport.meta(folder) else { continue }
            if let topic {
                if let id = meta["topic_id"] as? String { guard id == topic.id.uuidString else { continue } }
                else { guard meta["topic"] as? String == topic.name else { continue } }
            }
            let seconds = (meta["audio_seconds"] as? NSNumber)?.doubleValue ?? 0
            let name = meta["topic"] as? String ?? ""
            emit(["type": "recording", "id": folder.lastPathComponent, "path": folder.path,
                  "topic": name, "seconds": seconds, "language": meta["language"] as? String ?? ""],
                 human: "\(folder.lastPathComponent)  \(name) · \(Int(seconds)) s\n  \(folder.path)")
        }
    }

    private func show(_ selector: String) throws {
        let folder = try CLICatalog.recording(selector, among: RunRecorder.runs())
        let reading = try ConversationFile.read(folder)
        emit(["type": "recording_opened", "id": folder.lastPathComponent, "topic": reading.topic, "path": folder.path],
             human: "\(folder.lastPathComponent) · \(reading.topic)")
        for sentence in reading.sentences {
            emit(["type": "transcript", "id": sentence.id, "final": true, "text": sentence.text,
                  "voice": sentence.voice.map { $0 as Any } ?? NSNull(), "start_seconds": sentence.start, "end_seconds": sentence.end],
                 human: "[#\(sentence.id) · \(sentence.voice.map { "voice \($0)" } ?? "unknown")] \(sentence.text)")
        }
        for block in reading.blocks {
            guard let card = block.cards.last else { continue }
            emit(["type": "card", "id": card.id, "block": block.block, "versions": block.cards.count, "text": card.text],
                 human: "\n[Card \(card.id) · block \(block.block)]\n\(card.text)")
        }
    }

    private func begin(_ selector: String?) throws {
        guard let model else { return }
        guard model.core.phase == .idle || model.core.phase == .review else { throw CLIError(message: "Stop the current conversation before starting another.") }
        guard !model.noteIsPending else { throw CLIError(message: "The previous topic note is still being written. Wait for note_saved.") }
        let topic = try CLICatalog.topic(selector, in: TopicStore())
        if AudioCapture.scriptedFile != nil, !topic.evaluation {
            throw CLIError(message: "Scripted CLI measurements require an evaluation topic; an owner's topic is never used.")
        }
        if model.core.phase == .review { model.send(.done) }
        didStart = false
        model.start(topic)
        if let failure = model.startFailure { throw CLIError(message: failure) }
        model.assistant?.onReply = { [weak self] text in
            self?.emit(["type": "assistant_reply", "text": text], human: "\n\(text)\n")
        }
        model.assistant?.onAuthorization = { [weak self] request in
            self?.emit(["type": "tool_authorization", "id": request.id.rawValue, "capability": request.capability.rawValue,
                        "arguments": String(decoding: (try? JSONEncoder().encode(request.arguments.mapValues(\.harness))) ?? Data(), as: UTF8.self)],
                       human: "Allow \(request.capability.rawValue)? Use allow \(request.id.rawValue) or deny \(request.id.rawValue).")
        }
        statusCount = 0
        emit(["type": "starting", "topic_id": topic.id.uuidString, "topic": topic.name,
              "demo": options.demo, "recording_enabled": model.isRecording],
             human: "Starting \(topic.name)\(options.demo ? " (demo; no audio is captured)" : " · microphone")…\nControls: pause, resume, ask, me <voice>, stop, quit. Ctrl-C stops cleanly.")
    }

    private func heard(_ event: ServerEvent) {
        guard !exiting else { return }
        defer {
            if event == .error(.speechProvider) { finish(code: 1) }
        }
        let object = CLIOutput.event(event)
        if options.json { emit(object); return }
        switch event {
        case .transcript(let line) where line.isFinal:
            emit(object, human: "[#\(line.segmentID) r\(line.revision) · \(line.voicePending ? "pending" : line.speaker.title)] \(line.text)")
        case .cardFinished(let id):
            if let card = model?.core.cards.first(where: { $0.id == id }) {
                emit(object, human: "\n[Card \(id) · block \(card.start.blockID ?? id)]\n\(card.text)\n")
            }
        case .state(let state, _): emit(object, human: "[\(state.rawValue)]")
        case .error(let code), .cardError(_, let code): emit(object, human: "Error: \(code.rawValue)")
        case .speakerMapping(_, let me): emit(object, human: me.map { "You: voice \($0)" } ?? "Self mapping cleared")
        default: break
        }
    }

    private func observe() {
        guard let model, !exiting else { return }
        if model.stageStatus.count < statusCount { statusCount = 0 }
        for status in model.stageStatus.dropFirst(statusCount) { emit(["type": "status", "message": status], human: status) }
        statusCount = model.stageStatus.count
        let phase = model.core.phase
        if phase != lastPhase {
            lastPhase = phase
            emit(["type": "phase", "phase": String(describing: phase)], human: "[\(String(describing: phase))]")
        }
        if phase == .listening, !didStart {
            didStart = true
            if let seconds = options.duration {
                duration = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            }
        }
        if !stopping, let error = model.captureError {
            emit(["type": "error", "message": error], human: "Capture failed: \(error)")
            finish(code: 1)
        } else if !stopping, model.microphoneDenied || model.core.notice == .microphoneDenied {
            emit(["type": "error", "message": "Microphone permission was denied. Enable Listen in System Settings > Privacy & Security > Microphone."], human: "Microphone permission was denied. Enable Listen in System Settings > Privacy & Security > Microphone.")
            finish(code: 1)
        }
    }

    private func readInput() {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine(strippingNewline: true) { continuation.yield(line) }
            continuation.finish()
        }
        input = Task { [weak self] in
            for await line in lines {
                guard let self, !self.stopping else { break }
                do { try self.command(line) }
                catch { self.emit(["type": "error", "message": error.localizedDescription], human: error.localizedDescription) }
            }
            self?.finish()
        }
    }

    private func command(_ line: String) throws {
        guard line.count <= 4096 else { throw CLIError(message: "Command is too long.") }
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard let word = parts.first else { return }
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        switch word {
        case "start": try begin(argument ?? options.topic)
        case "topics": topics()
        case "recordings": try recordings()
        case "show":
            guard let argument else { throw CLIError(message: "Use show <recording-id>.") }
            try show(argument)
        case "pause": model?.send(.pause)
        case "resume": model?.send(.resume)
        case "ask":
            guard model?.assistant == nil else { throw CLIError(message: "Use say <request> in a voice topic.") }
            model?.send(.helpNow)
        case "say":
            guard let argument, let assistant = model?.assistant, assistant.ready else { throw CLIError(message: "Start a configured voice topic and use say <request> once it is ready.") }
            assistant.submit(argument)
        case "allow", "deny":
            guard let argument, let assistant = model?.assistant,
                  let request = assistant.pending.first(where: { $0.id.rawValue == argument }) else { throw CLIError(message: "Use \(word) <pending-operation-id>.") }
            assistant.decide(request, allow: word == "allow")
        case "shorter", "explain", "deeper", "dismiss":
            guard let argument, let id = UInt64(argument), model?.core.cards.contains(where: { $0.id == id }) == true else {
                throw CLIError(message: "Use \(word) <visible-card-id>.")
            }
            let action: CardAction = word == "shorter" ? .shorter : word == "explain" ? .explain : word == "deeper" ? .technicalDetail : .dismiss
            model?.send(.cardAction(id, action))
        case "me":
            guard let argument, let voice = UInt32(argument), voice > 0 else { throw CLIError(message: "Use me <voice-number>. This is a session label, not authentication.") }
            model?.send(.thisIsMe(voice: voice))
        case "stop": stopConversation()
        case "quit", "exit": finish()
        case "status":
            if let model { emit(["type": "status", "phase": String(describing: model.core.phase), "topic": model.topicName,
                                "frames": model.capturedFrames, "note_pending": model.noteIsPending],
                               human: "\(String(describing: model.core.phase)) · \(model.topicName) · \(model.capturedFrames) frames") }
        case "help": emit(["type": "help", "text": CLIArguments.help], human: CLIArguments.help)
        default: throw CLIError(message: "Unknown terminal command. Type help. Transcript and model text are never commands.")
        }
    }

    private func stopConversation() {
        guard let model else { return }
        model.stopAndSave()
        duration?.cancel(); duration = nil
        if let run = model.recordedTo { emit(["type": "recording_saved", "path": run.path], human: "Recording saved: \(run.path)") }
    }

    private func installSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.stopping { ListenCLI.exitCleanly(130); return }
                    self.finish()
                }
            }
            source.resume()
            signals.append(source)
        }
    }

    private func finish(code: Int32 = 0) {
        guard !stopping else { return }
        stopping = true
        stopConversation()
        Task { [weak self] in
            guard let self else { return }
            // The normal session's summary/minutes writes the same topic note as the GUI. Bound
            // terminal shutdown; a slow provider must not hold Ctrl-C forever.
            let deadline = ContinuousClock.now + .seconds(30)
            while self.model?.noteIsPending == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let note = self.model?.savedNote {
                self.emit(["type": "note_saved", "path": note.path, "summary_pending": self.model?.noteIsPending == true],
                          human: "Topic note saved: \(note.path)\(self.model?.noteIsPending == true ? " (summary did not finish before exit)" : "")")
            }
            self.emit(["type": "finished", "code": code, "frames": self.model?.capturedFrames ?? 0,
                       "frames_after_stop": self.model?.framesAfterStop ?? 0], human: "Stopped.")
            self.exiting = true
            ListenCLI.exitCleanly(code)
        }
    }

    private func emit(_ object: [String: Any], human: String? = nil) {
        do {
            if options.json { try output.write(contentsOf: CLIOutput.line(object)) }
            else if let human { try output.write(contentsOf: Data((CLIOutput.safe(human) + "\n").utf8)) }
        } catch {
            // A closed output pipe must end recording just like Ctrl-C.
            if model != nil, !stopping { finish(code: 0) }
            else { ListenCLI.exitCleanly(0) }
        }
    }
}
#endif
