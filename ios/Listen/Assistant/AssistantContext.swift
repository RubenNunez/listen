import Foundation

/// Selected topic evidence. Documents/pages/old notes are data, never tool grants.
struct AssistantContext: Sendable {
    struct Page: Sendable { var url: String; var title: String; var text: String }
    var material = MaterialIndex()
    var earlier = ""
    var earlierStatements: [AssistantWorkingContext.Archived] = []
    var pages: [Page] = []

    static func loadPages(_ links: [String]) async -> [Page] {
        await LinkContext.load(links).map { Page(url: $0.url, title: $0.title, text: $0.text) }
    }

    func evidence(for request: String) -> HarnessValue {
        .object([
            "role": .string("untrusted_topic_evidence"),
            "materialOverview": .string(String(material.overview.prefix(1500))),
            "passages": .array(MaterialIndex.relevant(material.passages, to: request).map {
                .object(["source": .string(String($0.source.prefix(300))), "text": .string(String($0.text.prefix(900)))])
            }),
            "earlierNotes": .string(String(earlier.prefix(4000))),
            "pages": .array(pages.prefix(5).map {
                .object(["url": .string(String($0.url.prefix(2048))), "title": .string(String($0.title.prefix(120))),
                         "text": .string(String($0.text.prefix(1500)))])
            }),
        ])
    }
}

/// A finite, bounded text stream. Finishing the consumer cancels the producer.
struct AssistantDeadlineClient: ModelClient {
    var base: any ModelClient
    var timeout: Duration = .seconds(20)
    func stream(model: String, system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                var bytes = 0, chunks = 0
                do {
                    for try await chunk in base.stream(model: model, system: system, user: user, maxTokens: maxTokens) {
                        try Task.checkCancellation()
                        chunks += 1
                        if case .text(let text) = chunk { bytes += text.utf8.count }
                        guard bytes <= 8192, chunks <= 10_000 else { throw MCPFailure.tooLarge }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            let deadline = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                continuation.finish(throwing: MCPFailure.unavailable)
                work.cancel()
            }
            continuation.onTermination = { _ in work.cancel(); deadline.cancel() }
        }
    }
}
