import CryptoKit
import Foundation
import Testing
@testable import Listen

@Suite struct TopicExportTests {
    private func temporary() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "export-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aTopicIsMovedWithItsFolderAndRunsAndAManifestWithChecksums() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        let sandbox = base.appending(path: "Topics/T", directoryHint: .isDirectory)
        try manager.createDirectory(at: sandbox.appending(path: "conversations"), withIntermediateDirectories: true)
        try "# Note".write(to: sandbox.appending(path: "conversations/2026-11-16_20-00-00.md"), atomically: true, encoding: .utf8)
        let run = base.appending(path: "runs/2026-11-16_20-11-09", directoryHint: .isDirectory)
        try manager.createDirectory(at: run, withIntermediateDirectories: true)
        try #"{"topic": "Critical path geiserich 2026-11-16 before 2011", "seconds": 300.5, "language": "de"}"#
            .write(to: run.appending(path: "run.json"), atomically: true, encoding: .utf8)
        try "{\"kind\":\"model_request\",\"t\":1}\n{\"kind\":\"card_started\",\"t\":2}\n{\"kind\":\"usage\",\"t\":3}\n"
            .write(to: run.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
        let sound = Data(repeating: 7, count: 3000)
        try sound.write(to: run.appending(path: "audio.wav"))
        var topic = Topic(name: "Critical path geiserich 2026-11-16 before 2011")
        topic.evaluation = true

        let archive = try TopicExport.pack(name: topic.name, topic: topic, sandbox: sandbox, runs: [run], reason: "evaluation",
                                            into: base.appending(path: "runs/exports"))

        #expect(!manager.fileExists(atPath: run.path) && !manager.fileExists(atPath: sandbox.path), "moved, not copied")
        #expect(archive.lastPathComponent.hasSuffix("_critical-path-geiserich-2026-11-16-before-2011.listen-topic"))
        let manifest = try JSONDecoder().decode(TopicExport.Manifest.self, from: Data(contentsOf: archive.appending(path: "manifest.json")))
        #expect(manifest.format == "listen-topic-export" && manifest.version == 1 && manifest.topicID == topic.id.uuidString)
        #expect(manifest.runs.first == .init(name: "2026-11-16_20-11-09", started: nil, seconds: 300.5, audioSeconds: nil, language: "de",
                                             events: 3, requests: 1, cards: 1))
        let audio = try #require(manifest.contents.first { $0.path == "runs/2026-11-16_20-11-09/audio.wav" })
        #expect(audio.bytes == 3000 && audio.sha256 == SHA256.hash(data: sound).map { String(format: "%02x", $0) }.joined())
        #expect(manifest.contents.contains { $0.path == "topic/conversations/2026-11-16_20-00-00.md" })
        #expect(manifest.contents.contains { $0.path == "topic.json" })
        let index = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: base.appending(path: "runs/exports/index.json")))
        #expect(index["runs"]?["2026-11-16_20-11-09"] == archive.lastPathComponent + "/runs/2026-11-16_20-11-09")
    }

    @Test func evaluationTopicsAreRecognisedAndOlderTopicsLoadUnmarked() throws {
        #expect(TopicExport.isEvaluation("Context routing Dreisam 2026-11-16 JEV V3"))
        #expect(TopicExport.isEvaluation("Scripted") && TopicExport.isEvaluation("Snippet check"))
        #expect(!TopicExport.isEvaluation("General") && !TopicExport.isEvaluation("Scriptedness") && !TopicExport.isEvaluation("Merlo"))
        let old = try JSONDecoder().decode(Topic.self, from: Data(#"{"id": "6B9920D5-B6EC-43AA-9FE7-752CAD36144D", "name": "General"}"#.utf8))
        #expect(!old.evaluation)
    }
}
