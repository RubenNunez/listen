import Foundation

/// The pages a topic links to, read once when a conversation starts and given
/// to the models as context. Only links the user typed are fetched; the pages'
/// text is material for the models and is never treated as instructions.
enum LinkContext {
    struct Page: Equatable, Sendable {
        var url: String
        var title: String
        var text: String
    }

    static let perPage = 1500
    static let most = 5

    /// Fetches the pages, the reachable ones in the order given.
    static func load(_ links: [String]) async -> [Page] {
        await withTaskGroup(of: (Int, Page?).self) { group in
            for (index, link) in links.prefix(most).enumerated() {
                group.addTask { (index, await page(link)) }
            }
            var pages: [(Int, Page)] = []
            for await (index, page) in group { if let page { pages.append((index, page)) } }
            return pages.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func page(_ link: String) async -> Page? {
        guard let url = URL(string: link) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("text/html, text/plain, text/markdown", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (bytes, response) = try? await session.bytes(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.isEmpty || type.contains("text") || type.contains("json") || type.contains("xml") else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_000_000 else { return nil }
                data.append(byte)
            }
        } catch { return nil }
        let raw = String(decoding: data, as: UTF8.self)
        let isHTML = type.contains("html") || raw.range(of: "<html", options: .caseInsensitive) != nil
        let text = isHTML ? Self.text(fromHTML: raw) : raw
        let title = isHTML ? Self.title(inHTML: raw) : nil
        guard !text.isEmpty else { return nil }
        return Page(url: link, title: title ?? url.host() ?? link, text: String(text.prefix(perPage)))
    }

    static func title(inHTML html: String) -> String? {
        guard let match = html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/) else { return nil }
        let title = text(fromHTML: String(match.1))
        return title.isEmpty ? nil : String(title.prefix(120))
    }

    /// The readable text of a page: no scripts, styles or tags, common entities
    /// resolved, whitespace collapsed.
    static func text(fromHTML html: String) -> String {
        var text = html
        text.replace(/(?is)<(script|style|noscript|svg|head|nav|footer)\b.*?<\/\1>/, with: " ")
        text.replace(/(?s)<!--.*?-->/, with: " ")
        text.replace(/(?i)<\/(p|div|h[1-6]|li|tr|section|article)>|<br\s*\/?>/, with: "\n")
        text.replace(/<[^>]+>/, with: " ")
        for (entity, character) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü", "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(separator: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The pages as one block for a prompt.
    static func prompt(_ pages: [Page]) -> String {
        pages.map { "[\($0.url)] \($0.title)\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// An address without the tracking a search service adds to it.
    static func plain(_ address: String) -> String {
        var text = address
        text.replace(/[?&]utm_[a-z]+=[^&#)\s]*/, with: "")
        // A query that lost its first part still needs its "?".
        if !text.contains("?"), let amp = text.firstIndex(of: "&") { text.replaceSubrange(amp...amp, with: "?") }
        return text
    }

    /// A card from a model that searched the web, put in order: the sources
    /// leave the lines and stand once at the end, by site, and only those the
    /// search really reported.
    static func tidy(_ card: String, found: [String], sourcesLabel: String) -> String {
        let reported = found.map(plain)
        var chart = ""
        var text = card
        if let block = text.firstMatch(of: /(?s)```chart.*?(```|$)/) {
            chart = String(block.0)
            text.removeSubrange(block.range)
        }
        var cited: [String] = []
        for match in text.matches(of: /\]\((https?:\/\/[^)\s]+)\)/) {
            let address = plain(String(match.1))
            if reported.contains(address), !cited.contains(address) { cited.append(address) }
        }
        // Citations in brackets after a sentence, then lines that hold nothing but links.
        text.replace(/\s*\(\[[^\]]*\]\(https?:\/\/[^)\s]+\)\)/, with: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            var rest = String(line)
            rest.replace(/\[[^\]]*\]\(https?:\/\/[^)\s]+\)/, with: "")
            let onlyLinks = line.contains("](http") && rest.trimmingCharacters(in: CharacterSet(charactersIn: " ·,;-–*•:")).count < 12
            return !onlyLinks
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var sites: [String] = []
        var links: [String] = []
        for address in cited + reported where links.count < 3 {
            guard let host = URL(string: address)?.host()?.replacing(/^www\./, with: ""), !sites.contains(host) else { continue }
            sites.append(host)
            links.append("[\(host)](\(address))")
        }
        if !links.isEmpty { text += "\n\n\(sourcesLabel): " + links.joined(separator: " · ") }
        if !chart.isEmpty { text += "\n\n" + chart }
        return text
    }

    /// A card may link, but only to pages the user gave: any other link keeps
    /// its words and loses its address, and a bare unknown address is removed.
    static func keepingOnlyLinks(to allowed: [String], in card: String) -> String {
        // Code is not prose: an address inside a fenced block is part of the code
        // (an SVG lost its xmlns to this filter, run of 15 November 2026).
        let pieces = card.split(separator: "```", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count < 3 else {
            return pieces.enumerated()
                .map { $0.offset % 2 == 1 ? $0.element : keepingOnlyLinks(to: allowed, in: $0.element, trimming: false) }
                .joined(separator: "```").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return keepingOnlyLinks(to: allowed, in: card, trimming: true)
    }

    private static func keepingOnlyLinks(to allowed: [String], in card: String, trimming: Bool) -> String {
        let known = Set(allowed.map(plain) + allowed)
        var text = card
        // One pass: a Markdown link, or else a bare address.
        text.replace(/\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)|(https?:\/\/[^\s)]+)/) { match in
            if let address = match.2 {
                return known.contains(String(address)) ? String(match.0) : String(match.1 ?? "")
            }
            let address = String(match.3 ?? "")
            return known.contains(address) ? "[\(URL(string: address)?.host() ?? "Link")](\(address))" : ""
        }
        // Lines lose the stray spaces a removed address leaves behind.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.joined(separator: "\n")
        return trimming ? joined.trimmingCharacters(in: .whitespacesAndNewlines) : joined
    }
}
