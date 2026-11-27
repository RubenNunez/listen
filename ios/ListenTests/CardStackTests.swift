import SwiftUI
import Testing
import UIKit

@testable import Listen

/// A block's versions are pages of different heights, side by side. These tests lay a
/// stack out for real and ask how tall it is: the page in view decides, and a page that
/// is being written is given all the height its text needs.
///
/// "For real" means mounted as the app mounts it: in a window, inside a vertical scroll
/// view. The pages take their width from the scroll view they lie in
/// (`containerRelativeFrame`), and a hosting controller that is only asked for a size,
/// without a window, never places that scroll view: the pages then get no width at all
/// and the text wraps letter by letter. And the stack keeps state (the page in view), so
/// what changes in the app is changed here in the same mounted stack, not in a new one.
@MainActor
@Suite struct CardStackHeight {
    private static let short = "Cache\n**LRU evicts 1 of 6 entries: the one used longest ago.**"
    /// As tall as `short`, and a page of its own before `short` or `tall`: its number is another
    /// one. Versions that only complete or extend each other are one page (`CardHistoryPages`),
    /// and these tests are about rows of pages.
    private static let earlierShort = "Cache\n**LRU evicts 1 of 9 entries: the one used longest ago.**"
    private static let tall = short + "\n"
        + (1...14).map { "Detail \($0): a line that belongs to the answer above and takes room." }.joined(separator: "\n")

    private func card(_ id: UInt64, _ text: String, replaces: UInt64? = nil, streaming: Bool = false) -> SessionCore.Card {
        var card = SessionCore.Card(start: CardStart(
            generationID: id, kind: .fast, style: .answer, triggerSegment: 1, sourceCard: replaces,
            contextVersion: 0, mappingVersion: 0))
        card.text = text
        card.status = streaming ? .streaming : .finished
        return card
    }

    /// A stack of these versions, mounted in a window and opened as the app opens it.
    private func mounted(_ versions: [SessionCore.Card], width: CGFloat = 420, turnsPages: Bool = false) throws -> MountedStack {
        try MountedStack(versions, width: width, turnsPages: turnsPages)
    }

    /// How tall a stack of these versions is when it is opened.
    private func opened(_ versions: [SessionCore.Card], width: CGFloat = 420) async throws -> CGFloat {
        let stack = try mounted(versions, width: width)
        defer { stack.remove() }
        return try await stack.height()
    }

    @Test func anEarlierTallVersionDoesNotReserveItsHeight() async throws {
        let shortNewest = try await opened([card(1, Self.tall), card(2, Self.short, replaces: 1)])
        let allShort = try await opened([card(1, Self.earlierShort), card(2, Self.short, replaces: 1)])
        let newestTall = try await opened([card(1, Self.earlierShort), card(2, Self.tall, replaces: 1)])
        #expect(abs(shortNewest - allShort) < 1, "the short newest page decides when the stack opens")
        #expect(shortNewest < newestTall - 100)
    }

    @Test func anUpdateLeadsWithItsNewAnswerAndKeepsEarlierContextCollapsed() async throws {
        var focused = card(2, Self.tall + "\n**New short answer.**", replaces: 1)
        focused.start.focusText = "Cache\n**New short answer.**"
        let compact = try await opened([card(1, Self.short), focused])
        focused.start.focusText = nil
        let expanded = try await opened([card(1, Self.short), focused])
        #expect(compact < expanded - 100)
        let retained = CardBody.earlierContext(whole: Self.tall + "\n**New short answer.**", focus: "Cache\n**New short answer.**")
        #expect(retained.contains { $0.contains("Detail 14") })
        #expect(!retained.contains("**New short answer.**"))
    }

    @Test func openingHistoryActuallyPlacesTheNewestPageInView() async throws {
        let stack = try mounted([card(1, Self.tall), card(2, Self.short, replaces: 1)])
        defer { stack.remove() }
        _ = try await stack.height()
        try stack.expectInView(2)
    }

    @Test func theCurrentPageStaysInViewWhenHistoryGrows() async throws {
        let two = [card(1, Self.earlierShort), card(2, Self.short, replaces: 1)]
        let stack = try mounted(two)
        defer { stack.remove() }
        _ = try await stack.height()
        try stack.expectInView(2)
        stack.table.versions = two + [card(3, Self.tall.replacingOccurrences(of: "1 of 6", with: "2 of 6"), replaces: 2)]
        _ = try await stack.height()
        try stack.expectInView(3)
        // Seek backwards while the horizontal scroll view remains mounted.
        stack.table.versions = two
        stack.table.seeks += 1
        _ = try await stack.height()
        try stack.expectInView(2)
    }

    @Test func loadingARecordingPlacesTheNewestPageInView() async throws {
        let stack = try mounted([])
        defer { stack.remove() }
        // Replay loads its timeline on appearance, after the empty feed was mounted.
        try await Task.sleep(for: .milliseconds(100))
        stack.table.versions = [card(1, Self.tall), card(2, Self.short, replaces: 1)]
        _ = try await stack.height()
        try stack.expectInView(2)
    }

    @Test func aPageTallerThanTheWindowFitsAllItsContent() async throws {
        let text = Self.short + "\n" + (1...60).map {
            "Detail \($0): a complete line that must remain visible inside the card."
        }.joined(separator: "\n")
        let alone = try await opened([card(2, text)])
        let stack = try mounted([card(1, Self.earlierShort), card(2, text, replaces: 1)])
        defer { stack.remove() }
        let paged = try await stack.height()
        #expect(alone > 1_000, "the regression needs a card taller than its window")
        #expect(abs(paged - alone - 38) < 1, "the pager adds 28 points and a 10-point gap; the card keeps all its height")
        let body = try #require(stack.bodySize(for: 2))
        #expect(paged >= body.height + 2 * CardMetrics.inset + 38 - 1,
                "the selected body, its padding and the pager must fit inside the stack")
    }

    @Test func aNewPageDoesNotClipTheCardThatWasAlreadyVisible() async throws {
        let stack = try mounted([card(1, Self.tall)])
        defer { stack.remove() }
        let single = try await stack.height()
        stack.table.versions = [card(1, Self.tall), card(2, Self.tall, replaces: 1, streaming: true)]
        _ = try await stack.height()
        // A changed number keeps the previous version as a separate historical page.
        stack.table.versions = [card(1, Self.tall), card(2, Self.tall.replacingOccurrences(of: "1 of 6", with: "2 of 6"), replaces: 1)]
        let paged = try await stack.height()
        #expect(abs(paged - single - 38) < 1, "adding history must not reduce the visible card's height")
        let body = try #require(stack.bodySize(for: 2))
        #expect(paged >= body.height + 2 * CardMetrics.inset + 38 - 1)
    }

    @Test func aPageThatIsBeingWrittenGrowsByAllItsTextNeeds() async throws {
        // The same text as one page without a row of versions around it is the measure.
        let single = try mounted([card(1, Self.short)])
        defer { single.remove() }
        let low = try await single.height()
        single.table.versions = [card(1, Self.tall)]
        let alone = try await single.height() - low

        // One stack, mounted once: the text of its newest page grows while it is shown. A
        // version that is being written is no new page yet, so the row needs an earlier page
        // that already is one.
        let pages = [card(1, Self.earlierShort), card(2, Self.short, replaces: 1)]
        let begins = pages + [card(3, Self.short, replaces: 2, streaming: true)]
        let stack = try mounted(begins)
        defer { stack.remove() }
        let begun = try await stack.height()
        stack.table.versions = pages + [card(3, Self.tall, replaces: 2, streaming: true)]
        let written = try await stack.height()
        #expect(alone > 100)
        #expect(abs((written - begun) - alone) < 1, "nothing of the growing page is cut off or squeezed")

        // And the height is not kept when the text is short again.
        stack.table.versions = begins
        let again = try await stack.height()
        #expect(abs(again - begun) < 1, "a height the stack once had does not stay")
    }

    @Test func aNarrowerStackIsTallerBecauseItsTextWraps() async throws {
        let stack = try mounted([card(1, Self.earlierShort), card(2, Self.tall, replaces: 1)], width: 620)
        defer { stack.remove() }
        let wide = try await stack.height()
        stack.table.width = 260
        let narrow = try await stack.height()
        #expect(narrow > wide + 20)
        stack.table.width = 620
        let wideAgain = try await stack.height()
        #expect(abs(wideAgain - wide) < 1, "back at the first width, back at the first height")
    }

    @Test func turningToAnotherVersionTakesThatPagesHeight() async throws {
        let stack = try mounted([card(1, Self.tall), card(2, Self.short, replaces: 1)], turnsPages: true)
        defer { stack.remove() }
        let newest = try await stack.height()
        // The same texts with the tall one in view when the stack opens are the measure.
        let tallInView = try await opened([card(1, Self.earlierShort), card(2, Self.tall, replaces: 1)])
        #expect(newest < tallInView - 100)

        stack.table.page = 1
        let earlier = try await stack.height()
        #expect(abs(earlier - tallInView) < 1, "the earlier, taller page in view decides")
        #expect(stack.table.page == 1, "the stack stays on the page it was turned to")
        try stack.expectInView(1)

        stack.table.page = CardBlocks.newestPage
        let back = try await stack.height()
        #expect(abs(back - newest) < 1, "back on the newest page, back at its height")
        try stack.expectInView(2)
    }

    @Test func aReplayThatMovesBackTakesTheHeightOfThatMoment() async throws {
        // The stack holds the page itself, as in the replay.
        let stack = try mounted([card(1, Self.earlierShort)])
        defer { stack.remove() }
        let first = try await stack.height()
        stack.table.versions = [card(1, Self.earlierShort), card(2, Self.tall, replaces: 1)]
        let later = try await stack.height()
        #expect(later > first + 100)
        stack.table.versions = [card(1, Self.earlierShort)]
        let before = try await stack.height()
        #expect(abs(before - first) < 1, "one version again: as tall as it was with one version")
        stack.table.versions = [card(1, Self.earlierShort), card(2, Self.tall, replaces: 1)]
        let forward = try await stack.height()
        #expect(abs(forward - later) < 1, "forward again: the row of versions is back on its newest page")
    }

    @Test func aPageInViewThatIsGoneGivesWayToTheNewest() async throws {
        let three = [card(1, Self.tall), card(2, Self.earlierShort, replaces: 1), card(3, Self.tall, replaces: 2)]
        let stack = try mounted(three, turnsPages: true)
        defer { stack.remove() }
        let newest = try await stack.height()
        stack.table.page = 2
        let middle = try await stack.height()
        #expect(middle < newest - 100, "the short version in the middle is in view")

        // The replay moves back to before the third version: the second is now the newest page.
        stack.table.versions = Array(three.dropLast())
        let moved = try await stack.height()
        #expect(abs(moved - middle) < 1, "the same text is in view, as the newest page")
        #expect(stack.table.page == CardBlocks.newestPage, "a page that is gone is not kept as the page in view")

        // Forward again: the reader is on the newest page, so the third version is in view.
        stack.table.versions = three
        let forward = try await stack.height()
        #expect(abs(forward - newest) < 1)
    }

    @Test func aNewerVersionTurnsAReaderOnAnEarlierPageToIt() async throws {
        let two = [card(1, Self.tall), card(2, Self.short, replaces: 1)]
        let stack = try mounted(two, turnsPages: true)
        defer { stack.remove() }
        let newest = try await stack.height()
        stack.table.page = 1
        let earlier = try await stack.height()
        #expect(earlier > newest + 100, "the earlier, taller version is in view")

        // A better version arrives while the reader is on the first one, which is still there.
        stack.table.versions = two + [card(3, Self.short, replaces: 2)]
        let updated = try await stack.height()
        #expect(stack.table.page == CardBlocks.newestPage, "the version that took the block's place is in view")
        #expect(abs(updated - newest) < 1, "and the stack is as tall as it, not as the page that was in view")

        // Turning back is still possible, and text written into the newest version, the same
        // card as before, does not take the reader away again.
        stack.table.page = 1
        let turnedBack = try await stack.height()
        #expect(abs(turnedBack - earlier) < 1)
        stack.table.versions = two + [card(3, Self.tall, replaces: 2)]
        let written = try await stack.height()
        #expect(stack.table.page == 1, "the reader stays on the page they turned to while no other card is the newest")
        #expect(abs(written - earlier) < 1)
    }

    @Test func aMomentChosenByHandShowsTheNewestVersionOfThatMoment() async throws {
        let three = [card(1, Self.tall), card(2, Self.earlierShort, replaces: 1), card(3, Self.tall, replaces: 2)]
        let stack = try mounted(three, turnsPages: true)
        defer { stack.remove() }
        let newest = try await stack.height()
        stack.table.page = 2
        let middle = try await stack.height()
        #expect(middle < newest - 100, "the short version in the middle is in view")

        // A moment is chosen at which the block has the same versions: nothing in it changed.
        stack.table.seeks += 1
        let sought = try await stack.height()
        #expect(stack.table.page == CardBlocks.newestPage, "a chosen moment does not keep a page turned to before")
        #expect(abs(sought - newest) < 1)

        // Turned back again, then a moment before the third version is chosen: the page that
        // was in view still exists, and the newest of that moment is shown all the same.
        stack.table.page = 1
        _ = try await stack.height()
        stack.table.versions = Array(three.dropLast())
        stack.table.seeks += 1
        let back = try await stack.height()
        #expect(stack.table.page == CardBlocks.newestPage)
        #expect(abs(back - middle) < 1, "the second version is the newest at that moment")
    }
}

/// Which versions of a block are pages to turn back to (`CardHistory`): a heuristic on
/// words. These tests say what it folds, what it keeps, and where it is wrong.
@Suite struct CardHistoryPages {
    @Test func anUpdatedEarlierSubjectGetsFocusAndSourceLabelsDoNotClaimVerification() {
        func card(_ id: UInt64, _ title: String, source: UInt64? = nil) -> SessionCore.Card {
            var card = SessionCore.Card(start: CardStart(generationID: id, kind: .deep, style: .answer,
                triggerSegment: 1, sourceCard: source, contextVersion: 0, mappingVersion: 0))
            card.text = title
            card.status = .finished
            return card
        }
        let first = card(1, "Alpha\nEarlier answer.")
        let second = card(2, "Beta\nSecond subject.")
        var update = card(3, "Alpha\nThe relevant new answer.", source: 1)
        let titleOnly = card(4, "Gamma")
        let blocks = CardBlocks.blocks(from: [first, second, update, titleOnly])
        #expect(CardBlocks.focused(in: blocks)?.id == 1)
        #expect(CardEvidence.of(update) == .draft, "deep alone is not source support")
        update.start.evidenceSegment = 12
        #expect(CardEvidence.of(update) == .conversation)
        update.text += "\n\nSources: [Primary](https://example.com)"
        #expect(CardEvidence.of(update) == .sources)
    }

    private func versions(_ texts: [String], writingLast: Bool = false) -> [SessionCore.Card] {
        texts.enumerated().map { index, text in
            var card = SessionCore.Card(start: CardStart(
                generationID: UInt64(index + 1), kind: .fast, style: .answer, triggerSegment: 1,
                sourceCard: index == 0 ? nil : UInt64(index), contextVersion: 0, mappingVersion: 0))
            card.text = text
            card.status = index == texts.count - 1 ? (writingLast ? .streaming : .finished) : .superseded
            return card
        }
    }

    /// The texts of the pages a block with these versions shows.
    private func pages(_ texts: String..., writingLast: Bool = false) -> [String] {
        CardBlocks.Block(id: 1, versions: versions(texts, writingLast: writingLast)).pages.map(\.text)
    }

    private static let firstLines = "**Eiffelturm**\n**330 m** hoch."
    private static let draft = "**Eiffelturm**\n**330 m** hoch.\nSteht in Paris, eröffnet 1889."
    private static let checked = "**Eiffelturm**\n- *330 m* hoch.\n- Steht in Paris, eröffnet 1889.\n\nQuellen: [toureiffel.paris](https://www.toureiffel.paris/de)"

    @Test func firstLinesTheDraftAndTheSameAnswerWithSourcesAreOnePage() {
        #expect(pages(Self.firstLines, Self.draft, Self.checked) == [Self.checked], "the newest text, and nothing to turn back to")
        #expect(CardHistory.step(from: Self.firstLines, to: Self.draft) == .folds(.kept))
        #expect(CardHistory.step(from: Self.draft, to: Self.checked) == .folds(.same), "sources and formatting are no other answer")
        let formatted = "Eiffelturm:\n- *330 m* hoch.\n- Steht in Paris, eröffnet 1889.\n\nQuellen: [toureiffel.paris](https://www.toureiffel.paris/de)"
        #expect(CardHistory.step(from: Self.draft, to: formatted) == .folds(.same), "only sources and formatting, of the title too")
        // Nothing is taken out of the block itself.
        let block = CardBlocks.Block(id: 1, versions: versions([Self.firstLines, Self.draft, Self.checked]))
        #expect(block.versions.map(\.text) == [Self.firstLines, Self.draft, Self.checked])
        #expect(block.current.text == Self.checked)
        #expect(pages(Self.draft) == [Self.draft])
    }

    @Test func anAnswerThatOnlyGrowsStaysOnePage() {
        let more = "**iPhone**\nErschien 2007 in den USA, in Deutschland im November."
        #expect(pages("**iPhone**\nErschien 2007 in den USA.", more) == [more], "a line that was continued after all its words")
        let added = "**Cache**\nDer Cache ist threadsicher.\nGetestet mit acht Threads."
        #expect(pages("**Cache**\nDer Cache ist threadsicher.", added) == [added], "a line of its own was added")
        let block = "**Klinge beim Cricut Joy**\n**Ja – Klinge inklusive.**\nNach dem Zeichnen: Stift herausnehmen, Klinge einsetzen."
        let grown = block + "\n**Wechselintervall** – abhängig von der Nutzung.\n\nQuellen: [cricut.com](https://cricut.com/b)\n\n```chart\ntitle: x\nA: 1\nB: 2\n```"
        #expect(pages(block, grown) == [grown], "another answer, sources and a chart were added; what it said stays")
        #expect(pages("**Cache**\nDer Empfänger bremst den Sender.", "**Cache**\nEmpfänger bremst Sender.").count == 1, "articles went")
        // Code whose fence was never closed was cut off while it was written; the rest completes it.
        let code = "**Schleife**\n```swift\nfor i in 1...3 {\n"
        #expect(pages(code, code + "    print(i)\n}\n```").count == 1, "code that was written to its end")
        #expect(CardHistory.step(from: code, to: code + "    print(i)\n}\n```") == .folds(.kept))
    }

    @Test func theSameWordsInAnotherOrderKeepThePageBefore() {
        let before = "**Spiel**\nAnna schlägt Tom."
        let after = "**Spiel**\nTom schlägt Anna."
        #expect(pages(before, after) == [before, after])
        #expect(CardHistory.step(from: before, to: after) == .page(.order))
        #expect(!CardHistory.step(from: "**Ablauf**\nFirst commit, then push.", to: "**Ablauf**\nFirst push, then commit.").isFold)
    }

    @Test func aQualifyingWordThatCameOrWentKeepsThePageBefore() {
        let sure = "**Cache**\nDer Cache ist sicher."
        let rarely = "**Cache**\nDer Cache ist selten sicher."
        #expect(pages(sure, rarely) == [sure, rarely])
        #expect(CardHistory.step(from: sure, to: rarely) == .page(.qualifier))
        #expect(CardHistory.step(from: rarely, to: sure) == .page(.qualifier), "a qualifier that went")
        #expect(!CardHistory.step(from: sure, to: "**Cache**\nDer Cache ist nur sicher.").isFold)
        #expect(!CardHistory.step(from: sure, to: "**Cache**\nDer Cache ist immer sicher.").isFold)
        #expect(!CardHistory.step(from: sure, to: "**Cache**\nDer Cache ist wahrscheinlich sicher.").isFold)
        #expect(!CardHistory.step(from: sure, to: "**Cache**\nDer Cache könnte sicher sein.").isFold)
        #expect(!CardHistory.step(from: "**Cache**\nThe cache may be stale.", to: "**Cache**\nThe cache is stale.").isFold)
        #expect(!CardHistory.step(from: "**Cache**\nThe cache is stale.", to: "**Cache**\nThe cache might be stale.").isFold)
        #expect(!CardHistory.step(from: "**Cache**\nThe cache is always warm.", to: "**Cache**\nThe cache is warm.").isFold)
        // Also at the end of the line: a continuation must not qualify what stands before it.
        #expect(CardHistory.step(from: sure, to: "**Cache**\nDer Cache ist sicher, wahrscheinlich.") == .page(.qualifier))
        #expect(!CardHistory.step(from: sure, to: "**Cache**\nDer Cache ist sicher, aber nur bei einem Thread.").isFold)
        #expect(!CardHistory.step(from: sure, to: "**Cache**\nDer Cache ist sicher, außer unter Last.").isFold)
    }

    @Test func aWordPutIntoALineKeepsThePageBefore() {
        let before = "**Cache**\nDer Empfänger bremst den Sender."
        let after = "**Cache**\nEmpfänger bremst bei Überlast Sender."
        #expect(pages(before, after) == [before, after], "what was put between the words may narrow them")
        #expect(!CardHistory.step(from: "**Preis**\nKostet 100.", to: "**Preis**\nKostet 100 Millionen.").isFold, "what follows a number may be its magnitude")
        #expect(!CardHistory.step(from: "**Preis**\nKostet 100 €.", to: "**Preis**\nKostet 100 € pro Monat.").isFold, "or what it is counted per")
    }

    @Test func aChangedTitleKeepsThePageBefore() {
        let fifteen = "**iPhone 15**\nErschien im Herbst."
        let sixteen = "**iPhone 16**\nErschien im Herbst."
        #expect(pages(fifteen, sixteen) == [fifteen, sixteen], "the body is the same, the thing it is about is not")
        #expect(CardHistory.step(from: fifteen, to: sixteen) == .page(.title))
        #expect(CardHistory.step(from: fifteen, to: "iphone 15:\nErschien im Herbst.") == .folds(.same), "formatting only")
        #expect(CardHistory.step(from: "**Cache**\nErschien im Herbst.", to: "**Speicher**\nErschien im Herbst.") == .page(.title), "other words")
        #expect(CardHistory.step(from: sixteen, to: "**iPhone**\nErschien im Herbst.") == .page(.title), "a number that is gone")
        // Only a title-only preview may be continued without preserving a page.
        #expect(CardHistory.step(from: "**iPhone**", to: sixteen) == .folds(.kept))
        #expect(CardHistory.step(from: "**iPhone**\nErschien im Herbst.", to: sixteen) == .page(.title))
        #expect(CardHistory.step(from: "**iPhone 1**\nErschien im Herbst.", to: sixteen) == .page(.title), "a number is never continued")
        #expect(CardHistory.step(from: fifteen, to: "**iPhone 15 Pro**\nErschien im Herbst.") == .page(.title))
    }

    @Test func anotherCurrencyOrUnitKeepsThePageBefore() {
        let euro = "**Preis**\nKostet 100 EUR."
        let dollar = "**Preis**\nKostet 100 USD."
        #expect(pages(euro, dollar) == [euro, dollar])
        #expect(CardHistory.step(from: euro, to: dollar) == .page(.unit))
        #expect(CardHistory.step(from: "**Preis**\nKostet 100€.", to: "**Preis**\nKostet 100$.") == .page(.unit))
        #expect(CardHistory.step(from: "**Preis**\nKostet 100 €.", to: dollar) == .page(.unit))
        #expect(CardHistory.step(from: euro, to: "**Preis**\nKostet $100.") == .page(.unit))
        #expect(!CardHistory.step(from: "**Preis**\nKostet 100 €.", to: "**Preis**\nKostet 100.").isFold, "a unit that is gone")
        #expect(!CardHistory.step(from: "**Anteil**\nBei 54 %.", to: "**Anteil**\nBei 54 ‰.").isFold)
        #expect(!CardHistory.step(from: "**Turm**\n330 m hoch.", to: "**Turm**\n330 km hoch.").isFold)
        // The same amount written differently is the same amount.
        #expect(CardHistory.step(from: euro, to: "**Preis**\nKostet 100€.") == .folds(.same))
        #expect(CardHistory.step(from: euro, to: "**Preis**\nKostet **100 €**.") == .folds(.same))
        #expect(CardHistory.step(from: dollar, to: "**Preis**\nKostet $100.") == .folds(.same))
        let chart = "**iOS**\nZahlen von Apple.\n```chart\ntitle: Anteile\nunit: %\niOS 26: 54\niOS 18: 31\n```"
        #expect(!CardHistory.step(from: chart, to: chart.replacingOccurrences(of: "unit: %", with: "unit: Mio")).isFold, "the unit of a chart")
    }

    @Test func finishedCodeThatGotMoreCodeKeepsThePageBefore() {
        let finished = "**Schleife**\n```swift\nfor i in 1...3 { print(i) }\n```"
        let more = "**Schleife**\n```swift\nfor i in 1...3 { print(i) }\nexit(1)\n```"
        #expect(pages(finished, more) == [finished, more], "the earlier code was whole; what follows it is new behaviour")
        #expect(CardHistory.step(from: finished, to: more) == .page(.code))
        #expect(CardHistory.step(from: finished, to: finished + "\nLäuft dreimal.").isFold, "the same code, and a line about it")
        // Code that was cut off folds only into code that begins with it.
        let cut = "**Schleife**\n```swift\nfor i in 1...3 {\n"
        #expect(CardHistory.step(from: cut, to: "**Schleife**\n```swift\nfor i in 0..<3 {\n    print(i)\n}\n```") == .page(.code))
    }

    @Test func aChangedNumberKeepsThePageBefore() {
        let before = "**Eiffelturm**\n**330 m** hoch, steht in Paris."
        let after = "**Eiffelturm**\n**324 m** hoch, steht in Paris."
        #expect(pages(before, after) == [before, after])
        #expect(CardHistory.step(from: before, to: after) == .page(.number))
        #expect(!CardHistory.step(from: "**Preis**\n**13,19 €**", to: "**Preis**\n**13,99 €**").isFold)
        #expect(!CardHistory.step(from: "**Temperatur**\nBei -5 Grad.", to: "**Temperatur**\nBei 5 Grad.").isFold, "a sign belongs to its number")
        #expect(CardHistory.step(from: "**Anteil**\n**54,2 %** nutzen iOS 26.", to: "**Anteil**\n54.2% nutzen iOS 26.") == .folds(.same), "the same number written differently")
        let chart = "**iOS**\nZahlen von Apple.\n```chart\ntitle: Anteile\niOS 26: 54\niOS 18: 31\n```"
        #expect(!CardHistory.step(from: chart, to: chart.replacingOccurrences(of: "54", with: "58")).isFold, "a value of the chart")
    }

    @Test func anAnswerTurnedRoundKeepsThePageBefore() {
        let yes = "**Klinge**\n**Ja**, die Klinge ist austauschbar."
        let no = "**Klinge**\n**Nein**, die Klinge ist fest verbaut."
        #expect(pages(yes, no) == [yes, no])
        #expect(CardHistory.step(from: yes, to: no) == .page(.reversal))
        #expect(CardHistory.step(from: "**Cache**\nDer Cache ist threadsicher.", to: "**Cache**\nDer Cache ist nicht threadsicher.") == .page(.negation))
        #expect(!CardHistory.step(from: "**Cache**\nThe cache is not thread-safe.", to: "**Cache**\nThe cache is thread-safe.").isFold)
        #expect(!CardHistory.step(from: "**Cache**\nIt is safe.", to: "**Cache**\nIt isn't safe.").isFold)
    }

    @Test func anotherAnswerChangedCodeAndWhatIsGoneKeepThePageBefore() {
        let lru = "**Cache**\nLRU verwirft den am längsten ungenutzten Eintrag."
        let redis = "**Cache**\nRedis speichert Daten im Arbeitsspeicher."
        #expect(pages(lru, redis) == [lru, redis])
        #expect(CardHistory.step(from: lru, to: redis) == .page(.different))
        let code = "**Schleife**\nBis drei.\n```swift\nfor i in 1...3 { print(i) }\n```"
        #expect(CardHistory.step(from: code, to: code.replacingOccurrences(of: "1...3", with: "0..<3")) == .page(.code))
        #expect(!CardHistory.step(from: "**Backoff**\n```formula\nt = 2^n\n```", to: "**Backoff**\n```formula\nt = 3^n\n```").isFold)
        #expect(!CardHistory.step(from: Self.draft, to: Self.firstLines).isFold, "a line that is gone")
        #expect(!CardHistory.step(from: code, to: "**Schleife**\nBis drei.").isFold, "code that is gone")
        // Three versions, one real change: the first lines fold into the draft, the draft stays.
        let corrected = "**Eiffelturm**\n**324 m** hoch.\nSteht in Paris, eröffnet 1889."
        #expect(pages(Self.firstLines, Self.draft, corrected) == [Self.draft, corrected])
    }

    @Test func aVersionThatIsBeingWrittenIsNoPageUntilItIsFinished() {
        let lru = "**Cache**\nLRU verwirft den am längsten ungenutzten Eintrag."
        let redis = "**Cache**\nRedis speichert Daten im Arbeitsspeicher."
        #expect(pages(lru, "**Cache**\nRedis", writingLast: true) == ["**Cache**\nRedis"], "its text is shown at once; what it lacks is not held against it yet")
        #expect(pages(lru, redis) == [lru, redis], "finished, and another answer: the one before is a page")
    }

    /// What comparing words cannot see. Each of these is wrong, and known. Nearly all of
    /// it errs to the safe side: a page too many, never a changed statement without one.
    @Test func whereTheHeuristicIsWrong() {
        // A page although nothing changed: a synonym, a reworded title, a harmless word put
        // into a line, a line that ended in a number and was continued, first lines cut
        // inside a word.
        #expect(!CardHistory.step(from: "**Cache**\nLRU evicts the oldest entry.", to: "**Cache**\nLRU removes the oldest entry.").isFold)
        #expect(!CardHistory.step(from: "**Eiffelturm: Höhe**\n330 m hoch.", to: "**Höhe des Eiffelturms**\n330 m hoch.").isFold)
        #expect(!CardHistory.step(from: "**Cache**\nLRU evicts the oldest entry.", to: "**Cache**\nLRU then evicts the oldest entry.").isFold)
        #expect(!CardHistory.step(from: "**iPhone**\nErschien 2007.", to: "**iPhone**\nErschien 2007, in Deutschland im November.").isFold)
        #expect(!CardHistory.step(from: "**Eiffelturm**\n**330 m** ho", to: Self.firstLines).isFold)
    }

    @Test func anAddedLineThatRestrictsTheAnswerKeepsThePageBefore() {
        let before = "**Cache**\nDer Cache ist sicher."
        #expect(CardHistory.step(from: before, to: before + "\nDas gilt nur unter Linux.") == .page(.qualifier))
        #expect(CardHistory.step(from: before, to: before + "\nDas gilt nicht unter Windows.") == .page(.negation))
    }

    /// A replay puts the table back from the recording at each moment. The pages of a
    /// moment come from the versions of that moment only, and every version stays counted.
    @Test func aReplayShowsNoPageAndNoTextFromLater() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let corrected = "**Eiffelturm**\n**324 m** hoch.\nSteht in Paris, eröffnet 1889."
        let events: [[String: Any]] = [
            ["t": 1.0, "kind": "card_started", "card": 1, "layer": "fast", "sentence": 1],
            ["t": 1.1, "kind": "card_text", "card": 1, "text": Self.draft],
            ["t": 5.0, "kind": "card_started", "card": 2, "layer": "deep", "sentence": 1],
            ["t": 5.1, "kind": "card_text", "card": 2, "text": Self.checked],
            ["t": 5.2, "kind": "card_replaced", "card": 1, "by": 2],
            ["t": 9.0, "kind": "card_started", "card": 3, "layer": "deep", "sentence": 2],
            ["t": 9.1, "kind": "card_text", "card": 3, "text": corrected],
            ["t": 9.2, "kind": "card_replaced", "card": 2, "by": 3],
        ]
        let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try lines.joined(separator: "\n").write(to: folder.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
        let timeline = RunTimeline(folder: folder)
        #expect(timeline.cards.count == 3, "the timeline counts every version")

        let early = timeline.blocks(at: 3)
        #expect(early.count == 1 && early[0].versions.count == 1)
        #expect(early[0].pages.map(\.text) == [Self.draft], "neither the sources nor the correction are there yet")

        let middle = timeline.blocks(at: 6)
        #expect(middle.count == 1 && middle[0].versions.map(\.text) == [Self.draft, Self.checked], "both versions of that moment, as recorded")
        #expect(middle[0].pages.map(\.text) == [Self.checked], "one page: the checked card took the draft's place")
        #expect(!middle[0].pages.contains { $0.text.contains("324") })

        let late = timeline.blocks(at: 10)
        #expect(late.count == 1 && late[0].versions.count == 3)
        #expect(late[0].pages.map(\.text) == [Self.checked, corrected], "the number changed: what stood there before is a page")
        #expect(late[0].current.text == corrected)

        // Back to an earlier moment after a later one was shown: the same as before.
        #expect(timeline.blocks(at: 6)[0].pages.map(\.text) == [Self.checked])
    }
}

/// What the mounted stack shows. Changing it changes the stack that is already on screen.
@MainActor @Observable
private final class StackTable {
    var versions: [SessionCore.Card]
    var width: CGFloat
    /// The page in view, when the test turns the pages; otherwise the stack holds it itself.
    var page: UInt64? = CardBlocks.newestPage
    /// How often a moment was chosen by hand, as the replay counts it.
    var seeks = 0
    let turnsPages: Bool
    var highlightsUpdates = false

    init(versions: [SessionCore.Card], width: CGFloat, turnsPages: Bool) {
        self.versions = versions
        self.width = width
        self.turnsPages = turnsPages
    }
}

/// Where the layout writes the size it gave the stack. Not observed: reading it lays nothing out again.
@MainActor
private final class StackProbe {
    var size = CGSize.zero
    var bodies: [UInt64: CGSize] = [:]
    var frame = CGRect.zero
    var bodyFrames: [UInt64: CGRect] = [:]
    var highlights: [UInt64: CardUpdateHighlights] = [:]
}

private struct UpdateHighlightProbe: ViewModifier {
    let probe: StackProbe
    let card: UInt64
    @Environment(\.cardUpdateHighlights) private var highlights

    func body(content: Content) -> some View {
        content.onChange(of: highlights, initial: true) { _, value in probe.highlights[card] = value }
    }
}

/// The stack as the replay shows it: in a column of a given width inside a vertical scroll view.
private struct MountedStackView: View {
    @Bindable var table: StackTable
    let probe: StackProbe

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !table.versions.isEmpty {
                    CardStack(
                        block: CardBlocks.Block(id: table.versions[0].id, versions: table.versions),
                        highlightsUpdates: table.highlightsUpdates,
                        turnedTo: table.turnsPages ? $table.page : nil,
                        seeks: table.seeks
                    ) { card, _ in
                        CardBody(text: card.text, isWriting: card.status == .streaming, focusText: card.start.focusText)
                            .equatable()
                            .modifier(UpdateHighlightProbe(probe: probe, card: card.id))
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.bodies[card.id] = $0 }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.bodyFrames[card.id] = $0 }
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.size = $0 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frame = $0 }
                    .settlesIntoPlace()
                }
            }
            .coordinateSpace(.named(SettlesIntoPlace.space))
            .frame(width: table.width, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
            .animation(.smooth(duration: 0.3), value: table.versions.count)
        }
        .defaultScrollAnchor(.top)
    }
}

/// One stack in one window of the app the tests run in, from `init` until `remove()`.
@MainActor
private final class MountedStack {
    let table: StackTable
    private let probe = StackProbe()
    private let window: UIWindow

    init(_ versions: [SessionCore.Card], width: CGFloat, turnsPages: Bool) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "these tests need the app they run in to have a window scene: without a window nothing is laid out")
        table = StackTable(versions: versions, width: width, turnsPages: turnsPages)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        window.rootViewController = UIHostingController(rootView: MountedStackView(table: table, probe: probe))
        // These are geometry probes, not UI demos. Keep their windows from covering the
        // owner's app while retaining a mounted window for SwiftUI's scroll layout.
        window.alpha = 0
        window.isUserInteractionEnabled = false
        window.isHidden = false
    }

    /// How tall the stack is once the layout has come to rest: after what was changed has
    /// been taken in and any movement (turning to another version is animated) has ended.
    func height() async throws -> CGFloat {
        var last: CGFloat?
        var rests = 0
        for _ in 0..<100 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let now = probe.size.height
            if now > 0, now == last { rests += 1 } else { rests = 0 }
            last = now
            if rests >= 6 {
                // The stack is exactly as wide as the column it was given, and so are its pages.
                // If this fails, the heights say nothing: the pages did not get their width.
                #expect(abs(probe.size.width - table.width) < 1, "the stack is laid out at the width it was given")
                return now
            }
        }
        Issue.record("the stack's layout did not come to rest within five seconds (last height \(last ?? 0))")
        return last ?? 0
    }

    func remove() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func bodySize(for card: UInt64) -> CGSize? { probe.bodies[card] }
    func highlights(for card: UInt64) -> CardUpdateHighlights? { probe.highlights[card] }

    func image() -> UIImage {
        let view = window.rootViewController!.view!
        return UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    func expectInView(_ card: UInt64) throws {
        let body = try #require(probe.bodyFrames[card])
        #expect(body.minX >= probe.frame.minX - 1 && body.maxX <= probe.frame.maxX + 1,
                "the body of card \(card) must actually be in view, not another page: body \(body), stack \(probe.frame)")
        #expect(body.width > 0 && body.maxY <= probe.frame.maxY - 38 - CardMetrics.inset + 1,
                "the visible body must fit above the pager with its bottom padding")
    }
}

@MainActor
@Suite struct CardLiveUpdates {
    private let now = Date(timeIntervalSinceReferenceDate: 100)
    private let original = "Cache\n**LRU evicts 1 entry.**\nThe other entries remain."

    private func card(_ text: String) -> SessionCore.Card { card(1, text) }

    private func card(_ id: UInt64, _ text: String, replaces: UInt64? = nil) -> SessionCore.Card {
        var card = SessionCore.Card(start: CardStart(
            generationID: id, kind: .fast, style: .answer, triggerSegment: 1, sourceCard: replaces,
            contextVersion: 0, mappingVersion: 0))
        card.text = text
        card.status = .finished
        return card
    }

    @Test func openingAnExistingAnswerDoesNotFlash() {
        var highlights = CardUpdateHighlights()
        highlights.observe(card(original), at: now)
        #expect(highlights.pulses.isEmpty)
        highlights.observe(card(original), at: now.addingTimeInterval(1))
        #expect(highlights.pulses.isEmpty)
    }

    @Test func onlyTheReplacedLineFlashes() {
        var highlights = CardUpdateHighlights()
        highlights.observe(card(original), at: now)
        highlights.observe(card(2, original.replacingOccurrences(of: "1 entry", with: "2 entries"), replaces: 1), at: now)
        #expect(Set(highlights.pulses.keys) == [.line("LRU evicts 2 entries.")])
    }

    @Test func streamingThroughAnEmptyReplacementKeepsThePreviousAnswerAsBaseline() {
        var highlights = CardUpdateHighlights()
        highlights.observe(card(original), at: now)
        highlights.observe(card(2, "", replaces: 1), at: now)
        highlights.observe(card(2, "Cache", replaces: 1), at: now)
        highlights.observe(card(2, original + "\nA new detail.", replaces: 1), at: now)
        #expect(Set(highlights.pulses.keys) == [.line("A new detail.")])
        highlights.observe(card(2, original + "\nA new detail grows.", replaces: 1), at: now.addingTimeInterval(0.1))
        #expect(Set(highlights.pulses.keys) == [.line("A new detail grows.")])
    }

    @Test func formattingAndMovingExistingLinesDoNotFlash() {
        var highlights = CardUpdateHighlights()
        highlights.observe(card(original), at: now)
        highlights.observe(card("Cache\nThe other entries remain.\nLRU evicts 1 entry."), at: now)
        #expect(highlights.pulses.isEmpty)
    }

    @Test func aDeletionMarksTheHeading() {
        var highlights = CardUpdateHighlights()
        highlights.observe(card(original), at: now)
        highlights.observe(card("Cache\n**LRU evicts 1 entry.**"), at: now)
        #expect(Set(highlights.pulses.keys) == [.title])
    }

    @Test func sourcesAndRichContentAreTrackedSeparately() {
        var highlights = CardUpdateHighlights()
        highlights.observe(card(original), at: now)
        highlights.observe(card(original + "\n```swift\nlet count = 2\n```\nSources: [Docs](https://example.com/docs)"), at: now)
        #expect(Set(highlights.pulses.keys) == [.code, .sources])
    }

    @Test func anUnrelatedNewLineDoesNotRestartAnEarlierPulse() throws {
        var highlights = CardUpdateHighlights()
        highlights.observe(card(original), at: now)
        highlights.observe(card(original + "\nFirst addition."), at: now)
        let first = try #require(highlights.pulses[.line("First addition.")])
        highlights.observe(card(original + "\nFirst addition.\nSecond addition."), at: now.addingTimeInterval(0.5))
        #expect(highlights.pulses[.line("First addition.")] == first)
        highlights.observe(card(original + "\nFirst addition.\nSecond addition."), at: now.addingTimeInterval(3))
        #expect(highlights.pulses.isEmpty)
    }

    @Test func aMountedLiveStackHighlightsItsFirstReplacementEvenWhenThePagerAppears() async throws {
        let stack = try MountedStack([card(original)], width: 420, turnsPages: true)
        defer { stack.remove() }
        stack.table.highlightsUpdates = true
        _ = try await stack.height()
        #expect(stack.highlights(for: 1)?.pulses.isEmpty == true)
        stack.table.versions.append(card(2, original.replacingOccurrences(of: "1 entry", with: "2 entries"), replaces: 1))
        _ = try await stack.height()
        #expect(Set(stack.highlights(for: 2)?.pulses.keys.map { $0 } ?? []) == [.line("LRU evicts 2 entries.")])
        stack.table.page = 1
        _ = try await stack.height()
        #expect(stack.highlights(for: 1)?.pulses.isEmpty == true, "Historical pages do not inherit live flashes")
    }

    @Test func aMountedStackHighlightsTextGrowthWithoutANewGeneration() async throws {
        let stack = try MountedStack([card(original)], width: 420, turnsPages: false)
        defer { stack.remove() }
        stack.table.highlightsUpdates = true
        _ = try await stack.height()
        stack.table.versions[0].text += "\nA streamed addition."
        _ = try await stack.height()
        #expect(stack.highlights(for: 1)?.pulses[.line("A streamed addition.")] != nil)
    }

    @Test func replayAndHistoryDoNotOptIn() async throws {
        let stack = try MountedStack([card(original)], width: 420, turnsPages: false)
        defer { stack.remove() }
        _ = try await stack.height()
        stack.table.versions.append(card(2, original.replacingOccurrences(of: "1 entry", with: "2 entries"), replaces: 1))
        _ = try await stack.height()
        #expect(stack.highlights(for: 2)?.pulses.isEmpty == true)
    }

    @Test func theChangedLineIsPaintedYellowThenFadesWithoutChangingHeight() async throws {
        let stack = try MountedStack([card(original)], width: 420, turnsPages: false)
        defer { stack.remove() }
        stack.table.highlightsUpdates = true
        _ = try await stack.height()
        let before = try yellowPixels(in: stack.image())
        stack.table.versions[0].text = original.replacingOccurrences(of: "1 entry", with: "2 entries")
        let height = try await stack.height()
        let marked = try yellowPixels(in: stack.image())
        #expect(marked > before + 200, "The rendered answer must have a visible yellow mark, not just a diff in state")
        try await Task.sleep(for: .seconds(2.2))
        let faded = try yellowPixels(in: stack.image())
        #expect(faded <= before + 50, "The mark disappears after two seconds")
        #expect(abs(try await stack.height() - height) < 1, "Fading must not move or resize the answer")
    }

    private func yellowPixels(in image: UIImage) throws -> Int {
        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try #require(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, i in
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            return count + (r > 50 && g > 40 && b * 5 < min(r, g) * 4 && abs(r - g) < 80 ? 1 : 0)
        }
    }
}
