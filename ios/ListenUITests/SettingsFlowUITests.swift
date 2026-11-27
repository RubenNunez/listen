import XCTest

/// Idle settings/transfer navigation only: no recording, model calls or real QR codes.
@MainActor final class SettingsFlowUITests: XCTestCase {
    private func launch(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-microphoneOn", "NO", "-recordRuns", "NO"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(settings.frame.width, 44)
        XCTAssertGreaterThanOrEqual(settings.frame.height, 44)
        return app
    }

    private func openTransfer(_ app: XCUIApplication) {
        app.buttons["Settings"].tap()
        let transfer = app.buttons["settings.deviceTransfer"]
        XCTAssertTrue(transfer.waitForExistence(timeout: 5))
        transfer.tap()
        XCTAssertTrue(app.buttons["transfer.scan"].waitForExistence(timeout: 5))
    }

    func testConnectionsExposeThePersonalRouterWithoutAdvanced() {
        let app = launch(); defer { app.terminate() }
        app.buttons["Settings"].tap()
        let connections = app.buttons["settings.connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 5))
        connections.tap()
        let pair = app.buttons["router.pair"]
        for _ in 0..<5 where !pair.isHittable { app.swipeUp() }
        XCTAssertTrue(pair.isHittable)
    }

    func testConnectionsManageProvidersAndVoiceSetup() {
        let app = launch(); defer { app.terminate() }
        app.buttons["Settings"].tap()
        app.buttons["settings.connections"].tap()
        let add = app.buttons["Add key OpenAI"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["OpenAI"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        attach(app, "connections")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let voice = app.buttons["settings.voice"]
        if !voice.isHittable { app.swipeUp() }
        voice.tap()
        XCTAssertTrue(app.navigationBars["Voice quick start"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings.connections"].waitForExistence(timeout: 5))
    }

    private func openRouterScanner(_ app: XCUIApplication) {
        app.buttons["Settings"].tap()
        app.buttons["settings.connections"].tap()
        let pair = app.buttons["router.pair"]
        for _ in 0..<5 where !pair.isHittable { app.swipeUp() }
        XCTAssertTrue(pair.isHittable)
        pair.tap()
        XCTAssertTrue(app.navigationBars["Scan router code"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["scanner.cancel"].exists)
        if app.alerts.firstMatch.waitForExistence(timeout: 1) { app.alerts.firstMatch.buttons.firstMatch.tap() }
    }

    func testRouterPairingOpensCameraAndCanRescanOrPaste() {
        let app = launch(); defer { app.terminate() }
        openRouterScanner(app)
        XCTAssertTrue(app.buttons["scanner.manualEntry"].isHittable)
        XCTAssertFalse(app.buttons["Pair this device"].exists)
        attach(app, "router-camera")
        app.buttons["scanner.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add router"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["router.review"].exists)
        app.buttons["router.scan"].tap()
        let paste = app.buttons["scanner.manualEntry"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let field = app.textFields["router.link"]
        let input = field.exists ? field : app.textViews["router.link"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("listen://pair?host=127.0.0.1&port=50551&code=ABCD2345&fp=" + String(repeating: "a", count: 64))
        app.buttons["router.review"].tap()
        XCTAssertTrue(app.navigationBars["Pair Listen Router"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pair this device"].exists)
        XCTAssertFalse(app.staticTexts["Paired · model requests are off"].exists)
        attach(app, "router-pairing-review")
        app.buttons["router.rescan"].tap()
        XCTAssertTrue(app.navigationBars["Scan router code"].waitForExistence(timeout: 5))
        app.buttons["scanner.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Pair Listen Router"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pair this device"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add router"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.buttons["router.pair"].tap()
        XCTAssertTrue(app.navigationBars["Scan router code"].waitForExistence(timeout: 5))
    }

    func testInvalidRouterLinkStaysInSetup() {
        let app = launch(); defer { app.terminate() }
        openRouterScanner(app)
        app.buttons["scanner.manualEntry"].tap()
        let field = app.textFields["router.link"]
        // Multiline fields are exposed as text views on some OS versions.
        let input = field.exists ? field : app.textViews["router.link"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("invalid synthetic pairing link")
        app.buttons["router.review"].tap()
        XCTAssertTrue(app.staticTexts["router.failure"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pair this device"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["router.pair"].waitForExistence(timeout: 5))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// AX can see a label even when it is white on white. Inspect the middle of
    /// the real native button, away from its rounded edges and surrounding card.
    private func assertVisibleButtonLabel(_ button: XCUIElement) throws {
        let image = try XCTUnwrap(button.screenshot().image.cgImage)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(
            x: CGFloat(image.width) * 0.2, y: CGFloat(image.height) * 0.2,
            width: CGFloat(image.width) * 0.6, height: CGFloat(image.height) * 0.6)))
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var light = 0, dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] > 220 && pixels[i + 1] > 220 && pixels[i + 2] > 220 { light += 1 }
            if pixels[i] < 35 && pixels[i + 1] < 35 && pixels[i + 2] < 35 { dark += 1 }
        }
        XCTAssertGreaterThan(light, width * height / 1000, "Button needs a visible light foreground or background")
        XCTAssertGreaterThan(dark, width * height / 1000, "Button needs a contrasting dark foreground or background")
    }

    func testTransferAndScannerReturnToSettingsWithoutLosingTheAction() throws {
        let app = launch()
        defer { app.terminate() }
        openTransfer(app)
        let scan = app.buttons["transfer.scan"]
        XCTAssertTrue(scan.isHittable && scan.isEnabled)
        XCTAssertGreaterThanOrEqual(scan.frame.height, 44)
        try assertVisibleButtonLabel(scan)
        attach(app, "transfer-regular")
        scan.tap()
        let cancel = app.buttons["scanner.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        cancel.tap()
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertTrue(scan.isEnabled && scan.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings.deviceTransfer"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        // Repeat sheet creation and navigation; it must not accumulate stale scanner state.
        openTransfer(app)
        XCTAssertTrue(scan.isHittable && scan.isEnabled)
    }

    func testTransferStaysUsableWithLargestAccessibilityText() throws {
        let app = launch(largeText: true)
        defer { app.terminate() }
        openTransfer(app)
        let scan = app.buttons["transfer.scan"]
        XCTAssertTrue(scan.isHittable && scan.isEnabled)
        XCTAssertGreaterThanOrEqual(scan.frame.height, 44)
        XCTAssertGreaterThanOrEqual(scan.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(scan.frame.maxX, app.frame.maxX)
        try assertVisibleButtonLabel(scan)
        attach(app, "transfer-accessibility")
    }

    func testTopicsHistoryAndSystemsCanBeOpenedAndDismissedRepeatedly() {
        let app = launch()
        defer { app.terminate() }
        for iteration in 0..<2 {
            app.buttons["Open topics"].tap()
            let history = app.buttons["History"]
            XCTAssertTrue(history.waitForExistence(timeout: 5))
            if iteration == 0 { attach(app, "topics") }
            history.tap()
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            if iteration == 0 { attach(app, "history") }
            // Closing while a disk snapshot is pending must remain possible.
            close.tap()
            let systems = app.buttons["Systems"]
            XCTAssertTrue(systems.waitForExistence(timeout: 5))
            systems.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            let back = app.buttons["Back to the orb"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(app.buttons["Open topics"].waitForExistence(timeout: 5))
        }
        app.buttons["Settings"].tap()
        let advanced = app.buttons["Advanced"]
        if !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        let advancedBar = app.navigationBars["Advanced"]
        XCTAssertTrue(advancedBar.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Intelligence"].exists)
        XCTAssertFalse(app.buttons["Add key OpenAI"].exists)
        XCTAssertFalse(app.switches["Record conversations"].exists)
        attach(app, "advanced-settings")
        advancedBar.buttons["Done"].tap()
        XCTAssertTrue(advancedBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.deviceTransfer"].waitForExistence(timeout: 5))
    }
}
