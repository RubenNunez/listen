import XCTest

/// Plays the scripted demo session once, end to end, in the real app.
final class DemoFlowUITests: XCTestCase {
    @MainActor
    func testDemoSessionFromStartToReview() throws {
        let app = XCUIApplication()
        app.launch()

        // Start shows only the orb; a tap flows on to the topics.
        let orb = app.buttons["Open topics"]
        XCTAssertTrue(orb.waitForExistence(timeout: 10))
        attach(app, "start")
        orb.tap()
        let start = app.buttons["Start listening"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let listening = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Listening'")).firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 15), "capture started and the session is listening")
        attach(app, "listening")

        // Voice 2 is the user in the script: mark its first line.
        XCTAssertTrue(app.staticTexts["Danke für die Einladung."].waitForExistence(timeout: 15))
        let thisIsMe = app.buttons.matching(identifier: "This is me")
        thisIsMe.element(boundBy: thisIsMe.count - 1).tap()
        let hint = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Which voice is yours?'")).firstMatch
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5), "the mapping hint goes away once a voice is marked")

        // The next question from the other voice produces a card.
        let card = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Es wurde kein Modell aufgerufen.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        attach(app, "card")

        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))

        app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Session ended"].waitForExistence(timeout: 5))
        attach(app, "review")
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label)
        print("REVIEW_TEXTS: \(texts.prefix(12))")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Start listening"].waitForExistence(timeout: 5))
        attach(app, "topics")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
