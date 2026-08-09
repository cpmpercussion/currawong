// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// Proves the app is genuinely wired to the library: this test only compiles if
/// the local SPM path dependency resolved and linked, and only passes if the
/// client the composition root builds starts in a safe state.
///
/// No socket is opened. `IAX2Client` builds its transport lazily, inside
/// `connect(to:)`, so constructing one touches nothing but memory.
///
/// Note what is *not* imported here: `IAX2Kit`. The test reaches the client
/// through `RadioCore`'s vocabulary alone, which is the same constraint the
/// rest of the app is under.
@MainActor
final class CompositionRootTests: XCTestCase {
    func testAFreshRootIsIdleAndNotTransmitting() {
        let root = CompositionRoot()

        XCTAssertEqual(root.transmitState, .idle)
        XCTAssertFalse(TransmitStatusPresentation(state: root.transmitState).isTransmitting)
    }

    func testTheClientIsNotConnectedBeforeConnectIsCalled() async {
        let root = CompositionRoot()

        let isConnected = await root.client.isConnected
        XCTAssertFalse(isConnected)

        let destination = await root.client.currentDestination
        XCTAssertNil(destination)
    }

    /// Stopping transmit is documented as safe on a client that was never
    /// connected — SF-2 and SF-3 both call it from paths that cannot know the
    /// current state, so it must not trap here either.
    func testStopTransmitOnAnUnconnectedClientIsHarmless() async {
        let root = CompositionRoot()

        await root.client.stopTransmit()

        XCTAssertEqual(root.transmitState, .idle)
    }
}
