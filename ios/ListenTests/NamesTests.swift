import Testing
@testable import Listen

@MainActor @Suite struct NamesThatAreNames {
    @Test func wordsOfTheConversationAreNotNames() {
        // Offered as names in the runs of 17 November 2026.
        for word in ["ja", "Ja", "Stadt", "Papa", "Genau", "Okay"] {
            #expect(!AnswerEngine.looksLikeName(word), "\(word)")
        }
    }

    @Test func namesStayNames() {
        for name in ["Lena", "Marco", "Nora Keller", "Anna-Lena"] {
            #expect(AnswerEngine.looksLikeName(name), "\(name)")
        }
    }

    @Test func aModelsReplyKeepsOnlyNames() {
        let names = AnswerEngine.names(in: "1=Lena\n2=ja\n3=Stadt\n4=Marco")
        #expect(names == [1: "Lena", 4: "Marco"])
    }
}
