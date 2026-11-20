// A walk through the main screens on the sample inbox (HEYPIGEON_MOCK)
// that keeps a picture of each. Nothing here checks a pixel, and a screen
// the walk cannot reach is skipped, not failed: SmokeTests say whether the
// app works, this says what it looks like. ios-ci exports the pictures as
// an artifact ("screens-iphone"), so a change to the look can be seen on a
// pull request without a device. Light first, then the same screens in
// dark, then the inbox with the sample order's parcel card.

import XCTest

@MainActor
final class ScreenTourTests: XCTestCase {
    /// The first row of the sample inbox (MockEngine).
    private let subject = "Q4 roadmap review"

    override func setUp() async throws {
        // A missing screen leaves a gap in the pictures, nothing more.
        continueAfterFailure = true
    }

    func testTheMainScreensInLight() {
        tolerant()
        let app = launch(dark: false, order: false)
        tour(app, prefix: "light")
    }

    func testTheMainScreensInDark() {
        tolerant()
        let app = launch(dark: true, order: false)
        tour(app, prefix: "dark")
    }

    func testTheInboxWithTheParcelCard() {
        tolerant()
        let app = launch(dark: false, order: true)
        guard element(app, containing: "Track parcel").waitForExistence(timeout: 40) else { return }
        keep("light-20-inbox-parcels", app)
    }

    // MARK: The walk

    private func tour(_ app: XCUIApplication, prefix: String) {
        let row = element(app, containing: subject)
        guard row.waitForExistence(timeout: 40) else { return }
        keep("\(prefix)-01-inbox", app)

        // A thread, and back.
        row.tap()
        let other = element(app, containing: "Weekend ride?")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: other)
        if XCTWaiter().wait(for: [gone], timeout: 20) == .completed {
            keep("\(prefix)-02-thread", app)
            back(app)
            _ = other.waitForExistence(timeout: 20)
        }

        // The other two lists.
        if tap(app.buttons["Remind me"].firstMatch) { keep("\(prefix)-03-remind-me", app) }
        if tap(app.buttons["Need reply"].firstMatch) { keep("\(prefix)-04-need-reply", app) }
        _ = tap(app.buttons["Inbox"].firstMatch)

        // Folders and accounts, then Settings from it.
        if tap(app.buttons["Folders and accounts"].firstMatch) {
            keep("\(prefix)-05-folders", app)
            let settings = element(app, containing: "Settings")
            if settings.waitForExistence(timeout: 5) {
                app.swipeUp()
                keep("\(prefix)-06-folders-end", app)
                if tap(app.buttons["Settings"].firstMatch) || tap(settings) {
                    keep("\(prefix)-07-settings", app)
                    app.swipeUp()
                    keep("\(prefix)-08-settings-further", app)
                    app.swipeUp()
                    keep("\(prefix)-09-settings-end", app)
                }
            }
            closeSheets(app)
        }

        // A new message.
        if tap(app.buttons["Compose"].firstMatch) {
            keep("\(prefix)-10-compose", app)
            closeSheets(app)
        }
    }

    // MARK: Helpers

    /// Whatever goes wrong on the walk is expected: the pictures that
    /// were kept are the result, and the smoke tests are what fails a
    /// build.
    private func tolerant() {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("The tour keeps pictures; a screen it cannot reach is a gap, not a failure.", options: options)
    }

    private func launch(dark: Bool, order: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HEYPIGEON_MOCK"] = "1"
        app.launchEnvironment["HEYPIGEON_MOCK_ORDER"] = order ? "1" : "0"
        // Settings › Appearance for this launch only: the argument domain
        // of the defaults the setting is stored in.
        app.launchArguments += ["-appearance", dark ? "dark" : "light"]
        app.launch()
        dismissSystemAlert()
        return app
    }

    /// Anything on screen whose label holds `text`: a row may be one
    /// combined element or separate texts.
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// The system's notification question covers the app at first launch:
    /// answer it, whichever way, so the taps reach the app.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 6) else { return }
        let buttons = alert.buttons
        if buttons.count > 0 { buttons.element(boundBy: buttons.count - 1).tap() }
    }

    /// Taps `element` if it shows up and can be tapped; says whether it did.
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        return true
    }

    /// Back from a pushed screen: the bar's button, or the edge swipe when
    /// the bar does not offer one to the test (it did not on iOS 27's).
    private func back(_ app: XCUIApplication) {
        let button = app.buttons["BackButton"].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.tap()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
    }

    /// Closes whatever sheets are up: their close button, else a drag
    /// down from the top of the sheet. Twice at most (Settings over the
    /// folders).
    private func closeSheets(_ app: XCUIApplication) {
        for _ in 0..<2 {
            let list = element(app, containing: subject)
            if list.exists, list.isHittable { return }
            let close = app.buttons["Close"].firstMatch
            if close.exists, close.isHittable {
                close.tap()
            } else {
                let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            }
            // The sheet's own animation; a bounded wait.
            _ = element(app, containing: subject).waitForExistence(timeout: 3)
        }
    }

    /// Keeps a picture of the screen under `name`, once it has settled.
    private func keep(_ name: String, _ app: XCUIApplication) {
        // Transitions and the glass bars take a moment; a bounded wait.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 1.2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
