// Gmail labels made, renamed and deleted from the sidebar: the three
// dialogs (New label, Rename label, Delete this label?) and the state
// behind them. The phone's sidebar sheet and the Mac's sidebar column each
// carried the same three, word for word. The labels are the account's own
// in Gmail, so what is done here shows on the web and the other devices.

import SwiftUI

/// Which label dialog is up, and the name typed into it.
struct LabelEditing {
    var creating = false
    var renaming: MailLabelItem?
    var deleting: MailLabelItem?
    var name = ""

    /// "New label": an empty name field.
    mutating func startNew() {
        name = ""
        creating = true
    }

    /// "Rename": the field starts on the label's name.
    mutating func startRenaming(_ label: MailLabelItem) {
        name = label.name
        renaming = label
    }
}

/// The dialogs themselves. Deleting asks first: Gmail has no way to bring
/// a label back onto the mail it was on.
struct LabelDialogs: ViewModifier {
    @Binding var editing: LabelEditing
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert("New label", isPresented: $editing.creating) {
                TextField("Name", text: $editing.name)
                Button("Add") {
                    guard let account = model.labelAccountId else { return }
                    let name = editing.name
                    Task { await model.createLabel(named: name, accountId: account) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.labelAccountId.map { "A Gmail label in \($0)." } ?? "Add an account first.")
            }
            .alert("Rename label",
                   isPresented: Binding(get: { editing.renaming != nil }, set: { if !$0 { editing.renaming = nil } }),
                   presenting: editing.renaming) { label in
                TextField("Name", text: $editing.name)
                Button("Rename") {
                    let name = editing.name
                    Task { await model.renameLabel(label, to: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this label?",
                                isPresented: Binding(get: { editing.deleting != nil }, set: { if !$0 { editing.deleting = nil } }),
                                titleVisibility: .visible, presenting: editing.deleting) { label in
                Button("Delete \(label.name)", role: .destructive) {
                    Task { await model.deleteLabel(label) }
                }
            } message: { _ in
                Text("The label is removed from Gmail. Its mail stays where it is, without the label.")
            }
    }
}

extension View {
    /// The New / Rename / Delete label dialogs, driven by `editing`.
    func labelDialogs(_ editing: Binding<LabelEditing>) -> some View {
        modifier(LabelDialogs(editing: editing))
    }
}

extension AppModel {
    /// The account a new label is made in: the one shown, else the first.
    var labelAccountId: String? { selectedAccountId ?? accounts.first?.id }

    /// The labels the sidebar lists: the user's own (Gmail's CATEGORY_
    /// tabs are not folders to open) of the account on screen — every
    /// account's while the list shows them all. The phone used to list
    /// them unfiltered.
    static func visibleLabels(_ all: [MailLabelItem], accountId: String?) -> [MailLabelItem] {
        all.filter { !$0.id.hasPrefix("CATEGORY_") && (accountId == nil || $0.accountId == accountId) }
    }
}
