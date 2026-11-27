import Foundation
import Observation

/// Each system owns its settings. system.json supplies defaults for new definitions only.
@MainActor @Observable
final class SystemStore {
    private(set) var systems: [ListenSystem]
    private(set) var storageProblem: String?
    var lastError: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: SystemConfig
    @ObservationIgnored private var revision: Data?

    nonisolated static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/systems.json")
    }

    init(file: URL = SystemStore.defaultFile, current: @autoclosure () -> SystemConfig = SystemConfig.load().config) {
        self.file = file
        defaults = current()
        let data = try? Data(contentsOf: file)
        revision = data
        systems = []
        if let data {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard (1...2).contains(saved.version), Set(saved.systems.map(\.id)).count == saved.systems.count else {
                    throw SystemPackageError(message: "The saved systems version or system IDs are invalid.")
                }
                systems = Self.withBuiltIns(saved.systems).map { materialize($0) }
                if saved.version != 2 || systems != saved.systems {
                    do { try persist(systems) }
                    catch { storageProblem = "Systems were loaded but could not be migrated. \(error.localizedDescription)" }
                }
            } catch {
                storageProblem = "Saved systems could not be loaded. The original file has been preserved. \(error.localizedDescription)"
                systems = Self.seeded(from: defaults, decisions: UserDefaults.standard.bool(forKey: JevClient.enabledKey)).map { materialize($0) }
            }
        } else if FileManager.default.fileExists(atPath: file.path) {
            storageProblem = "The systems file cannot be read. It has not been replaced."
        } else {
            systems = Self.seeded(from: defaults, decisions: UserDefaults.standard.bool(forKey: JevClient.enabledKey)).map { materialize($0) }
            do { try persist(systems) } catch { storageProblem = error.localizedDescription }
        }
    }

    func system(_ id: String?) -> ListenSystem? { systems.first { $0.id == id } }

    func chosen(for topic: Topic?) -> ListenSystem {
        if let chosen = system(topic?.system), chosen.isRunnable { return chosen }
        return system(ListenSystem.defaultID) ?? materialize(ListenSystem.builtIns[0])
    }

    func update(_ system: ListenSystem) {
        do {
            guard let index = systems.firstIndex(where: { $0.id == system.id }) else {
                throw SystemPackageError(message: "This system no longer exists.")
            }
            var next = systems
            next[index] = materialize(system)
            try persist(next)
        } catch { lastError = error.localizedDescription }
    }

    func create() throws -> ListenSystem {
        let system = ListenSystem(id: unusedID("new-system"), name: unusedName("New system"), summary: "", symbol: "square.stack.3d.up",
            blocks: ListenSystem.Kind.allCases.map { .init(kind: $0, on: $0.isFixed) })
        let complete = materialize(system)
        try persist(systems + [complete])
        return complete
    }

    @discardableResult func duplicate(_ system: ListenSystem) throws -> ListenSystem {
        var copy = materialize(system)
        copy.builtIn = false
        copy.name = unusedName(system.name + " copy")
        copy.id = unusedID(system.id + "-copy")
        try persist(systems + [copy])
        return copy
    }

    func package(for system: ListenSystem) -> SystemPackage {
        SystemPackage(system: materialize(system), defaults: defaults)
    }

    func install(_ package: SystemPackage, replace: Bool = false) throws -> ListenSystem {
        var imported = try SystemPackage.read(package.data()).system
        var next = systems
        if replace, let index = next.firstIndex(where: { $0.id == imported.id }) {
            imported.builtIn = next[index].builtIn
            next[index] = imported
        } else {
            imported.builtIn = false
            imported.id = unusedID(imported.id)
            imported.name = unusedName(imported.name)
            next.append(imported)
        }
        try persist(next)
        return imported
    }

    func delete(_ system: ListenSystem) {
        guard !system.builtIn else { return }
        do { try persist(systems.filter { $0.id != system.id }) } catch { lastError = error.localizedDescription }
    }

    func reset(_ system: ListenSystem) {
        guard let original = ListenSystem.builtIns.first(where: { $0.id == system.id }) else { return }
        update(materialize(original))
    }

    func isChanged(_ system: ListenSystem) -> Bool {
        guard let original = ListenSystem.builtIns.first(where: { $0.id == system.id }) else { return false }
        return materialize(original) != system
    }

    private func materialize(_ original: ListenSystem) -> ListenSystem {
        var system = original
        for kind in ListenSystem.Kind.allCases where !system.blocks.contains(where: { $0.kind == kind }) {
            system.blocks.append(.init(kind: kind, on: system.requires(kind)))
        }
        for kind in ListenSystem.Kind.allCases where system.requires(kind) { system.set(kind, true) }
        if system.isVoiceAssistant { system.set(.writer, false) }
        for kind in ListenSystem.Kind.allCases {
            if let parent = kind.dependsOn, !system.isOn(parent) { system.set(kind, false) }
        }
        system.configuration = system.effectiveConfiguration(over: defaults)
        return system
    }

    private struct Saved: Codable { var version = 2; var systems: [ListenSystem] }

    /// Compare-and-save protects other windows. Memory changes only after the atomic write.
    private func persist(_ next: [ListenSystem]) throws {
        guard storageProblem == nil else { throw SystemPackageError(message: storageProblem!) }
        let disk = try? Data(contentsOf: file)
        guard disk == revision else {
            throw SystemPackageError(message: "Systems changed in another window. Reopen this view before saving.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Saved(systems: next))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let disk { try disk.write(to: file.appendingPathExtension("backup"), options: .atomic) }
        try data.write(to: file, options: .atomic)
        revision = data
        systems = next
    }

    nonisolated static func withBuiltIns(_ stored: [ListenSystem]) -> [ListenSystem] {
        var systems = stored.map { original in
            var system = original
            for kind in ListenSystem.Kind.allCases where !system.blocks.contains(where: { $0.kind == kind }) {
                system.blocks.append(.init(kind: kind, on: false))
            }
            return system
        }
        for builtIn in ListenSystem.builtIns where !systems.contains(where: { $0.id == builtIn.id }) {
            systems.insert(builtIn, at: min(systems.count, ListenSystem.builtIns.firstIndex(of: builtIn) ?? 0))
        }
        return systems
    }

    nonisolated static func seeded(from config: SystemConfig, decisions: Bool) -> [ListenSystem] {
        ListenSystem.builtIns.map { original in
            guard original.id == ListenSystem.defaultID else { return original }
            var system = original
            system.set(.secondHearing, config.voice.whisper)
            system.set(.swissGerman, config.voice.swissGerman)
            system.set(.speakers, config.voice.speakers)
            system.set(.decisions, decisions)
            system.set(.quotes, config.agents.evidenceAnswers)
            system.set(.research, config.agents.web)
            system.set(.researchRejected, config.agents.researchRejectedDrafts)
            system.set(.forecast, config.agents.forecast)
            system.set(.forecastWhileSpeaking, config.agents.forecastWhileSpeaking)
            system.set(.names, config.agents.names)
            system.set(.summary, config.agents.summary)
            system.set(.meetingItems, config.agents.meetingItems)
            system.set(.meetingMinutes, config.agents.meetingMinutes)
            return system
        }
    }

    private func unusedID(_ proposed: String) -> String {
        let base = String(proposed.prefix(52))
        if !systems.contains(where: { $0.id == base }) { return base }
        var number = 2
        while systems.contains(where: { $0.id == "\(base)-\(number)" }) { number += 1 }
        return "\(base)-\(number)"
    }

    private func unusedName(_ proposed: String) -> String {
        let base = String(proposed.prefix(80))
        if !systems.contains(where: { $0.name == base }) { return base }
        var number = 2
        while true {
            let suffix = " \(number)"
            let name = String(base.prefix(max(0, 80 - suffix.count))) + suffix
            if !systems.contains(where: { $0.name == name }) { return name }
            number += 1
        }
    }
}
