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
    private func closeCard() { app.buttons.matching(identifier: "floatingCardClose").allElementsBoundByIndex.last!.tap() }
    private func expandCard() {
        let close = app.buttons.matching(identifier: "floatingCardClose").allElementsBoundByIndex.last!
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width / 2, dy: close.frame.minY - 14))
        start.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
    }
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
        tap("systemLanguage-en"); expandCard()
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
        tap("myVoicesButton"); expandCard(); screenshot("My Voices floating card")
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voiceDetail-' ")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20)); detail.tap(); expandCard()
        XCTAssertTrue(app.sliders["voiceSpeedSlider"].waitForExistence(timeout: 20))
        app.sliders["voiceSpeedSlider"].adjust(toNormalizedSliderPosition: 0.4)
        app.sliders["voicePitchSlider"].adjust(toNormalizedSliderPosition: 0.55)
        XCTAssertFalse(app.sliders["Brightness"].exists)
        XCTAssertFalse(app.buttons["Confirm Voice"].exists)
        screenshot("Voice Detail shaping and current indicator")
        tap("voiceLanguageButton"); screenshot("Voice Language floating card")
        closeCard()
        let accent = app.buttons["voiceAccentButton"]
        XCTAssertTrue(accent.waitForExistence(timeout: 120))
        accent.tap(); screenshot("Voice Accent floating card"); closeCard()
        closeCard(); closeCard()
        generate()
        tap("saveGeneratedAudioButton")
        tap("generatedAudioLibraryButton"); expandCard()
        let audio = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'generatedAudio-' ")).firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 20)); audio.tap(); expandCard()
        XCTAssertTrue(app.textFields["Audio Name"].waitForExistence(timeout: 20))
        screenshot("Generated Audio object card")
        app.textFields["Audio Name"].tap(); app.textFields["Audio Name"].typeText(" renamed")
        XCTAssertTrue(app.buttons["Share"].exists)
    }
}
