// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-18.** Which controls each connection state has.
final class SessionPaneLayoutTests: XCTestCase {
    func testDisconnectedShowsTheFormAndNoTransmitControls() {
        let layout = SessionPaneLayout(connection: .disconnected)
        XCTAssertTrue(layout.showsConnectForm)
        XCTAssertFalse(layout.showsTransmitControls)
    }

    /// The point of switching on `.connecting` rather than `.connected`: the
    /// layout changes once, when the operator presses Connect, not a second time
    /// while they are watching for the link to come up.
    func testConnectingAlreadyShowsTheTransmitControls() {
        let layout = SessionPaneLayout(connection: .connecting)
        XCTAssertTrue(layout.showsTransmitControls)
        XCTAssertFalse(layout.showsConnectForm)
    }

    func testConnectedShowsTheTransmitControlsAndNoForm() {
        let layout = SessionPaneLayout(connection: .connected)
        XCTAssertTrue(layout.showsTransmitControls)
        XCTAssertFalse(layout.showsConnectForm)
    }

    /// Hanging up keeps the controls until the link is actually gone. Taking
    /// them away a beat early makes a disconnect look like a fault.
    func testDisconnectingKeepsTheTransmitControls() {
        let layout = SessionPaneLayout(connection: .disconnecting)
        XCTAssertTrue(layout.showsTransmitControls)
        XCTAssertFalse(layout.showsConnectForm)
    }

    /// The reason this is a type and not two comparisons in two files. The two
    /// halves are made in `SessionPane` and `RootView` respectively; a state
    /// showing both, or neither, is the way they would drift apart.
    func testExactlyOneOfTheTwoShowsInEveryState() {
        for connection: RadioSession.ConnectionStatus in [
            .disconnected, .connecting, .connected, .disconnecting,
        ] {
            let layout = SessionPaneLayout(connection: connection)
            XCTAssertNotEqual(
                layout.showsConnectForm, layout.showsTransmitControls,
                "both or neither at \(connection)")
        }
    }
}
