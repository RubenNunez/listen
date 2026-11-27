import Foundation

/// The app was called Wisper until 15 November 2026. What it stored under
/// that name is taken over once, so topics, keys, notes and settings survive
/// the rename.
enum Migration {
    static func run() {
        let files = FileManager.default
        let support = URL.applicationSupportDirectory
        let old = support.appending(path: "Wisper", directoryHint: .isDirectory)
        let new = support.appending(path: "Listen", directoryHint: .isDirectory)
        if files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) {
            try? files.moveItem(at: old, to: new)
        }
        // Settings lived under the old bundle ID. Readable only where apps are
        // not sandboxed (the locally signed Mac build); elsewhere this finds nothing.
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromWisper") else { return }
        defaults.set(true, forKey: "migratedFromWisper")
        guard let before = UserDefaults(suiteName: "com.meowop.wisper")?.persistentDomain(forName: "com.meowop.wisper") else { return }
        for (key, value) in before where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            defaults.set(value, forKey: key)
        }
    }
}
