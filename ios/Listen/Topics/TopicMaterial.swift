import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Files and folders the user gives a topic before a conversation: what the talk is likely to
/// be about. They are copied into the topic's own folder (`material`), so they stay readable on
/// the phone too and nothing outside is touched later. When something is added, an index of
/// short passages is written beside them; a conversation reads only that index.
///
/// What goes to the models: an overview of the files (names and first lines) with every
/// request, and the few passages that share the most specific words with what was just said.
/// The names of things in the files also go to both listening stages, so a term such as
/// "SQL-Injection" is expected rather than heard as "Desqualinjection". The files themselves
/// never leave the device; the passages go to the models the user connected, as the briefing does.
struct TopicMaterial {
    /// Text formats read as they are; PDF and RTF are converted to text.
    static let readable: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "xml", "html", "htm", "rtf", "pdf",
        "swift", "py", "js", "ts", "java", "kt", "go", "rs", "c", "h", "cpp", "sql", "sh", "toml",
    ]
    static let largestFile = 5_000_000
    static let mostFiles = 200

    let folder: URL
    private var indexFile: URL { folder.appending(path: ".listen-index.json") }

    init(topic: Topic.ID, root: URL = TopicSandbox.root) {
        folder = TopicSandbox(topic: topic, root: root).folder.appending(path: "material", directoryHint: .isDirectory)
    }

    /// What was added, files and folders as the user chose them.
    var items: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies files, and the readable files inside folders, into the topic. Too large, unreadable
    /// and surplus files are left out. Returns how many files were copied.
    @discardableResult
    func add(_ chosen: [URL]) -> Int {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied = Self.files(in: folder).count
        let before = copied
        for url in chosen {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            let destination = unused(folder.appending(path: url.lastPathComponent))
            if isFolder.boolValue {
                for file in Self.files(in: url) where copied < Self.mostFiles {
                    let relative = String(file.path.dropFirst(url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let target = destination.appending(path: relative)
                    try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? manager.copyItem(at: file, to: target)) != nil {
                        if Self.isHintFile(target) { try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path) }
                        copied += 1
                    }
                }
            } else if copied < Self.mostFiles, Self.isReadable(url) {
                if (try? manager.copyItem(at: url, to: destination)) != nil {
                    if Self.isHintFile(destination) { try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path) }
                    copied += 1
                }
            }
        }
        writeIndex()
        return copied - before
    }

    func remove(_ item: URL) {
        guard item.path.hasPrefix(folder.path) else { return }
        try? FileManager.default.removeItem(at: item)
        writeIndex()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The index written when material was added; empty when there is none.
    var index: MaterialIndex {
        (try? Data(contentsOf: indexFile)).flatMap { try? JSONDecoder().decode(MaterialIndex.self, from: $0) } ?? MaterialIndex()
    }

    func writeIndex() {
        let files = Self.files(in: folder)
        let passages = files.filter { !Self.isHintFile($0) }.flatMap { file in
            MaterialIndex.passages(of: Self.text(of: file), source: String(file.path.dropFirst(folder.path.count + 1)))
        }
        var seen = Set<String>()
        // Reimporting replaces the active reference set, while older copies remain recoverable.
        // A malformed newest set disables hints rather than silently reviving stale cards.
        let file = files.filter(Self.isHintFile).max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a == b ? $0.path < $1.path : a < b
        }
        let hints = (file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([MaterialIndex.PreparedHint].self, from: $0) } ?? [])
            .filter { $0.isValid && seen.insert($0.id).inserted }.prefix(32)
        let index = MaterialIndex(passages: passages, overview: MaterialIndex.overview(passages), terms: MaterialIndex.terms(in: passages),
                                  preparedHints: Array(hints))
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexFile, options: .atomic) }
    }

    private static func isHintFile(_ file: URL) -> Bool {
        file.lastPathComponent.wholeMatch(of: /listen-hints(?: [0-9]+)*\.json/) != nil
    }

    private func unused(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let name = url.pathExtension.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(url.pathExtension)"
            candidate = url.deletingLastPathComponent().appending(path: name)
            number += 1
        }
        return candidate
    }

    // MARK: Reading

    static func isReadable(_ file: URL) -> Bool {
        guard readable.contains(file.pathExtension.lowercased()) else { return false }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0 && size <= largestFile
    }

    /// Readable files inside a folder, in a fixed order; hidden files and packages are skipped.
    static func files(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter(isReadable)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func text(of file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: file)?.string ?? ""
        case "rtf":
            return (try? NSAttributedString(url: file, options: [:], documentAttributes: nil))?.string ?? ""
        case "html", "htm":
            let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return raw.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        default:
            return (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
        }
    }
}
