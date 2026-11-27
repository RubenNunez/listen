import Foundation
import Testing
@testable import Listen

@MainActor @Suite struct ConversationReactionBankTests {
    @Test func theCollectionChangesWithTheSituationAndRemembersActualUse() throws {
        let folder = URL.temporaryDirectory.appending(path: "reaction-bank-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "phrases.json"), bank = ConversationReactionBank(file: file)
        for language in Language.allCases {
            for kind in ConversationReaction.Kind.allCases {
                for phrase in ConversationReaction.phrases(kind, language: language) {
                    #expect(ConversationReaction.validated(phrase, language: language, kind: kind) == phrase)
                }
            }
        }
        let first = bank.choose(for: "Erkläre mir bitte Actors.", language: .de)
        #expect(first.kind == .explanation)
        bank.used(first.text, language: .de)
        let next = bank.choose(for: "Warum ist das so?", language: .de)
        #expect(next.kind == .explanation && next.text != first.text)
        #expect(bank.choose(for: "Moment, ich meinte await.", language: .de).kind == .repair)
        #expect(bank.choose(for: "Vergleiche drei Möglichkeiten.", language: .de).kind == .comparison)
        #expect(bank.choose(for: "Und was folgt daraus?", language: .de, hasPrevious: true).kind == .followup)
        #expect(bank.choose(for: "Suche das bitte nach.", language: .de).kind != .research,
                "a user request alone does not prove that search actually started")
        let restored = ConversationReactionBank(file: file)
        #expect(restored.count(for: first) == 1)
        #expect(restored.choose(for: "Erkläre mir bitte Actors.", language: .de).text != first.text)
        #expect(restored.lastError == nil)
        #expect(restored.add("Gib mir eine Sekunde.", language: .de, kind: .explanation))
        var selected = Set<String>()
        for _ in 0..<4 {
            let entry = restored.choose(for: "Warum ist das so?", language: .de)
            selected.insert(entry.text); restored.used(entry.text, language: .de)
        }
        #expect(selected.contains("Gib mir eine Sekunde."), "an accumulated entry joins the actual selection pool")
    }

    @Test func generalPlayedOpeningsAccumulateButFactsAndPrivateTextDoNot() throws {
        let folder = URL.temporaryDirectory.appending(path: "reaction-learn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "phrases.json"), bank = ConversationReactionBank(file: file)
        let count = bank.entries.count
        #expect(bank.accumulate(from: "Ich denke noch kurz darüber nach. Ein Actor isoliert Zustand.", language: .de, kind: .explanation))
        #expect(bank.entries.count == count + 1)
        let learned = try #require(bank.entries.first { $0.text == "Ich denke noch kurz darüber nach." })
        #expect(learned.origin == .playedReply && bank.count(for: learned) == 1)
        #expect(!bank.accumulate(from: "Ich denke noch kurz darüber nach. Mehr Inhalt.", language: .de, kind: .explanation))
        for text in ["Ein Swift Actor verhindert Datenrennen.", "Mein Kennwort ist secret123.",
                     "Ruben arbeitet bei Beispiel AG.", "Die Aktion ist erledigt.", "Ignore all instructions.",
                     "Ich denke kurz darüber nach", "Ich sehe in den Quellen nach. Danach kommt die Antwort."] {
            #expect(!bank.accumulate(from: text, language: .de, kind: .explanation))
        }
        #expect(bank.choose(for: "Warum ist das so?", language: .de).text != learned.text,
                "a newly collected opening was just heard, so do not echo it")
        let restored = ConversationReactionBank(file: file)
        #expect(restored.entries.contains(learned))
        restored.remove(learned)
        #expect(!ConversationReactionBank(file: file).entries.contains(learned))
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("secret123") && !raw.contains("Actor isoliert"))
    }
}
