// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The session pane's link button: what it says in each state, and what it
/// actually dials.
///
/// Two halves, and the second is the one that matters on air: **the button must
/// dial the channel it names, and name the channel the status panel above it is
/// showing.** It used to name the last channel connected to this run instead, so
/// selecting a different channel left the pane showing one destination above a
/// button offering another — and pressing it dialled the second. See the note on
/// ``SessionLinkControl`` for why the wording changed with the behaviour.
@MainActor
final class SessionLinkControlTests: XCTestCase {
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")

    private var allStar: NodeSettings { SessionHarness.goodSettings }
    private var other: NodeSettings { SessionHarness.otherSettings }

    // MARK: - What the button says

    func testConnectedOffersDisconnect() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .connected, destinationName: "Repeater"))

        XCTAssertEqual(control.title, "Disconnect")
        XCTAssertTrue(control.isEnabled)
        XCTAssertTrue(control.isDestructive)
    }

    /// A connect that is going nowhere is abandonable, and this is the only
    /// control that offers it — the form's button is inert while busy.
    func testConnectingOffersCancelRatherThanDisconnect() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .connecting, destinationName: nil))

        XCTAssertEqual(control.title, "Cancel")
        XCTAssertTrue(control.isEnabled)
    }

    /// The one state with nothing left to ask for.
    func testDisconnectingIsShownButDisabled() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .disconnecting, destinationName: "Repeater"))

        XCTAssertEqual(control.title, "Disconnecting…")
        XCTAssertFalse(control.isEnabled)
    }

    /// The label names the place, because a button that keys a transmitter
    /// should not be ambiguous about which one.
    func testDisconnectedOffersToConnectToTheSelectedChannel() throws {
        let control = try XCTUnwrap(
            SessionLinkControl(connection: .disconnected, destinationName: "VK1RGI"))

        XCTAssertEqual(control.title, "Connect to VK1RGI")
        XCTAssertTrue(control.isEnabled)
        XCTAssertFalse(control.isDestructive, "connecting is not the destructive action")
        XCTAssertTrue(control.isProminent, "it is the next step after choosing a channel")
    }

    /// The word is the only thing the last-connected channel decides. Both
    /// spellings dial the selection.
    func testTheSelectionBeingWhereWeJustWereOnlyChangesTheWord() throws {
        let returning = try XCTUnwrap(
            SessionLinkControl(
                connection: .disconnected, destinationName: "VK1RGI",
                isReturningToLastConnected: true))

        XCTAssertEqual(returning.title, "Reconnect to VK1RGI")
        XCTAssertTrue(returning.isProminent)
    }

    /// Disconnect is findable because it is red and in a fixed place. A second
    /// filled slab under the PTT would compete with it for the glance SF-3
    /// wants spent on the transmit state.
    func testOnlyTheAffirmativeActionIsProminent() throws {
        let connected = try XCTUnwrap(
            SessionLinkControl(connection: .connected, destinationName: "VK1RGI"))
        XCTAssertFalse(connected.isProminent)

        let cancelling = try XCTUnwrap(
            SessionLinkControl(connection: .connecting, destinationName: "VK1RGI"))
        XCTAssertFalse(cancelling.isProminent)
    }

    /// With no channel selected there is nowhere for the button to go, and a
    /// dead button only invites pressing it.
    func testNothingIsShownWithNoChannelSelected() {
        XCTAssertNil(SessionLinkControl(connection: .disconnected, destinationName: nil))
        XCTAssertNil(SessionLinkControl(connection: .disconnected, destinationName: ""))
    }

    // MARK: - `restoreLastConnectedChannel()`, which the button no longer calls
    //
    // The button dials the selection now, so nothing in the UI reaches these.
    // They are kept because `lastConnectedChannel` itself is still live — it
    // decides whether the button says "Reconnect" or "Connect", and
    // `RadioSession` falls back to it — and because the restore is a coherent
    // model capability somebody may want wired to something else. If it is
    // still unused when the next task passes through here, delete both.

    func testNoLastChannelUntilACallIsAnswered() async {
        let harness = SessionHarness()
        XCTAssertNil(harness.session.lastConnectedChannel)

        harness.session.settings = allStar
        await harness.session.connect()

        XCTAssertEqual(harness.session.lastConnectedChannel?.id, allStar.id)
    }

    /// Reconnect must not offer to return to somewhere that refused us — the
    /// button would then mean "retry the thing that failed", which is a
    /// different offer and one the form is better placed to make.
    func testAFailedConnectLeavesNoLastChannel() async {
        let harness = SessionHarness()
        harness.session.settings = allStar
        harness.client.connectError = SessionHarness.ConnectFailed()

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertNil(harness.session.lastConnectedChannel)
    }

    func testDisconnectingKeepsTheLastChannelSoItCanBeReturnedTo() async {
        let harness = SessionHarness()
        harness.session.settings = allStar
        await harness.session.connect()

        await harness.session.disconnect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.lastConnectedChannel?.id, allStar.id)
    }

    /// What the restore does when it is called: it moves the selection back,
    /// list and draft together, and brings the secret with it.
    ///
    /// **This is no longer what the link button does.** It used to call this
    /// first, which changed the selection out from under the operator — the pane
    /// showed one channel and the button dialled another.
    func testReconnectingReturnsToTheLastChannelAfterAnotherWasSelected() async {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])
        await harness.session.connect()
        await harness.session.disconnect()

        harness.session.select(other.id)
        XCTAssertEqual(harness.session.settings.id, other.id, "precondition")

        XCTAssertTrue(harness.session.restoreLastConnectedChannel())

        XCTAssertEqual(harness.session.settings.id, allStar.id)
        XCTAssertEqual(
            harness.session.channels.selectedID, allStar.id,
            "the list's selection follows the draft, or the two disagree on screen")
        XCTAssertEqual(harness.session.secret, "hunter2", "and its secret comes back with it")
    }

    /// A channel deleted after the call can still be reconnected to: an unsaved
    /// draft is a supported state, and refusing the call because a list entry
    /// went away would be a worse answer than placing it.
    func testReconnectingWorksAfterTheChannelWasDeleted() async {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])
        await harness.session.connect()
        await harness.session.disconnect()

        harness.session.select(other.id)
        harness.session.deleteChannel(allStar.id)

        XCTAssertTrue(harness.session.restoreLastConnectedChannel())

        XCTAssertEqual(harness.session.settings.id, allStar.id)
        XCTAssertEqual(harness.session.secret, "hunter2")
        XCTAssertFalse(harness.session.channels.channels.contains { $0.id == allStar.id })
    }

    func testRestoringIsRefusedWithNoLastChannelAndWhileALinkIsUp() async {
        let harness = SessionHarness()
        XCTAssertFalse(
            harness.session.restoreLastConnectedChannel(), "nowhere to go back to yet")

        harness.session.settings = allStar
        await harness.session.connect()

        XCTAssertFalse(
            harness.session.restoreLastConnectedChannel(),
            "changing the draft under a live link is what `select(_:)` refuses too")
    }

    /// And the round trip: restore, connect, and the call goes to the channel on
    /// the label rather than to the one that was selected.
    func testReconnectPlacesTheCallToTheChannelOnTheLabel() async {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])
        await harness.session.connect()
        await harness.session.disconnect()
        harness.session.select(other.id)

        harness.session.restoreLastConnectedChannel()
        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.session.settings.id, allStar.id)
        XCTAssertEqual(harness.settingsSeen.last?.host, allStar.host)
    }
}
