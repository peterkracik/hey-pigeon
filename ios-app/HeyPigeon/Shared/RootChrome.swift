// What every root of the app carries, once: the toast, the "Account
// disconnected" alert and the sheets a row's actions open (Remind me, Add
// to bundle, a summary). The phone's root (HeyPigeonApp), the Mac's
// window (macos-app MainWindow) and the phone's Bundles cover each spelled
// these out, word for word; the two toasts differed only in their surface
// and where they sit (Platform.swift: `toastSurface`, `ToastMetrics`).

import SwiftUI

/// Bottom toast with an optional Undo — the archive gesture's safety net.
struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Two at most: a send's Undo keeps its place, and what is said
        // during its window shows above it (AppModel.show).
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                HStack(spacing: 12) {
                    Text(toast.text).font(.subheadline.weight(.medium)).lineLimit(2)
                    if toast.undo != nil {
                        // Through the model: the action leaves the undo
                        // stack with it, so `z` cannot take it back twice.
                        Button("Undo") { model.undo(toast: toast.id) }
                            .toastButton()
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, ToastMetrics.verticalPadding)
                .toastSurface()
                // With Reduce Motion the toast fades where it stands.
                .transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
                .task(id: toast.id) {
                    try? await Task.sleep(for: toast.duration)
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.animation(.default)) { model.dismissToast(toast.id) }
                }
            }
        }
        .padding(.bottom, ToastMetrics.bottomInset(threadOpen: model.openThread != nil))
    }
}

/// The sheets an email's actions open, wherever the email is shown. The
/// root presents them while the phone's Bundles cover is closed, the cover
/// while it is open (`AppModel.modal`): one view cannot present a sheet
/// over another view's sheet.
struct SharedSheets: ViewModifier {
    let inBundles: Bool
    /// The phone's root resigns the keyboard as a sheet closes; the Mac
    /// must not, or its list loses the keys.
    let dismissesKeyboard: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(item: model.modal(\.pendingRemind, inBundles: inBundles), onDismiss: closed) { row in
                RemindSheet(row: row)
            }
            .sheet(item: model.modal(\.pendingBundlePick, inBundles: inBundles), onDismiss: closed) { row in
                AddToBundleSheet(row: row)
            }
            .sheet(item: model.modal(\.summarySheet, inBundles: inBundles)) { p in
                SummarySheet(presentation: p)
            }
    }

    private func closed() {
        if dismissesKeyboard { Keyboard.dismiss() }
    }
}

/// An account lost its sign-in (the engine's `onAccountDisconnected`):
/// say so once, with the way back in.
struct DisconnectedAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
            "Account disconnected",
            isPresented: Binding(get: { model.disconnectedAccountId != nil },
                                 set: { if !$0 { model.disconnectedAccountId = nil } })
        ) {
            Button("Reconnect") {
                let id = model.disconnectedAccountId
                Task { await model.addAccount(loginHint: id) }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("\(model.disconnectedAccountId ?? "") needs to sign in again. Mail for it is stale until then.")
        }
    }
}

extension View {
    /// Remind me, Add to bundle and the summary sheet, for a root
    /// (`inBundles: false`) or the phone's Bundles cover (`true`).
    func sharedSheets(inBundles: Bool, dismissesKeyboard: Bool = false) -> some View {
        modifier(SharedSheets(inBundles: inBundles, dismissesKeyboard: dismissesKeyboard))
    }

    /// The "Account disconnected" alert, with Reconnect.
    func disconnectedAlert() -> some View {
        modifier(DisconnectedAlert())
    }
}
