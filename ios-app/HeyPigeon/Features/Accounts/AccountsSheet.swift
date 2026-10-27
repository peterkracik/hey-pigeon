// The account switcher (desktop 0/1/2) — and the way into Settings.

import SwiftUI

struct AccountsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    accountRow(nil, title: "All accounts", subtitle: "Unified inbox", color: nil)
                    ForEach(model.accounts) { a in
                        accountRow(a.id, title: a.displayName, subtitle: a.email, color: a.color,
                                   disconnected: model.accountStates[a.id]?.isConnected == false)
                    }
                }
                Section {
                    Button {
                        dismiss()
                        Task { await model.addAccount() }
                    } label: { Label("Add Google account", systemImage: "plus.circle") }
                    Button {
                        dismiss()
                        model.showSettings = true
                    } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func accountRow(_ id: String?, title: String, subtitle: String, color: AccountColor?, disconnected: Bool = false) -> some View {
        Button {
            model.selectedAccountId = id
            Haptics.light()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if let color {
                    Circle().fill(Theme.tagForeground(color)).frame(width: 12, height: 12)
                } else {
                    HStack(spacing: -4) {
                        ForEach(model.accounts.prefix(3)) { a in
                            Circle().fill(Theme.tagForeground(a.color)).frame(width: 12, height: 12)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text(disconnected ? "Disconnected — tap to reconnect in Settings" : subtitle)
                        .font(.caption).foregroundStyle(disconnected ? .red : Theme.textTertiary)
                }
                Spacer()
                if let n = model.counts["inbox"], id == model.selectedAccountId, n > 0 {
                    Text("\(n)").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                if id == model.selectedAccountId {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
    }
}
