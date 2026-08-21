// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import XCTest

@testable import Currawong

/// **APP-18, the hazard half.** The PTT button is on screen only while there is
/// a link, so a link that drops under a held finger takes the button away —
/// and the gesture that would have reported the release goes with it.
///
/// ``PushToTalkButton``'s `.onDisappear { onRelease(.viewDisappeared) }` was
/// written for the compact layout, where leaving the Session tab while keyed
/// unkeys. Under APP-18 it is also the last line of defence for a dropped link,
/// and this file is the test that says so: the model's own path and the view's
/// path are exercised separately, and then together.
///
/// **These tests host real SwiftUI views**, because `onDisappear` is not
/// something a view model can be asked about — see ``ViewHost``, which owns the
/// window and the platform difference.
///
/// **They run on both platforms**, and the compact one is the reason: leaving the
/// Session tab while keyed is a case only iOS has, and while this file was
/// `#if os(macOS)` the only platform it covered was the one without the problem.
@MainActor
final class SessionPaneStateTests: XCTestCase {

    private func sessionPane(_ harness: SessionHarness) -> some View {
        SessionPane(
            session: harness.session,
            accessory: BLEPTTController(
                makeCentral: { FakeBLECentral() },
                store: InMemoryPTTSettingsStore(),
                retryDelay: {}),
            remoteCommand: RemoteCommandPTTController(
                makeSource: { FakeRemoteCommandSource() },
                store: InMemoryPTTSettingsStore()),
            showsHeader: false,
            linkAction: {})
    }

    // MARK: - The hazard

    /// The plan's test: drop the link while keyed, and the operator is not left
    /// keyed. With the pane hosted, so the PTT button really does leave the
    /// hierarchy as the connection state changes.
    func testALinkDroppedWhileKeyedReleasesTheKey() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        let host = ViewHost(sessionPane(harness))
        XCTAssertTrue(harness.session.isTransmitting, "precondition: on air")

        // The far end, or the transport, hangs up. Not `disconnect()` — that is
        // the operator asking, and it ends transmission on its way out through a
        // path of its own.
        harness.eventContinuation.yield(.disconnected(reason: "The node hung up"))

        await waitUntil("the link is gone") { harness.session.connection == .disconnected }
        await harness.settleAll()
        host.settle()

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.session.isKeyDown)
        XCTAssertFalse(harness.client.isTransmitting, "the client is still keyed")
    }

    /// And it is reported as the link ending, not as a view going away. The
    /// status panel shows an unexpected stop reason to the operator, and
    /// `.viewDisappeared` is one — so if the `onDisappear` release were the one
    /// that landed, every dropped link would also accuse the app of losing its
    /// own screen.
    func testTheDroppedLinkIsWhatGetsReported() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.keyDown()
        let host = ViewHost(sessionPane(harness))

        harness.eventContinuation.yield(.disconnected(reason: nil))
        await waitUntil("the link is gone") { harness.session.connection == .disconnected }
        await harness.settleAll()
        host.settle()

        XCTAssertEqual(harness.session.lastStopReason, .disconnecting)
    }

    /// The other side of that: the button disappears on *every* disconnect,
    /// keyed or not, and a disconnect with nothing transmitting must not leave
    /// the panel reporting a transmission that ended because a view went away.
    func testHangingUpWithNothingKeyedReportsNoStopReason() async {
        let harness = SessionHarness()
        await harness.connect()
        let host = ViewHost(sessionPane(harness))
        XCTAssertNil(harness.session.lastStopReason, "precondition: nothing has stopped yet")

        await harness.session.disconnect()
        await harness.settleAll()
        host.settle()

        XCTAssertNil(
            harness.session.lastStopReason,
            "the PTT button leaving the screen is not a transmission ending")
    }

    // MARK: - The path itself

    /// The load-bearing line, in isolation: take the button out of the
    /// hierarchy and the release arrives, from `onDisappear`, with no gesture
    /// left to report it.
    ///
    /// Hosted as a bare ``PushToTalkButton`` rather than through the pane,
    /// because the pane's model ends transmission itself on the way down — which
    /// is correct, and which would hide the failure this asserts against.
    func testRemovingThePushToTalkButtonReleases() {
        let reasons = ReasonLog()
        let host = ViewHost(
            PushToTalkButton(
                isEnabled: true,
                isTransmitting: true,
                isKeyDown: true,
                onPress: {},
                onRelease: { reasons.append($0) }))
        XCTAssertEqual(reasons.reasons, [], "nothing released while the button is on screen")

        host.replaceRootView(with: Text("the link dropped"))

        XCTAssertEqual(reasons.reasons, [.viewDisappeared])
    }
}

/// A box, so the release closure can record into something the test can read
/// back without capturing a `var` in an escaping closure.
@MainActor
private final class ReasonLog {
    private(set) var reasons: [TransmitStopReason] = []
    func append(_ reason: TransmitStopReason) { reasons.append(reason) }
}
