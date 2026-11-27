import XCTest

/// Real native gestures against a local synthetic recording, with no model/account calls.
@MainActor final class ReplayGestureUITests: XCTestCase {
    private func launch(seconds: Int = 600) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-replayUXFixture"]
        app.launchEnvironment["LISTEN_REPLAY_FIXTURE_SECONDS"] = String(seconds)
        app.launchEnvironment["LISTEN_REPLAY_INPUT_DIAGNOSTICS"] = "1"
        app.launch()
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(pin(app).waitForExistence(timeout: 20))
        print("PIN_BOOT \(String(describing: pin(app).value))")
        let visible = NSPredicate(format: "hittable == true")
        expectation(for: visible, evaluatedWith: pin(app))
        waitForExpectations(timeout: 10)
        return app
    }

    private func pin(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "replay.playhead").firstMatch
    }

    private func time(_ pin: XCUIElement) -> Double {
        Double((pin.value as? String ?? "").split(separator: " ").first ?? "") ?? -1
    }

    func testPinFollowsTheHandAndDoesNotRecenterOnRelease() {
        let app = launch()
        defer { app.terminate() }
        let pin = pin(app)
        let initial = pin.frame.midX, before = time(pin)
        let screenScale = pin.frame.width / 44
        let viewport = app.scrollViews["timeline.horizontal"]
        // Stay outside the edge-scroll zone, including on a narrow phone viewport.
        let distance = min(120, max(20, initial - viewport.frame.minX - 64))
        let start = pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = start.withOffset(CGVector(dx: -distance, dy: 0))
        print("PIN_BEFORE value=\(String(describing: pin.value)) frame=\(pin.frame) viewport=\(viewport.frame)")
        start.press(forDuration: 0.1, thenDragTo: target)
        let followState = String(describing: app.buttons["replay.follow"].value)
        print("PIN_TRACE initial=\(initial) final=\(pin.frame.midX) before=\(before) after=\(time(pin)) follow=\(followState)")
        print("PIN_AFTER value=\(String(describing: pin.value))")
        XCTAssertEqual(pin.frame.midX, initial - distance, accuracy: 2, "the thumb stays where the hand put it")
        XCTAssertEqual(time(pin), before - distance / (46 * screenScale), accuracy: 0.15)
        XCTAssertEqual(app.buttons["replay.follow"].value as? String, "Detached")
        let next = pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let back = min(75, distance * 0.6)
        next.press(forDuration: 0.1, thenDragTo: next.withOffset(CGVector(dx: back, dy: 0)))
        XCTAssertEqual(pin.frame.midX, initial - distance + back, accuracy: 2, "direction reversal has no accumulated offset")
        XCTAssertEqual(app.buttons["replay.follow"].value as? String, "Detached")
    }

    /// A field of the playhead's diagnostic value, such as `offset`, `pin` or `visible`.
    private func field(_ name: String, of pin: XCUIElement) -> String {
        let value = pin.value as? String ?? ""
        guard let range = value.range(of: " \(name)=") else { return "" }
        return String(value[range.upperBound...].prefix { $0 != " " })
    }

    private func diagnostic(_ name: String, of pin: XCUIElement) -> Double {
        Double(field(name, of: pin)) ?? .nan
    }

    func testDraggingTheSliderBringsTheStripAlong() {
        let app = launch()
        defer { app.terminate() }
        let pin = pin(app)
        app.sliders["replay.slider"].adjust(toNormalizedSliderPosition: 0.1)
        print("SLIDER_TRACE value=\(String(describing: pin.value))")
        // Far from where the strip stood (the end); the slider's placement itself is not exact.
        XCTAssertLessThan(time(pin), 300)
        XCTAssertEqual(field("visible", of: pin), "true", "the strip came along to the chosen moment")
        XCTAssertEqual(app.buttons["replay.follow"].value as? String, "Detached")
    }

    /// Holds the pin inside the strip's leading edge, `inset` points or (nil) halfway into the
    /// band along the edge. While it is held there, the strip has to come along: how far it
    /// scrolled, in seconds of the recording.
    private func holdNearLeadingEdge(inset: CGFloat?) -> (carried: Double, pinAt: Double, inset: CGFloat, visible: Bool) {
        let app = launch()
        defer { app.terminate() }
        let pin = pin(app)
        let viewport = app.scrollViews["timeline.horizontal"]
        let screenScale = pin.frame.width / 44
        let inset = inset ?? min(160, max(56, viewport.frame.width / screenScale / 6)) / 2
        let offset = diagnostic("offset", of: pin), initial = pin.frame.midX
        let start = pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = start.withOffset(CGVector(dx: viewport.frame.minX + inset * screenScale - initial, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 1.5)
        let carried = (offset - diagnostic("offset", of: pin)) / 46
        print("EDGE_TRACE inset=\(inset) carried=\(carried) value=\(String(describing: pin.value))")
        return (carried, diagnostic("pin", of: pin), inset, pin.isHittable)
    }

    func testHoldingThePinAtTheEdgeCarriesTheStripAlong() {
        let result = holdNearLeadingEdge(inset: 16)
        XCTAssertGreaterThan(result.carried, 3, "the strip moved along while the pin was held at the edge")
        XCTAssertEqual(result.pinAt, 16, accuracy: 4, "the pin stays under the hand")
        XCTAssertTrue(result.visible)
    }

    func testHoldingThePinNearTheEdgeAlreadyCarriesTheStripAlong() {
        // Not only the last few points: the band where the strip comes along is wide enough to find.
        let result = holdNearLeadingEdge(inset: nil)
        XCTAssertGreaterThan(result.carried, 3, "the strip moved along before the hand reached the very edge")
        XCTAssertEqual(result.pinAt, Double(result.inset), accuracy: 4, "the pin stays under the hand")
        XCTAssertTrue(result.visible)
    }

    func testPanningDoesNotChangeTimeAndFollowIsExplicit() {
        let app = launch()
        defer { app.terminate() }
        let follow = app.buttons["replay.follow"]
        follow.tap()
        print("FOLLOW_TRACE afterDetach=\(String(describing: follow.value))")
        let before = time(pin(app))
        let viewport = app.scrollViews["timeline.horizontal"]
        XCTAssertTrue(viewport.exists)
        // This horizontal scroll view lives in a vertically clipped panel. Its full
        // accessibility frame can extend below the phone; stay in the visible top rows.
        let from = viewport.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: viewport.frame.width * 0.5, dy: 80))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: min(100, viewport.frame.width * 0.25), dy: 0)))
        XCTAssertEqual(follow.value as? String, "Detached")
        follow.tap()
        print("FOLLOW_TRACE afterAttach=\(String(describing: follow.value)) enabled=\(follow.isEnabled)")
        print("FOLLOW_PIN \(String(describing: pin(app).value))")
        XCTAssertTrue(pin(app).waitForExistence(timeout: 5))
        XCTAssertEqual(time(pin(app)), before, accuracy: 0.1)
        XCTAssertEqual(follow.value as? String, "Following")
    }

    func testPlaybackAndPauseRemainConsistentAfterDragging() {
        let app = launch()
        defer { app.terminate() }
        let play = app.buttons["replay.play"]
        play.tap()
        XCTAssertEqual(play.label, "Pause")
        let playhead = pin(app)
        XCTAssertTrue(playhead.waitForExistence(timeout: 5))
        let from = playhead.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 100, dy: 0)))
        play.tap()
        XCTAssertEqual(play.label, "Play")
        let atPause = time(playhead)
        // An accessibility read after another UI action must not find a resumed clock.
        app.buttons["replay.follow"].tap()
        XCTAssertEqual(time(pin(app)), atPause, accuracy: 0.1)
    }

    func testTokenCounterKeepsItsColumnWhenUsageBecomesIncomplete() {
        let app = launch(seconds: 10)
        defer { app.terminate() }
        let tokens = app.descendants(matching: .any).matching(identifier: "timeline.tokens").firstMatch
        let slider = app.sliders["replay.slider"]
        slider.adjust(toNormalizedSliderPosition: 2 / 12)
        let labelX = app.staticTexts["requests"].frame.minX
        let column = tokens.frame
        XCTAssertFalse((tokens.value as? String ?? "").hasPrefix("≥"))
        slider.adjust(toNormalizedSliderPosition: 4 / 12)
        XCTAssertTrue((tokens.value as? String ?? "").hasPrefix("≥"))
        XCTAssertEqual(tokens.frame.minX, column.minX, accuracy: 1)
        XCTAssertEqual(tokens.frame.width, column.width, accuracy: 1)
        XCTAssertEqual(app.staticTexts["requests"].frame.minX, labelX, accuracy: 1)
        XCTAssertGreaterThan(tokens.frame.midX, app.frame.midX)
    }

    func testScrubbingPerformance() {
        let app = launch()
        defer { app.terminate() }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app),
                          XCTOSSignpostMetric(subsystem: "com.meowop.listen", category: "Replay", name: "PlayheadUpdate")],
                options: options) {
            let pin = pin(app)
            let start = pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -40, dy: 0)))
            let back = pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            back.press(forDuration: 0.05, thenDragTo: back.withOffset(CGVector(dx: 40, dy: 0)))
        }
    }
}
