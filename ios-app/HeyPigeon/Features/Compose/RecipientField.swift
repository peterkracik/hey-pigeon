// Recipient chips + an input, like the desktop RecipientField: comma,
// space or return commits the typed address. While typing, known people
// (who mail comes from) that match show under the field; a tap, or return
// on a name, adds one.

import SwiftUI

struct RecipientField<Field: Hashable>: View {
    @Binding var addresses: [String]
    var focused: FocusState<Field?>.Binding
    let field: Field
    /// Known people to complete from, most frequent first.
    var people: [PersonSuggestion] = []
    /// What is typed and not a chip yet. The composer's, not the field's:
    /// Send and the draft save count an address still in it, which used
    /// to be dropped — a tap on Send does not end the field's editing.
    @Binding var text: String
    /// What the engine knows for the typed letters: everyone the stored
    /// mail was exchanged with, then the account's Google contacts
    /// (`MailEngine.searchContacts`). `people` only has who wrote lately.
    @State private var found: [PersonSuggestion] = []
    @Environment(AppModel.self) private var model

    private var typed: String { text.trimmingCharacters(in: .whitespaces).lowercased() }

    private var matches: [PersonSuggestion] {
        let q = typed
        guard !q.isEmpty, focused.wrappedValue == field else { return [] }
        let known = people.filter { p in
            !addresses.contains(p.person.address)
                && (p.person.address.contains(q) || p.person.name.lowercased().contains(q))
        }
        var seen = Set(known.map { $0.person.address.lowercased() })
        let more = found.filter { p in
            !addresses.contains(p.person.address) && seen.insert(p.person.address.lowercased()).inserted
        }
        return Array((known + more).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 6) {
                ForEach(addresses, id: \.self) { a in
                    HStack(spacing: 4) {
                        Text(a).font(.footnote).lineLimit(1)
                        Button { addresses.removeAll { $0 == a } } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.sunken, in: Capsule())
                }
                // Next to chips the input only needs room for a caret, so the
                // first chip does not push it onto a line of its own.
                TextField(addresses.isEmpty ? "Email address" : "", text: $text)
                    .plainInput(.email)
                    .submitLabel(.next)
                    .focused(focused, equals: field)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: addresses.isEmpty || !text.isEmpty ? 120 : 24, maxWidth: .infinity, alignment: .leading)
                    .onChange(of: text) { _, t in
                        // A space only ends an address; in a name it keeps searching.
                        if t.hasSuffix(",") || (t.hasSuffix(" ") && t.contains("@")) { commit() }
                    }
                    .onSubmit {
                        if !typed.contains("@"), let first = matches.first { add(first.person.address) } else { commit() }
                    }
                    .onChange(of: focused.wrappedValue) { _, f in if f != field { commit() } }
            }
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { p in
                        Button { add(p.person.address) } label: { suggestion(p) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = field }
        // Two letters or more, a moment after the last one; the newest wins.
        .task(id: typed) {
            let q = typed
            guard q.count >= 2, focused.wrappedValue == field else {
                if !found.isEmpty { found = [] }
                return
            }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let contacts = await model.engine.searchContacts(q, limit: 6)
            guard !Task.isCancelled else { return }
            found = contacts.map { c in
                PersonSuggestion(person: SearchPerson(name: c.name.isEmpty ? c.email : c.name, address: c.email.lowercased()), accountId: "")
            }
        }
    }

    private func suggestion(_ p: PersonSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if p.person.name != p.person.address {
                Text(p.person.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            Text(p.person.address).font(.footnote).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func add(_ address: String) {
        text = ""
        if !addresses.contains(address) { addresses.append(address) }
        focused.wrappedValue = field
    }

    /// The typed text becomes a chip when it looks like an address. Text
    /// that does not ("ana@", a name with no match) stays in the field for
    /// the user to finish, instead of vanishing or becoming a bad chip.
    private func commit() {
        guard !text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")).isEmpty else { text = ""; return }
        guard let a = EmailAddress.pending(text) else { return }
        text = ""
        guard !addresses.contains(a) else { return }
        addresses.append(a)
    }
}
