// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The split layout's secondary panes: the one the operator is looking at, and
/// the ones the picker offers to go to.
///
/// A pure value for the same reason ``SessionPaneLayout`` is one — this decision
/// used to be three computed properties inside ``RootView``, and the part of it
/// that matters is not "which panes exist" but *which one you land on when the
/// set changes underneath you*. That happens on every connect, every disconnect
/// and every mode change, and it is not visible from any one of the three.
///
/// ## `connect` and `session` are complements
///
/// The same complement ``SessionPaneLayout`` makes, one level up. Disconnected,
/// the pane worth the column is the connect form; connected, it is the radio —
/// status, meters, PTT, and nothing under them. Neither state has a use for the
/// other's pane, so exactly one of the two is ever in the picker, and because
/// `session` sorts before every optional pane it is also what a connect falls
/// back *to*.
///
/// That fallback is the whole point of the type. Before it there was no
/// `session` pane at all: connecting took `connect` out of the picker and the
/// column landed on the first thing left, which in M17 is the reflector
/// directory — so linking to a reflector left the operator looking at a list of
/// reflectors, with the radio squeezed into the top half of an iPad's column.
struct DetailPaneSet: Equatable {
    /// The panes the picker offers, in the order it offers them.
    let panes: [DetailPane]

    init(connection: RadioSession.ConnectionStatus, mode: RadioMode) {
        let showsConnectForm = SessionPaneLayout(connection: connection).showsConnectForm
        panes = DetailPane.allCases.filter { pane in
            switch pane {
            // **APP-18.** The form is the disconnected state's pane and only
            // that state's: connected it is a read-only wall of fields whose one
            // useful line is on the status panel already (APP-16). It leaves the
            // picker rather than staying in it greyed, because a pane that is
            // offered and then refuses is worse than one that is not offered.
            case .connect: return showsConnectForm
            case .session: return !showsConnectForm
            case .keypad: return mode.sendsDTMF
            // Separate panes rather than one that changes contents, because
            // they are separate networks — nothing in an EchoLink listing means
            // anything to M17 — and a pane whose title stayed put while
            // everything under it changed would suggest otherwise.
            case .stations: return mode == .echoLink
            case .reflectors: return mode == .m17
            case .setup: return true
            }
        }
    }

    /// The stored selection, resolved against what this mode and this connection
    /// state actually offer.
    ///
    /// Resolved on *read* rather than corrected from an `onChange`, so there is
    /// no frame in which the picker points at a pane that is not there — and so
    /// the stored choice comes back when its pane does: connect while the form
    /// is showing and the column moves to the radio; disconnect and the form is
    /// showing again.
    ///
    /// The fallback is the first pane there is, which is `connect` or `session`
    /// — whichever of the pair this state has — because that pair is always
    /// present and is the pane the state is about. ``panes`` is never empty, so
    /// the picker never has nothing to select; `setup` is the last resort only
    /// because a total is safer than a `!`.
    func resolving(_ chosen: DetailPane) -> DetailPane {
        panes.contains(chosen) ? chosen : (panes.first ?? .setup)
    }
}

/// The split layout's detail column, pane by pane.
///
/// Declaration order is the picker's order and the fallback's preference, so
/// `connect` and `session` come first deliberately: see ``DetailPaneSet``.
enum DetailPane: String, CaseIterable, Identifiable, Hashable {
    /// The connect form. Disconnected only.
    case connect
    /// The radio, given the whole column. Connected only — its content is the
    /// session pane the column already has above the divider, which is why
    /// ``RootView`` renders nothing *under* it and lets the pane expand instead.
    case session
    case keypad
    case stations
    case reflectors
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return "Connect"
        case .session: return "Radio"
        case .keypad: return "Keypad"
        case .stations: return "Stations"
        case .reflectors: return "Reflectors"
        case .setup: return "Settings"
        }
    }
}
