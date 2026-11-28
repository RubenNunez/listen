import Foundation

/// Keeps one conversation as data for improving the system: the sound that
/// was captured and everything the harness did with it, with times.
///
/// One folder per run, on this device only, outside the repository:
///   audio.wav      16 kHz mono, exactly what the stages heard
///   events.jsonl   one JSON object per line: transcript lines of both stages,
///                  layer steps with their duration, cards, names, spend
///   run.json       topic, language, start, duration, app version
///
/// This is other people's speech. It is never uploaded by the app, and the
/// user can switch recording off or delete all runs in Account.
@MainActor
final class RunRecorder {
    static let settingKey = "recordRuns"
    /// Set only by an explicitly recording spoken session, never by a voice preview.
    private(set) static weak var assistantOutput: RunRecorder?

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: settingKey) == nil || UserDefaults.standard.bool(forKey: settingKey)
    }

    /// Application Support by default. A development build can be started with
    /// `-runsFolder <path>` to collect runs somewhere else, such as the project folder.
    static var folder: URL {
        if let custom = UserDefaults.standard.string(forKey: "runsFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "Listen/Runs", directoryHint: .isDirectory)
    }

    /// Every recorded run, oldest first: from the folder in use, from the app's own folder, and
    /// from a folder a development build was last pointed at. The app started from the Dock
    /// would otherwise not show what a build started with `-runsFolder` recorded.
    static func runs() -> [URL] {
        RecordingLibrary.runs(in: searchFolders)
    }

    /// Capture configuration on the main actor without enumerating any files.
    /// Background readers take these immutable locations, never UserDefaults.
    static var searchFolders: [URL] {
        let defaults = UserDefaults.standard
        if let custom = defaults.string(forKey: "runsFolder"), !custom.isEmpty { defaults.set(custom, forKey: keptFolderKey) }
        var places = [folder, URL.applicationSupportDirectory.appending(path: "Listen/Runs", directoryHint: .isDirectory)]
        if let kept = defaults.string(forKey: keptFolderKey) { places.append(URL(fileURLWithPath: kept, isDirectory: true)) }
        return places
    }

    private static let keptFolderKey = "runsFolderKept"

    /// The newest recorded run of a topic that holds anything, if there is one.
    static func newest(topic: String) -> URL? {
        runs().reversed().first { run in
            guard let data = try? Data(contentsOf: run.appending(path: "run.json")),
                let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return meta["topic"] as? String == topic && ((meta["audio_seconds"] as? Double) ?? 0) > 5
        }
    }

    let directory: URL
    private let began = Date()
    private var audio: FileHandle?
    private var sides: FileHandle?
    private var events: FileHandle?
    private var audioBytes = 0
    private var mutedSince: Double?
    private var outputBuffers = 0
    private var meta: [String: Any]

    init?(topic: String, language: String, root: URL? = nil, topicID: UUID? = nil,
          input: String = "unspecified", evaluation: Bool = false) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let parent = root ?? Self.folder
        var stamp = began
        var candidate = parent.appending(path: formatter.string(from: stamp), directoryHint: .isDirectory)
        // Switching interfaces can end one run and start the next within a second. Never
        // reopen/truncate a previous run; keep the existing timestamp-shaped history IDs.
        while FileManager.default.fileExists(atPath: candidate.path) {
            stamp = stamp.addingTimeInterval(1)
            candidate = parent.appending(path: formatter.string(from: stamp), directoryHint: .isDirectory)
        }
        directory = candidate
        meta = [
            "topic": topic, "language": language, "started": ISO8601DateFormatter().string(from: began),
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "sample_rate": Int(WireProtocol.sampleRate),
            "input": input, "evaluation": evaluation,
        ]
        if let topicID { meta["topic_id"] = topicID.uuidString }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audioFile = directory.appending(path: "audio.wav")
            let eventFile = directory.appending(path: "events.jsonl")
            FileManager.default.createFile(atPath: audioFile.path, contents: Self.header(dataBytes: 0))
            FileManager.default.createFile(atPath: eventFile.path, contents: nil)
            audio = try FileHandle(forWritingTo: audioFile)
            events = try FileHandle(forWritingTo: eventFile)
            try audio?.seekToEnd()
            meta["state"] = "recording"
            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appending(path: "run.json"))
        } catch {
            return nil
        }
    }

    /// Preserve replay time with generated silence, never microphone samples. TTS and
    /// tool events continue on the same clock while capture is muted.
    func setMicrophoneMuted(_ muted: Bool, at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard audio != nil else { return }
        if muted {
            guard mutedSince == nil else { return }
            mutedSince = time
            log("microphone", ["muted": true])
        } else if let start = mutedSince {
            mutedSince = nil
            let seconds = max(0, time - start)
            var bytes = Int(seconds * WireProtocol.sampleRate) * 2
            let silence = Data(count: WireProtocol.frameBytes)
            while bytes > 0 {
                let count = min(bytes, silence.count)
                audio(silence.prefix(count))
                bytes -= count
            }
            log("microphone", ["muted": false, "generated_silence_seconds": seconds])
        }
    }

    /// 16-bit samples as captured, and while an app's sound is mixed in, how loud each side
    /// was. The sides go to `sides.bin`: for every 100 ms frame of `audio.wav`, two little-endian
    /// UInt16, the microphone's and the app's RMS times 65 534; 65 535 for a frame without sides.
    /// They are the truth about who spoke in a call, for measuring speaker labels later.
    func audio(_ pcm: Data, side: (mine: Float, theirs: Float)? = nil) {
        guard mutedSince == nil, let audio else { return }
        if audioBytes == 0 {
            log("audio_clock", ["sample": 0, "sample_rate": WireProtocol.sampleRate,
                "first_frame_seconds": Double(pcm.count) / 2 / WireProtocol.sampleRate,
                "measurement": "first captured frame delivery; not acoustic onset"])
        }
        try? audio.write(contentsOf: pcm)
        let frame = audioBytes / WireProtocol.frameBytes
        audioBytes += pcm.count
        if side != nil || sides != nil {
            if sides == nil {
                let file = directory.appending(path: "sides.bin")
                FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0xFF, count: frame * 4))
                sides = try? FileHandle(forWritingTo: file)
                _ = try? sides?.seekToEnd()
            }
            func value(_ rms: Float?) -> UInt16 { rms.map { UInt16(max(0, min(65_534, $0 * 65_534))) } ?? 0xFFFF }
            var entry = Data()
            for number in [value(side?.mine), value(side?.theirs)] { withUnsafeBytes(of: number.littleEndian) { entry.append(contentsOf: $0) } }
            try? sides?.write(contentsOf: entry)
        }
        // Keep the header current every few seconds, so a run that never
        // reaches its end (the app was quit) is still a valid sound file.
        if audioBytes % (5 * 32_000) < pcm.count {
            try? audio.seek(toOffset: 0)
            try? audio.write(contentsOf: Self.header(dataBytes: audioBytes))
            _ = try? audio.seekToEnd()
        }
    }

    func log(_ kind: String, _ fields: [String: Any]) {
        guard let data = eventData(kind, fields) else { return }
        try? events?.write(contentsOf: data)
    }

    func recordAssistantOutput() {
        Self.assistantOutput = self
        meta["assistant_audio"] = "output/*.wav; scheduled buffers, with playback/stop receipts in events.jsonl; not acoustic capture"
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appending(path: "run.json"))
        }
    }

    /// The app's own synthesized PCM, before the speaker. No system/other-app tap.
    /// Each file is complete immediately, even if the app later crashes. A scheduled
    /// buffer is not claimed heard: playback and interruption are separate events.
    func output(_ samples: [Float], sampleRate: Double, player: String) -> Int? {
        guard events != nil, !samples.isEmpty, sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { return nil }
        outputBuffers += 1
        let file = String(format: "output/%06d.wav", outputBuffers)
        let pcm = samples.map { sample -> Int16 in
            guard sample.isFinite else { return 0 }
            return Int16(max(-32767, min(32767, sample * 32767)))
        }.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try FileManager.default.createDirectory(at: directory.appending(path: "output"), withIntermediateDirectories: true)
            try (Self.header(dataBytes: pcm.count, sampleRate: Int(sampleRate.rounded())) + pcm).write(to: directory.appending(path: file))
            log("voice_output_buffer", ["buffer": outputBuffers, "file": file, "player": player,
                "sample_rate": sampleRate, "samples": samples.count, "seconds": Double(samples.count) / sampleRate,
                "state": "scheduled", "measurement": "internal generated PCM, not acoustic playback"])
            return outputBuffers
        } catch {
            log("voice_output_error", ["buffer": outputBuffers, "reason": "Could not save synthesized audio"])
            return nil
        }
    }

    /// A summary or cancelled request may finish after the audio recording has stopped.
    /// Append its usage to this run, never to a newer session, without reopening audio.
    func logUsage(_ fields: [String: Any]) {
        logModelEvent("usage", fields)
    }

    /// The final summary starts after Stop; both ends of that model call belong here.
    func logModelEvent(_ kind: String, _ fields: [String: Any]) {
        guard ["model_request", "usage", "voice_operation", "mcp_request", "mcp_result"].contains(kind) else { return }
        if events != nil { log(kind, fields); return }
        guard let data = eventData(kind, fields),
              let file = try? FileHandle(forWritingTo: directory.appending(path: "events.jsonl")) else { return }
        defer { try? file.close() }
        do {
            try file.seekToEnd()
            try file.write(contentsOf: data)
        } catch {}
    }

    private func eventData(_ kind: String, _ fields: [String: Any]) -> Data? {
        var line = fields
        line["t"] = (Date().timeIntervalSince(began) * 1000).rounded() / 1000
        line["kind"] = kind
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return nil }
        return data + Data("\n".utf8)
    }

    /// The last provisional complete sentence logged per segment.
    private var provisional: [UInt64: String] = [:]

    func log(_ event: ServerEvent) {
        switch event {
        case .transcript(let segment) where !segment.isFinal:
            // A complete sentence that the recogniser still holds back, logged when its words
            // first appear or change: how much earlier than the commit it could be known.
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = text.last, ".?!".contains(last) else { return }
            let key = DirectedContext.evidenceKey(text)
            guard provisional[segment.segmentID] != key else { return }
            provisional[segment.segmentID] = key
            if provisional.count > 50, let oldest = provisional.keys.min() { provisional[oldest] = nil }
            log("provisional", ["id": segment.segmentID, "text": text])
        case .transcript(let segment):
            log("sentence", [
                "id": segment.segmentID, "revision": segment.revision, "text": segment.text,
                "voice": segment.voice.map { Int($0) } as Any? ?? NSNull(),
                "start_ms": segment.startMs, "end_ms": segment.endMs,
                // The voice is still the speaker model's first guess, or the sentence waits for one.
                "pending": segment.voicePending,
            ])
        case .cardStarted(let start):
            log("card_started", ["card": start.generationID, "layer": start.kind.rawValue, "sentence": start.triggerSegment ?? 0,
                                 "context_version": start.contextVersion,
                                 "evidence_segment": start.evidenceSegment as Any? ?? NSNull(),
                                 "block_id": start.blockID as Any? ?? NSNull(),
                                 "focus_text": start.focusText as Any? ?? NSNull(),
                                 "meeting": start.meeting as Any? ?? NSNull()])
        case .cardDelta(let id, let text): log("card_text", ["card": id, "text": text])
        case .cardSuperseded(let id, let by): log("card_replaced", ["card": id, "by": by])
        case .cardCancelled(let id): log("card_dismissed", ["card": id])
        case .speakerMapping(_, let me): log("me", ["voice": me.map { Int($0) } as Any? ?? NSNull()])
        case .budget(let spent, _, _): log("spent", ["usd": Double(spent) / 1e9])
        case .error(let code): log("error", ["code": code.rawValue])
        default: break
        }
    }

    /// How many steps of each sentence's trace are in the log already.
    private var loggedSteps: [UInt64: Int] = [:]

    /// Every step of a trace once, also when several came together (the third hearing of a
    /// sentence and the total of its stage arrive in one report).
    func log(_ trace: LayerTrace) {
        let from = min(loggedSteps[trace.id] ?? 0, trace.steps.count)
        let fresh = from < trace.steps.count ? Array(trace.steps[from...]) : Array(trace.steps.suffix(1))
        loggedSteps[trace.id] = trace.steps.count
        if loggedSteps.count > 400, let oldest = loggedSteps.keys.min() { loggedSteps[oldest] = nil }
        for step in fresh {
            log("layer", [
                "sentence": trace.id, "name": step.name, "detail": step.detail, "changed": step.changed,
                "seconds": step.seconds as Any? ?? NSNull(),
            ])
        }
    }

    func finish() {
        setMicrophoneMuted(false)
        if Self.assistantOutput === self { Self.assistantOutput = nil }
        guard let audio else { return }
        // The header was written for an empty file; now the length is known.
        try? audio.seek(toOffset: 0)
        try? audio.write(contentsOf: Self.header(dataBytes: audioBytes))
        try? audio.close()
        try? events?.close()
        try? sides?.close()
        sides = nil
        self.audio = nil
        events = nil
        meta["seconds"] = (Date().timeIntervalSince(began) * 10).rounded() / 10
        meta["audio_seconds"] = Double(audioBytes) / 2 / WireProtocol.sampleRate
        meta["state"] = "finished"
        meta["output_buffers"] = outputBuffers
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appending(path: "run.json"))
        }
    }

    /// A WAV header for 16 kHz mono 16-bit PCM.
    nonisolated static func header(dataBytes: Int, sampleRate: Int = Int(WireProtocol.sampleRate)) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        return data
    }
}
