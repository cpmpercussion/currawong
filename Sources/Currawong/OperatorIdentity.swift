// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Who is operating — as distinct from where they are connecting to.
///
/// One callsign, app-wide, not a property of a saved channel: the licence
/// belongs to the person, not the destination, and switching identity (a
/// contest call, a club station) should be a deliberate act in one place, not
/// an emergent property of which channel is selected.
///
/// A dedicated struct also keeps `makeLink(settings, identity, credentials)`
/// from being called with the callsign and the secret swapped — two adjacent
/// `String` parameters, one of which is a password, is a silent mistake to
/// make, and the failure mode is transmitting an EchoLink password as a
/// callsign.
struct OperatorIdentity: Equatable, Sendable, Codable {
    /// The operator's callsign, sent as the calling name in every mode.
    ///
    /// Uppercased when validated. It is stored as typed so the field does not
    /// fight the operator mid-word.
    var callsign: String

    /// **EchoLink.** The operator's name, shown to the far end and in the
    /// directory listing. May be empty. App-wide, like ``callsign``: only the
    /// EchoLink form offers it, but it edits this one value, not a channel field.
    var operatorName: String

    /// **EchoLink.** A short location for the directory listing — a town, or a
    /// three-letter airport code. May be empty, and app-wide like ``operatorName``.
    var location: String

    init(callsign: String = "", operatorName: String = "", location: String = "") {
        self.callsign = callsign
        self.operatorName = operatorName
        self.location = location
    }

    /// Nobody identified yet — a fresh install, before the first thing is typed.
    static let empty = OperatorIdentity()

    /// What is wrong with an identity the operator has typed.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case missingCallsign

        var description: String {
            switch self {
            case .missingCallsign:
                return "Enter your callsign. Transmitting without identifying is not legal anywhere."
            }
        }
    }

    /// The callsign in the one form anything durable may be keyed by.
    ///
    /// The identity is deliberately **stored as typed** — uppercasing the field
    /// under the operator's cursor would be rude — while `connect()` files the
    /// secret under this validated form. Use this, not ``callsign``, for any
    /// Keychain account name (see ``NodeSettings/secretAccount(for:)``): a
    /// secret filed under one spelling and looked up under another presents as
    /// the app having lost it.
    var normalisedCallsign: String {
        callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// The identity, trimmed and uppercased, or a complaint about it.
    ///
    /// The callsign is required in every mode: transmitting unidentified is not
    /// legal anywhere. Name and location are trimmed but not required and not
    /// uppercased — they are display text shown to another human, and blank is
    /// a legitimate answer.
    func validated() throws -> OperatorIdentity {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw ValidationError.missingCallsign }
        return OperatorIdentity(
            callsign: trimmed,
            operatorName: operatorName.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
