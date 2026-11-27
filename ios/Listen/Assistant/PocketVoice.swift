import CryptoKit
import FluidAudio
import Foundation

/// The files of the German Pocket TTS pack, and how they reach the device.
///
/// The app fetches them itself, on the user's request (`LocalVoice.download`), from one
/// pinned revision of the official Core ML repository, and checks each against the size and
/// hash recorded here. FluidAudio would otherwise fetch what it misses on first use, from
/// the repository's moving `main` and with every voice of the pack; `PocketVoice` therefore
/// hands it a folder only once `complete` holds, and it then finds everything on disk.
enum PocketVoiceFiles {
    struct File: Equatable, Sendable {
        /// Inside the pack's folder.
        let path: String
        let bytes: Int64
        /// As the repository records it for its binary files. The few text files have none
        /// and are checked by size.
        var sha256: String?
    }

    /// Fetches one file to a place on disk and reports the bytes written so far.
    typealias Fetch = @Sendable (_ source: URL, _ destination: URL, _ written: @escaping @Sendable (Int64) -> Void) async throws -> Void

    static let repository = "FluidInference/pocket-tts-coreml"
    /// The repository's head on 23 November 2026 (last changed 1 November 2026).
    static let revision = "c2e998e269e4d4b51f74061faddb8450cd8f9a9a"
    static let pack = "v2.1/german"

    /// What FluidAudio 0.18.4 loads for the default placement (fp16 language model), and four
    /// of the pack's voices. Sizes and hashes read from the repository's file list at `revision`.
    static let files: [File] = [
        File(path: "manifest.json", bytes: 739),
        File(path: "cond_prefill.mlmodelc/analytics/coremldata.bin", bytes: 243,
             sha256: "4775182e4d9f214ad95408328db188a92eff8313c22dfa751a7a344fa97379e9"),
        File(path: "cond_prefill.mlmodelc/coremldata.bin", bytes: 1151,
             sha256: "94e7823168aa983079bac808a03e88f6fa1eda74fcc6fdaf0efad40489ba6c83"),
        File(path: "cond_prefill.mlmodelc/model.mil", bytes: 228_662),
        File(path: "cond_prefill.mlmodelc/weights/weight.bin", bytes: 133_237_248,
             sha256: "446a487be4e656586fa2a8ffa75b792fe06591398080ea594e92b413b2b965c2"),
        File(path: "flowlm_step.mlmodelc/analytics/coremldata.bin", bytes: 243,
             sha256: "7f183c1be7fe10900e60f98b28fec4da6cf9c8b8eaf20b3ac6f0306fff6473e9"),
        File(path: "flowlm_step.mlmodelc/coremldata.bin", bytes: 1191,
             sha256: "ea9b92f59f67021b9bb4dd6549df1ea6eb88806a0bd767218d85bb1738ff9465"),
        File(path: "flowlm_step.mlmodelc/model.mil", bytes: 236_884),
        File(path: "flowlm_step.mlmodelc/weights/weight.bin", bytes: 152_186_240,
             sha256: "871e7e2668c661e77a9255b1fb7f89eba0a60181b6cf04df8a42e793ef7f80c5"),
        File(path: "flow_decoder_fused.mlmodelc/analytics/coremldata.bin", bytes: 243,
             sha256: "8bcd0c77ddf388bc5e36a4c39f5649cab6e040fe7dde06c55c16c4afaf535943"),
        File(path: "flow_decoder_fused.mlmodelc/coremldata.bin", bytes: 413,
             sha256: "28cfa0328e31d406f42b645e7a86f29c216315287a58e1626f80584fc4bc6d17"),
        File(path: "flow_decoder_fused.mlmodelc/model.mil", bytes: 333_331),
        File(path: "flow_decoder_fused.mlmodelc/weights/weight.bin", bytes: 19_012_608,
             sha256: "6ee76653a292aaee52385edda87a2e5da948e1fbbb676ebf06e8d253f6582b03"),
        File(path: "mimi_decoder.mlmodelc/analytics/coremldata.bin", bytes: 243,
             sha256: "0f7c42f7b8c9c6e53e1ced55eebc608f339bf1b2e724ff2302150667fd412ba2"),
        File(path: "mimi_decoder.mlmodelc/coremldata.bin", bytes: 1777,
             sha256: "2fb9d7ab308ebf86a14e5cf3841c34a9c6e5716d2be56301f35609261ce54f2e"),
        File(path: "mimi_decoder.mlmodelc/metadata.json", bytes: 16_844),
        File(path: "mimi_decoder.mlmodelc/model.mil", bytes: 107_403),
        File(path: "mimi_decoder.mlmodelc/weights/weight.bin", bytes: 41_768_256,
             sha256: "fc64ac703e883ade4ec052f3c14cc2a4489161bcabfdb24c6496e420eb3965b3"),
        File(path: "constants_bin/bos_before_voice.bin", bytes: 4096,
             sha256: "4b8b306d01ae74f9c843da41be0e7b23b32c98e82c2380a5fa77cef2338a3d34"),
        File(path: "constants_bin/bos_emb.bin", bytes: 128,
             sha256: "be9f77dd0de8b5af969a0ddc5d57522e99df7e4134c40e55766104f53eeff5ad"),
        File(path: "constants_bin/text_embed_table.bin", bytes: 16_388_096,
             sha256: "a733347daa714c28d83c36907b7962fb68e58f72025cb426eedc330663ab6b70"),
        File(path: "constants_bin/tokenizer.model", bytes: 59_837,
             sha256: "389079b9c67cd17ff1c565d53bc695df390b4ca8abf2300947e659585edd9d2a"),
        File(path: "constants_bin/alba.safetensors", bytes: 6_194_424,
             sha256: "b5a1933388634f63f0f709d3139f64d3c78281160d4a3bf6ea3bd1abc3ba94b6"),
        File(path: "constants_bin/cosette.safetensors", bytes: 6_194_424,
             sha256: "e9b82e86a807783bf1f17fd5ad9fdedee1af2e111ef3c7789d10a9a76c89a32a"),
        File(path: "constants_bin/fantine.safetensors", bytes: 6_538_488,
             sha256: "f0c2c0d22f5835c8cf8698cc7cb6ab93778229163eb1c55c86fe7e4ec512501a"),
        File(path: "constants_bin/eponine.safetensors", bytes: 6_931_704,
             sha256: "111350eaf68881da45a08239541b445481756365ac03308234a863f070334f33"),
    ]

    /// The folder given to FluidAudio as its cache, inside the local voices' folder.
    static var base: URL { LocalVoice.root.appending(path: "pocket-tts", directoryHint: .isDirectory) }

    /// The pack's path in the repository as the linked FluidAudio names it. It has to equal
    /// `pack`: a library that looks elsewhere would not find these files (checked by a test).
    static var libraryPack: String { PocketTtsLanguage.german.repoSubdirectory }

    /// Where FluidAudio looks for the pack below the cache folder it is given.
    static func folder(in base: URL = PocketVoiceFiles.base) -> URL {
        base.appending(path: PocketTtsConstants.defaultModelsSubdirectory, directoryHint: .isDirectory)
            .appending(path: Repo.pocketTts.folderName, directoryHint: .isDirectory)
            .appending(path: libraryPack, directoryHint: .isDirectory)
    }

    /// Written last, with the revision the files were checked against.
    private static func marker(_ base: URL) -> URL { base.appending(path: ".listen-complete") }

    static func source(_ file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(pack)/\(file.path)")!
    }

    private static func size(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    /// The pack's folder if every file of this revision is on the device. Reads no network.
    static func complete(_ files: [File] = PocketVoiceFiles.files, base: URL = PocketVoiceFiles.base) -> URL? {
        guard libraryPack == pack, (try? Data(contentsOf: marker(base))) == Data(revision.utf8) else { return nil }
        let directory = Self.folder(in: base)
        return files.allSatisfy { size(directory.appending(path: $0.path)) == $0.bytes } ? directory : nil
    }

    /// Fetches what is missing, file by file. A file counts only once its size and hash
    /// match, so a download that was cancelled or failed goes on from its last whole file.
    static func download(
        _ files: [File] = PocketVoiceFiles.files, base: URL = PocketVoiceFiles.base,
        fetch: Fetch = { try await PocketFileFetch(destination: $1, written: $2).run($0) },
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard libraryPack == pack else {
            throw LocalVoiceUnavailable(message: "This app's Pocket TTS files do not fit the speech library it was built with.")
        }
        let manager = FileManager.default, directory = Self.folder(in: base)
        let staging = base.appending(path: "Staging", directoryHint: .isDirectory)
        try? manager.removeItem(at: marker(base))
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let total = Double(max(files.reduce(0) { $0 + $1.bytes }, 1))
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appending(path: file.path)
            if size(destination) != file.bytes {
                let partial = staging.appending(path: UUID().uuidString)
                let before = done
                try await fetch(source(file), partial) { progress(Double(before + min($0, file.bytes)) / total) }
                try Task.checkCancellation()
                try verify(partial, file)
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? manager.removeItem(at: destination)
                try manager.moveItem(at: partial, to: destination)
            }
            done += file.bytes
            progress(Double(done) / total)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = base
        try? root.setResourceValues(values)
        try Data(revision.utf8).write(to: marker(base))
    }

    /// The marker goes first, so a half-removed pack never counts as complete.
    static func remove(base: URL = PocketVoiceFiles.base) {
        try? FileManager.default.removeItem(at: marker(base))
        try? FileManager.default.removeItem(at: base)
    }

    static func verify(_ url: URL, _ file: File) throws {
        let mismatch = LocalVoiceUnavailable(message: "A downloaded voice file does not match the published one. Try again.")
        guard size(url) == file.bytes else { throw mismatch }
        guard let expected = file.sha256 else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw mismatch }
    }
}

/// One file over HTTPS, with its progress and a cancellation that stops the transfer. No
/// cookies, credentials or cache: the repository is public and the request carries nothing
/// of the user.
final class PocketFileFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let written: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?
    private var reported: Int64 = -1

    init(destination: URL, written: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.written = written
    }

    func run(_ source: URL) async throws {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        // The session holds its delegate until it is invalidated.
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: source)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // The repository hands large files to its storage host. Never to plain HTTP.
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        // Once per megabyte is enough for a progress bar.
        let step = totalBytesWritten >> 20
        let changed = lock.withLock {
            guard step != reported else { return false }
            reported = step
            return true
        }
        if changed { written(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone when this returns, so it is moved here.
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw LocalVoiceUnavailable(message: "The voice files could not be fetched from Hugging Face.")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { failure = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.failure)
        }
        if let error = error ?? failure { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

/// Pocket TTS through FluidAudio: Core ML on this device, no server and no Python. One
/// manager stays loaded; generations run one after another, like `QwenVoice`'s.
///
/// Nothing here downloads. The pack has to be complete on disk (`PocketVoiceFiles`) before
/// FluidAudio is given its folder, and only voices that came with the pack are accepted.
actor PocketVoice: LocalVoiceSynthesizing {
    static let shared = PocketVoice()

    private var manager: PocketTtsManager?
    private var loading: Task<PocketTtsManager, any Error>?
    private var last: Task<Void, Never>?
    /// Voices that have spoken once since the model was loaded.
    private var warmed: Set<String> = []
    /// Raised by `unload`, so a load that ends afterwards is not kept.
    private var epoch = 0

    func prepare(model: String, voice: String) async throws {
        let started = epoch
        _ = try await load(model, voice: voice)
        try Task.checkCancellation()
        guard epoch == started else { throw CancellationError() }
        guard !warmed.contains(voice) else { return }
        // A voice's first generation reads its file and fills the model's caches. Its audio is dropped.
        for try await _ in try await speech("Hallo.", model: model, voice: voice, language: .de) {}
        try Task.checkCancellation()
        guard epoch == started else { throw CancellationError() }
        warmed.insert(voice)
    }

    func speech(_ text: String, model: String, voice: String, language: Language) async throws
        -> AsyncThrowingStream<LocalVoiceChunk, any Error>
    {
        if let reason = TalkBack.unsupported(model, language: language) { throw LocalVoiceUnavailable(message: reason) }
        let started = epoch
        let manager = try await load(model, voice: voice)
        try Task.checkCancellation()
        guard epoch == started else { throw CancellationError() }
        let previous = last
        let rate = Double(PocketTtsConstants.audioSampleRate)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LocalVoiceChunk.self)
        let job = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                guard epoch == started else { throw CancellationError() }
                // Frames of 80 ms. Ending this loop early ends FluidAudio's generation with it.
                for try await frame in try await manager.synthesizeStreaming(text: text, voice: voice) {
                    try Task.checkCancellation()
                    guard epoch == started else { throw CancellationError() }
                    continuation.yield(LocalVoiceChunk(samples: frame.samples, sampleRate: rate))
                }
                // FluidAudio ends a cancelled generation without an error.
                try Task.checkCancellation()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { if case .cancelled = $0 { job.cancel() } }
        last = job
        return stream
    }

    func unload() async {
        epoch += 1
        let initializing = loading
        initializing?.cancel()
        loading = nil
        warmed = []
        let previous = manager, pending = last
        manager = nil
        last = nil
        pending?.cancel()
        await pending?.value
        _ = await initializing?.result
        await previous?.cleanup()
    }

    private func load(_ id: String, voice: String) async throws -> PocketTtsManager {
        guard TalkBack.model(id)?.family == .pocket, TalkBack.voices(for: id).contains(voice) else {
            throw LocalVoiceUnavailable(message: "The system names a local voice this app does not offer.")
        }
        if let reason = LocalVoice.cannotRun(id) { throw LocalVoiceUnavailable(message: reason) }
        // Checked every time: without the files FluidAudio would fetch them by itself.
        guard PocketVoiceFiles.complete() != nil else {
            manager = nil
            throw LocalVoiceUnavailable(message: "The Pocket TTS voice is not downloaded.")
        }
        if let manager { return manager }
        if let loading { return try await loading.value }
        let base = PocketVoiceFiles.base, started = epoch
        let task = Task.detached {
            let manager = PocketTtsManager(defaultVoice: TalkBack.pocketVoices[0], language: .german, directory: base)
            try await manager.initialize()
            return manager
        }
        loading = task
        do {
            let loaded = try await task.value
            guard epoch == started else { await loaded.cleanup(); throw CancellationError() }
            loading = nil
            manager = loaded
            return loaded
        } catch {
            if epoch == started { loading = nil }
            throw error
        }
    }
}
