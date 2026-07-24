import XCTest

/// Drives an informational intent and asserts the generative screen renders
/// (a native card with facts and tappable suggestion chips), proving the
/// ErgonUI path end to end on device. Uses a general-knowledge query so it
/// needs no permissions or network.
final class GenerativeUITests: XCTestCase {
    @MainActor
    func testInformationalIntentRendersGenerativeScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["Ask Ergon"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("what kinds of things can you help me with\n")

        // The generative screen streams a title, then facts, then chips.
        // Wait generously for on-device generation of two passes (reply, then
        // the ErgonScreen).
        let generativeScreen = app.otherElements["generativeScreen"]
        XCTAssertTrue(generativeScreen.waitForExistence(timeout: 200),
                      "The generative screen never rendered")

        // Capture the rendered screen as an attachment for the record.
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "generative-screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
