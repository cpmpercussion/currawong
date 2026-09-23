// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Who is operating, app-wide: the licence belongs to the person, not the
/// channel.
///
/// A struct rather than loose strings, so a callsign and a password can never
/// be swapped in a call — which would transmit the password as a callsign.
struct OperatorIdentity: Equatable, Sendable, Codable {
    /// The operator's callsign, sent as the calling name in every mode. Stored
    /// as typed; uppercased by ``validated()``.
    var callsign: String

    /// **EchoLink.** The operator's name, shown to the far end and in the
    /// directory. May be empty.
    var operatorName: String

    /// **EchoLink.** A short location for the directory listing. May be empty.
    var location: String

    init(callsign: String = "", operatorName: String = "", location: String = "") {
        self.callsign = callsign
        self.operatorName = operatorName
        self.location = location
    }

    /// Nobody identified yet.
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

    /// The callsign in the one form anything durable may be keyed by. Use this,
    /// not ``callsign``, for any Keychain account name, or a secret filed under
    /// one spelling is lost under another.
    var normalisedCallsign: String {
        callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// The identity trimmed, with the callsign uppercased and required. Name
    /// and location are optional display text and keep their case.
    func validated() throws -> OperatorIdentity {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw ValidationError.missingCallsign }
        return OperatorIdentity(
            callsign: trimmed,
            operatorName: operatorName.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
