// Keeps a picture of the Mac window as the tests' host app shows it: the
// sample inbox (no account in CI, so the mock engine), in light and in
// dark. Nothing here checks a pixel, and with no window to draw (a runner
// without a screen) there is simply no picture. macos-ci exports them as
// an artifact ("screens-mac"), so a change to the look can be seen on a
// pull request without a Mac. The phone's pictures come from its UI
// tests (ios-app/HeyPigeonUITests/ScreenTourTests.swift).

import AppKit
import XCTest

@MainActor
final class WindowPictureTests: XCTestCase {
    /// Settings › Appearance (the shared `Appearance`), which the window
    /// follows as soon as the stored value changes.
    private let appearanceKey = "appearance"

    func testKeepsPicturesOfTheWindow() async throws {
        guard let window = await mainWindow() else { return }
        let defaults = UserDefaults.standard
        let before = defaults.string(forKey: appearanceKey)
        defer {
            if let before { defaults.set(before, forKey: appearanceKey) } else { defaults.removeObject(forKey: appearanceKey) }
        }
        for mode in ["light", "dark"] {
            defaults.set(mode, forKey: appearanceKey)
            // The window redraws on the next turns of the run loop; a bounded wait.
            try await Task.sleep(for: .seconds(1.5))
            keep("mac-\(mode)-window", window)
        }
    }

    /// The app's own window (not a panel, not the menu bar extra), once it is up.
    private func mainWindow() async -> NSWindow? {
        for _ in 0..<20 {
            let candidates = NSApp.windows.filter { $0.contentView != nil && $0.frame.width > 400 && $0.frame.height > 300 }
            if let window = candidates.max(by: { $0.frame.width < $1.frame.width }) { return window }
            try? await Task.sleep(for: .seconds(0.5))
        }
        return nil
    }

    /// Draws the window's content into a bitmap and attaches it.
    private func keep(_ name: String, _ window: NSWindow) {
        // The frame view, so the toolbar is in the picture too.
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let shot = XCTAttachment(image: image)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
