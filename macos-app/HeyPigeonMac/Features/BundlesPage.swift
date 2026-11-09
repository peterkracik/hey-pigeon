// Bundles as a page of the window (WindowState.showBundles), in the
// list's place as Settings is: the sheet the Mac showed before looked
// like a dialog over the window, and an email open in it was cut off
// from the window's keys and from the composer's placement. The stack is
// the shared one (BundlesStack: the list, a bundle, an email in it) over
// the window's path, so the open email is the window's open thread for
// every key, menu item and the inline reply; the stack's own toolbar
// items (New bundle, the bundle's menu, the thread's) and its Back join
// the window's toolbar, which names the page (MainToolbar).

import SwiftUI

struct BundlesPage: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        BundlesStack(path: $state.bundlePath)
            .scrollIndicators(.never)
            .frame(maxWidth: MacLayout.maxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MacTheme.content)
            // Focusable so the key map works after a click on the page, with
            // no ring drawn around it.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
            .onAppear { focused = true }
    }
}
