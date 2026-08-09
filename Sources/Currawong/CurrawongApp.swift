// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Currawong's entry point.
///
/// Deliberately thin: it owns the ``CompositionRoot`` for the process lifetime
/// and hands it to the root view. Everything that knows about a specific
/// network lives in the composition root; everything that knows about the user
/// lives below ``RootView``.
@main
struct CurrawongApp: App {
    /// `@State` rather than a plain `let`, because a `let` on an `App` is
    /// re-initialised whenever SwiftUI re-creates the value — and re-creating
    /// the composition root would mean re-creating the network client, and with
    /// it any call in progress.
    @State private var root = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            RootView(root: root)
        }
        #if os(macOS)
        .defaultSize(width: 420, height: 560)
        #endif
    }
}
