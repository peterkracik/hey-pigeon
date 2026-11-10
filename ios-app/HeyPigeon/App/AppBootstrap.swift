// What both apps do once at launch, before their first scene: open the
// engine and connect the widget buttons to the model. The phone's app
// (HeyPigeonApp) and the Mac's (macos-app HeyPigeonMacApp) each had a copy
// of both, alike but for the name of the OAuth client's Info.plist key.

import Foundation

@MainActor
enum AppBootstrap {
    /// Real engine unless the scheme asks for the mock (HEYPIGEON_MOCK=1) or
    /// no OAuth client id is configured — then the sample inbox, so the UI
    /// is always runnable (and CI builds without secrets). `clientIdKey` is
    /// the Info.plist key the platform's client id is under.
    static func makeEngine(clientIdKey: String) -> MailEngine {
        let env = ProcessInfo.processInfo.environment
        let clientId = (Bundle.main.object(forInfoDictionaryKey: clientIdKey) as? String) ?? ""
        if env["HEYPIGEON_MOCK"] == "1" || clientId.isEmpty || clientId.hasPrefix("$(") {
            return MockEngine()
        }
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("HeyPigeon", isDirectory: true)
            return try RustEngine(dataDir: dir, clientId: clientId)
        } catch {
            assertionFailure("engine failed to open: \(error)")
            return MockEngine()
        }
    }

    /// Widget buttons, Live Activity buttons and Controls run their intents
    /// in the app's process (Shared/WidgetShared/WidgetIntents.swift; on
    /// the Mac, Shortcuts can run them — its widgets use heypigeon://
    /// links instead); this is where they reach the model. The snapshot
    /// and the Live Activity follow so the surface that was tapped shows
    /// the result at once (the Mac has no Live Activity: its controller
    /// does nothing).
    static func installWidgetActions() {
        WidgetActions.handler = { action in
            guard let model = AppModel.current else { return }
            switch action {
            case .markDone(let id):
                if let row = try? model.engine.threadRow(id: id), !row.isDone { model.markDone(row) }
            case .snooze(let id, let hours):
                model.snooze(threadId: id, hours: hours)
            case .open(let target):
                model.handle(DeepLink(target))
            case .cancelTriage:
                TriageAgent.current?.cancel()
            }
            // The optimistic row change lands on the next main-actor turn.
            try? await Task.sleep(for: .milliseconds(50))
            model.reload()
            await ReminderLiveActivityController.sync(model)
        }
    }
}
