import XCTest

/// The voice menu only: no microphone, samples, downloads, models or external services.
/// Opening the menu and choosing an entry must work without any of them.
@MainActor final class VoiceChoiceUITests: XCTestCase {
    private func launch(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LISTEN_TALKBACK_MUTE"] = "1"
        app.launchEnvironment["LISTEN_TEST_NO_MICROPHONE"] = "1"
        app.launchArguments = ["-microphoneOn", "NO", "-recordRuns", "NO", "-voiceChoiceFixture", UUID().uuidString]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 15))
        return app
    }

    private func menu(in app: XCUIApplication) -> XCUIElement {
        let menu = app.buttons["assistant.voice"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        return menu
    }

    /// An entry of the open menu: by its identifier, or by its name where the system's menu drops identifiers.
    private func entry(_ id: String, named name: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["voice.choice." + id]
        return identified.waitForExistence(timeout: 3) ? identified : app.buttons[name].firstMatch
    }

    private func choose(_ id: String, named name: String, in app: XCUIApplication) {
        menu(in: app).tap()
        let item = entry(id, named: name, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu offers \(name)")
        item.tap()
    }

    func testTheReactionCollectionCanGrowAndAnAddedPhraseCanBeRemoved() {
        let app = launch(); defer { app.terminate() }
        app.buttons["assistant.waitingSound"].tap()
        let collection = app.buttons["Conversation reactions"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5)); collection.tap()
        XCTAssertTrue(app.navigationBars["Conversation reactions"].waitForExistence(timeout: 5))
        let input = app.textFields["reaction.newPhrase"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Gib mir eine Sekunde.")
        app.buttons["reaction.add"].tap()
        app.swipeUp()
        let phrase = app.staticTexts["Gib mir eine Sekunde."]
        XCTAssertTrue(phrase.waitForExistence(timeout: 5))
        phrase.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3)); remove.tap()
        XCTAssertTrue(phrase.waitForNonExistence(timeout: 3))
    }

    func testChoosingFromTheMenuSwitchesAtOnceAndIsRetainedAfterRelaunch() {
        let app = launch(); defer { app.terminate() }
        choose("local.pocket-german.alba", named: "Alba", in: app)
        XCTAssertEqual(menu(in: app).value as? String, "Alba · Pocket TTS German", "one tap changes the voice: nothing to confirm")
        // The same name under two models stays two entries.
        choose("local.qwen-8bit.Sohee", named: "Sohee", in: app)
        XCTAssertEqual(menu(in: app).value as? String, "Sohee · Qwen3-TTS 0.6B 8-bit")
        choose("local.pocket-german.fantine", named: "Fantine", in: app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 15))
        XCTAssertEqual(menu(in: app).value as? String, "Fantine · Pocket TTS German")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "voice-choice-saved"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testTheMenuOffersFemaleVoicesOfBothEnginesAndNamesWhatIsUnavailable() {
        let app = launch(); defer { app.terminate() }
        menu(in: app).tap()
        for (id, name) in [("local.pocket-german.alba", "Alba"), ("local.pocket-german.cosette", "Cosette"),
                           ("local.pocket-german.fantine", "Fantine"), ("local.pocket-german.eponine", "Eponine"),
                           ("local.qwen-8bit.Serena", "Serena"), ("local.qwen-8bit.Vivian", "Vivian"),
                           ("local.qwen-8bit.Ono_Anna", "Ono Anna"), ("local.qwen-8bit.Sohee", "Sohee")] {
            XCTAssertTrue(entry(id, named: name, in: app).exists, "\(name) is offered")
        }
        for name in ["Ryan", "Aiden", "Eric", "Dylan", "Uncle Fu"] {
            XCTAssertFalse(app.buttons[name].exists, "\(name) is not part of the comparison")
        }
        let phonon = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Phonon 40M-DE")).firstMatch
        XCTAssertTrue(phonon.exists)
        XCTAssertFalse(phonon.isEnabled, "named, and not selectable")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "voice-menu-open"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testVoiceControlsRemainReachableAtTheLargestTextSize() {
        let app = launch(largeText: true); defer { app.terminate() }
        let voice = menu(in: app), sample = app.buttons["assistant.voice.sample"], pulse = app.buttons["assistant.waitingSound"]
        XCTAssertTrue(voice.isHittable && sample.isHittable && pulse.isHittable)
        for control in [voice, sample, pulse] {
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
            XCTAssertFalse(control.frame.isEmpty)
        }
        // Accessibility frames can represent 44 pt as 43.999999999999886.
        XCTAssertGreaterThanOrEqual(voice.frame.height + 0.001, 44)
        XCTAssertGreaterThanOrEqual(sample.frame.width + 0.001, 44)
        XCTAssertGreaterThanOrEqual(sample.frame.height + 0.001, 44)
        // At this size the menu scrolls; its first voice is in reach without scrolling.
        choose("local.pocket-german.alba", named: "Alba", in: app)
        XCTAssertEqual(menu(in: app).value as? String, "Alba · Pocket TTS German")
        XCTAssertTrue(app.buttons["assistant.voice.sample"].isHittable && app.buttons["voice.choice.done"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "voice-choice-large-text"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSpokenConversationKeepsStopAndVoiceReachable() {
        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["LISTEN_TALKBACK_MUTE"] = "1"
            app.launchEnvironment["LISTEN_TEST_NO_MICROPHONE"] = "1"
            app.launchArguments = ["-microphoneOn", "NO", "-recordRuns", "NO", "-spokenConversationFixture", UUID().uuidString]
            if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch()
            let stop = app.buttons["spoken.interrupt"]
            XCTAssertTrue(stop.waitForExistence(timeout: 15) && stop.isHittable)
            XCTAssertGreaterThanOrEqual(stop.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(stop.frame.maxY, app.frame.maxY)
            let status = app.descendants(matching: .any).matching(identifier: "spoken.status").firstMatch
            XCTAssertTrue(status.label.contains("Speaking"))
            XCTAssertFalse(status.label.contains("Listening"))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = largeText ? "spoken-conversation-large-text" : "spoken-conversation"
            attachment.lifetime = .keepAlways; add(attachment)
            let voice = app.buttons["assistant.voice"]
            let answers = app.scrollViews["spoken.answers"]
            XCTAssertTrue(answers.exists)
            for _ in 0..<5 {
                if voice.isHittable { break }
                answers.swipeDown()
            }
            XCTAssertTrue(voice.isHittable, "voice selection remains reachable by scrolling")
            XCTAssertTrue(stop.isHittable, "interrupt stays reachable while browsing the conversation")
            let words = app.scrollViews["spoken.words"]
            XCTAssertTrue(words.exists)
            XCTAssertGreaterThanOrEqual(voice.frame.minY + 1, words.frame.maxY, "the voice menu must not overlap the live sentence")
            XCTAssertLessThanOrEqual(voice.frame.maxY, answers.frame.maxY + 1)
            XCTAssertFalse(app.buttons["Read aloud"].exists, "spoken mode uses its selected native voice")
            stop.tap()
            XCTAssertTrue(stop.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }
}

extension VoiceChoiceUITests {
    func testAssistantWordFadeAndControlsAtNormalAndLargeText() {
        for large in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["LISTEN_TALKBACK_MUTE"] = "1"
            app.launchEnvironment["LISTEN_TEST_NO_MICROPHONE"] = "1"
            app.launchArguments = ["-microphoneOn", "NO", "-recordRuns", "NO", "-assistantPresentationFixture", UUID().uuidString]
            if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch()
            XCTAssertTrue(app.staticTexts["assistant.reply"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["assistant.voice"].isHittable && app.buttons["assistant.close"].isHittable)
            let orb = app.buttons["assistant.orb"]
            XCTAssertTrue(orb.exists)
            XCTAssertGreaterThanOrEqual(orb.frame.minY + 1, app.buttons["assistant.voice"].frame.maxY)
            XCTAssertGreaterThanOrEqual(app.staticTexts["assistant.reply"].frame.minY + 1, app.staticTexts["assistant.status"].frame.maxY)
            let early = XCTAttachment(screenshot: app.screenshot())
            early.name = large ? "assistant-large-revealing" : "assistant-revealing"; early.lifetime = .keepAlways; add(early)
            Thread.sleep(forTimeInterval: 13)
            let full = XCTAttachment(screenshot: app.screenshot())
            full.name = large ? "assistant-large-settled" : "assistant-settled"; full.lifetime = .keepAlways; add(full)
            XCTAssertTrue(app.buttons["assistant.close"].isHittable)
            app.terminate()
        }
    }
}
