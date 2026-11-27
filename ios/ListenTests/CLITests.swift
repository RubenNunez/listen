import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct TerminalInterface {
    @Test func theTestHostCannotRequestOrOpenAPhysicalMicrophone() async throws {
        try #require(AudioCapture.physicalInputDisabled, "the TestAction must disable physical capture")
        #if !targetEnvironment(simulator)
        #expect(!AudioCapture.hasPermission)
        #expect(!(await AudioCapture.requestPermission()))
        let capture = AudioCapture()
        #expect(throws: AudioCapture.CaptureError.physicalInputDisabled) { try capture.start() }
        #expect(!capture.isRunning)
        #endif
    }
    @Test func invalidArgumentsCannotStartAudio() throws {
        for arguments in [["-cli", "--duration", "NaN", "listen"], ["listen", "--duration", "-1"],
                          ["listen", "--topic"], ["listen", "--unknown"], ["show"], ["show", "one", "two"],
                          ["topics", "--demo"], ["topics", "--topic", "x"], ["listen", "--json", "--json"]] {
            #expect(throws: CLIError.self) { try CLIArguments.parse(arguments) }
        }
        let live = try CLIArguments.parse(["-cli", "listen", "--topic", "Topic with spaces", "--json", "--duration", "3.5"])
        #expect(live.command == .listen && live.topic == "Topic with spaces" && live.json && live.duration == 3.5)
        #expect(try CLIArguments.parse(["-cli"]).command == .interactive)
    }

    @Test func topicSelectionUsesTheSharedStoreAndRejectsAmbiguousNames() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cli-topics-\(UUID().uuidString).json")
        let store = TopicStore(file: url)
        let first = Topic(name: "Repeated"), second = Topic(name: "Repeated")
        store.upsert(first); store.upsert(second)
        let disk = try Data(contentsOf: url)
        #expect(try CLICatalog.topic(first.id.uuidString, in: store) == first)
        #expect(try CLICatalog.topic(nil, in: store) == second)
        #expect(throws: CLIError.self) { try CLICatalog.topic("Repeated", in: store) }
        #expect(throws: CLIError.self) { try CLICatalog.topic("Missing", in: store) }
        #expect(try Data(contentsOf: url) == disk, "Browsing/choosing in the CLI never overwrites the GUI's topic file")
    }

    @Test func recordingSelectionOnlyOpensAnActualListedRun() throws {
        let one = URL(fileURLWithPath: "/one/2026-11-20_01-00-00")
        let two = URL(fileURLWithPath: "/two/2026-11-20_01-00-00")
        #expect(try CLICatalog.recording(one.path, among: [one, two]) == one)
        #expect(throws: CLIError.self) { try CLICatalog.recording(one.lastPathComponent, among: [one, two]) }
        #expect(throws: CLIError.self) { try CLICatalog.recording("../../unlisted", among: [one]) }
    }

    @Test func terminalEventsRetainRevisionsPendingVoicesAndBlockIdentity() throws {
        let segment = TranscriptSegment(segmentID: 42, isFinal: true, revision: 3, voice: nil, speaker: .overlap,
                                        text: "Correction\n\u{1B}[31m", startMs: 100, endMs: 500, voicePending: true)
        let data = try CLIOutput.line(CLIOutput.event(.transcript(segment)))
        #expect(data.filter { $0 == 10 }.count == 1, "one JSON record per line even for multiline/control text")
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsed["id"] as? Int == 42 && parsed["revision"] as? Int == 3 && parsed["pending"] as? Bool == true)
        #expect(parsed["text"] as? String == segment.text && parsed["voice"] is NSNull)
        #expect((parsed["speaker"] as? [String: Any])?["kind"] as? String == "overlap")
        let card = CardStart(generationID: 12, kind: .fast, style: .answer, triggerSegment: 42, sourceCard: 11,
                             contextVersion: 0, mappingVersion: 0, blockID: 2, meeting: true)
        let event = CLIOutput.event(.cardStarted(card))
        #expect(event["block"] as? UInt64 == 2 && event["source"] as? UInt64 == 11 && event["meeting"] as? Bool == true)
        #expect(!CLIOutput.safe(segment.text).contains("\u{1B}"))
    }

    @Test func theRecordingLockIsExclusiveAndReleasedOnClose() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "cli-lock-\(UUID().uuidString)/recording.lock")
        var first: RecordingLease? = try RecordingLease(file: path)
        #expect(first != nil)
        #expect(throws: RecordingLease.Failure.self) { try RecordingLease(file: path) }
        first = nil
        let second = try RecordingLease(file: path)
        #expect(FileManager.default.fileExists(atPath: path.path))
        withExtendedLifetime(second) {}
    }

    @Test func newRecordingsKeepTheirTopicIdentityForBothInterfaces() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cli-run-\(UUID().uuidString)")
        let topicID = UUID()
        let recorder = try #require(RunRecorder(topic: "Synthetic topic", language: "en", root: root, topicID: topicID))
        recorder.finish()
        let meta = try #require(TopicExport.meta(recorder.directory))
        #expect(meta["topic_id"] as? String == topicID.uuidString)
    }

    @Test func recordedAssistantPCMHasItsOwnRateAndDoesNotPretendToBeHeard() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-output-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try #require(RunRecorder(topic: "Synthetic output", language: "de", root: root))
        #expect(TopicExport.meta(run.directory)?["state"] as? String == "recording", "a crash must not leave an undiscoverable run")
        run.recordAssistantOutput()
        #expect(RunRecorder.assistantOutput === run)
        let id = try #require(run.output([0, 0.5, -.infinity, .nan, -0.5], sampleRate: 44_100, player: "synthetic"))
        let wav = try Data(contentsOf: run.directory.appending(path: "output/000001.wav"))
        let rate = wav[24..<28].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        #expect(rate == 44_100 && wav.count == 54)
        run.log("voice_output_stopped", ["player": "synthetic"])
        run.finish()
        #expect(RunRecorder.assistantOutput == nil)
        #expect(run.output([0.5], sampleRate: 24_000, player: "synthetic") == nil)
        let events = try String(contentsOf: run.directory.appending(path: "events.jsonl"), encoding: .utf8)
        #expect(id == 1 && events.contains("voice_output_buffer") && events.contains("voice_output_stopped"))
        #expect(!events.contains("voice_output_played"), "generated or stopped audio is not a playback receipt")
        #expect(TopicExport.meta(run.directory)?["output_buffers"] as? Int == 1)
    }

    @Test func fastSuccessiveRunsDoNotOverwriteTheEarlierRecordingOrNote() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cli-collision-\(UUID().uuidString)")
        let first = try #require(RunRecorder(topic: "First", language: "en", root: root))
        first.audio(Data(repeating: 1, count: 3200)); first.finish()
        let before = try Data(contentsOf: first.directory.appending(path: "audio.wav"))
        let second = try #require(RunRecorder(topic: "Second", language: "en", root: root))
        second.finish()
        #expect(first.directory != second.directory)
        #expect(try Data(contentsOf: first.directory.appending(path: "audio.wav")) == before)
        let sandbox = TopicSandbox(topic: UUID(), root: root.appending(path: "topics"))
        var note = TopicSandbox.Conversation(topic: "Synthetic", began: Date(), seconds: 1, people: [], cards: ["First"], sentences: 1,
                                             runID: first.directory.lastPathComponent)
        let one = try #require(sandbox.write(note))
        note.cards = ["Second"]; note.runID = second.directory.lastPathComponent
        let two = try #require(sandbox.write(note))
        let firstNote = try String(contentsOf: one, encoding: .utf8)
        #expect(one != two && firstNote.contains("First"))
        note.runID = "../outside"
        #expect(sandbox.write(note) == nil)
    }

    @Test func headlessSessionUsesTheSameEventsAndPauseResumeStopWithoutAudio() async throws {
        let model = SessionModel(transport: DemoTransport(), interface: .terminal)
        var events: [ServerEvent] = []
        model.onEvent = { events.append($0) }
        model.start(Topic(name: "Synthetic CLI test"))
        for _ in 0..<100 where model.core.phase != .listening { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.core.phase == .listening)
        model.send(.pause)
        #expect(model.core.phase == .pausedByUser)
        model.send(.resume)
        #expect(model.core.phase == .listening)
        model.send(.stop)
        #expect(model.core.phase == .review && model.capturedFrames == 0)
        #expect(events.contains(.state(.listening, reason: nil)) && events.contains(.state(.stopped, reason: nil)))
    }
}
