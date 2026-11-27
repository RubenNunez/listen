import Foundation

/// How fast each model of the signed-in ChatGPT plan answers: the time to the first
/// word and to the whole of a short card. The fastest ones are the right drafters,
/// because a draft is judged by when it appears, and the checked card comes after it.
enum ModelSpeed {
    struct Result: Codable {
        var slug: String
        var name: String
        /// Seconds to the first piece of text; nil when the model failed.
        var firstWord: Double?
        var whole: Double?
        var problem: String?
    }

    static var file: URL { URL.applicationSupportDirectory.appending(path: "Listen/model-speed.json") }

    /// Keeps the timings in `file`.
    static func record(_ results: [Result]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(results) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Asks every model of the plan the same small question, three at a time.
    static func measure() async -> [Result] {
        guard let token = try? await ChatGPTSession.shared.accessToken(),
            let models = try? await ChatGPT.models(accessToken: token)
        else { return [] }
        let client = ResponsesClient()
        var results: [Result] = []
        await withTaskGroup(of: Result.self) { group in
            var waiting = models[...]
            func next() {
                guard let model = waiting.popFirst() else { return }
                group.addTask {
                    var result = Result(slug: model.slug, name: model.name)
                    let began = Date()
                    do {
                        for try await chunk in client.stream(
                            model: "chatgpt/\(model.slug)",
                            system: "Reply with a card: a title of at most six words, then two short lines. No preamble.",
                            user: "Latest lines:\n[voice 1] Was sagt das CAP-Theorem aus?", maxTokens: 200)
                        {
                            if case .text = chunk, result.firstWord == nil { result.firstWord = Date().timeIntervalSince(began) }
                        }
                        result.whole = Date().timeIntervalSince(began)
                    } catch {
                        result.problem = (error as? any ModelFailure)?.reason ?? "failed"
                    }
                    return result
                }
            }
            for _ in 0..<3 { next() }
            for await result in group {
                results.append(result)
                next()
            }
        }
        // Said beside the numbers: whether the requests could ask for little reasoning.
        UserDefaults.standard.set(ResponsesClient.takesEffort, forKey: "planTakesLowEffort")
        return results.sorted { ($0.firstWord ?? 999) < ($1.firstWord ?? 999) }
    }

    /// Measures, writes the result beside the configuration, and makes the two fastest models
    /// that are not the chosen one draft at the same time.
    @discardableResult
    static func measureAndChoose() async -> [Result] {
        let results = await measure()
        record(results)
        let chosen = ChatGPT.Credentials.load()?.model
        let fastest = results.filter { $0.firstWord != nil && $0.slug != chosen }.prefix(2).map(\.slug)
        if !fastest.isEmpty { UserDefaults.standard.set(Array(fastest), forKey: ChatGPT.alsoAskedKey) }
        return results
    }
}
