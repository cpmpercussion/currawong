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

    /// **EchoLink.** The operator's name, shown to the far end and in the
    /// directory listing. May be empty.
    ///
    /// Here rather than in `NodeSettings` for the same reason the callsign is:
    /// it is a fact about the person, not about where they are connecting. Only
    /// EchoLink transmits it, so only the EchoLink form offers it — but what it
    /// edits is the one app-wide value, not a field of that channel.
    var operatorName: String

    /// **EchoLink.** A short location for the directory listing — a town, or a
    /// three-letter airport code. May be empty.
    ///
    /// App-wide with the same caveat as ``operatorName``: an operator who
    /// travels changes this once, not once per saved channel.
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

    /// The identity, trimmed and uppercased, or a complaint about it.
    ///
    /// Required in every mode. Two of the three protocols carry the callsign in
    /// their own frames and the third has nothing else to identify us by, but
    /// the real reason is the one in the message: transmitting unidentified is
    /// not legal anywhere, and this app is not going to make it easy.
    /// The name and location are trimmed but **not** required and not
    /// uppercased — they are display text shown to another human, and an
    /// operator who leaves them blank has said something legitimate.
    func validated() throws -> OperatorIdentity {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw ValidationError.missingCallsign }
        return OperatorIdentity(
            callsign: trimmed,
            operatorName: operatorName.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
