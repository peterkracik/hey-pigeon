// The sidebar: accounts (desktop 0/1/2), folders, labels, Settings — the
// desktop sidebar as a sheet, opened from the top-left circle. Same canvas
// as the main screens, sections on white cards, close in the nav bar.

import SwiftUI

struct SidebarSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            list
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        .presentationBackground(Theme.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var list: some View {
        List {
            Section {
                folderRow(.inbox)
                accountRow(nil, title: "All accounts", subtitle: nil, color: nil)
                ForEach(model.accounts) { a in
                    accountRow(a.id, title: a.displayName, subtitle: a.email, color: a.color,
                               disconnected: model.accountStates[a.id]?.isConnected == false)
                }
            }
            .listRowBackground(Theme.card)
            // The desktop sidebar's folders, in its order (Archive is "done"
            // in this app's vocabulary; Scheduled and Need reply are tabs).
            Section {
                folderRow(.starred)
                folderRow(.sent)
                folderRow(.drafts)
                folderRow(.archive)
                tabRow(.scheduled, count: model.scheduledCount)
                tabRow(.needReply, count: model.needReplyCount)
                folderRow(.all)
                folderRow(.spam)
                folderRow(.trash)
            }
            .listRowBackground(Theme.card)
            if !model.labels.isEmpty {
                Section {
                    ForEach(model.labels) { l in
                        Button { go(.label(id: l.id, name: l.name)) } label: {
                            Label(l.name, systemImage: "tag")
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }
            Section {
                // The consent sheet needs a window to present over; closing
                // this sheet first tore it down. Stay up until it finishes.
                Button {
                    Task {
                        await model.addAccount()
                        dismiss()
                    }
                } label: { Label("Add Google account", systemImage: "plus.circle") }
                Button { dismiss(); model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            .listRowBackground(Theme.card)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        // The inset-grouped default leaves a wide gutter in a sheet; keep
        // the cards close to the edges like the inbox rows.
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .foregroundStyle(Theme.textPrimary)
    }

    private func go(_ folder: MailView) {
        model.tab = .inbox
        model.folder = folder
        Haptics.light()
        dismiss()
    }

    private func folderRow(_ view: MailView, title: String? = nil) -> some View {
        let n = model.counts[view.countKey] ?? 0
        return Button { go(view) } label: {
            HStack {
                Label(title ?? view.title, systemImage: view.systemImage)
                Spacer()
                if n > 0 { Text("\(n)").font(.subheadline).foregroundStyle(Theme.textTertiary) }
                if model.tab == .inbox && model.folder == view {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
    }

    private func tabRow(_ tab: MainTab, count: Int) -> some View {
        Button { model.tab = tab; dismiss() } label: {
            HStack {
                Label(tab.title, systemImage: tab.systemImage)
                Spacer()
                if count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(Theme.textTertiary) }
            }
        }
    }

    private func accountRow(_ id: String?, title: String, subtitle: String?, color: AccountColor?, disconnected: Bool = false) -> some View {
        Button {
            model.selectedAccountId = id
            Haptics.light()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    // The account dot sits right in front of the name.
                    HStack(spacing: 7) {
                        if let color {
                            Circle().fill(Theme.tagForeground(color)).frame(width: 9, height: 9)
                        } else {
                            HStack(spacing: -3) {
                                ForEach(model.accounts.prefix(3)) { a in
                                    Circle().fill(Theme.tagForeground(a.color)).frame(width: 9, height: 9)
                                }
                            }
                        }
                        Text(title)
                    }
                    if disconnected {
                        Text("Disconnected — reconnect in Settings").font(.caption).foregroundStyle(.red)
                    } else if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if id == model.selectedAccountId {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
    }
}
