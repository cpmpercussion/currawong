// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// How a `TransmitState` is shown to the operator.
///
/// A pure value derived from the state and nothing else, so the decision about
/// what "transmitting" looks like can be unit-tested without a view, a client
/// or a network. Everything that displays transmit state — the placeholder view
/// today, the TX banner in APP-2, the Live Activity in APP-3 — should go
/// through this, so they cannot disagree with one another about what the radio
/// is doing.
///
/// APP-3's Live Activity holds to the same rule from one step further out: it is
/// handed strings rather than a `TransmitState`, so the widget process cannot
/// form its own opinion about what "transmitting" looks like. See
/// ``RadioSession/desiredActivity``.
struct TransmitStatusPresentation: Equatable {
    /// Short label, e.g. for a status line.
    let label: String

    /// Longer text explaining the state.
    let detail: String

    /// Whether the operator's voice is going on air right now. Drives the
    /// prominent, unmissable presentation — SF-4 exists because a transmitting
    /// radio the operator has not noticed is the dominant on-air failure mode.
    let isTransmitting: Bool

    init(state: TransmitState) {
        switch state {
        case .idle:
            label = "Not connected"
            detail = "No node connected."
            isTransmitting = false
        case .receiving:
            label = "Receiving"
            detail = "Connected. Listening."
            isTransmitting = false
        case .transmitting:
            label = "Transmitting"
            detail = "On air."
            isTransmitting = true
        }
    }
}
