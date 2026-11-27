import XCTest

/// Explicit setup only: isolated topics, no capture, inference, credentials or tool calls.
@MainActor final class VoiceSetupUITests: XCTestCase {
    private func launch(largeText: Bool = false, longList: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-microphoneOn", "NO", "-recordRuns", "NO", "-topicUXFixture", UUID().uuidString]
        if longList { app.launchArguments.append("-topicUXLongList") }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["start.voice"].waitForExistence(timeout: 15))
        return app
    }

    private func create(_ name: String, in app: XCUIApplication) {
        let create = app.buttons["voiceSetup.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let field = app.textFields["topic.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(name)
        app.buttons["topic.save"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Voice quick start"].waitForExistence(timeout: 5))
    }

    func testTalkWithoutAConfiguredTopicOffersSetupAndPersistsAnExplicitCreation() {
        let app = launch(); defer { app.terminate() }
        app.buttons["start.voice"].tap()
        XCTAssertTrue(app.staticTexts["voiceSetup.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Could not start listening"].exists)
        app.buttons["voiceSetup.create"].tap()
        XCTAssertTrue(app.textFields["topic.name"].waitForExistence(timeout: 5))
        app.buttons["topic.cancel"].tap()
        XCTAssertTrue(app.staticTexts["voiceSetup.empty"].waitForExistence(timeout: 5))
        create("Synthetic voice setup", in: app)
        XCTAssertFalse(app.staticTexts["voiceSetup.empty"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceSetup.topic").firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["start.voice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Microphone"].value as? String, "0")
        app.buttons["Open topics"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic voice setup"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.buttons["Settings"].tap()
        app.buttons["settings.voice"].tap()
        let choice = app.descendants(matching: .any).matching(identifier: "voiceSetup.topic").firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue((choice.label + (choice.value as? String ?? "")).contains("Synthetic voice setup"))
        XCTAssertFalse(app.staticTexts["voiceSetup.unavailable"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "voice-setup-configured"; image.lifetime = .keepAlways; add(image)
    }

    func testSettingsCreationUpdatesSharedTopicsAndAnArchivedTargetDoesNotStartAnotherTopic() {
        let app = launch(); defer { app.terminate() }
        app.buttons["Settings"].tap()
        app.buttons["settings.voice"].tap()
        create("Synthetic archived voice setup", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        app.buttons["Open topics"].tap()
        let options = app.buttons["Options for Synthetic archived voice setup"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap(); app.buttons["topic.archive"].tap()
        app.buttons["Back to the orb"].tap()
        app.buttons["start.voice"].tap()
        XCTAssertTrue(app.staticTexts["voiceSetup.unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["voiceSetup.empty"].exists)
        app.buttons["voiceSetup.reset"].tap()
        XCTAssertFalse(app.staticTexts["voiceSetup.unavailable"].exists)
        app.buttons["Done"].tap()
        XCTAssertEqual(app.switches["Microphone"].value as? String, "0")
        app.buttons["start.voice"].tap()
        XCTAssertTrue(app.staticTexts["voiceSetup.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["voiceSetup.unavailable"].exists)
    }

    func testVoiceSetupRemainsUsableWithLargestTextWithoutStartingCapture() {
        let app = launch(largeText: true); defer { app.terminate() }
        app.buttons["start.voice"].tap()
        let create = app.buttons["voiceSetup.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable, "The empty-state action must be reachable before the explanation text, even with a stale saved target")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "voice-setup-accessibility"; image.lifetime = .keepAlways; add(image)
        create.tap()
        XCTAssertTrue(app.textFields["topic.name"].waitForExistence(timeout: 5))
        app.buttons["topic.cancel"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["start.voice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Microphone"].value as? String, "0")
    }


    func testVoiceTopicCreatedFromTopicSettingsIsVisibleInALongList() {
        let app = launch(longList: true); defer { app.terminate() }
        app.buttons["Open topics"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["settings.voice"].tap()
        create("Synthetic voice from topic settings", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        let row = app.staticTexts["Synthetic voice from topic settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable, "Creating through Settings must bring the new topic into view too")
        XCTAssertTrue(app.buttons["New topic"].isHittable)
        app.buttons["Back to the orb"].tap()
        XCTAssertEqual(app.switches["Microphone"].value as? String, "0")
        app.buttons["Open topics"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable, "Reopening topics must keep the selected topic in view")

    }

}
