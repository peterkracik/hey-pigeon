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

        // A thread (its message is a web view: it gets longer to draw),
        // the Remind sheet over it, and back.
        row.tap()
        let other = element(app, containing: "Weekend ride?")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: other)
        if XCTWaiter().wait(for: [gone], timeout: 20) == .completed {
            keep("\(prefix)-02-thread", app, settle: 3)
            if tap(app.buttons["Remind me"].firstMatch) {
                keep("\(prefix)-02-thread-remind", app)
                closeSheet(app)
            }
            back(app)
            _ = other.waitForExistence(timeout: 20)
        }

        // The other two lists.
        if tap(app.buttons["Remind me"].firstMatch) { keep("\(prefix)-03-remind-me", app) }
        if tap(app.buttons["Need reply"].firstMatch) { keep("\(prefix)-04-need-reply", app) }
        _ = tap(app.buttons["Inbox"].firstMatch)

        // Folders and accounts, then Settings from it. Settings is the
        // list's last row and a lazy list has not made it yet: scroll to
        // the end before looking for it.
        if tap(app.buttons["Folders and accounts"].firstMatch) {
            keep("\(prefix)-05-folders", app)
            app.swipeUp()
            app.swipeUp()
            keep("\(prefix)-06-folders-end", app)
            if tap(app.buttons["Settings"].firstMatch) || tap(element(app, containing: "Settings")) {
                keep("\(prefix)-07-settings", app)
                app.swipeUp()
                keep("\(prefix)-08-settings-further", app)
                app.swipeUp()
                keep("\(prefix)-09-settings-end", app)
            } else {
                keepTree("\(prefix)-06-folders-end-tree", app)
            }
            closeSheets(app)
        }

        // Ask my inbox.
        if tap(app.buttons["Ask my inbox"].firstMatch) {
            keep("\(prefix)-10-ask", app)
            closeSheets(app)
        }

        // A new message.
        let compose = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Compose")).firstMatch
        if tap(compose) {
            keep("\(prefix)-11-compose", app)
            closeSheets(app)
        } else {
            keepTree("\(prefix)-11-compose-tree", app)
        }

        // The bundles and one of them, last: the walk ends inside their
        // cover and nothing has to find its way back out.
        if tap(app.buttons["Folders and accounts"].firstMatch), tap(element(app, containing: "All bundles")) {
            keep("\(prefix)-12-bundles", app)
            if tapFirstHittable(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Lisbon trip"))) {
                keep("\(prefix)-13-bundle", app)
            }
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

    /// Taps `element` if it shows up and can be tapped; says whether it
    /// did. A sheet on its way out still covers what is under it, so the
    /// element gets the same time again to come free (Compose was
    /// "not there" for the moment the folders took to leave).
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let free = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        guard XCTWaiter().wait(for: [free], timeout: timeout) == .completed else { return false }
        element.tap()
        return true
    }

    /// Taps the first of `query`'s elements that can be tapped: the same
    /// words may stand on the screen under a cover too.
    private func tapFirstHittable(_ query: XCUIElementQuery, timeout: TimeInterval = 5) -> Bool {
        guard query.firstMatch.waitForExistence(timeout: timeout) else { return false }
        for candidate in query.allElementsBoundByIndex where candidate.exists && candidate.isHittable {
            candidate.tap()
            return true
        }
        return false
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

    /// Closes whatever sheets are up over the list. Twice at most
    /// (Settings over the folders).
    private func closeSheets(_ app: XCUIApplication) {
        for _ in 0..<2 {
            let list = element(app, containing: subject)
            if list.exists, list.isHittable { return }
            closeSheet(app)
        }
    }

    /// Closes the sheet on top: its close button, else a drag down from
    /// the top of the sheet.
    private func closeSheet(_ app: XCUIApplication) {
        let close = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Close")).firstMatch
        if close.exists, close.isHittable {
            close.tap()
        } else {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        // The sheet's own animation; a bounded wait.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "sheet leaves")], timeout: 1.5)
    }

    /// Keeps what the test can see of the screen, as text, where the walk
    /// could not go on: the labels say why.
    private func keepTree(_ name: String, _ app: XCUIApplication) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// Keeps a picture of the screen under `name`, once it has settled.
    private func keep(_ name: String, _ app: XCUIApplication, settle: TimeInterval = 1.2) {
        // Transitions and the glass bars take a moment; a bounded wait.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: settle)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
