// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Currawong's entry point.
///
/// Deliberately thin: it owns the ``CompositionRoot`` for the process lifetime
/// and hands its view model to the root view. Everything that knows about a
/// specific network lives in the composition root; everything that knows about
/// the user lives below ``RootView``.
///
/// Note that no type in this file is spelled out. `root.session` is a
/// `RadioSession<IAX2Client>` and inference carries it into `RootView` without
/// this file — or `RootView` — ever naming the client.
@main
struct CurrawongApp: App {
    /// `@State` rather than a plain `let`, because a `let` on an `App` is
    /// re-initialised whenever SwiftUI re-creates the value — and re-creating
    /// the composition root would mean re-creating the view model, and with it
    /// any call in progress.
    @State private var root = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            RootView(session: root.session)
        }
        #if os(macOS)
        .defaultSize(width: 480, height: 760)
        #endif
    }
}
