import XCTest

final class VoiceStudioUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-ui-regression", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func tap(_ identifier: String) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 30), identifier)
        if !element.isHittable { app.swipeUp() }
        element.tap()
    }
    private func closeCard(_ title: String) { tap("floatingCardBack") }
    private func expandCard(_ title: String) { XCTAssertTrue(app.buttons["floatingCardBack"].waitForExistence(timeout: 20)) }
    private func generate() {
        let field = app.descendants(matching: .any).matching(identifier: "generationTextField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        if !field.isHittable { app.swipeUp() }
        field.tap(); field.typeText("Hello from Voice Studio.")
        if let done = app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last { done.tap() }
        tap("generateSpeechButton")
        XCTAssertTrue(app.buttons["saveGeneratedAudioButton"].waitForExistence(timeout: 180))
        screenshot("Generated unsaved output")
    }

    func testSystemVoiceSelectionAndRealSystemGeneration() {
        screenshot("Home source row")
        XCTAssertFalse(app.buttons["Confirm Voice"].exists)
        XCTAssertFalse(app.buttons["Prepare Voice"].exists)
        tap("systemVoicesButton"); screenshot("System languages floating card")
        tap("systemLanguage-en"); expandCard("English")
        let voice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'systemVoice-' ")).firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 120))
        screenshot("English usable voices floating card")
        voice.tap()
        XCTAssertTrue(app.buttons["currentVoiceCard"].waitForExistence(timeout: 20))
        screenshot("Selected current voice")
        generate()
        XCTAssertFalse(app.buttons["Prepare Voice"].exists)
    }

    func testSavedVoiceShapingAutomaticConversionAndAudioObjectCard() {
        tap("myVoicesButton"); expandCard("My Voices"); screenshot("My Voices floating card")
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voiceDetail-' ")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20)); detail.tap(); expandCard("Shape Voice")
        tap("voiceCurrentIndicator")
        XCTAssertTrue(app.sliders["voiceSpeedSlider"].waitForExistence(timeout: 20))
        app.sliders["voiceSpeedSlider"].adjust(toNormalizedSliderPosition: 0.4)
        app.sliders["voicePitchSlider"].adjust(toNormalizedSliderPosition: 0.55)
        XCTAssertFalse(app.sliders["Brightness"].exists)
        XCTAssertFalse(app.buttons["Confirm Voice"].exists)
        screenshot("Voice Detail shaping and current indicator")
        tap("voiceLanguageButton"); screenshot("Voice Language floating card")
        closeCard("Language")
        app.swipeUp()
        let accent = app.buttons["voiceAccentButton"]
        XCTAssertTrue(accent.waitForExistence(timeout: 120))
        accent.tap(); screenshot("Voice Accent floating card"); closeCard("Accent")
        closeCard("Shape Voice"); closeCard("My Voices")
        generate()
        tap("saveGeneratedAudioButton")
        tap("generatedAudioLibraryButton"); expandCard("Generation History")
        let audio = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'generatedAudio-' ")).firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 20)); audio.tap(); expandCard("Generated Audio")
        XCTAssertTrue(app.textFields["Audio Name"].waitForExistence(timeout: 20))
        screenshot("Generated Audio object card")
        app.textFields["Audio Name"].tap(); app.textFields["Audio Name"].typeText(" renamed")
        XCTAssertTrue(app.buttons["Share"].exists)
    }
    func testLayeredCardTwentyCyclesAndDeleteRecovery() {
        for _ in 0..<20 {
            tap("myVoicesButton")
            let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voiceDetail-' ")).firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 20)); detail.tap()
            XCTAssertTrue(app.sliders["voiceSpeedSlider"].waitForExistence(timeout: 20))
            tap("voiceLanguageButton"); tap("floatingCardBack")
            tap("floatingCardClose")
        }
        tap("myVoicesButton")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voiceDetail-' ")).firstMatch.tap()
        app.swipeUp(); tap("Delete Voice…"); tap("Delete")
        XCTAssertTrue(app.otherElements["myVoicesFloatingCard"].waitForExistence(timeout: 20))
        screenshot("Deleted detail recovers to library")
    }
    func testRealSameContentImitationRepeatedAndUnsupportedNewText() {
        tap("myVoicesButton")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voiceDetail-' ")).firstMatch.tap()
        tap("voiceImitateButton")
        tap("imitationHistoryButton")
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'generatedAudio-' ")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 20)); source.tap()
        for _ in 0..<10 {
            let run = app.buttons["runImitationButton"]
            XCTAssertTrue(run.waitForExistence(timeout: 30))
            let ready = NSPredicate(format: "enabled == true")
            expectation(for: ready, evaluatedWith: run)
            waitForExpectations(timeout: 180)
            if !run.isHittable { app.swipeDown() }
            run.tap()
            let save = app.buttons["saveGeneratedAudioButton"]
            XCTAssertTrue(save.waitForExistence(timeout: 180))
            if !save.isHittable { app.swipeUp() }
            save.tap()
            XCTAssertTrue(save.waitForNonExistence(timeout: 20))
        }
        screenshot("Real same-content imitation saved")
        let text = app.descendants(matching: .any).matching(identifier: "imitationTextField").firstMatch
        if !text.isHittable { app.swipeDown() }
        text.tap(); text.typeText("Different words")
        XCTAssertFalse(app.buttons["runImitationButton"].isEnabled)
        screenshot("New-text imitation truthfully unavailable")
    }

    func testReducedMotionLayerNavigation() {
        app.terminate()
        app.launchArguments.append("-ui-reduce-motion")
        app.launch()
        tap("myVoicesButton")
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voiceDetail-' ")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20)); detail.tap()
        tap("voiceLanguageButton")
        screenshot("Reduce Motion layered cards")
        tap("floatingCardBack"); tap("floatingCardClose")
        XCTAssertTrue(app.buttons["currentVoiceCard"].waitForExistence(timeout: 20))
    }

}
