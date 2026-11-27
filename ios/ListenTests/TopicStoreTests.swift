import Foundation
import Testing

@testable import Listen

@MainActor
@Suite struct Topics {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "topics-\(UUID().uuidString).json")
    }

    @Test func aFreshStoreHasOneSelectedTopic() {
        let store = TopicStore(file: temporaryFile())
        #expect(store.topics.map(\.name) == ["General"])
        #expect(store.selected.name == "General")
    }

    @Test func topicsAndSelectionSurviveARestart() {
        let file = temporaryFile()
        let store = TopicStore(file: file)
        var topic = Topic(name: "Backend interview")
        topic.language = .en
        topic.notes = "Senior Rust role"
        topic.repositories = ["octo/streams"]
        store.upsert(topic)

        let reloaded = TopicStore(file: file)
        #expect(reloaded.topics.count == 2)
        #expect(reloaded.selected == topic, "a new topic becomes the selected one")
    }

    @Test func editingReplacesAndTheLastTopicCannotBeDeleted() {
        let store = TopicStore(file: temporaryFile())
        var general = store.selected
        general.name = "Allgemein"
        store.upsert(general)
        #expect(store.topics.map(\.name) == ["Allgemein"])

        store.delete(general)
        #expect(store.topics.count == 1)

        store.upsert(Topic(name: "Zweites"))
        store.delete(store.selected)
        #expect(store.topics.map(\.name) == ["Allgemein"])
        #expect(store.selected.name == "Allgemein")
    }

    @Test func repositoryNamesAreValidated() {
        #expect(Topic.isValidRepository("octo/streams"))
        #expect(Topic.isValidRepository("my-org/repo.name_1"))
        #expect(!Topic.isValidRepository("streams"))
        #expect(!Topic.isValidRepository("https://github.com/octo/streams"))
        #expect(!Topic.isValidRepository("octo/streams/extra"))
    }
}

@Suite struct SentenceSplitting {
    @Test func finishedSentencesAreSeparatedFromTheRemainder() {
        let split = LocalTransport.sentences(in: "Guten Tag, schön dass Sie da sind. Können Sie das erklären? Und wie")
        #expect(split.complete == ["Guten Tag, schön dass Sie da sind.", "Können Sie das erklären?"])
        #expect(split.rest == "Und wie")
    }

    @Test func aDotInsideAWordOrNumberDoesNotEndASentence() {
        let split = LocalTransport.sentences(in: "Version 2.5 läuft auf example.com seit gestern")
        #expect(split.complete.isEmpty)
        #expect(split.rest == "Version 2.5 läuft auf example.com seit gestern")
    }

    @Test func textThatEndsWithASentenceLeavesNoRemainder() {
        let split = LocalTransport.sentences(in: "Das war alles!")
        #expect(split.complete == ["Das war alles!"])
        #expect(split.rest.isEmpty)
    }
}

struct KeychainRoundTrip {
    @Test func storesReadsAndRemovesASecret() throws {
        let account = "test-\(UUID().uuidString)"
        try Keychain.set("first", for: account)
        try Keychain.set("second", for: account)
        #expect(Keychain.get(account) == "second")
        Keychain.remove(account)
        #expect(Keychain.get(account) == nil)
    }
}

struct CorrectionPlausibility {
    @Test func acceptsTheSameSentenceWithAFixedWord() {
        #expect(Correction.isPlausible("Wie setzen Sie Backpressure um?", for: "Wie setzen Sie Backpresscher um?"))
    }

    @Test func rejectsInventedOrMuchLongerText() {
        #expect(!Correction.isPlausible("Vielen Dank fürs Zuschauen.", for: "Und wie testen Sie das?"))
        #expect(!Correction.isPlausible("Und wie testen Sie das unter Last mit einem Lasttest der viele Verbindungen öffnet und noch mehr", for: "Und wie testen Sie das?"))
        #expect(!Correction.isPlausible("", for: "Hallo"))
    }
}

@Suite struct TopicFolders {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sandbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func conversation(_ cards: [String], at seconds: TimeInterval) -> TopicSandbox.Conversation {
        .init(topic: "Lunch", began: Date(timeIntervalSince1970: seconds), seconds: 95,
              people: ["You", "Anna"], cards: cards, sentences: 12)
    }

    @Test func aConversationLeavesAMarkdownNoteThatTheNextOneReads() throws {
        let root = root()
        let sandbox = TopicSandbox(topic: UUID(), root: root)
        #expect(sandbox.context().isEmpty)

        let file = try #require(sandbox.write(conversation(["**GTA 6**\nRelease: 2026"], at: 1_000_000)))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(file.pathExtension == "md")
        #expect(text.contains("## At the table\n\n- You\n- Anna"))
        #expect(text.contains("**GTA 6**"))
        #expect(sandbox.context().contains("Release: 2026"))
        #expect(TopicSandbox.noteCount(root: root) == 1)
    }

    @Test func nothingShownLeavesNoNote() {
        let sandbox = TopicSandbox(topic: UUID(), root: root())
        #expect(sandbox.write(conversation([], at: 1_000_000)) == nil)
        #expect(sandbox.notes.isEmpty)
    }

    @Test func aSummaryAloneIsEnoughForANote() throws {
        let sandbox = TopicSandbox(topic: UUID(), root: root())
        var talk = conversation([], at: 1_000_000)
        talk.summary = "- Lasttest verschoben"
        let file = try #require(sandbox.write(talk))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("## Summary\n\n- Lasttest verschoben"))
        #expect(!text.contains("Listen showed"))
        talk.cards = ["Eine Karte"]
        sandbox.write(talk)
        #expect(sandbox.notes.count == 1, "the same conversation replaces its note")
    }

    @Test func contextKeepsTheNewestNotesWithinItsSize() {
        let sandbox = TopicSandbox(topic: UUID(), root: root())
        for index in 0..<5 {
            sandbox.write(conversation(["Card \(index) " + String(repeating: "x", count: 300)], at: 1_000_000 + Double(index) * 100))
        }
        let context = sandbox.context(notes: 3, characters: 700)
        #expect(context.contains("Card 4"))
        #expect(!context.contains("Card 0"))
        #expect(context.count <= 700 + 3)
    }

    @Test func clearingMemoryKeepsTheUsersOwnFiles() throws {
        let sandbox = TopicSandbox(topic: UUID(), root: root())
        sandbox.write(conversation(["A card"], at: 1_000_000))
        try "Immer kurz.".write(to: sandbox.folder.appending(path: "instructions.md"), atomically: true, encoding: .utf8)
        sandbox.clearNotes()
        #expect(sandbox.notes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sandbox.folder.appending(path: "instructions.md").path))
    }

    @Test func deletingRemovesTheNotes() {
        let root = root()
        let sandbox = TopicSandbox(topic: UUID(), root: root)
        sandbox.write(conversation(["A card"], at: 1_000_000))
        sandbox.delete()
        #expect(TopicSandbox.noteCount(root: root) == 0)
    }
}

@Suite struct TwoHearings {
    private let dictionary: Set<String> = [
        "mach", "einen", "ein", "aufsatz", "über", "käfer", "kannst", "kommst", "du", "nun", "besser", "zuhören",
        "wie", "setzen", "sie", "um",
    ]
    private func settle(_ heard: String, _ candidate: String, glossary: String = "") -> String {
        Correction.arbitrate(heard: heard, candidate: candidate, glossary: glossary) { dictionary.contains($0.lowercased()) }
    }

    @Test func anInventedWordDoesNotReplaceARealOne() {
        #expect(settle("Mach einen Aufsatz über Käfer", "Mach ein Aufstatt über Käfer.") == "Mach einen Aufsatz über Käfer.")
    }

    @Test func aRealWordFromTheSecondStageWins() {
        #expect(settle("Kommst du nun besser zuhören?", "Kannst du nun besser zuhören?") == "Kannst du nun besser zuhören?")
    }

    @Test func glossaryWordsCountAsWords() {
        #expect(settle("Wie setzen Sie Backpresscher um", "Wie setzen Sie Backpressure um?", glossary: "Backpressure") == "Wie setzen Sie Backpressure um?")
        // Neither is in the dictionary: the second stage is believed.
        #expect(settle("Wie setzen Sie Backpresscher um", "Wie setzen Sie Backpressure um?") == "Wie setzen Sie Backpressure um?")
    }

    @Test func punctuationAndEqualSentencesComeFromTheSecondStage() {
        #expect(settle("Mach einen Aufsatz", "Mach einen Aufsatz.") == "Mach einen Aufsatz.")
    }

    private let german: Set<String> = [
        "ich", "gehe", "heute", "nicht", "mehr", "einkaufen", "wir", "haben", "das", "gestern", "schon", "besprochen",
        "wie", "hoch", "ist", "der", "eiffelturm",
    ]
    private func dialect(_ text: String, over settled: String, first: String, second: String?) -> Bool {
        Correction.prefersDialect(text, over: settled, first: first, second: second) { german.contains($0.lowercased()) }
    }

    @Test func theDialectLayerIsTakenWhenTheOthersStruggle() {
        // Dialect: the two standard listeners write different nonsense, the dialect model writes German.
        #expect(dialect(
            "Ich gehe heute nicht mehr einkaufen.", over: "I gang hüt nüme go poschte",
            first: "I gang hüt nüme go poschte", second: "Igang Hütte nimmer Kupfosten"))
        // They agree with each other, but half of what they wrote are not words.
        #expect(dialect(
            "Wir haben das gestern schon besprochen.", over: "Mir händ das geschter scho besproche",
            first: "Mir händ das geschter scho besproche", second: "Mir händ das geschter scho besproche."))
    }

    @Test func threeHearingsAreSettledByAVote() {
        // All three differ: the largest model stands.
        #expect(Correction.vote(
            first: "die laute Schlange und geht in dem Sender", second: "Wir begrenzen die Warteschlage.",
            strongest: "Wir begrenzen die Warteschlange.") == "Wir begrenzen die Warteschlange.")
        #expect(Correction.vote(
            first: "Und wie testen Sie das Unterllast", second: "Und wie testen Sie das Unterlast?",
            strongest: "Und wie testen Sie das unter Last?") == "Und wie testen Sie das unter Last?")
        // Two against one: the largest model is overruled.
        #expect(Correction.vote(
            first: "Zeig mal, ob das jetzt funktioniert", second: "Zeig mal, ob das jetzt funktioniert.",
            strongest: "Ich zeige mal, ob das jetzt funktioniert.") == "Zeig mal, ob das jetzt funktioniert.")
        #expect(Correction.vote(
            first: "Kannst du nun besser zuhören", second: "Kannst du nun besser zuhören?",
            strongest: "Kannst du noch besser zuhören?") == "Kannst du nun besser zuhören?")
        // The glossary word the second hearing was primed with wins.
        #expect(Correction.vote(
            first: "wie Sie Backpresscher umsetzen", second: "wie Sie Backpressure umsetzen?",
            strongest: "wie Sie Backpresser umsetzen?", glossary: "Backpressure") == "wie Sie Backpressure umsetzen?")
        // Where the largest model and the first agree against the second, nothing is overruled.
        #expect(Correction.vote(
            first: "Versuche nun einfach zuzuhören", second: "Versuche nun einfach zu hören.",
            strongest: "Versuche nun einfach zuzuhören.") == "Versuche nun einfach zuzuhören.")
    }

    @Test func onStandardGermanTheDialectLayerChangesNothing() {
        #expect(!dialect(
            "Wie hoch ist der Eiffelturm?", over: "Wie hoch ist der Eiffelturm?",
            first: "Wie hoch ist der Eiffelturm", second: "Wie hoch ist der Eiffelturm?"))
        // It hears something else entirely while the others agree on real words: not believed.
        #expect(!dialect(
            "Das haben wir gestern besprochen.", over: "Wie hoch ist der Eiffelturm?",
            first: "Wie hoch ist der Eiffelturm", second: "Wie hoch ist der Eiffelturm?"))
        // Invented length.
        #expect(!dialect(
            String(repeating: "ich gehe heute ", count: 10), over: "I gang hüt",
            first: "I gang hüt", second: "Igang Hütte"))
    }

    @MainActor @Test func theSystemDictionaryTellsAWordFromANonWord() {
        guard WordCheck.isAvailable(.de) else { return }
        #expect(WordCheck.isWord("Aufsatz", in: .de))
        #expect(!WordCheck.isWord("Aufstatt", in: .de))
    }
}

@Suite struct TopicLinks {
    @Test func topicsSavedBeforeLinksExistedStillLoad() throws {
        let old = Data(#"{"repositories":[],"language":"de","name":"General","id":"23B958C8-2FC1-4A72-9A34-BE9DDF47E8A3","notes":""}"#.utf8)
        let topic = try JSONDecoder().decode(Topic.self, from: old)
        #expect(topic.name == "General")
        #expect(topic.links.isEmpty)
    }

    @Test func onlyWebAddressesAreLinks() {
        #expect(Topic.isValidLink("https://example.com/page"))
        #expect(!Topic.isValidLink("example.com"))
        #expect(!Topic.isValidLink("file:///etc/passwd"))
        #expect(!Topic.isValidLink("https://localhost"))
    }

    @Test func aPageBecomesReadableText() {
        let html = "<html><head><title>GTA&nbsp;VI &amp; mehr</title><style>p{}</style></head><body><script>x()</script><h1>Release</h1><p>Erscheint  am <b>19. November</b>.</p></body></html>"
        #expect(LinkContext.title(inHTML: html) == "GTA VI & mehr")
        #expect(LinkContext.text(fromHTML: html) == "Release\nErscheint am 19. November .")
    }

    @Test func aCardLinksOnlyToPagesTheUserGave() {
        let allowed = ["https://example.com/gta"]
        #expect(LinkContext.keepingOnlyLinks(to: allowed, in: "**GTA**\nHerbst\n[Rockstar](https://example.com/gta)")
            == "**GTA**\nHerbst\n[Rockstar](https://example.com/gta)")
        #expect(LinkContext.keepingOnlyLinks(to: allowed, in: "**GTA**\n[Quelle](https://invented.example/x)") == "**GTA**\nQuelle")
        #expect(LinkContext.keepingOnlyLinks(to: allowed, in: "**GTA**\nSiehe https://invented.example/x") == "**GTA**\nSiehe")
        #expect(LinkContext.keepingOnlyLinks(to: allowed, in: "Siehe https://example.com/gta") == "Siehe [example.com](https://example.com/gta)")
    }
}

@Suite struct CardInstructions {
    @Test func theStarterFileIsWrittenOnceAndATopicCanAddItsOwn() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "instructions-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = base.appending(path: "Instructions", directoryHint: .isDirectory)
        let topics = base.appending(path: "Topics", directoryHint: .isDirectory)
        let topic = UUID()
        #expect(Instructions.load(topic: topic, folder: folder, topics: topics).contains("Essence first"))
        // What the user wrote is kept, not overwritten by the starter.
        try "Nur Stichworte.".write(to: folder.appending(path: "cards.md"), atomically: true, encoding: .utf8)
        let own = TopicSandbox(topic: topic, root: topics).folder
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try "Immer mit Codebeispiel.".write(to: own.appending(path: "instructions.md"), atomically: true, encoding: .utf8)
        let text = Instructions.load(topic: topic, folder: folder, topics: topics)
        #expect(text == "Nur Stichworte.\n\nFor this topic:\nImmer mit Codebeispiel.")
    }
}

@Suite struct TopicHistory {
    @Test func aNoteIsReadBackForLookingAtATopic() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sandbox = TopicSandbox(topic: UUID(), root: root)
        let file = try #require(sandbox.write(.init(
            topic: "Basteln", began: Date(timeIntervalSince1970: 1_800_000_000), seconds: 125, people: ["Anna", "Markus"],
            cards: ["**Stern**\nFünfzackig.\n```svg\n<svg viewBox=\"0 0 1 1\"></svg>\n```", "**Papier**\n**250 g/m²**"],
            sentences: 18, summary: "- Stern geschnitten\n- Papier offen")))
        let past = try #require(TopicSandbox.read(file))
        #expect(past.length == "2 min, 18 sentences heard.")
        #expect(past.people == ["Anna", "Markus"])
        #expect(past.summary == "- Stern geschnitten\n- Papier offen")
        #expect(past.cards.count == 2)
        #expect(past.cards[0].contains("<svg") && past.cards[1] == "**Papier**\n**250 g/m²**")
        #expect(past.when.count == 16, "date and time as written in the note")
    }
}
