// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-33.** The once-per-install statement that the operator holds a licence,
/// shown the first time they try to transmit.
///
/// Not a licence check, and must never grow into one: there is no global
/// register to check against, and a per-country one would work for some
/// operators and quietly exclude the rest. All three networks Currawong reaches
/// already verify a licence to issue an account or token, so this states an
/// obligation the operator already carries rather than duplicating that work.
///
/// Gated at first transmit, not launch, because listening is not transmitting —
/// only ``RadioSession/beginTransmit(from:)`` consults it, not `connect()`, the
/// directory browsers or the receive path.
///
/// ``currentVersion`` is an `Int`, not a `Bool`, so materially changed wording
/// can be put in front of the operator again; bump it for a substance change,
/// not a typo. Not keyed to the callsign: switching to a contest call or club
/// station is legitimate and should not re-ask.
enum LicenceAcknowledgement {

    /// The version of the wording below. Stored when the operator accepts; the
    /// gate opens only for a stored version at least this high.
    static let currentVersion = 1

    /// Whether a stored version satisfies the current wording. `nil` — never
    /// acknowledged — is `false`, which is the fresh-install case.
    static func isSatisfied(by storedVersion: Int?) -> Bool {
        guard let storedVersion else { return false }
        return storedVersion >= currentVersion
    }

    // MARK: - The wording
    //
    // Here, not inline in the view, so the tests assert against the same
    // strings the operator reads.

    static let title = "Before you transmit"

    /// "Does not check" leads deliberately: the operator should learn what the
    /// app does not do from the app, not assume it has vouched for them.
    static let responsibility =
        "Currawong does not check licences. Transmitting on amateur frequencies requires a "
        + "licence in your country, and you are responsible for everything sent under your "
        + "callsign."

    /// General rather than per-destination: the app cannot reliably tell which
    /// nodes or reflectors are linked to a transmitter, and a per-channel
    /// warning would have to guess — wrong in the reassuring direction is the
    /// guess that matters.
    static let overTheAir =
        "Some of the nodes and reflectors you can reach from here are linked to radio "
        + "transmitters and some are not. Currawong cannot tell which — assume anything you "
        + "send may go out over the air."

    /// The declaration made concrete: naming the operator is harder to tap past
    /// than generic boilerplate.
    static func identification(callsign: String) -> String {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Your callsign is sent with every transmission and identifies you."
        }
        return "Your callsign, \(trimmed), is sent with every transmission and identifies you."
    }

    /// Not "Cancel": declining is a legitimate way to use the app, not an
    /// abort — the operator can still listen, browse and stay connected.
    static let declineButton = "Listen only"

    static let acceptButton = "I hold a licence"
}

/// The sheet ``LicenceAcknowledgement`` is shown in.
///
/// A sheet, not an alert: three paragraphs is longer than an alert gets read.
/// Its own type, not a `@ViewBuilder` on `RootView`, so APP-21's hosted-view
/// tests can put it on screen by itself.
struct LicenceAcknowledgementView: View {
    let callsign: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LicenceAcknowledgement.title)
                .font(.title2.weight(.semibold))

            Text(LicenceAcknowledgement.responsibility)
            Text(LicenceAcknowledgement.overTheAir)
            Text(LicenceAcknowledgement.identification(callsign: callsign))
                .font(.callout.weight(.medium))

            Spacer(minLength: 0)

            // Accept last and prominent, decline first and plain: "Listen
            // only" should not read as the discouraged choice.
            HStack {
                Button(LicenceAcknowledgement.declineButton, action: onDecline)
                    .buttonStyle(.bordered)
                Spacer()
                Button(LicenceAcknowledgement.acceptButton, action: onAccept)
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.callout)
        .padding(24)
        .frame(minWidth: 320, idealWidth: 420, minHeight: 300)
        .accessibilityIdentifier("licence-acknowledgement")
    }
}
