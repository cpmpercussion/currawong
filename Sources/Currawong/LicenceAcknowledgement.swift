// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The once-per-install statement that the operator holds a licence, shown
/// the first time they transmit (APP-33).
///
/// Not a licence check, and must never become one: there is no register to
/// check against, and the networks already verify licences themselves. Only
/// ``RadioSession/beginTransmit(from:)`` consults it; listening is never gated.
///
/// Versioned, so changed wording can be shown again: bump ``currentVersion``
/// for a change of substance. Not keyed to the callsign.
enum LicenceAcknowledgement {

    /// The version of the wording below.
    static let currentVersion = 1

    /// Whether a stored version satisfies the current wording.
    static func isSatisfied(by storedVersion: Int?) -> Bool {
        guard let storedVersion else { return false }
        return storedVersion >= currentVersion
    }

    // MARK: - The wording (here so tests assert the strings the operator reads)

    static let title = "Before you transmit"

    /// Leads with "does not check", so nobody assumes the app vouched for them.
    static let responsibility =
        "Currawong does not check licences. Transmitting on amateur frequencies requires a "
        + "licence in your country, and you are responsible for everything sent under your "
        + "callsign."

    /// General, not per channel: the app cannot tell which destinations reach
    /// a transmitter, and a wrong guess would be a reassuring one.
    static let overTheAir =
        "Some of the nodes and reflectors you can reach from here are linked to radio "
        + "transmitters and some are not. Currawong cannot tell which — assume anything you "
        + "send may go out over the air."

    /// Names the operator, which is harder to tap past than boilerplate.
    static func identification(callsign: String) -> String {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Your callsign is sent with every transmission and identifies you."
        }
        return "Your callsign, \(trimmed), is sent with every transmission and identifies you."
    }

    /// Not "Cancel": declining still leaves the app usable for listening.
    static let declineButton = "Listen only"

    static let acceptButton = "I hold a licence"
}

/// The sheet ``LicenceAcknowledgement`` is shown in. Its own type so the
/// hosted-view tests can show it alone.
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

            // "Listen only" must not read as the discouraged choice.
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
