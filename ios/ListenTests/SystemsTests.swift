import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct ListenSystems {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "systems-\(UUID().uuidString).json")
    }

    private func system(_ id: String) -> ListenSystem { ListenSystem.builtIns.first { $0.id == id }! }

    @Test func aSystemSetsTheEngineSwitchesOfItsBlocks() {
        var config = SystemConfig()
        system("expert-talk").apply(to: &config)
        #expect(config.agents.researchRejectedDrafts && config.agents.web && config.agents.forecast)
        #expect(!config.agents.evidenceAnswers && !config.agents.forecastWhileSpeaking)
        #expect(config.voice.whisper && config.voice.swissGerman && config.voice.speakers)
        // A block that depends on another does not run without it.
        var plain = system("interview")
        plain.set(.secondHearing, false)
        plain.set(.forecastWhileSpeaking, true)
        plain.set(.forecast, false)
        plain.apply(to: &config)
        #expect(!config.voice.whisper && !config.voice.swissGerman && !config.agents.forecastWhileSpeaking)
    }

    @Test func whatASystemNeedsFollowsFromItsBlocks() {
        #expect(system("interview").requirements == [.decisionService, .models, .dialectModel])
        var local = system("interview")
        for kind in [ListenSystem.Kind.decisions, .quotes, .forecast, .swissGerman, .research, .summary] { local.set(kind, false) }
        #expect(local.requirements == [.models], "the writer still needs a model")
        #expect(system("meeting").isRunnable)
        #expect(system("meeting").missingBlocks.isEmpty)
    }

    @Test func theStatusSaysWhatIsMissing() {
        let all = SystemCapabilities(decisionService: true, models: true, gitHub: false, dialectModel: true)
        #expect(all.status(of: system("interview")).ready)
        let noJev = SystemCapabilities(decisionService: false, models: true, gitHub: false, dialectModel: true)
        #expect(noJev.status(of: system("interview")).text.contains("Decision service"))
        #expect(all.status(of: system("meeting")).ready)
        #expect(noJev.status(of: system("meeting")).text.hasPrefix("Needs"))
    }

    @Test func theFirstInterviewKeepsTheSwitchesInUse() {
        var config = SystemConfig()
        config.agents.evidenceAnswers = false
        config.agents.forecast = false
        let store = SystemStore(file: file(), current: config)
        let interview = store.system("interview")!
        #expect(!interview.isOn(.quotes) && !interview.isOn(.forecast))
        // Applying it gives back the same switches: choosing systems changes nothing.
        var applied = config
        interview.apply(to: &applied)
        #expect(applied.agents == config.agents && applied.voice == config.voice)
        #expect(store.system("expert-talk")?.blocks == system("expert-talk").blocks)
    }

    @Test func systemsAreKeptChangedDuplicatedAndReset() throws {
        let url = file()
        let store = SystemStore(file: url, current: SystemConfig())
        var talk = store.system("expert-talk")!
        talk.set(.forecastWhileSpeaking, true)
        store.update(talk)
        let copy = try store.duplicate(talk)
        #expect(!copy.builtIn && copy.id != talk.id && copy.name == "Expert talk copy")
        let again = SystemStore(file: url, current: SystemConfig())
        #expect(again.system("expert-talk")?.isOn(.forecastWhileSpeaking) == true)
        #expect(again.system(copy.id) == copy)
        #expect(again.isChanged(again.system("expert-talk")!))
        again.reset(again.system("expert-talk")!)
        #expect(again.system("expert-talk")?.blocks == system("expert-talk").blocks)
        #expect(!again.isChanged(again.system("expert-talk")!))
        again.delete(again.system("interview")!)
        #expect(again.system("interview") != nil, "a shipped system is never deleted")
        again.delete(copy)
        #expect(again.system(copy.id) == nil)
    }

    @Test func aTopicRunsWithItsSystemOrInterview() {
        let store = SystemStore(file: file(), current: SystemConfig())
        var topic = Topic(name: "Talk")
        #expect(store.chosen(for: topic).id == "interview")
        topic.system = "expert-talk"
        #expect(store.chosen(for: topic).id == "expert-talk")
        topic.system = "meeting"
        #expect(store.chosen(for: topic).id == "meeting")
        topic.system = "gone"
        #expect(store.chosen(for: topic).id == "interview")
    }

    @Test func topicsSavedBeforeSystemsStillLoad() throws {
        let old = #"{"id":"0F8B1E9A-6C55-4A55-9E4C-2B5B2C1D7E11","name":"Old"}"#
        let topic = try JSONDecoder().decode(Topic.self, from: Data(old.utf8))
        #expect(topic.system == nil)
        var chosen = topic
        chosen.system = "expert-talk"
        let again = try JSONDecoder().decode(Topic.self, from: JSONEncoder().encode(chosen))
        #expect(again.system == "expert-talk")
    }

    @Test func anOlderFileGetsTheBlocksAndSystemsOfANewerApp() {
        var old = system("interview")
        old.blocks.removeAll { $0.kind == .repositories }
        let systems = SystemStore.withBuiltIns([old])
        #expect(systems.map(\.id) == ["interview", "expert-talk", "meeting", "voice-assistant"])
        #expect(systems[0].blocks.contains { $0.kind == .repositories && !$0.on })
    }

    @Test func meetingGraphKeepsItsInputWhenNormalDecisionsAreOff() {
        var meeting = system("meeting")
        meeting.set(.decisions, false)
        let edges = SystemGraph.edges(of: meeting)
        #expect(edges.contains { $0.from == .block(.hearing) && $0.to == .block(.meetingItems) })
        #expect(edges.contains { $0.from == .block(.hearing) && $0.to == .block(.meetingMinutes) })
        #expect(edges.contains { $0.from == .block(.meetingItems) && $0.to == .table })
    }

    @Test func theGraphOnlyJoinsBlocksItCanPlace() {
        for system in ListenSystem.builtIns {
            for edge in SystemGraph.edges(of: system) {
                #expect(SystemGraph.place(edge.from) != nil && SystemGraph.place(edge.to) != nil)
            }
        }
        // No two drawn blocks share a place.
        let places = ListenSystem.Kind.allCases.compactMap { SystemGraph.place(.block($0)) }.map { "\($0.column),\($0.row)" }
            + ["0,1", "4,1"]
        #expect(Set(places).count == places.count)
    }
}
