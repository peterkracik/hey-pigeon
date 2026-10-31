// A downloaded app opened straight from the download runs from a temporary
// read-only copy (macOS's App Translocation: a /private/var/…/AppTranslocation
// path, "/Volumes/VOLUME/*" in a crash report). From there the app's URL
// scheme is not its own, so Google's consent sheet cannot call back, and
// Sparkle cannot replace the bundle. The fix is the user's — move
// HeyPigeon.app into Applications in the Finder and open it from there —
// so the app says so once per launch, before anything is tried.

import AppKit

enum InstallLocation {
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/AppTranslocation/")
    }

    @MainActor
    static func warnIfTranslocated() {
        guard isTranslocated else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Hey Pigeon to your Applications folder"
        alert.informativeText = """
            macOS opened Hey Pigeon from a temporary copy because it was launched straight from the download. \
            From there, signing in with Google and automatic updates don't work.

            In the Finder, drag HeyPigeon.app from where you unzipped it into Applications, then open it from there.
            """
        alert.addButton(withTitle: "Open Applications Folder")
        alert.addButton(withTitle: "Continue Anyway")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
    }
}
