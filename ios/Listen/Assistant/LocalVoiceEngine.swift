import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioTTS
import Observation
import SwiftUI

/// The local voice's files and what the user sees of it: which models are on the device,
/// a running download, and why the voice is silent if it is.
///
/// A model is fetched from Hugging Face only when the user asks for it here. It lives in
/// Application Support, outside backups, and is complete only once `marker` is written.
@MainActor @Observable final class LocalVoice {
    enum Download: Equatable {
        case absent
        case downloading(Double)
        case ready
        case failed(String)
    }

    static let shared = LocalVoice()

    /// Why the session's local voice is not speaking, or that it is still loading.
    var notice: String?
    private var downloads: [String: Download] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var removals: [String: Task<Void, Never>] = [:]

    /// `LISTEN_TALKBACK_MODELS` moves the folder, for measurements that must not touch
    /// the user's own. `~` is the app's home, so a run on a phone can name a folder there.
    nonisolated static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["LISTEN_TALKBACK_MODELS"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "Listen/TalkBack", directoryHint: .isDirectory)
    }

    /// Where the package keeps a repository inside `root`.
    nonisolated static func folder(_ id: String) -> URL {
        root.appending(path: "mlx-audio/" + id.replacingOccurrences(of: "/", with: "_"), directoryHint: .isDirectory)
    }

    private nonisolated static func marker(_ id: String) -> URL { folder(id).appending(path: ".listen-complete") }

    /// The model's folder if its download finished.
    nonisolated static func complete(_ id: String) -> URL? {
        if TalkBack.model(id)?.family == .pocket { return PocketVoiceFiles.complete() }
        if TalkBack.model(id)?.family == .supertonic { return SupertonicVoiceFiles.complete() }
        return FileManager.default.fileExists(atPath: marker(id).path) ? folder(id) : nil
    }

    /// Why this device cannot run the Qwen voice at all, if so. This decides the default engine.
    nonisolated static var unsupported: String? {
        #if targetEnvironment(simulator)
        return "The local voice does not run in the simulator."
        #else
        // Not measured on a phone. The Mac run peaked near 3 GB, so smaller devices are refused.
        return ProcessInfo.processInfo.physicalMemory < 6 * 1_073_741_824
            ? "The local voice needs a device with more memory." : nil
        #endif
    }

    /// Why this device cannot run this model, if so. Pocket TTS is much smaller than Qwen3-TTS
    /// and is not refused for memory; no phone has run it in this app yet.
    nonisolated static func cannotRun(_ id: String) -> String? {
        guard let family = TalkBack.model(id)?.family, family != .qwen else { return unsupported }
        #if targetEnvironment(simulator)
        return "This local voice is not run in the simulator."
        #else
        return nil
        #endif
    }

    /// Loads the local voice of a voice topic before its first reply, which would otherwise
    /// wait for the model: 14.7 s on an iPhone 15 Pro Max (21 November 2026). Nothing is
    /// downloaded here, and a topic without the local voice loads nothing.
    static func preload(for topic: Topic) {
        guard !topic.archived else { return }
        var system = SystemConfig.load()
        SystemStore().chosen(for: topic).apply(to: &system.config)
        guard let voice = system.config.conversation, voice.enabled, voice.speakReplies, voice.talkBackEngine == .local,
              cannotRun(voice.talkBackModel) == nil, TalkBack.unsupported(voice.talkBackModel, language: topic.language) == nil,
              complete(voice.talkBackModel) != nil else { return }
        Task {
            try? await TalkBack.synthesizer(for: voice.talkBackModel).prepare(model: voice.talkBackModel, voice: voice.talkBackVoice)
            try? await ConversationReactionAudio.shared.prepare(model: voice.talkBackModel, voice: voice.talkBackVoice, language: topic.language)
        }
    }

    func state(_ id: String) -> Download {
        downloads[id] ?? (Self.complete(id) == nil ? .absent : .ready)
    }

    func download(_ id: String) {
        guard let model = TalkBack.model(id), tasks[id] == nil, removals[id] == nil, state(id) != .ready else { return }
        if model.family == .pocket { return downloadPocket(id) }
        if model.family == .supertonic { return downloadSupertonic(id) }
        guard let repository = Repo.ID(rawValue: id) else { return }
        downloads[id] = .downloading(0)
        tasks[id] = Task {
            do {
                let cache = HubCache(cacheDirectory: Self.root)
                var folder = try await ModelUtils.resolveOrDownloadModel(
                    client: HubClient(cache: cache), cache: cache, repoID: repository, requiredExtension: "safetensors",
                    progressHandler: { progress in
                        guard case .downloading = self.downloads[id] else { return }
                        self.downloads[id] = .downloading(progress.fractionCompleted)
                    })
                try Task.checkCancellation()
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? folder.setResourceValues(values)
                try Data().write(to: Self.marker(id))
                downloads[id] = nil
                // The missing model was the reason for the notice; the next reply loads it.
                notice = nil
            } catch {
                downloads[id] = Task.isCancelled ? nil : .failed(error.localizedDescription)
            }
            tasks[id] = nil
        }
    }

    /// The German Pocket TTS pack: this app's own download of a pinned file list (`PocketVoiceFiles`).
    private func downloadPocket(_ id: String) {
        downloads[id] = .downloading(0)
        tasks[id] = Task {
            do {
                try await PocketVoiceFiles.download(progress: { fraction in
                    Task { @MainActor in
                        guard case .downloading(let shown) = self.downloads[id], fraction > shown else { return }
                        self.downloads[id] = .downloading(fraction)
                    }
                })
                try Task.checkCancellation()
                downloads[id] = nil
                notice = nil
            } catch {
                downloads[id] = Task.isCancelled ? nil : .failed(
                    (error as? LocalVoiceUnavailable)?.message ?? error.localizedDescription)
            }
            tasks[id] = nil
        }
    }

    private func downloadSupertonic(_ id: String) {
        downloads[id] = .downloading(0)
        tasks[id] = Task {
            do {
                try await SupertonicVoiceFiles.download(progress: { fraction in
                    Task { @MainActor in
                        guard case .downloading(let shown) = self.downloads[id], fraction > shown else { return }
                        self.downloads[id] = .downloading(fraction)
                    }
                })
                try Task.checkCancellation()
                downloads[id] = nil
                notice = nil
            } catch {
                downloads[id] = Task.isCancelled ? nil : .failed(
                    (error as? LocalVoiceUnavailable)?.message ?? error.localizedDescription)
            }
            tasks[id] = nil
        }
    }

    /// Stops a running download. Core ML voices keep the files they have checked, so the next
    /// download goes on from there; a Qwen download is removed, as before.
    func cancel(_ id: String) {
        guard TalkBack.model(id)?.family != .qwen else { return remove(id) }
        tasks[id]?.cancel()
        downloads[id] = nil
    }

    /// Stops a download or deletes a downloaded model.
    func remove(_ id: String) {
        guard removals[id] == nil else { return }
        tasks[id]?.cancel()
        downloads[id] = nil
        let running = tasks[id]
        removals[id] = Task {
            defer { removals[id] = nil }
            if TalkBack.model(id)?.family == .pocket {
                // The download ends first, so it cannot write into the folder being removed.
                await running?.value
                await PocketVoice.shared.unload()
                PocketVoiceFiles.remove()
            } else if TalkBack.model(id)?.family == .supertonic {
                await running?.value
                await SupertonicVoice.shared.removeFiles()
            } else {
                await QwenVoice.shared.unload(id)
                try? FileManager.default.removeItem(at: Self.folder(id))
            }
            await ConversationReactionAudio.shared.remove(model: id)
        }
    }
}

/// Qwen3-TTS through mlx-audio-swift. One model stays loaded; generations run one after
/// another, because the model is not safe to use from two tasks at once. A reply is
/// prepared by `SpokenReply` and generated segment by segment by `SpokenVoice`.
actor QwenVoice: LocalVoiceSynthesizing {
    static let shared = QwenVoice()

    private var loaded: (id: String, model: Qwen3TTSModel)?
    private var loading: (id: String, task: Task<Qwen3TTSModel, any Error>)?
    private var last: Task<Void, Never>?

    /// What the last completed reply took: segments, attempts thrown away, segments cut.
    private(set) var trace: SpokenVoice.Outcome?
    private var seed: UInt64?
    /// Only Listen's fixed research acknowledgement, never a person's speech or dynamic
    /// replies. A repeat in the same voice need not run the entire model again.
    private var acknowledgements: [String: [LocalVoiceChunk]] = [:]

    /// For measurements: makes the next generation's sampling repeatable.
    func seedNext(_ seed: UInt64) { self.seed = seed }

    func prepare(model: String, voice: String) async throws {
        _ = try await load(model, voice: voice)
    }

    func speech(_ text: String, model: String, voice: String, language: Language) async throws
        -> AsyncThrowingStream<LocalVoiceChunk, any Error>
    {
        let qwen = try await load(model, voice: voice)
        let fixed = text == "Ich schaue das nach." || text == "Let me look that up."
        let cacheKey = model + ":" + voice + ":" + language.rawValue + ":" + text
        if fixed, let chunks = acknowledgements[cacheKey], seed == nil {
            trace = .init(samples: chunks.reduce(0) { $0 + $1.samples.count })
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        let previous = last
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LocalVoiceChunk.self)
        let segments = SpokenReply.segments(text, language: language)
        let rate = Double(qwen.sampleRate)
        let job = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                if let seed { MLXRandom.seed(seed) }
                seed = nil
                let cached = FixedVoiceAudio(limit: Int(rate * 6))
                trace = try await SpokenVoice.run(
                    segments, sampleRate: rate,
                    generate: { text, limit in Self.generate(qwen, text, voice: voice, language: language, limit: limit) },
                    yield: {
                        let chunk = LocalVoiceChunk(samples: $0, sampleRate: rate)
                        if fixed { cached.append(chunk) }
                        continuation.yield(chunk)
                    })
                try Task.checkCancellation()
                if fixed, trace?.cut == 0, let chunks = cached.complete {
                    if acknowledgements.count >= 8 { acknowledgements.removeAll() }
                    acknowledgements[cacheKey] = chunks
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            if Task.isCancelled {
                // A cancelled generation ends at its next token, not at once. The package
                // gives no signal for that, so the next one waits a moment.
                await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value
            }
        }
        continuation.onTermination = { if case .cancelled = $0 { job.cancel() } }
        last = job
        return stream
    }

    func unload(_ id: String) {
        if loaded?.id == id { loaded = nil }
        if loading?.id == id {
            loading?.task.cancel()
            loading = nil
        }
    }

    /// Frees whichever model is loaded (`TalkBack.release`).
    func unloadAll() {
        loaded = nil
        loading?.task.cancel()
        loading = nil
    }

    private func load(_ id: String, voice: String) async throws -> Qwen3TTSModel {
        if let loaded, loaded.id == id { return loaded.model }
        if let loading, loading.id == id { return try await loading.task.value }
        if let reason = LocalVoice.unsupported { throw LocalVoiceUnavailable(message: reason) }
        guard TalkBack.model(id)?.family == .qwen, TalkBack.voices.contains(voice) else {
            throw LocalVoiceUnavailable(message: "The system names a local voice this app does not offer.")
        }
        guard let folder = LocalVoice.complete(id) else {
            throw LocalVoiceUnavailable(message: "The local voice model is not downloaded.")
        }
        loaded = nil
        let task = Task.detached {
            let model = try await Qwen3TTSModel.fromModelDirectory(folder)
            // The first generation compiles the kernels. Its audio is dropped.
            for try await _ in Self.generate(model, "Hallo.", voice: voice, language: .de, limit: 40) {}
            return model
        }
        loading = (id, task)
        defer { if loading?.id == id { loading = nil } }
        let model = try await task.value
        if loading?.id == id { loaded = (id, model) }
        return model
    }

    /// Seconds of audio decoded at a time. `LISTEN_TALKBACK_INTERVAL` changes it for measurements,
    /// and `TalkBackProbe` sets it between its runs.
    nonisolated(unsafe) static var streamingInterval = ProcessInfo.processInfo.environment["LISTEN_TALKBACK_INTERVAL"].flatMap(Double.init) ?? 0.32

    /// One generation of at most `limit` audio tokens. Whether it ended by itself can be
    /// read from the package's events: an end token is reported but not counted as a code.
    private static func generate(_ model: Qwen3TTSModel, _ text: String, voice: String, language: Language, limit: Int)
        -> AsyncThrowingStream<SpokenVoice.Piece, any Error>
    {
        // A conservative conversational sampling profile. The 0.6B model does not have
        // reliable instruction-based emotion control; reducing randomness is a bounded
        // alternative, not a guarantee of an emotion or a fixed cadence.
        var sampling = model.defaultGenerationParameters
        sampling.temperature = 0.8
        sampling.topP = 0.95
        sampling.topK = 40
        sampling.repetitionPenalty = 1.05
        sampling.maxTokens = limit
        let source = model.generateStream(
            text: text, voice: voice, refAudio: nil, refText: nil, language: language == .de ? "German" : "English",
            generationParameters: sampling, streamingInterval: streamingInterval)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpokenVoice.Piece.self)
        let task = Task {
            do {
                var events = 0, codes = 0
                for try await event in source {
                    switch event {
                    case .token: events += 1
                    case .info(let info): codes = info.generationTokenCount
                    case .audio(let audio): continuation.yield(.audio(audio.asArray(Float.self)))
                    default: break
                    }
                }
                continuation.yield(.ended(reachedLimit: codes > 0 && events == codes))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: Views

/// The model's yield is Sendable; accumulation is bounded and synchronized off the audio
/// render thread. Overflowed or interrupted phrases are never kept as a partial cache hit.
private final class FixedVoiceAudio: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var chunks: [LocalVoiceChunk] = []
    private var count = 0
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: LocalVoiceChunk) {
        lock.lock(); defer { lock.unlock() }
        count += chunk.samples.count
        if count <= limit { chunks.append(chunk) }
    }
    var complete: [LocalVoiceChunk]? {
        lock.lock(); defer { lock.unlock() }
        return count > 0 && count <= limit ? chunks : nil
    }
}

/// The talk-back rows of a voice system's settings.
struct TalkBackSettings: View {
    /// The whole configuration, so model and voice change in one write. Only the three
    /// talk-back fields are touched here.
    @Binding var configuration: VoiceAssistantConfiguration
    private let store = LocalVoice.shared
    private var engine: TalkBackEngine { configuration.talkBackEngine }
    private var model: String { configuration.talkBackModel }

    var body: some View {
        Picker("Voice for replies", selection: $configuration.talkBackEngine) {
            Text("System voice").tag(TalkBackEngine.system)
            Text("Local voice (on this device)").tag(TalkBackEngine.local)
        }
        if engine == .local {
            // A voice belongs to its model: a model of the other family starts with its first
            // voice, written together with the model so no half-changed pair is ever saved.
            Picker("Local voice model", selection: Binding(get: { model }, set: { next in
                var changed = configuration
                changed.talkBackModel = next
                if !TalkBack.voices(for: next).contains(changed.talkBackVoice), let first = TalkBack.voices(for: next).first {
                    changed.talkBackVoice = first
                }
                configuration = changed
            })) {
                ForEach(TalkBack.models, id: \.id) { Text("\($0.title) · \(Self.size($0))").tag($0.id) }
            }
            Picker("Speaker", selection: $configuration.talkBackVoice) {
                ForEach(TalkBack.voices(for: model), id: \.self) { Text(TalkBack.voiceName($0)).tag($0) }
            }
            if let reason = LocalVoice.cannotRun(model) {
                Label("Unavailable: " + reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let chosen = TalkBack.model(model) {
                switch store.state(model) {
                case .absent:
                    Button("Download \(Self.size(chosen)) from Hugging Face") { store.download(model) }
                case .downloading(let fraction):
                    HStack {
                        ProgressView(value: fraction) { Text("Downloading \(Self.size(chosen)) · \(Int(fraction * 100)) %") }
                        Button("Cancel", role: .cancel) { store.cancel(model) }
                    }
                case .ready:
                    HStack {
                        Label("On this device", systemImage: "checkmark.circle")
                        Spacer()
                        Button("Remove", role: .destructive) { store.remove(model) }
                    }
                case .failed(let reason):
                    Label("Download failed: " + reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try again") { store.download(model) }
                }
            }
            Text("Speaks on this device. Until the model is downloaded and loaded, replies are shown as text; no other voice takes over.")
                .font(.caption).foregroundStyle(.secondary)
            if TalkBack.model(model)?.family == .supertonic { SupertonicLicenseNotice() }
        }
    }

    static func size(_ model: TalkBack.Model) -> String {
        model.gigabytes.formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}

/// In a running session: why the local voice is not speaking, and the download if the
/// model is missing, so the voice can be fetched without leaving the conversation.
struct LocalVoiceNotice: View {
    let configuration: VoiceAssistantConfiguration
    var compact = false
    private let store = LocalVoice.shared

    var body: some View {
        if configuration.speakReplies, configuration.talkBackEngine == .local {
            if let notice = store.notice { Text(notice).foregroundStyle(.orange) }
            if LocalVoice.cannotRun(configuration.talkBackModel) == nil, let model = TalkBack.model(configuration.talkBackModel) {
                switch store.state(model.id) {
                case .absent:
                    Button("Download \(model.short) (\(TalkBackSettings.size(model)))") { store.download(model.id) }
                        .accessibilityIdentifier("voice.download")
                case .downloading(let fraction):
                    HStack {
                        ProgressView(value: fraction) { Text("Downloading \(model.short) · \(Int(fraction * 100)) %") }
                        Button("Cancel", role: .cancel) { store.cancel(model.id) }
                            .accessibilityIdentifier("voice.download.cancel")
                    }
                case .failed(let reason):
                    Text("Download failed: " + reason).foregroundStyle(.orange)
                    Button("Try again") { store.download(model.id) }
                case .ready:
                    EmptyView()
                }
                if model.family == .supertonic { SupertonicLicenseNotice(compact: compact && LocalVoice.complete(model.id) != nil) }
            }
        }
    }
}

private struct SupertonicLicenseNotice: View {
    var compact = false
    @State private var showingLicense = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                Text("Downloading or using Supertonic is subject to the BigScience Open RAIL-M license, including its use restrictions. Experimental voice; phone performance and naturalness are still being evaluated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { showingLicense = true } label: {
                Label(compact ? "Supertonic · Experimental voice · License" : "Supertonic license and notices", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityIdentifier("voice.license")
        }
        .sheet(isPresented: $showingLicense) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Supertonic is subject to the BigScience Open RAIL-M license, including its use restrictions. Phone performance and naturalness are still being evaluated.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                    LegalView()
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingLicense = false } } }
            }
        }
    }
}
