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
            RootView(
                session: root.session,
                accessory: root.accessory,
                remoteCommand: root.remoteCommand)
                // The PTT input controllers, once, for the process. `RootView`
                // starts the session's own SF-3 observation itself — that is the
                // view's business and it should not depend on anybody
                // remembering to call this — so `activate()` is idempotent and
                // the two overlap harmlessly.
                .task { root.activate() }
        }
        #if os(macOS)
        .defaultSize(width: 480, height: 760)
        #endif
    }
}
