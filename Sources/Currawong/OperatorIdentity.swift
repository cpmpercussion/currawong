// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Who is operating — as distinct from where they are connecting to.
///
/// The callsign lived in ``NodeSettings`` until this type existed, which made it
/// a property of each saved channel. It never was one. An operator has one
/// callsign and uses it on every network they touch; storing it per channel
/// meant typing it again for each one, and left open the question of what it
/// would mean for two channels to disagree — a question with no good answer,
/// since the licence belongs to the person and not to the destination.
///
/// A licensed amateur may hold more than one callsign, and there are real
/// reasons to switch (a contest call, a club station). That is a *deliberate*
/// change of who you are on the air, so it belongs in one place that is changed
/// on purpose, rather than being an emergent property of which channel happened
/// to be selected.
///
/// ## Why a struct for one string
///
/// So that `makeLink(settings, identity, secret)` cannot be called with the
/// callsign and the secret the wrong way round. Two adjacent `String`
/// parameters, one of which is a password, is a mistake waiting to be made
/// silently — and the failure would be transmitting an operator's EchoLink
/// password as their callsign.
struct OperatorIdentity: Equatable, Sendable, Codable {
    /// The operator's callsign, sent as the calling name in every mode.
    ///
    /// Uppercased when validated. It is stored as typed so the field does not
    /// fight the operator mid-word.
    var callsign: String

    init(callsign: String = "") {
        self.callsign = callsign
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

    /// The identity, trimmed and uppercased, or a complaint about it.
    ///
    /// Required in every mode. Two of the three protocols carry the callsign in
    /// their own frames and the third has nothing else to identify us by, but
    /// the real reason is the one in the message: transmitting unidentified is
    /// not legal anywhere, and this app is not going to make it easy.
    func validated() throws -> OperatorIdentity {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw ValidationError.missingCallsign }
        return OperatorIdentity(callsign: trimmed)
    }
}
