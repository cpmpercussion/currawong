// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// Which panes the split layout's picker offers, and — the part that matters —
/// which one the operator lands on when the set changes under them.
final class DetailPaneSetTests: XCTestCase {
    private func panes(
        _ connection: RadioSession.ConnectionStatus, _ mode: RadioMode
    ) -> [DetailPane] {
        DetailPaneSet(connection: connection, mode: mode).panes
    }

    // MARK: - The complement

    func testDisconnectedOffersTheFormAndNotTheRadio() {
        for mode in RadioMode.allCases {
            let set = panes(.disconnected, mode)
            XCTAssertTrue(set.contains(.connect), "\(mode)")
            XCTAssertFalse(set.contains(.session), "\(mode)")
        }
    }

    func testALiveLinkOffersTheRadioAndNotTheForm() {
        for connection: RadioSession.ConnectionStatus in [
            .connecting, .connected, .disconnecting,
        ] {
            for mode in RadioMode.allCases {
                let set = panes(connection, mode)
                XCTAssertTrue(set.contains(.session), "\(mode) at \(connection)")
                XCTAssertFalse(set.contains(.connect), "\(mode) at \(connection)")
            }
        }
    }

    /// The same guarantee ``SessionPaneLayout`` makes one level down: never
    /// both, never neither. Neither state has any use for the other's pane.
    func testExactlyOneOfConnectAndSessionInEveryState() {
        for connection: RadioSession.ConnectionStatus in [
            .disconnected, .connecting, .connected, .disconnecting,
        ] {
            for mode in RadioMode.allCases {
                let set = panes(connection, mode)
                XCTAssertNotEqual(
                    set.contains(.connect), set.contains(.session),
                    "both or neither: \(mode) at \(connection)")
            }
        }
    }

    // MARK: - What each mode has

    func testOnlyAllStarLinkHasAKeypad() {
        XCTAssertTrue(panes(.connected, .allStarLink).contains(.keypad))
        XCTAssertFalse(panes(.connected, .m17).contains(.keypad))
        XCTAssertFalse(panes(.connected, .echoLink).contains(.keypad))
    }

    /// The directories are part of `Add channel`, not panes, so the keypad is
    /// the only thing a mode adds to the picker.
    func testOnlyTheKeypadDependsOnTheMode() {
        for connection: RadioSession.ConnectionStatus in [.disconnected, .connected] {
            let withKeypad = panes(connection, .allStarLink).filter { $0 != .keypad }
            XCTAssertEqual(withKeypad, panes(connection, .m17), "\(connection)")
            XCTAssertEqual(withKeypad, panes(connection, .echoLink), "\(connection)")
        }
    }

    func testSettingsIsAlwaysOffered() {
        for connection: RadioSession.ConnectionStatus in [
            .disconnected, .connecting, .connected, .disconnecting,
        ] {
            for mode in RadioMode.allCases {
                XCTAssertTrue(panes(connection, mode).contains(.setup))
            }
        }
    }

    func testThePickerIsNeverEmpty() {
        for connection: RadioSession.ConnectionStatus in [
            .disconnected, .connecting, .connected, .disconnecting,
        ] {
            for mode in RadioMode.allCases {
                XCTAssertFalse(panes(connection, mode).isEmpty)
            }
        }
    }

    // MARK: - Where a change in the set lands

    /// Connecting takes the connect form out of the picker, and the column
    /// must fall to the radio rather than to whichever pane sorts next.
    func testConnectingOnM17LandsOnTheRadio() {
        let set = DetailPaneSet(connection: .connected, mode: .m17)
        XCTAssertEqual(set.resolving(.connect), .session)
    }

    func testConnectingLandsOnTheRadioInEveryMode() {
        for mode in RadioMode.allCases {
            let set = DetailPaneSet(connection: .connected, mode: mode)
            XCTAssertEqual(set.resolving(.connect), .session, "\(mode)")
        }
    }

    /// And the same on the way in: `.connecting`, not `.connected`, so the
    /// column changes once — when the operator presses Connect.
    func testTheMoveHappensAtConnectingRatherThanConnected() {
        XCTAssertEqual(
            DetailPaneSet(connection: .connecting, mode: .m17).resolving(.connect), .session)
    }

    func testDisconnectingLandsBackOnTheForm() {
        for mode in RadioMode.allCases {
            let set = DetailPaneSet(connection: .disconnected, mode: mode)
            XCTAssertEqual(set.resolving(.session), .connect, "\(mode)")
        }
    }

    /// A mode change can take the selected pane away too, and the landing is
    /// the state's own pane rather than whatever sorts first.
    func testAModeChangeAwayFromTheKeypadLandsOnTheRadio() {
        let set = DetailPaneSet(connection: .connected, mode: .m17)
        XCTAssertEqual(set.resolving(.keypad), .session)
    }

    func testASelectionStillOnOfferIsLeftAlone() {
        let set = DetailPaneSet(connection: .connected, mode: .allStarLink)
        XCTAssertEqual(set.resolving(.keypad), .keypad)
        XCTAssertEqual(set.resolving(.setup), .setup)
        XCTAssertEqual(set.resolving(.session), .session)
    }

    /// The stored choice comes back when its pane does — the resolution is on
    /// read, so nothing overwrote it while the pane was away.
    func testTheStoredChoiceSurvivesAConnectAndComesBack() {
        var stored = DetailPane.connect
        XCTAssertEqual(
            DetailPaneSet(connection: .connected, mode: .m17).resolving(stored), .session)
        stored = .connect  // never written by the resolution above
        XCTAssertEqual(
            DetailPaneSet(connection: .disconnected, mode: .m17).resolving(stored), .connect)
    }
}
