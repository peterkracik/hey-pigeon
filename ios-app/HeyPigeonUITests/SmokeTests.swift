// One pass through the real app on the sample inbox (HEYPIGEON_MOCK): it
// launches, the inbox lists the sample mail, a thread opens over the
// list, and Back returns to it. Nothing here checks a pixel; it is
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
        // Another row of the list: gone while a thread covers the list,
        // back when the list is. ("Reply" as a label would prove nothing:
        // the Need reply tab has it before any thread opens.)
        let other = element(app, containing: "Weekend ride?")
        XCTAssertTrue(other.waitForExistence(timeout: 10), "the sample inbox is not the one expected")
        row.tap()

        // The thread took the screen.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: other)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the thread did not open")

        // Back to the list: the bar's button, or the edge swipe when the
        // bar does not offer one to the test (it did not on iOS 27's).
        let back = app.buttons["BackButton"]
        if back.waitForExistence(timeout: 5) {
            back.tap()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        XCTAssertTrue(other.waitForExistence(timeout: 20), "the list did not come back")
    }
}
