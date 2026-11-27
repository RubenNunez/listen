import XCTest

/// Core topic operations use their own persisted fixture, with audio and recording off.
@MainActor final class TopicEditingUITests: XCTestCase {
    private func launch(fixture: UUID = UUID(), blockedStore: Bool = false, longList: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-microphoneOn", "NO", "-recordRuns", "NO", "-topicUXFixture", fixture.uuidString]
        if blockedStore { app.launchArguments.append("-topicUXBlockedStore") }
        if longList { app.launchArguments.append("-topicUXLongList") }
        app.launch()
        openTopics(app)
        return app
    }
    private func openTopics(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Open topics"].waitForExistence(timeout: 10))
        app.buttons["Open topics"].tap()
        XCTAssertTrue(app.buttons["New topic"].waitForExistence(timeout: 5))
    }
    private func create(_ name: String, in app: XCUIApplication) {
        app.buttons["New topic"].tap()
        let field = app.textFields["topic.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["topic.save"].isEnabled)
        field.tap(); field.typeText(name)
        XCTAssertTrue(app.buttons["topic.save"].isEnabled)
        app.buttons["topic.save"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }
    private func select(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.containing(.staticText, identifier: name).firstMatch
    }

    func testNewTopicOpensWithTheRightTitleAndCancelsWithoutAddingAnything() {
        let app = launch(); defer { app.terminate() }
        app.buttons["Options for General"].tap()
        XCTAssertFalse(app.buttons["topic.delete"].isEnabled)
        app.staticTexts["Topics"].tap()
        app.buttons["New topic"].tap()
        XCTAssertTrue(app.navigationBars["New topic"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["topic.save"].isEnabled)
        app.buttons["topic.cancel"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["topic.cancel"].exists)
    }

    func testSameNamedTopicsRemainDistinctRows() {
        let app = launch(); defer { app.terminate() }
        create("Synthetic same name", in: app)
        create("Synthetic same name", in: app)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Synthetic same name").count, 2)
        XCTAssertTrue(app.staticTexts["General"].exists)
    }

    func testFailedSaveKeepsTheDraftOpen() {
        let app = launch(blockedStore: true); defer { app.terminate() }
        app.buttons["New topic"].tap()
        let field = app.textFields["topic.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Synthetic unsaved draft")
        app.buttons["topic.save"].tap()
        let alert = app.alerts["Could not save topic"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        XCTAssertEqual(field.value as? String, "Synthetic unsaved draft")
        XCTAssertTrue(app.buttons["topic.cancel"].exists)
        app.buttons["topic.cancel"].tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Synthetic unsaved draft"].exists)
    }

    func testNewTopicIsBroughtIntoViewInALongList() {
        let app = launch(longList: true); defer { app.terminate() }
        create("Synthetic newly visible topic", in: app)
        let row = app.staticTexts["Synthetic newly visible topic"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable, "The saved topic must be in view, not merely somewhere below 30 other rows")
        XCTAssertTrue(select("Synthetic newly visible topic", in: app).isSelected)
    }

    func testTopicActionsStayReachableAfterCreatingInALongList() {
        let app = launch(longList: true); defer { app.terminate() }
        create("Synthetic reachable actions", in: app)
        XCTAssertTrue(app.staticTexts["Synthetic reachable actions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New topic"].isHittable)
        XCTAssertTrue(app.buttons["History"].isHittable)
        XCTAssertTrue(app.buttons["Systems"].isHittable)
        XCTAssertTrue(app.buttons["Back to the orb"].isHittable)
        app.buttons["New topic"].tap()
        XCTAssertTrue(app.navigationBars["New topic"].waitForExistence(timeout: 5))
        app.buttons["topic.cancel"].tap()
        app.buttons["Back to the orb"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
    }

    func testCreatedTopicsStayVisibleSelectableAndPersistAfterRelaunch() {
        let app = launch(); defer { app.terminate() }
        create("Synthetic first topic", in: app)
        XCTAssertTrue(app.staticTexts["Synthetic first topic"].waitForExistence(timeout: 5))
        create("Synthetic second topic", in: app)
        XCTAssertTrue(app.staticTexts["Synthetic second topic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic first topic"].exists)
        let first = select("Synthetic first topic", in: app)
        first.tap(); XCTAssertTrue(first.isSelected)
        let second = select("Synthetic second topic", in: app)
        second.tap(); XCTAssertTrue(second.isSelected)
        app.terminate(); app.launch(); openTopics(app)
        XCTAssertTrue(app.staticTexts["Synthetic first topic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic second topic"].exists)
        XCTAssertTrue(select("Synthetic second topic", in: app).isSelected)
    }

    func testEditArchiveAndRestorePreserveBothTopics() {
        let app = launch(); defer { app.terminate() }
        create("Synthetic editable topic", in: app)
        XCTAssertTrue(app.staticTexts["Synthetic editable topic"].waitForExistence(timeout: 5))
        app.buttons["Options for Synthetic editable topic"].tap()
        app.buttons["topic.edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit topic"].waitForExistence(timeout: 5))
        let field = app.textFields["topic.name"]
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Synthetic editable topic".count))
        field.typeText("Synthetic renamed topic")
        app.buttons["topic.save"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic renamed topic"].waitForExistence(timeout: 5))
        app.buttons["Options for Synthetic renamed topic"].tap()
        app.buttons["topic.archive"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic renamed topic"].waitForNonExistence(timeout: 5))
        app.buttons["topics.archive"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic renamed topic"].waitForExistence(timeout: 5))
        app.buttons["Options for Synthetic renamed topic"].tap()
        app.buttons["topic.archive"].tap()
        app.buttons["topics.archive"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic renamed topic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["General"].exists)
    }
}
