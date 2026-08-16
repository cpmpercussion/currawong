// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Currawong's entry point.
///
/// Deliberately thin: it owns the ``CompositionRoot`` for the process lifetime
/// and hands its view model to the root view. Everything that knows about a
/// specific network lives in the composition root; everything that knows about
/// the user lives below ``RootView``.
///
/// Note that no type in this file is spelled out, and since `RadioSession`
/// stopped being generic there is no longer a client type to name even by
/// inference: the mode is chosen from the operator's settings at connect time,
/// inside the composition root.
@main
struct CurrawongApp: App {
    /// `@State` rather than a plain `let`, because a `let` on an `App` is
    /// re-initialised whenever SwiftUI re-creates the value — and re-creating
    /// the composition root would mean re-creating the view model, and with it
    /// any call in progress.
    @State private var root = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            content
        }
        #if os(macOS)
        // Two columns' worth. The old 480×760 was one scrolling column, and a
        // window that shape shows a sidebar and nothing beside it.
        .defaultSize(width: 1000, height: 700)
        #endif
    }

    /// The root view, plus the one platform difference worth having.
    ///
    /// Written as a property with the `#if` around whole expressions rather than
    /// around a modifier in the middle of a chain, because the latter is a newer
    /// piece of syntax than this app's floor of iOS 16 and macOS 13 implies and
    /// there is nothing to be gained by finding out where the line is.
    @ViewBuilder
    private var content: some View {
        let view = RootView(
            session: root.session,
            accessory: root.accessory,
            remoteCommand: root.remoteCommand,
            browser: root.stationBrowser,
            reflectorBrowser: root.reflectorBrowser,
            proxyPicker: root.proxyPicker,
            nodeLocator: root.nodeLocator)
            // The PTT input controllers, once, for the process. `RootView`
            // starts the session's own SF-3 observation itself — that is the
            // view's business and it should not depend on anybody
            // remembering to call this — so `activate()` is idempotent and
            // the two overlap harmlessly.
            .task { root.activate() }

        #if os(macOS)
        // A floor rather than a preference: below this the split view's detail
        // column can no longer hold the status box and the PTT button at once,
        // and a PTT button that has to be scrolled to is the thing the fixed
        // detail column exists to prevent.
        view.frame(minWidth: 760, minHeight: 620)
        #else
        view
        #endif
    }
}
