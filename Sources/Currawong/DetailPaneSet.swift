// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The split layout's secondary panes, and which one to land on when the set
/// changes — on every connect, disconnect and mode change. A pure value so that
/// is testable.
///
/// Exactly one of `connect` (disconnected) and `session` (connected) is ever
/// offered, and it sorts first, so it is where a changed set falls back to:
/// connecting lands on the radio rather than on whatever pane is left.
struct DetailPaneSet: Equatable {
    /// The panes the picker offers, in the order it offers them.
    let panes: [DetailPane]

    init(connection: RadioSession.ConnectionStatus, mode: RadioMode) {
        let showsConnectForm = SessionPaneLayout(connection: connection).showsConnectForm
        panes = DetailPane.allCases.filter { pane in
            switch pane {
            // APP-18: hidden rather than greyed while connected.
            case .connect: return showsConnectForm
            case .session: return !showsConnectForm
            case .keypad: return mode.sendsDTMF
            case .stations: return mode == .echoLink
            case .reflectors: return mode == .m17
            case .setup: return true
            }
        }
    }

    /// The stored selection, resolved against what this state offers. Resolved
    /// on read rather than corrected in an `onChange`, so the picker never
    /// points at a missing pane and the stored choice returns with its pane.
    /// ``panes`` is never empty; `setup` only makes the function total.
    func resolving(_ chosen: DetailPane) -> DetailPane {
        panes.contains(chosen) ? chosen : (panes.first ?? .setup)
    }
}

/// The split layout's detail column, pane by pane. Declaration order is the
/// picker's order and the fallback's preference; see ``DetailPaneSet``.
enum DetailPane: String, CaseIterable, Identifiable, Hashable {
    /// The connect form. Disconnected only.
    case connect
    /// The radio, given the whole column. Connected only; ``RootView`` renders
    /// nothing under the session pane for it.
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
