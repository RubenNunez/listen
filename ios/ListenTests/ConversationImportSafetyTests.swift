import Foundation
import Testing
@testable import Listen

@Suite struct ConversationImportSafety {
    /// Minimal synthetic ZIP records; sizes/methods can deliberately contradict the payload.
    private func archive(_ files: [(String, Data, UInt16, Int?)]) -> Data {
        func append(_ value: Int, bytes: Int, to data: inout Data) {
            for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
        }
        var local = Data(), central = Data()
        for (name, contents, method, declared) in files {
            let path = Data(name.utf8), header = local.count, size = declared ?? contents.count
            for (value, bytes) in [(0x04034b50,4),(20,2),(0,2),(Int(method),2),(0,2),(0,2),(0,4),
                                   (contents.count,4),(size,4),(path.count,2),(0,2)] { append(value, bytes: bytes, to: &local) }
            local.append(path); local.append(contents)
            for (value, bytes) in [(0x02014b50,4),(20,2),(20,2),(0,2),(Int(method),2),(0,2),(0,2),(0,4),
                                   (contents.count,4),(size,4),(path.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(header,4)] {
                append(value, bytes: bytes, to: &central)
            }
            central.append(path)
        }
        let offset = local.count
        local.append(central)
        for (value, bytes) in [(0x06054b50,4),(0,2),(0,2),(files.count,2),(files.count,2),(central.count,4),(offset,4),(0,2)] {
            append(value, bytes: bytes, to: &local)
        }
        return local
    }

    private func manifest(version: Any = 1, run: String = "synthetic-run") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": "listen-conversation", "version": version, "run": run])
    }

    private func stored(_ data: Data) throws -> (file: URL, root: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "import-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "synthetic.listen")
        try data.write(to: file)
        return (file, folder.appending(path: "runs"))
    }

    @Test func oversizedEntriesAreRejectedBeforeAllocation() throws {
        let data = archive([("manifest.json", Data("{}".utf8), 0, 1024 * 1024 + 1)])
        let entry = try #require(ZipArchive.entries(data).first)
        #expect(throws: ZipArchive.Failure.self) { try ZipArchive.contents(of: entry, in: data, maximumSize: 1024 * 1024) }
    }

    @Test func storedSizeMismatchAndEmptyCompressedPayloadAreRejected() throws {
        for (method, size, bytes) in [(UInt16(0), 10, Data("x".utf8)), (UInt16(8), 10, Data())] {
            let data = archive([("entry", bytes, method, size)])
            let entry = try #require(ZipArchive.entries(data).first)
            #expect(throws: ZipArchive.Failure.self) { try ZipArchive.contents(of: entry, in: data) }
        }
    }

    @Test func failedExtractionDoesNotPublishAPartialRun() throws {
        let made = try stored(archive([
            ("manifest.json", try manifest(), 0, nil),
            ("raw/events.jsonl", Data("{}\n".utf8), 0, nil),
            ("raw/run.json", Data("{}".utf8), 99, nil),
        ]))
        #expect(throws: ZipArchive.Failure.self) { try ConversationFile.open(made.file, runs: [], into: made.root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.root.path).isEmpty)
        #expect(throws: ZipArchive.Failure.self) { try ConversationFile.open(made.file, runs: [], into: made.root) }
    }

    @Test func duplicateRunFilesAreRejectedWithoutPublication() throws {
        let made = try stored(archive([
            ("manifest.json", try manifest(), 0, nil),
            ("raw/events.jsonl", Data("{}\n".utf8), 0, nil),
            ("raw/events.jsonl", Data("[]\n".utf8), 0, nil),
            ("raw/run.json", Data("{}".utf8), 0, nil),
        ]))
        #expect(throws: ConversationFile.OpenFailure.self) { try ConversationFile.open(made.file, runs: [], into: made.root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.root.path).isEmpty)
    }

    @Test func unsupportedManifestVersionsAndTraversalAreRejected() throws {
        for (version, name) in [(2 as Any, "synthetic-run"), (true as Any, "synthetic-run"), (1 as Any, "../outside")] {
            let made = try stored(archive([("manifest.json", try manifest(version: version, run: name), 0, nil)]))
            #expect(throws: ConversationFile.OpenFailure.self) { try ConversationFile.open(made.file, runs: [], into: made.root) }
            #expect(!FileManager.default.fileExists(atPath: made.root.path))
        }
    }
}
