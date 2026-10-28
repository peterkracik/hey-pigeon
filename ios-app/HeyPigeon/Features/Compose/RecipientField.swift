// Recipient chips + an input, like the desktop RecipientField: comma,
// space or return commits the typed address; backspace on an empty input
// removes the last chip.

import SwiftUI

struct RecipientField<Field: Hashable>: View {
    @Binding var addresses: [String]
    var focused: FocusState<Field?>.Binding
    let field: Field
    @State private var text = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(addresses, id: \.self) { a in
                HStack(spacing: 4) {
                    Text(a).font(.subheadline).lineLimit(1)
                    Button { addresses.removeAll { $0 == a } } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.sunken, in: Capsule())
            }
            TextField(addresses.isEmpty ? "Email address" : "", text: $text)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.next)
                .focused(focused, equals: field)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                .onChange(of: text) { _, t in
                    if t.hasSuffix(",") || t.hasSuffix(" ") { commit() }
                }
                .onSubmit { commit() }
                .onChange(of: focused.wrappedValue) { _, f in if f != field { commit() } }
        }
    }

    private func commit() {
        let a = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")).lowercased()
        text = ""
        guard !a.isEmpty, a.contains("@"), !addresses.contains(a) else { return }
        addresses.append(a)
    }
}
