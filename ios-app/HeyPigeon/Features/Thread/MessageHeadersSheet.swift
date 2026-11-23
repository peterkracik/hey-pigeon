// Show headers (docs/specs/message-advanced.md R7–R9): a message's
// headers as it was sent, fetched from Gmail when the sheet opens and
// held by the model only while it is open. One sheet for the phone, the
// iPad and the Mac.
//
// The look is the menu sheets' (docs/specs/marker-look.md): the raised
// paper, the title row, each group under its title (`SectionTitle`), a
// hairline between two rows; a header's name small in the mono above its
// value, which is data and in the mono too. The three apps draw it as
// one column of their own and not as a list: the Mac's inset list rules
// itself over a section's first row and under its title (Recent Opens
// found that out), and a header's value runs to as many lines as it
// has, which a column lays out the same everywhere.

import SwiftUI

struct MessageHeadersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Copy all was pressed: its label says so for a moment. Said here,
    /// not in a toast, which would be under the sheet.
    @State private var copied = false

    /// The sheet's margin: Remind me's and Recent Opens'.
    private static let inset: CGFloat = 20

    var body: some View {
        let sheet = model.headersSheet
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: MessageAdvanced.headersTitle, subtitle: subtitle(sheet)) { dismiss() }
                    .padding(.top, 20)
                if let sheet { content(sheet.state) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.inset)
            .padding(.bottom, 24)
        }
        // A sheet stands on the raised paper (a step up on dark).
        .background(Theme.raised)
        .sheetSize(.large)
    }

    private func subtitle(_ sheet: MessageHeadersPresentation?) -> String? {
        guard let sheet else { return nil }
        return sheet.subject.isEmpty ? "(no subject)" : sheet.subject
    }

    @ViewBuilder private func content(_ state: MessageHeadersPresentation.State) -> some View {
        switch state {
        case .loaded(let headers) where !headers.isEmpty:
            loaded(headers)
        case .loaded:
            notice(MessageAdvanced.headersEmpty)
        case .offline:
            notice(MessageAdvanced.headersOffline)
        case .failed(let why):
            ResultState(working: MessageAdvanced.headersWorking, error: why, isReady: false,
                        retry: { Task { await model.loadHeaders() } }) { EmptyView() }
                .padding(.top, 14)
        case .loading:
            ResultState(working: MessageAdvanced.headersWorking, error: nil, isReady: false) { EmptyView() }
                .padding(.top, 14)
        }
    }

    /// Nothing to list, in words, with the way to ask again.
    private func notice(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(Theme.bodySmall).foregroundStyle(Theme.textSecondary)
            Button("Try again") { Task { await model.loadHeaders() } }
                .buttonStyle(OutlineButtonStyle(compact: true))
        }
        .padding(.top, 14)
    }

    @ViewBuilder private func loaded(_ headers: [HeaderLine]) -> some View {
        let sections = MessageAdvanced.sections(headers)
        Button {
            guard model.copyHeaders() else { return }
            Haptics.light()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? MessageAdvanced.copied : MessageAdvanced.copyAll, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(OutlineButtonStyle(compact: true))
        .padding(.top, 8)
        group(MessageAdvanced.mainTitle, sections.main, first: true)
        group(MessageAdvanced.otherTitle, sections.other, first: sections.main.isEmpty)
        Text(MessageAdvanced.headersFooter)
            .font(Theme.text(.footer)).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
    }

    /// One group under its title: a hairline between two rows, none over
    /// the first or under the last. Nothing when the group is empty.
    @ViewBuilder private func group(_ title: String, _ headers: [HeaderLine], first: Bool) -> some View {
        if !headers.isEmpty {
            SectionTitle(title, count: headers.count)
                // The air that parts two groups; less under the button.
                .padding(.top, first ? 16 : 24)
                .padding(.bottom, 4)
            ForEach(headers) { header in
                row(header)
                if header.id != headers.last?.id { RowRule() }
            }
        }
    }

    private func row(_ header: HeaderLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(header.name).font(Theme.tag).foregroundStyle(Theme.textTertiary)
            // The whole value, however long (a Received line, a DKIM
            // signature), and selectable: one header is often what is
            // wanted, not all of them.
            Text(header.value).font(Theme.meta).foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}
