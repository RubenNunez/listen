import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import Listen

@Suite struct SupertonicVoiceTests {
    @Test func aCompleteMainClauseIsPreferredOverAnArbitraryCutInsideItsRelativeClause() throws {
        let text = "Die alten Römer bauten ein Reich auf, das weite Teile Europas, Nordafrikas und des Nahen Ostens umfasste."
        let parts = try SupertonicVoice.parts(text, language: .de)
        #expect(parts.first == "Die alten Römer bauten ein Reich auf,")
        #expect(parts.joined(separator: " ") == text)
        #expect(parts.allSatisfy { $0.decomposedStringWithCompatibilityMapping.unicodeScalars.count <= 69 })
        let instruction = "Die Hinweise sind eindeutig: Ein POST darf hier nicht automatisch wiederholt werden."
        let clauses = try SupertonicVoice.parts(instruction, language: .de)
        #expect(clauses.first == "Die Hinweise sind eindeutig:")
        #expect(clauses.joined(separator: " ") == instruction)
    }
    @Test func aNegationAndItsNounStayTogetherWithoutSentenceFinalIntonationAtAChunkSeam() throws {
        for (text, language, phrase) in [
            ("Der ausführliche Bericht gibt zu dieser wichtigen Frage noch keine Auskunft.", Language.de, "keine Auskunft"),
            ("This detailed report about the current situation provides no information about the cause.", Language.en, "no information")
        ] {
            let parts = try SupertonicVoice.parts(text, language: language)
            #expect(parts.count > 1 && parts.joined(separator: " ") == text)
            #expect(parts.contains { $0.contains(phrase) })
            for (index, part) in parts.enumerated() {
                let input = SupertonicVoice.continuationInput(part, continues: index < parts.count - 1)
                #expect(input.decomposedStringWithCompatibilityMapping.unicodeScalars.count <= 70)
                if index < parts.count - 1, part.last?.isLetter == true { #expect(input.hasSuffix(",")) }
            }
        }
        #expect(SupertonicVoice.continuationInput("Das ist abgeschlossen.", continues: true) == "Das ist abgeschlossen.")
        #expect(SupertonicVoice.continuationInput("Ein vollständiger letzter Satz", continues: false) == "Ein vollständiger letzter Satz")
    }

    @Test func outerPaddingIsBoundedWithoutCuttingSoftConsonantsOrInternalPauses() {
        let rate = 1000
        let soft = [Float](repeating: 0.0005, count: 50)
        let voice = [Float](repeating: 0.1, count: 200)
        let pause = [Float](repeating: 0, count: 400)
        let body = soft + voice + pause + voice + soft
        let padded = [Float](repeating: 0, count: 600) + body + [Float](repeating: 0, count: 700)
        let trimmed = SupertonicVoice.trimmingPadding(padded, sampleRate: rate)
        #expect(trimmed == [Float](repeating: 0, count: 80) + body + [Float](repeating: 0, count: 80))
        #expect(SupertonicVoice.trimmingPadding(body, sampleRate: rate) == body)
        #expect(SupertonicVoice.trimmingPadding(pause, sampleRate: rate) == pause)
        let joined = SupertonicVoice.trimmingPadding(padded, sampleRate: rate,
            contextMilliseconds: 40, minimumTrimMilliseconds: 40)
        #expect(joined == [Float](repeating: 0, count: 40) + body + [Float](repeating: 0, count: 40),
            "tighter joins keep the soft consonants and the internal breath intact")
    }

    @Test func thePinnedPackCoversTheSDKWithoutTheCrashingGPUVariant() throws {
        let files = SupertonicVoiceFiles.files
        let required = ModelNames.Supertonic3.requiredFiles(veVariant: "ane-int4")
        #expect(required.allSatisfy { path in files.contains { $0.path == path || $0.path.hasPrefix(path + "/") } })
        #expect(!files.contains { $0.path.hasPrefix("VectorEstimator_v2.mlmodelc/") })
        #expect(files.allSatisfy { $0.sha256?.count == 64 })
        #expect(SupertonicVoiceFiles.folder(in: URL(fileURLWithPath: "/tmp/fixture")).lastPathComponent == Repo.supertonic3.folderName)
        let model = TalkBack.supertonic
        #expect(TalkBack.voices(for: model) == ["F2"] && TalkBack.synthesizer(for: model) is SupertonicVoice)
        var config = VoiceAssistantConfiguration(enabled: true)
        config.talkBackModel = model; config.talkBackVoice = "F2"
        try config.validate()
        config.talkBackVoice = "M1"
        #expect(throws: (any Error).self) { try config.validate() }
        let text = "Ich prüfe die aktuelle Quelle zu Nvidia. Danach erkläre ich dir kurz, was die Entscheidung des Verwaltungsrats bedeutet."
        let parts = try SupertonicVoice.parts(text, language: .de)
        #expect(parts.joined(separator: " ") == text && parts.allSatisfy { $0.count <= 70 })
        // Preserve a long German token without overflowing the model's 128-scalar input.
        let long = String(repeating: "Ä", count: 160) + " Danach bleibt dieser letzte Satz erhalten."
        let bounded = try SupertonicVoice.parts(long, language: .de)
        #expect(bounded.allSatisfy { $0.decomposedStringWithCompatibilityMapping.unicodeScalars.count <= 70 })
        #expect(bounded.joined().filter { !$0.isWhitespace } == long.filter { !$0.isWhitespace })
        #expect(throws: (any Error).self) {
            try SupertonicVoice.parts("a" + String(repeating: "\u{0308}", count: 150), language: .de)
        }
    }

    @Test func aSameSizeCorruptCachedFileIsRepairedBeforeItCanBecomeReady() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "supertonic-\(UUID().uuidString)")
        defer { SupertonicVoiceFiles.remove(base: base) }
        let file = SupertonicVoiceFiles.File(path: "fixture.bin", bytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let folder = SupertonicVoiceFiles.folder(in: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: folder.appending(path: file.path))
        #expect(SupertonicVoiceFiles.complete([file], base: base) == nil)
        try await SupertonicVoiceFiles.download([file], base: base, fetch: { source, destination, _ in
            #expect(source.absoluteString.contains(SupertonicVoiceFiles.revision))
            try Data("abc".utf8).write(to: destination)
        }, progress: { _ in })
        #expect(SupertonicVoiceFiles.complete([file], base: base) == folder)
        #expect(try Data(contentsOf: folder.appending(path: file.path)) == Data("abc".utf8))
        // Refused downloads never write a new completion marker.
        try Data("bad".utf8).write(to: folder.appending(path: file.path))
        do {
            try await SupertonicVoiceFiles.download([file], base: base,
                fetch: { _, destination, _ in try Data("bad".utf8).write(to: destination) }, progress: { _ in })
            Issue.record("corrupt download accepted")
        } catch { #expect(SupertonicVoiceFiles.complete([file], base: base) == nil) }
    }
}
