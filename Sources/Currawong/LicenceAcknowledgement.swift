// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-33.** The once-per-install statement that the operator holds a licence,
/// shown the first time they try to transmit.
///
/// ## What this is not
///
/// It is not a licence check, and it must never grow into one. There is no
/// global register to check against; the registers that do exist are national,
/// inconsistent, and in some countries not public at all — so a check would work
/// for VK, US and UK operators and quietly exclude everyone else. It would also
/// mean sending a callsign to a third party, which this app otherwise does only
/// to the networks the operator is themselves a user of.
///
/// All three networks Currawong can reach — AllStarLink, EchoLink and M17 —
/// already verify a licence when they issue the account or the token that gets
/// an operator on the air. The gate below therefore duplicates none of their
/// work. What it does is state an obligation the operator already carries, at
/// the one moment it becomes real, in an app that can otherwise be installed and
/// listened to by anybody.
///
/// ## Why at the first transmit, and not at launch
///
/// Because **listening is not transmitting**, and gating the app at launch would
/// say it was. An operator may install Currawong, connect and listen without
/// ever seeing this. Nothing in `connect()`, the directory browsers or the
/// receive path consults it; only ``RadioSession/beginTransmit(from:)`` does.
///
/// Note what that does *not* buy, so nobody later reads more into it than is
/// there: the three networks all require an identity on the wire to connect at
/// all — M17 carries a base-40 callsign in `CONN`, EchoLink's directory login is
/// callsign and password, a Web Transceiver token is issued against a callsign —
/// so the unlicensed listener this gate permits is a case Currawong allows and
/// the networks mostly do not. The gate is honest about Currawong's own
/// behaviour. It does not claim to have opened a door somebody else keeps shut.
///
/// ## Why a version and not a `Bool`
///
/// So that materially changed wording can be put in front of an operator again.
/// A `Bool` cannot distinguish "agreed to something" from "agreed to *this*", and
/// the first time the text needs to change that distinction is the whole
/// question. Bump ``currentVersion`` when the substance changes — not for a typo.
///
/// It is deliberately **not** keyed to the callsign. A contest call or a club
/// station is a legitimate reason to change ``OperatorIdentity/callsign``, and
/// re-asking on every such change would train the operator to dismiss it.
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
    // Here rather than inline in the view so the tests assert against the same
    // strings the operator reads, and so a change to them is a change to a file
    // whose doc comment explains what they are for.

    static let title = "Before you transmit"

    /// The obligation, stated plainly. "Does not check" is the first clause
    /// deliberately: the operator should learn what the app does *not* do from
    /// the app, rather than assume it has vouched for them.
    static let responsibility =
        "Currawong does not check licences. Transmitting on amateur frequencies requires a "
        + "licence in your country, and you are responsible for everything sent under your "
        + "callsign."

    /// **The RF warning.** Some destinations are linked to a transmitter and
    /// some are not, and the app genuinely cannot tell which: the M17 host file
    /// does not say, an AllStar node's stats do not reliably say, and an
    /// EchoLink conference may be bridged to a repeater at the far end without
    /// anything in the protocol mentioning it. So this warns generally rather
    /// than per destination — a per-channel warning would have to guess, and a
    /// wrong guess in the reassuring direction is the one that matters.
    static let overTheAir =
        "Some of the nodes and reflectors you can reach from here are linked to radio "
        + "transmitters and some are not. Currawong cannot tell which — assume anything you "
        + "send may go out over the air."

    /// The declaration made concrete. The callsign is interpolated because a
    /// notice naming *this* operator is a statement about them, where generic
    /// boilerplate is something to tap past.
    static func identification(callsign: String) -> String {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Your callsign is sent with every transmission and identifies you."
        }
        return "Your callsign, \(trimmed), is sent with every transmission and identifies you."
    }

    /// **Not "Cancel".** The left button names the thing that remains available,
    /// because it is a legitimate way to use the app and not an abort: an
    /// operator who declines can still listen, browse and stay connected.
    static let declineButton = "Listen only"

    static let acceptButton = "I hold a licence"
}

/// The sheet ``LicenceAcknowledgement`` is shown in.
///
/// A sheet rather than an alert: it is three paragraphs, and an alert that long
/// is one nobody reads. Its own type rather than a `@ViewBuilder` on `RootView`
/// so that APP-21's hosted-view tests can put it on screen by itself.
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

            // Accept last and prominent, decline first and plain: the order puts
            // the weightier claim under the thumb, and keeps "Listen only" from
            // reading as the discouraged choice. It is not.
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
