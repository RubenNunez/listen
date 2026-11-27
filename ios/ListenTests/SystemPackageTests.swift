import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct SystemPackages {
    private func file() -> URL { FileManager.default.temporaryDirectory.appending(path: "package-\(UUID().uuidString)/systems.json") }
    private func source() -> ListenSystem { ListenSystem.builtIns[2] }
    private func packet() -> SystemPackage { SystemPackage(system: source(), defaults: SystemConfig()) }
    private func changed(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: packet().data()) as! [String: Any]
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func rejects(_ data: Data) {
        do { _ = try SystemPackage.read(data); Issue.record("Invalid system was accepted") }
        catch { }
    }

    @Test func aCompleteSystemRoundTripsWithoutGlobalDefaults() throws {
        var defaults = SystemConfig()
        defaults.prompts.meetingMinutes = "Use the topic language. Keep explicit deadlines."
        defaults.models.main = "test-model"
        defaults.scheduler.forecastMinimumIntervalSeconds = 37
        let original = SystemPackage(system: source(), defaults: defaults)
        let decoded = try SystemPackage.read(original.data())
        #expect(decoded.system == original.system)
        #expect(decoded.system.configuration?.prompts.meetingMinutes == defaults.prompts.meetingMinutes)
        #expect(decoded.system.configuration?.scheduler.forecastMinimumIntervalSeconds == 37)
        let root = try JSONSerialization.jsonObject(with: decoded.data()) as! [String: Any]
        let system = root["system"] as! [String: Any]
        let settings = system["settings"] as! [String: Any]
        #expect((settings["agents"] as! [String: Any])["meetingItems"] == nil, "switches have one authority")
        #expect(root["credentials"] == nil && system["builtIn"] == nil)
    }

    @Test func newAndImportedSystemsAreIndependentAndCollisionsAreExplicit() throws {
        let url = file()
        let store = SystemStore(file: url, current: SystemConfig())
        let original = store.system("meeting")!
        var package = store.package(for: original)
        package.system.configuration!.prompts.meetingMinutes = "Distinct minutes instruction"
        let added = try store.install(package)
        #expect(added.id != original.id && !added.builtIn)
        #expect(store.system("meeting") == original)
        #expect(added.configuration?.prompts.meetingMinutes == "Distinct minutes instruction")
        let updated = try store.install(package, replace: true)
        #expect(updated.id == original.id && updated.builtIn)
        #expect(store.system(added.id) == added)
        let created = try store.create()
        #expect(created.isOn(.hearing) && created.isOn(.writer) && !created.isOn(.meetingItems))
        let reload = SystemStore(file: url, current: SystemConfig())
        #expect(reload.systems == store.systems)
    }

    @Test func applyingASystemRestoresItsOwnSettingsAndMeetingSwitches() {
        var own = SystemConfig()
        own.prompts.meetingMinutes = "Own prompt"
        var system = source()
        system.configuration = own
        system.set(.decisions, false)
        var destination = SystemConfig()
        system.apply(to: &destination)
        #expect(destination.prompts.meetingMinutes == "Own prompt")
        #expect(destination.agents.meetingItems && destination.agents.meetingMinutes)
        #expect(system.usesDecisions, "Meeting still needs typed decisions with answers off")
    }

    @Test func longNamesRemainPortableWhenCopiedOrImportedAgain() throws {
        let store = SystemStore(file: file(), current: SystemConfig())
        var package = packet()
        package.system.name = String(repeating: "x", count: 80)
        let first = try store.install(package)
        let second = try store.install(package)
        let copy = try store.duplicate(first)
        #expect(second.name != first.name && copy.name != second.name)
        for system in [first, second, copy] {
            #expect(system.name.count <= 80)
            _ = try SystemPackage.read(store.package(for: system).data())
        }
    }

    @Test func invalidVersionsFieldsBlocksAndDependenciesAreRejected() throws {
        rejects(try changed { $0["version"] = 2 })
        rejects(try changed { $0["version"] = true })
        rejects(try changed { $0["flow"] = ["run": "arbitrary"] })
        for mode in 0..<5 {
            rejects(try changed { root in
                var system = root["system"] as! [String: Any]
                var blocks = system["blocks"] as! [[String: Any]]
                switch mode {
                case 0: blocks[0]["kind"] = "invented"
                case 1: blocks.append(blocks[0])
                case 2: blocks[0]["on"] = false
                case 3: blocks[0]["on"] = 1
                default:
                    blocks[blocks.firstIndex { $0["kind"] as? String == "secondHearing" }!]["on"] = false
                }
                system["blocks"] = blocks; root["system"] = system
            })
        }
        rejects(Data(repeating: 32, count: SystemPackage.maximumBytes + 1))
        rejects(Data("Instructions followed by {}".utf8))
    }

    @Test func partialSettingsAndInvalidLimitsAreRejected() throws {
        for mode in 0..<4 {
            rejects(try changed { root in
                var system = root["system"] as! [String: Any]
                var settings = system["settings"] as! [String: Any]
                var scheduler = settings["scheduler"] as! [String: Any]
                switch mode {
                case 0: settings["prompts"] = [:]
                case 1: scheduler["forecastRankProbability"] = 1.2
                case 2: scheduler["linesInRequest"] = 0
                default: scheduler["unknown"] = 4
                }
                settings["scheduler"] = scheduler
                system["settings"] = settings; root["system"] = system
            })
        }
    }

    @Test func importsDoNotDiscardKnownUnavailableBlocks() throws {
        var system = source(); system.set(.repositories, true)
        let parsed = try SystemPackage.read(SystemPackage(system: system, defaults: SystemConfig()).data())
        #expect(parsed.system.missingBlocks == [.repositories])
        let all = SystemCapabilities(decisionService: true, models: true, gitHub: true, dialectModel: true)
        #expect(all.status(of: parsed.system).text.hasPrefix("Unavailable"))
    }

    @Test func malformedSavedFilesArePreservedAndCannotBeOverwritten() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ malformed".utf8)
        try original.write(to: url)
        let store = SystemStore(file: url, current: SystemConfig())
        #expect(store.storageProblem != nil)
        do { _ = try store.create(); Issue.record("Corrupt storage was replaced") } catch { }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func anotherWindowsEditsArePreserved() throws {
        let url = file()
        let first = SystemStore(file: url, current: SystemConfig())
        let second = SystemStore(file: url, current: SystemConfig())
        _ = try first.create()
        let saved = try Data(contentsOf: url)
        let oldMemory = second.systems
        do { _ = try second.create(); Issue.record("Stale window overwrote new data") } catch { }
        #expect(second.systems == oldMemory)
        #expect(try Data(contentsOf: url) == saved)
    }

    @Test func olderDefinitionsCaptureDefaultsOnceAndKeepABackup() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldSystem = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source()))
        let old = try JSONSerialization.data(withJSONObject: ["version": 1, "systems": [oldSystem]])
        try old.write(to: url)
        var defaults = SystemConfig(); defaults.prompts.meetingMinutes = "Migration default"
        let migrated = SystemStore(file: url, current: defaults)
        #expect(migrated.storageProblem == nil)
        #expect(migrated.system("meeting")?.configuration?.prompts.meetingMinutes == "Migration default")
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == old)
        defaults.prompts.meetingMinutes = "Later global edit"
        let reopened = SystemStore(file: url, current: defaults)
        #expect(reopened.system("meeting")?.configuration?.prompts.meetingMinutes == "Migration default")
    }

    @Test func theLLMTemplateContainsTheActualImportableDefinition() throws {
        let template = try packet().llmTemplate()
        let json = String(template.components(separatedBy: "COMPLETE STARTING SYSTEM\n").last!)
        let parsed = try SystemPackage.read(Data(json.utf8))
        #expect(parsed.system.id == "meeting")
        #expect(template.contains("meetingItems") && template.contains("Unavailable in this build"))
        let fenced = "```json\n" + json + "\n```"
        #expect(try SystemPackage.read(Data(fenced.utf8)).system == parsed.system)
    }
}
