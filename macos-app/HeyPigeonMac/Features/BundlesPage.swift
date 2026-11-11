// Bundles as a page of the window (WindowState.showBundles), in the
// list's place as Settings is: the sheet the Mac showed before looked
// like a dialog over the window, and an email open in it was cut off
// from the window's keys and from the composer's placement. The stack is
// the shared one (BundlesStack: the list, a bundle, an email in it) over
// the window's path, so the open email is the window's open thread for
// every key, menu item and the inline reply; the stack's own toolbar
// items (New bundle, the bundle's menu, the thread's) and its Back join
// the window's toolbar, which names the page (MainToolbar). A bundle's
// Emails page, its Info page and the switcher between them are the
// window's own (BundleEmails.swift, BundleInfo.swift), handed to the
// shared screen: the inbox's rows on their card, cards in a reading
// column, and the toolbar's capsule tabs.

import SwiftUI

struct BundlesPage: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        BundlesStack(path: $state.bundlePath, parts: BundleScreenParts(
            switcher: { page, contents in
                // The switcher is up exactly while a bundle's own screen
                // is (not its editor, not an email of it): it tells the
                // page which background to stand on. Each page of the
                // screen said so itself before, and the one leaving
                // could take back what the one arriving had just set.
                let id = contents.bundle.id
                return AnyView(BundlePageTabs(page: page, openCount: contents.open.count)
                    .onAppear { state.bundlePageOf = id }
                    .onDisappear { if state.bundlePageOf == id { state.bundlePageOf = nil } })
            },
            emails: { contents in AnyView(BundleEmailList(contents: contents, state: state)) },
            info: { contents in AnyView(BundleInfoPage(contents: contents, state: state)) }
        ))
            .scrollIndicators(.never)
            .frame(maxWidth: MacLayout.maxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Behind a bundle's two pages the list's background, to the
            // window's edges, so their white cards read as the inbox's
            // do; the canvas behind every other page of the stack.
            .background(state.bundlePageOf == nil ? MacTheme.content : MacTheme.listBackground)
            // Focusable so the key map works after a click on the page, with
            // no ring drawn around it.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
            .onAppear { focused = true }
    }
}
