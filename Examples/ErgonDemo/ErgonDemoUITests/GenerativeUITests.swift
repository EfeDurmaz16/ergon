import XCTest

/// Renders the generative screen from a canned ErgonScreen (launch argument,
/// no model call) and asserts ErgonUI lays it out: the card, its facts, and
/// tappable suggestion chips. Deterministic and fast, unlike driving the full
/// three-generation on-device flow.
final class GenerativeUITests: XCTestCase {
    @MainActor
    func testGenerativeScreenRenders() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-previewScreen"]
        app.launch()

        // The card renders a title, fact values, and tappable suggestion chips.
        XCTAssertTrue(app.staticTexts["Weather"].waitForExistence(timeout: 15), "Title did not render")
        XCTAssertTrue(app.staticTexts["24 C"].exists, "Fact value did not render")
        let chip = app.buttons["See the weekend"]
        XCTAssertTrue(chip.exists, "Suggestion chip did not render")
        XCTAssertTrue(chip.isHittable, "Suggestion chip is not tappable")

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "generative-screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
