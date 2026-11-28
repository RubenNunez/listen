import Observation
import SwiftUI

/// Owns the state machine and carries out its commands with the real
/// microphone, voice and transport.
@MainActor
@Observable
final class SessionModel {
    enum Interface { case graphical, terminal }
    @ObservationIgnored private let interface: Interface
    @ObservationIgnored private var recordingLease: RecordingLease?
    /// Presentation-independent events, delivered after the shared state machine applied them.
    @ObservationIgnored var onEvent: ((ServerEvent) -> Void)?
    var startFailure: String?
    private(set) var assistant: VoiceAssistantSession?
    /// The cards of this conversation are said aloud (`VoiceAnswerSource.harness`). The
    /// answers come from the same engine as without it; `assistant` is nil then.
    private(set) var spoken: SpokenHarness?
    private var pendingNotes = 0
    var noteIsPending: Bool { pendingNotes > 0 }
    private(set) var core = SessionCore()
    /// Frames delivered by the microphone in this session.
    private(set) var capturedFrames = 0
    /// Seconds since the microphone last heard more than room noise, for the assistant's turns.
    @ObservationIgnored private var quietSeconds = 0.0
    @ObservationIgnored private var conversationActivity = ConversationActivity()
    /// Frames that arrived after Stop or Pause. Evidence for AC-03; must stay 0.
    private(set) var framesAfterStop = 0
    private(set) var captureError: String?
    /// Smoothed microphone level, 0 to 1. Drives the orb; never leaves the phone.
    private(set) var level = 0.0
    /// The shape of the sound being captured, for the orb. Never leaves the phone.
    private(set) var waveform = [Float](repeating: 0, count: Waveform.points)
    /// 0 is the calm line, towards 1 the raw signal shows through.
    @ObservationIgnored private var signalDetail = 0.0
    @ObservationIgnored private var waveformAt = Date()

    /// Per sentence, what each listening layer did. Newest last; for the debug overlay.
    private(set) var traces: [LayerTrace] = []
    /// News from the layers, such as models loading.
    private(set) var stageStatus: [String] = []

    /// Writes the running conversation to disk when the user allows it.
    @ObservationIgnored private var recorder: RunRecorder?
    @ObservationIgnored private var laidOutCards: Set<UInt64> = []
    @ObservationIgnored private var cardsInViewport: Set<UInt64> = []

    /// Geometry evidence, not a GPU paint or occlusion measurement. A hidden
    /// file evaluation can lay out cards; scene state is recorded explicitly.
    func cardLaidOut(_ id: UInt64, frame: CGRect, viewport: CGRect, hasBody: Bool, sceneActive: Bool) {
        guard hasBody, !frame.isEmpty, !viewport.isEmpty, let recorder else { return }
        let fields: [String: Any] = ["card": id, "scene_active": sceneActive,
                                     "height": frame.height, "viewport_height": viewport.height]
        if laidOutCards.insert(id).inserted { recorder.log("card_layout", fields) }
        if frame.intersects(viewport), cardsInViewport.insert(id).inserted {
            recorder.log("card_in_viewport", fields)
        }
    }
    /// Where the last conversation was recorded, for the review screen.
    private(set) var recordedTo: URL?
    /// The timeline of recorded runs is open: a panel over the lower half of the window.
    var showsTimeline = false
    /// The folder the running conversation is being recorded into, for the live timeline.
    var recordingInto: URL? { recorder?.directory }

    var isRecording: Bool { recorder != nil }

    private func record(_ trace: LayerTrace) {
        recorder?.log(trace)
        if let index = traces.firstIndex(where: { $0.id == trace.id }) {
            traces[index] = trace
        } else {
            traces.append(trace)
            if traces.count > 30 { traces.removeFirst(traces.count - 30) }
        }
    }

    /// The user's switch on the start screen. Off means no audio session at all.
    private(set) var microphoneOn = UserDefaults.standard.bool(forKey: "microphoneOn")
    private(set) var microphoneDenied = false
    private(set) var conversationMicrophoneMuted = false

    func setConversationMicrophoneMuted(_ muted: Bool) {
        guard conversationMicrophoneMuted != muted else { return }
        // Close ingestion first. Queued callbacks cannot become turns or recordings.
        if muted { conversationMicrophoneMuted = true; transport.setInputMuted(true) }
        do {
            try capture.setMuted(muted)
            conversationMicrophoneMuted = muted
            if !muted { transport.setInputMuted(false) }
            assistant?.setMicrophoneMuted(muted)
            spoken?.setMicrophoneMuted(muted)
            conversationActivity.reset(); quietSeconds = 0; buffered.removeAll()
            level = 0; waveform = [Float](repeating: 0, count: Waveform.points)
            recorder?.setMicrophoneMuted(muted)
        } catch {
            // Fail closed, including a failed unmute. Answers and tools stay active.
            conversationMicrophoneMuted = true
            assistant?.setMicrophoneMuted(true)
            spoken?.setMicrophoneMuted(true)
            transport.setInputMuted(true)
            try? capture.setMuted(true)
            recorder?.setMicrophoneMuted(true)
            captureError = error.localizedDescription
        }
    }
    /// The system the current conversation runs with.
    private(set) var runningSystem: ListenSystem?

    @ObservationIgnored private var coreWantsCapture = false
    /// The sides of the frame being delivered, while an app's sound is mixed in.
    @ObservationIgnored private var frameSide: (mine: Float, theirs: Float)?
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var transport: any Transport
    @ObservationIgnored private let injectedTransport: Bool
    @ObservationIgnored private let capture: AudioCapture
    @ObservationIgnored private let voice: ReadAloud?
    @ObservationIgnored private var audioSeq: UInt32 = 0
    @ObservationIgnored private var buffered: [AudioFrame] = []
    @ObservationIgnored private var reconnectTimeout: Task<Void, Never>?

    /// About five seconds of audio while the socket is down.
    private static let bufferFrames = 50

    /// What `start` builds a conversation from besides this session: the topic's system, the
    /// roles that answer, the recogniser's transport and the voice. The app takes them from the
    /// saved systems, the accounts, the on-device recogniser and the voice catalogue. A test
    /// gives its own, and `start` wires them exactly as it wires the app's; with parts given,
    /// no microphone is asked for or opened, nothing is recorded and no note is written.
    struct Parts {
        var system: (Topic) -> (SystemConfig.Loaded, ListenSystem)
        var answers: (Topic, SystemConfig.Loaded, ListenSystem, SpokenAnswerForm?) -> AnswerEngine?
        var transport: (Topic, AnswerEngine?) -> any Transport
        var speaker: (VoiceAssistantConfiguration) -> any AssistantSpeechOutput
    }
    @ObservationIgnored private let parts: Parts?

    init(transport: (any Transport)? = nil, interface: Interface = .graphical, lease: RecordingLease? = nil, parts: Parts? = nil) {
        self.parts = parts
        self.interface = interface
        recordingLease = lease
        capture = AudioCapture()
        voice = interface == .graphical ? ReadAloud() : nil
        if interface == .terminal { microphoneOn = false }
        injectedTransport = transport != nil
        self.transport = transport ?? DemoTransport()
        attach(self.transport)
        capture.onFrame = { [weak self] pcm in self?.captured(pcm) }
        capture.onWaveform = { [weak self] shape in
            guard let self, !self.conversationMicrophoneMuted, shape.count == Waveform.points * 2 else { return }
            // While someone keeps speaking the line gains detail, step by step,
            // from the calm shape towards the raw signal; in a pause it calms again.
            let now = Date()
            let elapsed = min(now.timeIntervalSince(self.waveformAt), 0.3)
            self.waveformAt = now
            self.signalDetail = self.isSpeechLikely
                ? min(0.75, self.signalDetail + elapsed / 4) : max(0, self.signalDetail - elapsed / 1.2)
            let detail = Float(self.signalDetail)
            // Publish one complete visual frame instead of notifying observers
            // separately for every sample. The signal math stays the same.
            var next = self.waveform
            for index in 0..<Waveform.points {
                let target = shape[index] * (1 - detail) + shape[index + Waveform.points] * detail
                next[index] = self.waveform[index] * 0.3 + target * 0.7
            }
            self.waveform = next
        }
        capture.onInterrupted = { [weak self] reason in self?.send(.audioInterrupted(reason)) }
        if AudioCapture.scriptedFile != nil, interface == .graphical {
            // A scripted conversation: start by itself, end a while after the last sound
            // so late cards still arrive, and quit once the run is written.
            capture.onScriptEnded = { [weak self] in
                Task {
                    try? await Task.sleep(for: .seconds(45))
                    self?.send(.stop)
                    try? await Task.sleep(for: .seconds(20))
                    exit(0)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                // The scripted talk goes into a topic of its own in the user's list, so it can be
                // opened and looked at afterwards like any other.
                let store = TopicStore()
                let chosen = store.selectedID
                // An isolated evaluation must not clear the owner's existing scripted notes.
                let evaluationTopic = ProcessInfo.processInfo.environment["LISTEN_EVAL_TOPIC"] ?? "Scripted"
                let environment = ProcessInfo.processInfo.environment
                if let existing = store.topics.first(where: { $0.name == evaluationTopic }), !existing.evaluation {
                    // Its memory would be cleared below: one of the owner's own topics is never used.
                    print("[Listen] \(evaluationTopic) is one of the owner's topics, not an evaluation; nothing was run")
                    exit(2)
                }
                var topic = store.topics.first { $0.name == evaluationTopic } ?? Topic(name: evaluationTopic)
                topic.notes = environment["LISTEN_NOTES"] ?? ""
                // Marked, so it can be exported with its runs later (TopicExport).
                topic.evaluation = true
                // `LISTEN_LANGUAGE=en` for a recording in English.
                topic.language = environment["LISTEN_LANGUAGE"].flatMap(Language.init(rawValue:)) ?? .de
                // `LISTEN_SYSTEM=<id>`: the replay runs with that system.
                if let id = environment["LISTEN_SYSTEM"] { topic.system = id }
                // `LISTEN_EVAL_FROM_TOPIC=<name>`: a recorded conversation is heard again with what its
                // topic held, briefing, files and instructions, copied and only read from the original.
                if let name = environment["LISTEN_EVAL_FROM_TOPIC"], let original = store.topics.first(where: { $0.name == name }),
                   original.id != topic.id {
                    if environment["LISTEN_NOTES"] == nil { topic.notes = original.notes }
                    if environment["LISTEN_LANGUAGE"] == nil { topic.language = original.language }
                    topic.links = original.links
                    topic.repositories = original.repositories
                    let from = TopicSandbox(topic: original.id).folder, to = TopicSandbox(topic: topic.id).folder
                    let files = FileManager.default
                    try? files.createDirectory(at: to, withIntermediateDirectories: true)
                    for item in ["material", "instructions.md"] where files.fileExists(atPath: from.appending(path: item).path) {
                        try? files.removeItem(at: to.appending(path: item))
                        try? files.copyItem(at: from.appending(path: item), to: to.appending(path: item))
                    }
                }
                store.upsert(topic)
                // Each scripted run starts without the memory of the last one, so runs can be compared.
                TopicSandbox(topic: topic.id).clearNotes()
                if let before = store.topics.first(where: { $0.id == chosen }) { store.select(before) }
                self?.start(topic)
                // A scripted run is watched for what the harness does: its timeline is open from the start.
                // `LISTEN_EVAL_TIMELINE=0` keeps it closed: a long replay then measures the engine, not the
                // drawing (an open timeline slowed a 34-minute replay to half speed, 17 November 2026).
                if ProcessInfo.processInfo.environment["LISTEN_EVAL_TIMELINE"] != "0" { self?.showsTimeline = true }
            }
        }
        capture.onHeadphonesChanged = { [weak self] on in self?.send(.headphonesChanged(on)) }
        capture.onSide = { [weak self] mine, theirs in self?.frameSide = (mine, theirs) }
        voice?.onFinished = { [weak self] in self?.send(.speechFinished) }
        capture.onInterrupted = { [weak self] reason in
            guard let self else { return }
            if self.core.phase == .idle {
                // Ambient listening lost the microphone: switch off, the user decides.
                self.microphoneOn = false
                self.syncCapture()
            } else {
                self.send(.audioInterrupted(reason))
            }
        }
        if microphoneOn, !AudioCapture.hasPermission { microphoneOn = false }
    }

    /// Loud enough that someone is probably speaking. A level threshold, not
    /// speech recognition.
    var isSpeechLikely: Bool { level > 0.12 }

    /// Names the user gave to voices in this conversation. Kept in memory only.
    private(set) var voiceNames: [UInt32: String] = [:]

    /// Voices the user named by hand; the harness does not overwrite those.
    @ObservationIgnored private var namedByHand: Set<UInt32> = []

    func name(_ voice: UInt32, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceNames[voice] = trimmed.isEmpty ? nil : String(trimmed.prefix(24))
        namedByHand.insert(voice)
    }

    /// Names the harness worked out from the conversation.
    private func found(_ names: [UInt32: String]) {
        for (voice, name) in names where !namedByHand.contains(voice) { voiceNames[voice] = name }
    }

    struct Participant: Identifiable, Equatable {
        let id: UInt32
        var label: SpeakerLabel
        var isSpeaking: Bool
        /// Given by the user; nil until they assign one.
        var name: String?

        var title: String { label == .me ? "You" : (name ?? label.title) }
    }

    /// Everyone heard so far, in order of first appearance. The one who spoke
    /// last is marked. Empty while speakers cannot be told apart.
    var participants: [Participant] { Self.participants(in: core, names: voiceNames) }

    static func participants(in core: SessionCore, names voiceNames: [UInt32: String]) -> [Participant] {
        var found: [Participant] = []
        var last: UInt32?
        for line in core.lines {
            guard case .speech(let segment) = line.content, let voice = segment.voice else { continue }
            // A first guess does not bring in someone new; it may still be taken back.
            if segment.voicePending, !found.contains(where: { $0.id == voice }) { continue }
            last = voice
            let label: SpeakerLabel = core.isMine(segment) ? .me : segment.speaker
            if let index = found.firstIndex(where: { $0.id == voice }) {
                if label == .me { found[index].label = .me }
            } else {
                found.append(Participant(id: voice, label: label, isSpeaking: false, name: voiceNames[voice]))
            }
        }
        if let last, let index = found.firstIndex(where: { $0.id == last }) { found[index].isSpeaking = true }
        return found
    }

    /// What is being worked out right now, for the feed. Nil when nothing is.
    var activity: String? {
        if core.cards.contains(where: { $0.status == .streaming }) { return "Working out an answer" }
        if case .speech(let segment)? = core.lines.last?.content, !segment.isFinal { return "Listening to the sentence" }
        return nil
    }

    /// Everyone who spoke in the whole conversation, for its end: the review and the topic's note.
    var everyone: [Participant] { Self.everyone(in: core.allSpeech, isMine: core.isMine, names: voiceNames) }

    /// A voice heard in only one or two sentences of a longer conversation is left out: most
    /// likely one person's voice split in two (an hour-long call showed eight voices, one of them
    /// in a single sentence; 19 November 2026). The user and named voices stay.
    static func everyone(in speech: [TranscriptSegment], isMine: (TranscriptSegment) -> Bool, names: [UInt32: String]) -> [Participant] {
        let heard = speech.filter { $0.isFinal && $0.voice != nil }
        var counts: [UInt32: Int] = [:]
        var found: [Participant] = []
        for segment in heard {
            guard let voice = segment.voice else { continue }
            counts[voice, default: 0] += 1
            let mine = isMine(segment)
            if let index = found.firstIndex(where: { $0.id == voice }) {
                if mine { found[index].label = .me }
            } else {
                found.append(Participant(id: voice, label: mine ? .me : segment.speaker, isSpeaking: false, name: names[voice]))
            }
        }
        return found.filter { $0.label == .me || $0.name != nil || heard.count < 30 || (counts[$0.id] ?? 0) > 2 }
    }

    /// The people of a conversation as its note lists them. In a call, each says which side it
    /// came through: the microphone is the user, the app's sound the others, told apart by voice.
    static func atTheTable(_ people: [Participant], call app: String?) -> [String] {
        guard let app else { return people.map(\.title) }
        var lines = people.map { $0.label == .me ? "You (microphone)" : "\($0.title) (\(app))" }
        if people.filter({ $0.label != .me }).count > 1 {
            lines.append("The voices on the \(app) side are told apart by sound: one person can appear as two.")
        }
        return lines
    }

    /// Distinct voices in the transcript so far; the orb draws one line each.
    var speakerCount: Int { Self.speakerCount(in: core) }

    static func speakerCount(in core: SessionCore) -> Int {
        var voices = Set<UInt32>()
        for line in core.lines {
            if case .speech(let segment) = line.content, let voice = segment.voice, !segment.voicePending { voices.insert(voice) }
        }
        return max(1, voices.count)
    }

    func setMicrophone(_ on: Bool) {
        guard on else {
            microphoneOn = false
            UserDefaults.standard.set(false, forKey: "microphoneOn")
            syncCapture()
            return
        }
        Task {
            let granted = await AudioCapture.requestPermission()
            self.microphoneOn = granted
            self.microphoneDenied = !granted
            UserDefaults.standard.set(granted, forKey: "microphoneOn")
            self.syncCapture()
        }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        syncCapture()
    }

    /// The microphone runs for a session when the state machine asks for it,
    /// and for the orb while idle in the foreground with the switch on. Idle
    /// audio is measured for its level and discarded.
    private func syncCapture() {
        // A scripted recording is for the session only: the idle orb must not use it up.
        let ambient = microphoneOn && isForeground && core.phase == .idle && AudioCapture.scriptedFile == nil
        let wanted = coreWantsCapture || ambient
        let voiceConversation = coreWantsCapture && (assistant != nil || spoken != nil)
        if capture.isRunning, capture.voiceConversation != voiceConversation {
            capture.stop()
        }
        capture.voiceConversation = voiceConversation
        if wanted, !capture.isRunning {
            do {
                if !Self.usesDemo, !injectedTransport, recordingLease == nil { recordingLease = try RecordingLease() }
                try capture.start()
            } catch {
                if coreWantsCapture {
                    coreWantsCapture = false
                    captureError = error.localizedDescription
                    send(.audioInterrupted(.captureFailed))
                } else {
                    microphoneOn = false
                }
            }
        } else if !wanted, capture.isRunning {
            capture.stop()
            level = 0
            waveform = [Float](repeating: 0, count: Waveform.points)
        }
        if !capture.isRunning, core.phase == .idle || core.phase == .review { recordingLease = nil }
        assistant?.setDuplexListening(capture.voiceProcessingActive)
        spoken?.setDuplexListening(capture.voiceProcessingActive)
    }

    /// The scripted demo runs in the simulator, where Apple's transcriber
    /// supports no language, and on a phone launched with `-demo`.
    /// Otherwise speech is transcribed on the device.
    static var usesDemo: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        ProcessInfo.processInfo.arguments.contains("-demo") || ProcessInfo.processInfo.arguments.contains("--demo")
        #endif
    }

    var isDemo: Bool { transport is DemoTransport }
    private var terminalDemo: Bool { interface == .terminal && (Self.usesDemo || isDemo) }
    /// Whether anything can produce cards in the running session.
    private(set) var hasAnswers = true
    /// Name of the topic the running session was started with.
    private(set) var topicName = ""
    @ObservationIgnored private var topic: Topic?
    @ObservationIgnored private var answers: AnswerEngine?
    @ObservationIgnored private var began = Date()
    /// The app whose sound joined this conversation, a call; nil without one.
    @ObservationIgnored private var callApp: String?
    /// The session being started was opened to look at: it pauses before it listens.
    @ObservationIgnored private var opensPaused = false
    /// The note this conversation left in its topic's folder, once it has ended.
    private(set) var savedNote: URL?
    @ObservationIgnored private var noteStarted = false
    /// Sentences whose answer is being checked on the web right now.
    private(set) var checking: Set<UInt64> = []
    /// How many earlier conversations of the topic this one continues.
    private(set) var continues = 0

    private func attach(_ transport: any Transport) {
        transport.onEvent = { [weak self] event in
            switch event {
            case .connected: self?.send(.transportConnected)
            case .disconnected: self?.send(.transportDisconnected)
            case .envelope(let envelope):
                if case .transcript = envelope.event, self?.conversationMicrophoneMuted == true { return }
                self?.recorder?.log(envelope.event)
                if case .state(let state, _) = envelope.event {
                    self?.recorder?.log("session", ["state": String(describing: state)])
                }
                if case .state(.stopped, _) = envelope.event { self?.finishRecording() }
                self?.send(.envelope(envelope))
                if case .state(.listening, _) = envelope.event, self?.core.phase == .listening {
                    self?.assistant?.start()
                    self?.assistant?.setPaused(false)
                    self?.spoken?.setPaused(false)
                }
                if case .transcript(let segment) = envelope.event, let self {
                    let supported = !self.capture.voiceProcessingActive
                        || (self.transport as? LocalTransport)?.hasSpeech(segment) != false
                    self.assistant?.receive(segment, hasAcousticSupport: supported)
                }
                // After the state machine has the event: what is said is what is on the table.
                self?.spoken?.receive(envelope.event)
                if case .state(.stopped, _) = envelope.event { self?.saveNote() }
                self?.onEvent?(envelope.event)
            }
        }
    }

    /// The output side for a topic: the device's own model when it has one, plus
    /// every model of the connected account. Nil when neither exists.
    private func finishRecording() {
        guard let recorder else { return }
        recorder.finish()
        recordedTo = recorder.directory
        self.recorder = nil
    }

    /// Also finalizes a start that was cancelled before a transport emitted stopped.
    func stopAndSave() {
        send(.stop)
        finishRecording()
        saveNote()
    }

    /// Leaves what this conversation showed in the topic's folder, so the next
    /// one in the same topic can continue from it. Never for the demo. The cards
    /// are written at once; a summary follows when a model is attached.
    private func saveNote() {
        guard let topic, !Self.usesDemo, !injectedTransport, parts == nil, savedNote == nil, !noteStarted else { return }
        if let assistant {
            guard assistant.configuration.keepNotes else { return }
            noteStarted = true
            let sandbox = TopicSandbox(topic: topic.id), started = began
            var note = TopicSandbox.Conversation(topic: topic.name, began: began, seconds: capturedFrames / 10,
                people: [], cards: [], sentences: core.allSpeech.filter(\.isFinal).count,
                runID: recordedTo?.lastPathComponent ?? recorder?.directory.lastPathComponent)
            // Commit useful local memory before starting optional remote work. An expired
            // deadline or background suspension must not erase this conversation's continuity.
            note.summary = assistant.memoryCheckpoint()
            note.contextStatements = assistant.contextStatements()
            savedNote = sandbox.write(note)
            let prompt = runningSystem?.configuration?.prompts.summary ?? SystemConfig().prompts.summary
            pendingNotes += 1
            Task {
                defer { pendingNotes -= 1 }
                guard let summary = await assistant.makeNote(prompt: prompt) else { return }
                note.summary = summary
                let file = sandbox.write(note)
                if began == started { savedNote = file }
            }
            return
        }
        let people = everyone
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.title) })
        var said: [String] = []
        // The whole conversation, not only the lines still on screen: an hour-long meeting was
        // summarised from its last ten minutes (19 November 2026).
        for segment in core.allSpeech where segment.isFinal {
            let who = core.isMine(segment) ? "You" : (segment.voice.flatMap { names[$0] } ?? "Someone")
            said.append("\(who): \(segment.text)")
        }
        var note = TopicSandbox.Conversation(
            topic: topic.name, began: began, seconds: capturedFrames / 10,
            people: Self.atTheTable(people, call: callApp),
            cards: core.cards
                .filter { !$0.text.isEmpty && ($0.status == .finished || $0.status == .streaming) }
                .map(\.text),
            blocks: CardBlocks.blocks(from: core.cards).map { $0.versions.map(\.text).filter { !$0.isEmpty } },
            sentences: said.count, runID: recordedTo?.lastPathComponent ?? recorder?.directory.lastPathComponent)
        // A topic that was only opened and looked at leaves no new note.
        guard !said.isEmpty else { return }
        noteStarted = true
        let sandbox = TopicSandbox(topic: topic.id)
        savedNote = sandbox.write(note)
        guard let answers else { return }
        let began = began
        pendingNotes += 1
        Task {
            defer { self.pendingNotes -= 1 }
            guard let summary = await answers.summarise(said.joined(separator: "\n")) else { return }
            note.summary = summary
            let file = sandbox.write(note)
            // Only this conversation's screen learns about it; a new one may have begun.
            if self.began == began, self.savedNote == nil { self.savedNote = file }
        }
    }

    /// Who does what in a conversation started now: the settings the engine gets, and the
    /// accounts that carry the requests. The session uses it, and the System view shows it.
    struct Plan {
        var settings: AnswerEngine.Settings
        var hasLocal: Bool
        var key: String?
        var direct: [String: any ModelClient]
        var problem: String?
    }

    /// `listenSystem`: the system the conversation runs with, already applied to `loaded`; it
    /// also decides whether typed decisions run. Nil keeps the account's choice (the System view).
    static func plan(for topic: Topic?, system loaded: SystemConfig.Loaded = SystemConfig.load(), listenSystem: ListenSystem? = nil, routers: RouterStore = .shared) -> Plan {
        let system = loaded.config
        var settings = AnswerEngine.Settings()
        settings.system = system
        var useJev = UserDefaults.standard.bool(forKey: JevClient.enabledKey)
        #if DEBUG
        // A finite evaluation opts in for its own process, never by changing the
        // owner's saved preference or copying their key into a command or file.
        if AudioCapture.scriptedFile != nil,
           let option = ProcessInfo.processInfo.environment["LISTEN_JEV_DECISIONS"] {
            useJev = option == "1"
        }
        #endif
        if useJev, listenSystem?.usesDecisions ?? true, let secret = Keychain.get(Connector.jev.rawValue) {
            settings.decisionClient = JevClient(key: secret)
        }
        #if DEBUG
        // A finite evaluation can compare with and without the forecast pool in its own process.
        if AudioCapture.scriptedFile != nil, let option = ProcessInfo.processInfo.environment["LISTEN_FORECAST"] {
            settings.system.agents.forecast = option != "0"
            // `LISTEN_FORECAST=pool`: lane B only, without ranking while a sentence is spoken.
            settings.system.agents.forecastWhileSpeaking = option == "1"
        }
        #endif
        settings.pause = .milliseconds(Int(system.scheduler.pauseSeconds * 1000))
        settings.minimumWords = system.scheduler.minimumWords
        settings.limitUSD = system.scheduler.budgetUSD
        settings.namingEvery = system.scheduler.namesEverySentences
        if let topic {
            settings.notes = String(topic.notes.prefix(1500))
            settings.earlier = TopicSandbox(topic: topic.id).context()
            settings.language = topic.language
        }
        settings.instructions = Instructions.load(topic: topic?.id)
        settings.userName = UserDefaults.standard.string(forKey: "accountName") ?? ""
        let key = Keychain.get(Connector.openRouter.rawValue)
        let hasLocal = LocalModelClient.isAvailable
        // Without OpenRouter, each provider the user attached with its own key is asked directly.
        var direct: [String: any ModelClient] = [:]
        if key == nil {
            settings.drafters = []
            let own: [(Connector, OpenRouterClient.Provider, String)] = [
                (.gemini, .gemini, "google/gemini-2.5-flash-lite"),
                (.deepSeek, .deepSeek, "deepseek/deepseek-chat"),
                (.openAI, .openAI, "openai/gpt-6-luna"),
            ]
            for (connector, provider, model) in own {
                guard let secret = Keychain.get(connector.rawValue) else { continue }
                direct[String(model.split(separator: "/")[0])] = OpenRouterClient(key: secret, provider: provider)
                settings.drafters.append(model)
            }
        }
        // A ChatGPT plan the user signed in with: one model of their choice, asked directly.
        var plan: String?
        if let account = ChatGPT.Credentials.load(), account.allowsPlan, let slug = account.model {
            direct["chatgpt"] = ResponsesClient()
            plan = "chatgpt/\(slug)"
            // The same model with web search answers the same moment with checked facts.
            settings.researcher = "chatgpt/\(slug)" + ResponsesClient.web
            // Other models of the plan the user switched on write the drafts: fast, cheap ones.
            // The chosen model drafts beside them only when there are none, or when system.json says so:
            // it is the slowest to a first word and the dearest to ask for nothing.
            let fast = (UserDefaults.standard.stringArray(forKey: ChatGPT.alsoAskedKey) ?? []).filter { $0 != slug }
            if fast.isEmpty || system.agents.mainDrafts { settings.drafters.append("chatgpt/\(slug)") }
            for other in fast { settings.drafters.append("chatgpt/\(other)") }
        }
        var routerMain: String?
        if let topic, let router = routers.active, let client = routers.client(topic: topic.id) {
            direct["router"] = client
            let route = "router/\(router.model)"
            routerMain = route
            settings.drafters.append(route)
        }
        let cloud = settings.drafters
        // The model on the device drafts cards only when nothing stronger is attached: next to
        // a strong model its drafts were thin, sometimes about the wrong subject, and each one
        // put another box on the table (run of 15 November 2026).
        if hasLocal, cloud.isEmpty {
            settings.drafters.insert(LocalModelClient.model, at: 0)
            // It writes a card for anything, so it is asked first whether there is one.
            settings.gated = [LocalModelClient.model]
        }
        if key == nil { settings.merger = plan ?? cloud.last ?? LocalModelClient.model }
        if let routerMain { settings.merger = routerMain }
        // Finding names is a small task: the model on the device when there is one.
        settings.namer = hasLocal ? LocalModelClient.model : cloud.first
        // What system.json names takes the place of what the accounts would give.
        if !system.models.drafts.isEmpty { settings.drafters = system.models.drafts }
        if !system.models.main.isEmpty {
            settings.merger = system.models.main
            settings.researcher = system.models.main.hasPrefix("chatgpt/") ? system.models.main + ResponsesClient.web : nil
        }
        if !system.models.names.isEmpty { settings.namer = system.models.names }
        if !system.agents.web { settings.researcher = nil }
        if !system.agents.names { settings.namer = nil }
        return Plan(settings: settings, hasLocal: hasLocal, key: key, direct: direct, problem: loaded.problem)
    }

    static func answers(for topic: Topic, system: SystemConfig.Loaded, listenSystem: ListenSystem,
                                spoken: SpokenAnswerForm? = nil) -> AnswerEngine? {
        var plan = plan(for: topic, system: system, listenSystem: listenSystem)
        // The same plan as for cards: roles, accounts and budget. Only the form of the answers differs.
        plan.settings.spoken = spoken
        guard !plan.settings.drafters.isEmpty else { return nil }
        return AnswerEngine(
            client: RoutedClient(
                local: plan.hasLocal ? LocalModelClient() : nil, remote: plan.key.map { OpenRouterClient(key: $0) }, direct: plan.direct),
            settings: plan.settings)
    }

    /// A recorded run opened to go through it in time.
    var replaying: URL?
    /// Blocks to put on the table when the next conversation begins: it carries on from a moment of a run.
    @ObservationIgnored private var carried: [[String]]?

    /// Starts a conversation in a topic with these blocks already on the table.
    func carryOn(in topic: Topic, with blocks: [[String]]) {
        carried = blocks
        start(topic)
    }

    /// Opens the topic on the listening screen with the cards of its last conversation,
    /// but does not listen yet: the microphone starts when the user resumes.
    func open(_ topic: Topic) {
        opensPaused = true
        start(topic)
    }

    /// `spoken`: started by Talk with Listen. The topic's own system answers and its answers
    /// are said (`VoicePresentation`); the system is not changed for it. A system that speaks
    /// by its own settings does so either way.
    func start(_ topic: Topic, spoken requested: Bool = false) {
        #if DEBUG
        // A finite file-fed evaluation can measure the spoken form in its own process.
        let requested = requested
            || (AudioCapture.scriptedFile != nil && ProcessInfo.processInfo.environment["LISTEN_SPOKEN_PRESENTATION"] == "1")
        #endif
        guard core.phase == .idle else {
            opensPaused = false
            return
        }
        startFailure = nil
        if !Self.usesDemo, !injectedTransport, parts == nil, recordingLease == nil {
            do { recordingLease = try RecordingLease() }
            catch { startFailure = error.localizedDescription; return }
        }
        if !injectedTransport {
            transport.onEvent = nil
            traces = []
            stageStatus = []
            voiceNames = [:]
            namedByHand = []
            if Self.usesDemo, parts == nil {
                hasAnswers = true
                transport = DemoTransport()
            } else {
                // One reading of system.json for the whole conversation: hearing and answering agree.
                // The topic's system then sets which blocks run.
                var system: SystemConfig.Loaded
                let chosen: ListenSystem
                if let parts { (system, chosen) = parts.system(topic) } else { (system, chosen) = (SystemConfig.load(), SystemStore().chosen(for: topic)) }
                chosen.apply(to: &system.config)
                runningSystem = chosen
                assistant = nil
                spoken = nil
                // Spoken: the system's own roles answer, as below without voice. Only the voice
                // fields of the conversation settings are used. Talk with Listen speaks a system
                // of cards the same way without changing it.
                var spokenCards: VoiceAssistantConfiguration?
                let presentation = VoicePresentation.plan(for: chosen, requested: requested)
                if var conversation = presentation?.configuration {
                    guard (try? conversation.validate()) != nil else {
                        startFailure = "The voice settings of this system are not valid. Check its system settings."
                        if !capture.isRunning { recordingLease = nil }
                        return
                    }
                    if interface == .terminal { conversation.speakReplies = false }
                    spokenCards = conversation
                }
                if var conversation = system.config.conversation, conversation.enabled, conversation.answerSource == .assistant {
                    if interface == .terminal { conversation.speakReplies = false }
                    var toolStore = MCPStore.shared
                    #if DEBUG
                    // A loopback-only synthetic service, in a file-fed evaluation topic.
                    // It never adds grants to the owner's installation or changes its system.
                    if topic.evaluation, AudioCapture.scriptedFile != nil,
                       let raw = ProcessInfo.processInfo.environment["LISTEN_VOICE_MCP_EVAL"],
                       let endpoint = URL(string: raw), ["localhost", "127.0.0.1"].contains(endpoint.host ?? ""),
                       MCPClient.validEndpoint(endpoint) {
                        let fixture = MCPStore(file: FileManager.default.temporaryDirectory.appending(path: "listen-voice-eval-\(UUID())/mcp.json"),
                            readSecret: { _ in nil }, writeSecret: { _, _ in }, deleteSecret: { _ in })
                        do {
                            try fixture.save(.init(name: "Synthetic voice evaluation", endpoint: endpoint,
                                permissions: [.init(id: "fixture.light", tool: "set_light", withoutConfirmation: true)]))
                            toolStore = fixture
                            conversation.toolIDs = ["fixture.light"]
                            conversation.recordAudio = true
                        } catch { startFailure = "The synthetic evaluation service could not be configured."; return }
                    }
                    #endif
                    let plan = Self.plan(for: topic, system: system, listenSystem: chosen)
                    let model = conversation.model.isEmpty ? plan.settings.merger : conversation.model
                    let prefix = String(model.split(separator: "/").first ?? "")
                    guard (try? conversation.validate()) != nil,
                          prefix == "local" ? plan.hasLocal : (plan.direct[prefix] != nil || plan.key != nil) else {
                        startFailure = "The voice assistant needs a supported model connection. Check its system and Account settings."
                        if !capture.isRunning { recordingLease = nil }
                        return
                    }
                    assistant = VoiceAssistantSession(topic: topic, system: chosen, configuration: conversation,
                        client: RoutedClient(local: plan.hasLocal ? LocalModelClient() : nil,
                            remote: plan.key.map { OpenRouterClient(key: $0) }, direct: plan.direct),
                        model: model, speaker: TalkBack.speaker(for: conversation), toolStore: toolStore, budgetUSD: plan.settings.limitUSD,
                        context: AssistantContext(material: TopicMaterial(topic: topic.id).index,
                            earlier: conversation.keepNotes ? TopicSandbox(topic: topic.id).context() : "",
                            earlierStatements: conversation.keepNotes ? TopicSandbox(topic: topic.id).contextStatements() : []),
                        openingModel: conversation.openingModel.isEmpty ? plan.settings.drafters.first(where: { $0 != model }) : conversation.openingModel,
                        openingReviewer: plan.settings.decisionClient)
                }
                let form = spokenCards == nil ? nil : SpokenAnswerForm()
                let answers = assistant != nil ? nil : parts.map { $0.answers(topic, system, chosen, form) }
                    ?? Self.answers(for: topic, system: system, listenSystem: chosen, spoken: form)
                hasAnswers = answers != nil || assistant != nil
                self.answers = answers
                if let spokenCards {
                    guard let answers else {
                        startFailure = "Talking with this topic needs a model connection for its system's roles. Check Account settings."
                        if !capture.isRunning { recordingLease = nil }
                        return
                    }
                    let material = TopicMaterial(topic: topic.id).index
                    let source = VoicePresentation.summary(
                        of: chosen, decisions: answers.routesEarlyText, deepens: answers.deepens, research: answers.researches,
                        material: !material.passages.isEmpty || !topic.notes.isEmpty)
                    // A system without voice settings keeps none: the voice chosen while talking
                    // is remembered beside it.
                    let remembers = presentation?.savedInSystem == false
                    let makeSpeaker = parts?.speaker ?? { TalkBack.speaker(for: $0) }
                    let voice = SpokenHarness(system: chosen.id, language: topic.language, configuration: spokenCards,
                                              speaker: makeSpeaker(spokenCards), source: source, makeSpeaker: makeSpeaker,
                                              saveVoice: remembers ? { [id = chosen.id] in try VoicePresentation.remember($0, system: id) } : nil)
                    answers.onRound = { [weak voice] trigger, running in voice?.round(trigger, running: running) }
                    answers.onCorrection = { [weak voice] card in voice?.correction(card: card) }
                    voice.onTurnPause = { [weak self] in self?.transport.endUtterance() }
                    spoken = voice
                }
                checking = []
                answers?.onChecking = { [weak self] trigger, running in
                    if running { self?.checking.insert(trigger) } else { self?.checking.remove(trigger) }
                }
                if let answers, !topic.links.isEmpty {
                    // The linked pages are read while the conversation already runs.
                    Task { answers.pages = await LinkContext.load(topic.links) }
                }
                // The topic's own files: their index was written when they were added (C1).
                let material = TopicMaterial(topic: topic.id).index
                answers?.material = material
                // Their names of things are expected by both listening stages.
                let terms = Array(material.terms.prefix(24))
                let glossary = ([topic.glossary] + (terms.isEmpty ? [] : [terms.joined(separator: ", ")])).filter { !$0.isEmpty }.joined(separator: ". ")
                let made: any Transport
                if let parts {
                    made = parts.transport(topic, answers)
                } else {
                    let local = LocalTransport(
                        language: topic.language,
                        refiner: assistant == nil ? WhisperRefiner(language: topic.language, glossary: glossary, voice: system.config.voice) : nil,
                        answers: answers, speakerWindowSeconds: system.config.voice.speakerWindowSeconds,
                        expected: material.terms)
                    local.onTrace = { [weak self] trace in self?.record(trace) }
                    local.onStatus = { [weak self] text in self?.stageStatus.append(text) }
                    local.onNames = { [weak self] names in
                        self?.recorder?.log("names", ["names": Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })])
                        self?.found(names)
                    }
                    made = local
                }
                recordedTo = nil
                // A conversation with a voice is recorded only when its system allows it as well.
                let permitsRecording = (assistant == nil && spoken == nil) || assistant?.configuration.recordAudio == true
                    || spoken?.configuration.recordAudio == true
                recorder = RunRecorder.isOn && permitsRecording && parts == nil ? RunRecorder(topic: topic.name, language: topic.language.rawValue,
                    topicID: topic.id, input: AudioCapture.scriptedFile == nil ? "microphone" : "file", evaluation: topic.evaluation) : nil
                if assistant != nil || spoken != nil { recorder?.recordAssistantOutput() }
                spoken?.record = { [run = recorder] kind, fields in
                    VoiceTiming.note(kind, fields)
                    run?.log(kind, fields)
                }
                spoken?.began()
                assistant?.record = { [run = recorder] kind, fields in
                    VoiceTiming.note(kind, fields)
                    if kind == "usage" || kind == "model_request" || kind == "voice_operation" { run?.logModelEvent(kind, fields) }
                    else { run?.log(kind, fields) }
                }
                assistant?.onStopRequested = { [weak self] in self?.stopAndSave() }
                assistant?.onTurnPause = { [weak self] in self?.transport.endUtterance() }
                // Which system the run was made with, for going through it and for measuring systems.
                recorder?.log("system", ["id": chosen.id, "name": chosen.name, "configured_voice_models": assistant?.configuredModels ?? [:],
                                         "blocks": chosen.blocks.filter(\.on).map(\.kind.rawValue),
                                         // How the conversation is spoken: by the system's own voice
                                         // settings, as a presentation over a system of cards, or not.
                                         "spoken": spoken == nil ? "no" : presentation?.savedInSystem == true ? "system" : "presentation"])
                // Keep late usage (including the final summary) with the run that made
                // the request, even after recording ends or another session starts.
                if let run = recorder {
                    answers?.onLog = { kind, fields in
                        if kind == "usage" || kind == "model_request" || kind == "meeting" { run.logModelEvent(kind, fields) }
                        else { run.log(kind, fields) }
                    }
                } else {
                    answers?.onLog = nil
                }
                transport = made
            }
            attach(transport)
        }
        topicName = topic.name
        self.topic = topic
        began = Date()
        savedNote = nil
        noteStarted = false
        callApp = nil
        continues = Self.usesDemo ? 0 : TopicSandbox(topic: topic.id).notes.count
        send(.start(language: topic.language))
    }

    func send(_ input: SessionCore.Input) {
        switch input {
        case .pause, .leftForeground, .audioInterrupted: assistant?.setPaused(true); spoken?.setPaused(true)
        case .stop: assistant?.stop(); spoken?.stop()
        case .done: assistant?.stop(); assistant = nil; spoken?.stop(); spoken = nil
        default: break
        }
        // Record lifecycle decisions without serializing envelopes or account data. A file
        // evaluation that ends early must say whether it was stopped, paused or interrupted.
        switch input {
        case .pause: recorder?.log("session", ["action": "pause"])
        case .resume: recorder?.log("session", ["action": "resume"])
        case .stop: recorder?.log("session", ["action": "stop"])
        case .leftForeground: recorder?.log("session", ["action": "leftForeground"])
        case .audioInterrupted(let reason):
            recorder?.log("session", ["action": "audioInterrupted", "reason": String(describing: reason)])
            VoiceTiming.note("session", ["state": "audioInterrupted " + String(describing: reason)])
        default: break
        }
        switch input {
        case .pause: VoiceTiming.note("session", ["state": "pause"])
        case .resume: VoiceTiming.note("session", ["state": "resume"])
        case .stop: VoiceTiming.note("session", ["state": "stop"])
        case .leftForeground: VoiceTiming.note("session", ["state": "leftForeground"])
        default: break
        }
        if case .start = input {
            setConversationMicrophoneMuted(false)
            conversationActivity.reset()
            quietSeconds = 0
            laidOutCards.removeAll()
            cardsInViewport.removeAll()
            capturedFrames = 0
            framesAfterStop = 0
            captureError = nil
            audioSeq = 0
        }
        for command in core.handle(input) {
            run(command)
        }
        switch core.phase {
        case .interrupted, .reconnecting, .pausedByUser: assistant?.setPaused(true); spoken?.setPaused(true)
        default: break
        }
        syncCapture()
    }

    /// One frame of captured sound. `AudioCapture` delivers the microphone's and a file's
    /// frames here; a test delivers its own.
    func captured(_ pcm: Data) {
        let side = frameSide
        frameSide = nil
        guard !conversationMicrophoneMuted else { return }
        if core.phase == .idle {
            level = level * 0.6 + Self.loudness(of: pcm) * 0.4
            return
        }
        guard core.isCapturing else {
            framesAfterStop += 1
            return
        }
        capturedFrames += 1
        audioSeq += 1
        level = level * 0.6 + Self.loudness(of: pcm) * 0.4
        let frame = AudioFrame(
            seq: audioSeq, captureMs: UInt64(Date().timeIntervalSince1970 * 1000), pcm: pcm,
            mine: side?.mine, theirs: side?.theirs)
        if core.forwardsAudio {
            recorder?.audio(pcm, side: side)
            if assistant != nil || spoken != nil {
                // How long the microphone has been quiet: the assistant ends a turn at a pause,
                // and a spoken card waits for one.
                if assistant?.blocksRecognition == true || spoken?.blocksRecognition == true {
                    // Do not learn Listen's loudspeaker as the room's background level.
                    conversationActivity.reset()
                    quietSeconds = 0
                } else {
                    conversationActivity.receive(pcm)
                    quietSeconds = conversationActivity.quietSeconds
                }
                if capture.voiceProcessingActive {
                    assistant?.microphoneActivity(speechSeconds: conversationActivity.speechSeconds, quietSeconds: quietSeconds)
                    spoken?.microphoneActivity(speechSeconds: conversationActivity.speechSeconds)
                }
                assistant?.heardQuiet(for: quietSeconds)
                spoken?.heardQuiet(for: quietSeconds)
            }
            if assistant?.blocksRecognition == true || spoken?.blocksRecognition == true {
                // Preserve recognizer time while withholding our own synthesized speech.
                transport.sendAudio(AudioFrame(seq: frame.seq, captureMs: frame.captureMs, pcm: Data(count: pcm.count)))
            } else { transport.sendAudio(frame) }
        } else if core.buffersAudio {
            buffered.append(frame)
            // Oldest audio goes first; the backend reports the gap it sees.
            if buffered.count > Self.bufferFrames { buffered.removeFirst(buffered.count - Self.bufferFrames) }
        }
    }

    private static func loudness(of pcm: Data) -> Double {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum = 0.0
            for sample in samples {
                let value = Double(sample) / 32_768
                sum += value * value
            }
            return min(1, (sum / Double(samples.count)).squareRoot() * 6)
        }
    }

    private func run(_ command: SessionCore.Command) {
        switch command {
        case .requestMicrophonePermission:
            let requestedFor = began
            Task {
                let fileInput = AudioCapture.scriptedFile != nil
                let granted = terminalDemo || fileInput || self.parts != nil ? true : await AudioCapture.requestPermission()
                guard self.began == requestedFor, self.core.phase == .starting else { return }
                self.microphoneDenied = !granted
                if !granted {
                    self.startFailure = "Microphone access is off. Allow Listen in Settings before starting a voice session."
                    self.recorder?.log("session", ["action": "microphone_denied"])
                    self.finishRecording()
                }
                self.send(.microphonePermission(granted))
            }
        case .connect:
            transport.connect()
        case .reconnect:
            Task {
                try? await Task.sleep(for: .seconds(1))
                if self.core.phase == .reconnecting { self.transport.connect() }
            }
        case .disconnect:
            transport.disconnect()
        case .send(let event):
            transport.send(event)
        case .startCapture:
            if opensPaused {
                // Opened to look, not to listen: the session is ready and paused before any sound is taken.
                opensPaused = false
                if let topic, let last = TopicSandbox(topic: topic.id).notes.last.flatMap(TopicSandbox.read) {
                    answers?.restore(last.blocks)
                }
                send(.pause)
                return
            }
            if let carried {
                // Carrying on from a moment of an earlier run: what lay on the table then lies there again.
                answers?.restore(carried)
                self.carried = nil
            }
            // The terminal demo exercises events only and never opens the microphone.
            coreWantsCapture = !terminalDemo && parts == nil
            syncCapture()
        case .stopCapture:
            coreWantsCapture = false
            syncCapture()
        case .flushBufferedAudio:
            buffered.forEach(transport.sendAudio)
            buffered.removeAll()
        case .discardBufferedAudio:
            buffered.removeAll()
        case .speak(let text):
            voice?.speak(text, language: core.language)
        case .stopSpeaking:
            voice?.stop()
        case .keepScreenAwake(let on):
            if interface == .graphical { UIApplication.shared.isIdleTimerDisabled = on }
        case .scheduleReconnectTimeout:
            reconnectTimeout?.cancel()
            reconnectTimeout = Task {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { self.send(.reconnectTimedOut) }
            }
        case .cancelReconnectTimeout:
            reconnectTimeout?.cancel()
            reconnectTimeout = nil
        }
    }
}
