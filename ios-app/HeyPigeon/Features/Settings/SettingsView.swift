// Settings: accounts first (connection + sync state, reconnect, remove),
// then the things that configure the inbox. AI and Jev arrive with iOS-M2
// once the ffi crate exposes them; the rows are here so the shape is set.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dayStartsAtHour") private var dayStart = 9
    @AppStorage("advanceAfterArchive") private var advanceAfterArchive = false
    @State private var removing: MailAccount?

    var body: some View {
        NavigationStack {
            List {
                Section("Accounts") {
                    ForEach(model.accounts) { a in
                        let state = model.accountStates[a.id]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Circle().fill(Theme.tagForeground(a.color)).frame(width: 10, height: 10)
                                Text(a.email).font(.body.weight(.medium))
                            }
                            HStack(spacing: 6) {
                                Circle().fill(state?.isConnected == false ? .red : .green).frame(width: 6, height: 6)
                                Text(statusText(state)).font(.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { removing = a } label: { Label("Remove", systemImage: "trash") }
                            if state?.isConnected == false {
                                Button { Task { await model.addAccount(loginHint: a.id) } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                            }
                        }
                        .contextMenu {
                            Button { Task { await model.addAccount(loginHint: a.id) } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) { removing = a } label: { Label("Remove account", systemImage: "trash") }
                        }
                    }
                    Button { Task { await model.addAccount() } } label: { Label("Add Google account", systemImage: "plus.circle") }
                }
                Section("Reading") {
                    Toggle("After archiving, open the next thread", isOn: $advanceAfterArchive)
                    Picker("Reminders default to", selection: $dayStart) {
                        ForEach([7, 8, 9, 10], id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                    }
                }
                Section {
                    LabeledContent("AI assistant", value: "Coming in iOS-M2")
                    LabeledContent("Jev triage", value: "Coming in iOS-M2")
                } footer: {
                    Text("Bring-your-own keys, called straight from the device — same as the desktop app. The core already supports both; the phone UI follows.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                    Link("heypigeon.app", destination: URL(string: "https://heypigeon.app")!)
                    Link("Privacy", destination: URL(string: "https://heypigeon.app/privacy.html")!)
                } footer: {
                    Text("No server, no analytics. Your mail stays between your device and your Google account.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove \(removing?.email ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove account", role: .destructive) {
                    if let a = removing { model.removeAccount(a) }
                    removing = nil
                }
            } message: {
                Text("Removes the local copy of its mail and signs it out on this device. Nothing changes in Gmail.")
            }
        }
    }

    private func statusText(_ s: AccountState?) -> String {
        guard let s else { return "—" }
        if !s.isConnected { return "Disconnected — reconnect to resume sync" }
        switch s.syncState {
        case "ok": return "Connected · reminders synced \(s.lastSyncAt.map(Formatters.rowTime) ?? "")"
        case "pending": return "Connected · syncing…"
        case "unavailable": return "Connected · reminder sync off: \(s.syncDetail ?? "re-connect to enable")"
        default: return "Connected · reminder sync error"
        }
    }
}
