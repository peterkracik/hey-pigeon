// One pass through the real app on the sample inbox (HEYPIGEON_MOCK): it
// launches, the inbox lists the sample mail, a thread opens with its reply
// bar, and Back returns to the list. Nothing here checks a pixel; it is
// there so that a crash or a hang on launch, or a list that never appears,
// fails CI instead of showing up on the phone.

import XCTest

@MainActor
final class SmokeTests: XCTestCase {
    /// The first row of the sample inbox (MockEngine).
    private let subject = "Q4 roadmap review"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Anything on screen whose label holds `text`: a row may be one
    /// combined element or separate texts.
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// The system's notification question covers the app at first launch:
    /// answer it, whichever way, so the taps below reach the list.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 6) else { return }
        let buttons = alert.buttons
        if buttons.count > 0 { buttons.element(boundBy: buttons.count - 1).tap() }
    }

    func testTheInboxOpensAThreadAndComesBack() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYPIGEON_MOCK"] = "1"
        app.launch()
        dismissSystemAlert()

        let row = element(app, containing: subject)
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the sample inbox never showed")
        row.tap()

        // The thread: its reply control is on screen.
        let reply = element(app, containing: "Reply")
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the thread did not open")

        // Back to the list.
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
        XCTAssertTrue(element(app, containing: "Weekend ride?").waitForExistence(timeout: 20), "the list did not come back")
    }
}
