// SPDX-License-Identifier: Apache-2.0

import Foundation
import IAX2Kit
import RadioCore

/// The one object in Currawong allowed to name a concrete network.
///
/// `RadioCore.NetworkClient` is the boundary between the app and the protocol
/// libraries: views and view models talk to `connect(to:)`, `startTransmit()`,
/// `stopTransmit()`, `disconnect()` and `state`, and know nothing about RFC
/// 5456. Somebody, though, has to decide *which* client is on the other side of
/// that protocol and build it — and this is that somebody. It is the single
/// documented exception to the rule, and it is why `import IAX2Kit` appears in
/// this file and nowhere else.
///
/// If a view or a view model finds itself needing an IAX2-shaped type, that is
/// a signal that `NetworkClient` is missing something. Fix it in the library
/// rather than leaking the detail upward.
///
/// ## What is deliberately not here yet
///
/// - **Audio.** `RadioCore.AudioPipeline` is attached by the app, not by
///   `IAX2Client`, and wiring it is APP-2's job. Two things must be true when
///   it is: `configureSession()` and `startCapture(onFrame:)` both `throw`, and
///   `signals` **must** be consumed so an interruption or route change drops
///   any transmission in progress (SF-3).
/// - **A connect screen and a PTT button.** Also APP-2 (PT-1).
/// - **Stored destinations.** APP-4; nothing is persisted yet.
@MainActor
final class CompositionRoot {
    /// The live network client.
    ///
    /// Concrete rather than `any NetworkClient`: the protocol has an
    /// `associatedtype Destination`, so an existential could not be handed a
    /// destination to connect to. APP-2's view model takes the client as a
    /// generic `Client: NetworkClient` parameter instead, which keeps it
    /// testable against a fake and keeps it free of IAX2.
    let client: IAX2Client

    /// Transmit state, for anything that only needs to display it.
    ///
    /// Reads the `NetworkClient` requirement, which is synchronous and
    /// lock-backed precisely so a view never has to `await` to find out whether
    /// it is transmitting.
    var transmitState: TransmitState { client.state }

    /// - Parameter configuration: watchdog timeout (SF-1, 180 s by default),
    ///   media grid, jitter buffer and leveller. Injectable so a test can build
    ///   a root without waiting three minutes for anything.
    init(configuration: IAX2Client.Configuration = IAX2Client.Configuration()) {
        self.client = IAX2Client(configuration: configuration)
    }
}
