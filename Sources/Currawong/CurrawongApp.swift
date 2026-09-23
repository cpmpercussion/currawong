// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Currawong's entry point.
///
/// Deliberately thin: it owns the ``CompositionRoot`` for the process lifetime
/// and hands its view model to the root view. Everything that knows about a
/// specific network lives in the composition root; everything that knows about
/// the user lives below ``RootView``.
///
/// No concrete client type appears in this file: the mode is chosen from the
/// operator's settings at connect time, inside the composition root.
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
        // Two columns' worth, so a sidebar shows something beside it.
        .defaultSize(width: 1000, height: 700)
        #endif
    }

    /// The root view, plus the one platform difference worth having.
    ///
    /// The `#if` wraps whole expressions rather than a modifier mid-chain,
    /// since the latter is newer syntax than this app's floor of iOS 16 and
    /// macOS 13 guarantees.
    @ViewBuilder
    private var content: some View {
        let view = RootView(
            session: root.session,
            accessory: root.accessory,
            remoteCommand: root.remoteCommand,
            browser: root.stationBrowser,
            reflectorBrowser: root.reflectorBrowser,
            proxyPicker: root.proxyPicker,
            nodeLocator: root.nodeLocator,
            portalLogin: root.portalLogin)
            // The PTT input controllers, once, for the process. `RootView`
            // starts the session's own SF-3 observation itself, so
            // `activate()` is idempotent and the two overlap harmlessly.
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
