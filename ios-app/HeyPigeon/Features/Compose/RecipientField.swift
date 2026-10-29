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
    @State private var text = ""

    private var typed: String { text.trimmingCharacters(in: .whitespaces).lowercased() }

    private var matches: [PersonSuggestion] {
        let q = typed
        guard !q.isEmpty, focused.wrappedValue == field else { return [] }
        return Array(people.lazy.filter { p in
            !addresses.contains(p.person.address)
                && (p.person.address.contains(q) || p.person.name.lowercased().contains(q))
        }.prefix(5))
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
                    .textContentType(.emailAddress).plainInput(.email)
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
        let a = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")).lowercased()
        guard !a.isEmpty else { text = ""; return }
        guard EmailAddress.isPlausible(a) else { return }
        text = ""
        guard !addresses.contains(a) else { return }
        addresses.append(a)
    }
}
