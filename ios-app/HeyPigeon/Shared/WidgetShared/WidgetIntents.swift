// The intents behind widget buttons, Live Activity buttons and Controls.
// They are compiled into the app AND the widget extension (the system
// needs the type in both), but they always run in the app's process:
// a LiveActivityIntent runs there without opening the app, an OpenIntent
// opens it. Their bodies therefore call a hook the app installs at launch
// (WidgetActions.handler → AppModel); in the extension the hook is nil and
// the intent is a no-op, which never happens because it never runs there.

import AppIntents
import Foundation

/// What a widget or control can ask the app to do.
enum WidgetAction: Equatable {
    case markDone(threadId: String)
    case snooze(threadId: String, hours: Int)
    case open(ControlTarget)
    /// Stop the triage run in progress (its Live Activity's button).
    case cancelTriage
}

enum WidgetActions {
    /// Installed by HeyPigeonApp at launch; nil in the extensions.
    nonisolated(unsafe) static var handler: (@MainActor (WidgetAction) async -> Void)?

    @MainActor
    static func run(_ action: WidgetAction) async {
        await handler?(action)
    }
}

/// Where a Control or a widget tap takes you.
enum ControlTarget: String, AppEnum {
    case inbox, scheduled, needReply, compose

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Hey Pigeon screen")
    static let caseDisplayRepresentations: [ControlTarget: DisplayRepresentation] = [
        .inbox: "Inbox",
        .scheduled: "Scheduled",
        .needReply: "Need reply",
        .compose: "Compose",
    ]
}

/// Done from a widget or the Live Activity: runs in the app's process in
/// the background (LiveActivityIntent), same path as the swipe.
struct WidgetMarkDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Done"
    static let description = IntentDescription("Marks the email done from a widget.")
    static let isDiscoverable = false

    @Parameter(title: "Thread") var threadId: String

    init() {}
    init(threadId: String) { self.threadId = threadId }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.markDone(threadId: threadId))
        return .result()
    }
}

/// Snooze a due reminder from the Live Activity: one hour from now.
struct WidgetSnoozeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze Reminder"
    static let description = IntentDescription("Moves the reminder an hour ahead.")
    static let isDiscoverable = false

    @Parameter(title: "Thread") var threadId: String
    @Parameter(title: "Hours", default: 1) var hours: Int

    init() {}
    init(threadId: String, hours: Int = 1) {
        self.threadId = threadId
        self.hours = hours
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.snooze(threadId: threadId, hours: hours))
        return .result()
    }
}

/// Stop from the triage Live Activity: the run ends at its next step and
/// nothing is applied. Runs in the app's process, like Done.
struct WidgetCancelTriageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Triage"
    static let description = IntentDescription("Stops the triage run in progress without changing anything.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.cancelTriage)
        return .result()
    }
}

/// A Control's action: open the app on a screen (Compose opens the composer).
struct OpenHeyPigeonIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Hey Pigeon"
    static let description = IntentDescription("Opens Hey Pigeon on a screen.")

    @Parameter(title: "Screen", default: .inbox) var target: ControlTarget

    init() {}
    init(target: ControlTarget) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.open(target))
        return .result()
    }
}
