// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which network a connection uses.
///
/// The app's own vocabulary, not the library's: nothing here names `IAX2Client`
/// or `M17Client`, and only `CompositionRoot` turns one of these into a
/// concrete client. Views and view models choose a mode and display its name,
/// and that is the whole of their protocol knowledge.
///
/// ## Why the two modes need different fields
///
/// They ask the operator for genuinely different things, and pretending
/// otherwise would mean a form with fields that quietly do nothing:
///
/// | | AllStarLink | M17 |
/// |---|---|---|
/// | Reached by | a node *number*, dialled | a reflector *module*, linked |
/// | Identity | username + secret, authenticated | callsign only, unauthenticated |
/// | Default port | 4569 | 17000 |
///
/// `NodeSettings` therefore carries the union and this enum says which half is
/// live. The alternative — two settings types — would double the store, the
/// form and the validation for one differing field.
enum RadioMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// AllStarLink over IAX2 (RFC 5456). The validated path.
    case allStarLink

    /// M17 over a reflector. Believed working, never confirmed on air — see
    /// ``isValidatedOnAir``.
    case m17

    var id: String { rawValue }

    /// What the operator sees.
    var displayName: String {
        switch self {
        case .allStarLink: return "AllStarLink"
        case .m17: return "M17"
        }
    }

    /// The port this mode uses when the operator has not said otherwise.
    ///
    /// Duplicated from the libraries rather than imported, for the same reason
    /// `NodeSettings.defaultPort` is: this layer does not import them. The
    /// destinations' own defaults are the authority on the wire.
    var defaultPort: UInt16 {
        switch self {
        case .allStarLink: return 4569
        case .m17: return 17000
        }
    }

    /// Whether this mode has ever been proven to work against real equipment.
    ///
    /// **This is not decoration.** AllStarLink has carried a two-way
    /// conversation through this stack; M17 has never been transmitted to a
    /// reflector by anyone, and its decoded audio has never been listened to.
    /// An operator picking M17 is the first person to try it, and the UI says
    /// so rather than presenting two equal choices.
    var isValidatedOnAir: Bool {
        switch self {
        case .allStarLink: return true
        case .m17: return false
        }
    }

    /// Shown beside the picker when the mode is unproven.
    var unvalidatedWarning: String? {
        isValidatedOnAir
            ? nil
            : """
            M17 has never been transmitted to a real reflector. It may not work \
            at all, and if it does, nobody has yet heard how it sounds.
            """
    }

    /// Whether this mode dials a node number and authenticates.
    ///
    /// Drives which fields the connect form shows, and which of them
    /// ``NodeSettings/validated()`` insists on.
    var usesNodeNumber: Bool { self == .allStarLink }

    /// Whether this mode links a reflector module.
    var usesModule: Bool { self == .m17 }
}
