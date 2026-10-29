// Control Center / Lock Screen / Action button: Compose, Scheduled, Inbox.
// Each opens the app on that screen through OpenHeyPigeonIntent (an
// OpenIntent compiled into both targets, as Apple requires).

import AppIntents
import SwiftUI
import WidgetKit

struct ComposeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.heypigeon.control.compose") {
            ControlWidgetButton(action: OpenHeyPigeonIntent(target: .compose)) {
                Label("Compose", systemImage: "square.and.pencil")
            }
        }
        .displayName("Compose")
        .description("Start a new email in Hey Pigeon.")
    }
}

struct ScheduledControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.heypigeon.control.scheduled") {
            ControlWidgetButton(action: OpenHeyPigeonIntent(target: .scheduled)) {
                Label("Scheduled", systemImage: "clock")
            }
        }
        .displayName("Scheduled")
        .description("Open your reminders in Hey Pigeon.")
    }
}

struct InboxControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.heypigeon.control.inbox") {
            ControlWidgetButton(action: OpenHeyPigeonIntent(target: .inbox)) {
                Label("Inbox", systemImage: "tray")
            }
        }
        .displayName("Inbox")
        .description("Open Hey Pigeon's inbox; it checks for mail on the way.")
    }
}
