import Foundation
import Testing
@testable import Listen

@MainActor private final class VoicePreviewDouble: AssistantSpeechOutput {
    var began: ((ConversationResponseID) -> Void)?
    var finished: ((ConversationResponseID) -> Void)?
    var cancelled: ((ConversationResponseID) -> Void)?
    var spoken: [(String, ConversationResponseID)] = []
    var stops = 0
    func speak(_ text: String, response: ConversationResponseID, language: Language) { spoken.append((text, response)) }
    func stop() { stops += 1; if let id = spoken.last?.1 { cancelled?(id) } }
}

@MainActor @Suite struct AssistantVoiceChoiceTests {
    private func store() -> (SystemStore, URL) {
        let file = URL.temporaryDirectory.appending(path: "voice-choice-\(UUID())/systems.json")
        return (SystemStore(file: file, current: SystemConfig()), file)
    }

    @Test func voiceSelectionSurvivesRelaunchAndRetainsTheSystemsOtherSettings() throws {
        let (store, file) = store()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var system = try #require(store.system("voice-assistant"))
        system.configuration?.conversation?.prompt = "Synthetic owner instructions."
        system.configuration?.conversation?.toolIDs = ["fixture.light"]
        system.configuration?.conversation?.model = "synthetic/model"
        store.update(system)
        let before = try #require(store.system(system.id)?.configuration?.conversation)
        let choice = AssistantVoiceChoice(engine: .local, voice: "Aiden")
        try choice.save(system: system.id, in: store)
        let next = try #require(SystemStore(file: file, current: SystemConfig()).system(system.id)?.configuration?.conversation)
        #expect(next == (try choice.applying(to: before)))
        #expect(next.prompt == before.prompt && next.toolIDs == before.toolIDs && next.model == before.model)
    }

    @Test func invalidOrMissingChoicesNeverOverwriteTheSavedSystem() throws {
        let (store, file) = store()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let before = try Data(contentsOf: file)
        #expect(throws: (any Error).self) {
            try AssistantVoiceChoice(engine: .local, voice: "Unknown").save(system: "voice-assistant", in: store)
        }
        #expect(throws: (any Error).self) {
            try AssistantVoiceChoice(engine: .system, voice: "Aiden").save(system: "missing", in: store)
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func anotherEditorsChangesAreNotOverwrittenByAStalePicker() throws {
        let (store, file) = store()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let other = SystemStore(file: file, current: SystemConfig())
        var system = try #require(other.system("voice-assistant"))
        system.configuration?.conversation?.prompt = "New instructions from another editor."
        other.update(system)
        let before = try Data(contentsOf: file)
        #expect(throws: (any Error).self) {
            try AssistantVoiceChoice(engine: .local, voice: "Ryan").save(system: system.id, in: store)
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func theSameVoiceNameUnderAnotherModelIsAnotherChoiceAndIsSavedAsSuch() throws {
        let (store, file) = store()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let small = AssistantVoiceChoice(engine: .local, model: TalkBack.models[0].id, voice: "Serena")
        let usual = AssistantVoiceChoice(engine: .local, model: TalkBack.models[1].id, voice: "Serena")
        #expect(small != usual && small.id != usual.id && small.name == usual.name && small.title != usual.title)
        #expect(usual == AssistantVoiceChoice(engine: .local, voice: "Serena"), "the default model is the one earlier choices meant")
        try small.save(system: "voice-assistant", in: store)
        func saved() throws -> VoiceAssistantConfiguration {
            try #require(SystemStore(file: file, current: SystemConfig()).system("voice-assistant")?.configuration?.conversation)
        }
        #expect(AssistantVoiceChoice(try saved()) == small)
        try usual.save(system: "voice-assistant", in: store)
        #expect(AssistantVoiceChoice(try saved()) == usual)
        let pocket = AssistantVoiceChoice(engine: .local, model: TalkBack.pocketGerman, voice: "eponine")
        try pocket.save(system: "voice-assistant", in: store)
        #expect(AssistantVoiceChoice(try saved()) == pocket && pocket.title == "Eponine · Pocket TTS German")
        // A voice under a model that does not have it is not a choice at all.
        #expect(throws: (any Error).self) {
            try AssistantVoiceChoice(engine: .local, model: TalkBack.pocketGerman, voice: "Serena").save(system: "voice-assistant", in: store)
        }
        #expect(AssistantVoiceChoice(try saved()) == pocket)
    }

    @Test func aChoiceChangesTheVoiceFieldsAndNothingElse() throws {
        var before = VoiceAssistantConfiguration(enabled: true, model: "local/apple", toolIDs: ["fixture.light"])
        before.prompt = "Synthetic owner instructions."
        before.recordAudio = true
        before.maximumTurns = 7
        let next = try AssistantVoiceChoice(engine: .local, model: TalkBack.pocketGerman, voice: "cosette").applying(to: before)
        var expected = before
        expected.talkBackEngine = .local
        expected.talkBackModel = TalkBack.pocketGerman
        expected.talkBackVoice = "cosette"
        #expect(next == expected && next.model == "local/apple", "the answer model is not the voice's to change")
    }

    @Test func theComparisonOffersFemaleVoicesOfModelsThatRunHereAndNothingElse() {
        let current = AssistantVoiceChoice(engine: .local, model: TalkBack.pocketGerman, voice: "alba")
        let offers = AssistantVoiceChoice.offered(current: current, downloaded: { _ in false })
        #expect(offers.map(\.model.id) == [TalkBack.pocketGerman, TalkBack.supertonic, TalkBack.defaultModel])
        #expect(offers[0].choices.map(\.voice) == ["alba", "cosette", "fantine", "eponine"])
        #expect(offers[2].choices.map(\.voice) == ["Serena", "Vivian", "Ono_Anna", "Sohee"])
        let all = offers.flatMap(\.choices)
        #expect(all.allSatisfy { $0.engine == .local } && Set(all.map(\.id)).count == all.count)
        #expect(!all.contains { ["Ryan", "Aiden", "Eric", "Dylan", "Uncle_Fu"].contains($0.voice) })
        #expect(all.allSatisfy { (try? $0.applying(to: VoiceAssistantConfiguration(enabled: true))) != nil }, "every entry can be saved")
        // Another Qwen checkpoint appears once it is the one in use, or on the device.
        let small = AssistantVoiceChoice(engine: .local, model: TalkBack.models[0].id, voice: "Vivian")
        #expect(AssistantVoiceChoice.offered(current: small, downloaded: { _ in false }).map(\.model.id)
            == [TalkBack.pocketGerman, TalkBack.supertonic, TalkBack.models[0].id, TalkBack.defaultModel])
        #expect(AssistantVoiceChoice.offered(current: current, downloaded: { $0 == TalkBack.models[2].id }).map(\.model.id)
            == [TalkBack.pocketGerman, TalkBack.supertonic, TalkBack.defaultModel, TalkBack.models[2].id])
    }

    @Test func anEarlierMaleOrDeviceVoiceIsShownAndKeptUntilAnotherIsChosen() throws {
        var male = VoiceAssistantConfiguration(enabled: true)
        male.talkBackEngine = .local
        male.talkBackVoice = "Ryan"
        let kept = AssistantVoiceChoice(male)
        #expect(kept.name == "Ryan" && kept.title == "Ryan · Qwen3-TTS 0.6B 8-bit")
        #expect(!AssistantVoiceChoice.offered(current: kept, downloaded: { _ in false }).contains { $0.choices.contains(kept) })
        #expect(try kept.applying(to: male) == male, "showing the saved voice rewrites nothing")

        var device = male
        device.talkBackEngine = .system
        let system = AssistantVoiceChoice(device)
        #expect(system.name == "Device voice" && system.detail == nil && system.id == "system")
        #expect(!AssistantVoiceChoice.offered(current: system, downloaded: { _ in false }).contains { $0.choices.contains(system) })
        #expect(try system.applying(to: device) == device)
        // Going back to the device voice elsewhere keeps the local pair the system had.
        #expect(try AssistantVoiceChoice(engine: .system, voice: "Serena").applying(to: male).talkBackVoice == "Ryan")
    }

    @Test func aSampleOfAModelThatCannotSpeakHereFailsOpenlyAndMakesNoVoice() {
        var made = 0
        let preview = AssistantVoicePreview { _ in made += 1; return VoicePreviewDouble() }
        var ends = 0
        preview.ended = { ends += 1 }
        // Pocket TTS German and an English conversation: refused before any voice exists.
        preview.play(.init(engine: .local, model: TalkBack.pocketGerman, voice: "alba"), configuration: .init(enabled: true), language: .en)
        #expect(made == 0 && preview.playing == nil && preview.failure != nil && ends == 0)
        // A voice outside the catalogue is refused the same way.
        preview.clearFailure()
        preview.play(.init(engine: .local, model: TalkBack.pocketGerman, voice: "Serena"), configuration: .init(enabled: true), language: .de)
        #expect(made == 0 && preview.playing == nil && preview.failure != nil && ends == 0)
    }

    @Test func theEndOfASampleIsReportedOnceAndOnlyIfOneWasPlaying() throws {
        let voice = VoicePreviewDouble()
        let preview = AssistantVoicePreview { _ in voice }
        var ends = 0
        preview.ended = { ends += 1 }
        preview.stop()
        #expect(ends == 0)
        preview.play(.init(engine: .system, voice: "Serena"), configuration: .init(enabled: true), language: .de)
        let id = try #require(voice.spoken.last?.1)
        #expect(voice.spoken[0].0 == AssistantVoicePreview.text(.de) && ends == 0)
        voice.began?(id)
        voice.finished?(id)
        #expect(ends == 1 && preview.playing == nil && !preview.audible)
        preview.stop()
        #expect(ends == 1)
    }

    @Test func replacingOrClosingAPreviewIgnoresItsLateCallbacks() throws {
        let first = VoicePreviewDouble(), second = VoicePreviewDouble()
        var calls = 0
        let preview = AssistantVoicePreview { _ in calls += 1; return calls == 1 ? first : second }
        let configuration = VoiceAssistantConfiguration(enabled: true)
        let one = AssistantVoiceChoice(engine: .system, voice: "Serena")
        let two = AssistantVoiceChoice(engine: .system, voice: "Aiden")
        #expect(calls == 0 && preview.playing == nil, "opening a picker must not start audio")
        preview.play(one, configuration: configuration, language: .de)
        let old = try #require(first.spoken.last?.1)
        #expect(first.spoken[0].0 == "Hallo. Welche Stimme gefällt dir am besten?")
        first.began?(old)
        #expect(preview.audible)
        preview.play(two, configuration: configuration, language: .de)
        let current = try #require(second.spoken.last?.1)
        first.finished?(old); first.cancelled?(old)
        #expect(preview.playing == two && !preview.audible && preview.failure == nil)
        second.began?(current)
        preview.stop()
        second.finished?(current); second.cancelled?(current)
        #expect(preview.playing == nil && !preview.audible && preview.failure == nil)
        #expect(first.stops == 1 && second.stops == 1)
    }
}
