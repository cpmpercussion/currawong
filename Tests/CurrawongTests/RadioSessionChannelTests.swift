// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The channel half of ``RadioSession`` (APP-4): the list, the selection, and
/// the rules about moving between channels.
///
/// `session.settings` is the selected channel as the connect form edits it,
/// and `session.channels` is the list it is saved into as it is typed;
/// `ChannelEditingTests` covers that half. Selecting changes which channel the
/// form shows, and may not happen mid-call.
///
/// Every one of these runs against ``FakeNetworkClient``. No socket, no node.
@MainActor
final class RadioSessionChannelTests: XCTestCase {
    /// The operator. App-wide now, rather than a settings field.
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")


    // Computed rather than stored, so they are read on the main actor alongside
    // the harness that defines them. The values themselves are constants, so
    // each channel's id is stable across the whole run — which is what makes
    // "is this the same channel?" a question worth asking.
    private var allStar: NodeSettings { SessionHarness.goodSettings }
    private var other: NodeSettings { SessionHarness.otherSettings }
    private var echo: NodeSettings { SessionHarness.echoLinkSettings }

    // MARK: - Loading

    /// The migration, seen from the view model: an operator updating from a
    /// build before APP-4 finds their node as channel one, selected, and in the
    /// form — not an empty app.
    func testALegacyNodeArrivesAsTheSelectedChannel() {
        let harness = SessionHarness(settings: allStar)

        XCTAssertEqual(harness.session.channels.channels, [allStar])
        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertEqual(harness.session.settings, allStar)
    }

    /// With no channels at all the draft is an empty one to fill in, which is
    /// exactly what the app did before it had a list.
    func testNoChannelsGivesAnEmptyDraft() {
        let harness = SessionHarness(settings: nil, channels: [])

        XCTAssertTrue(harness.session.channels.channels.isEmpty)
        XCTAssertNil(harness.session.channels.selectedID)
        XCTAssertEqual(harness.session.settings.host, "")
        XCTAssertEqual(harness.session.secret, "")
    }

    // MARK: - Selecting

    /// Selecting loads the channel's fields **and its secret**. The secret is
    /// the half that is easy to forget: it lives in the Keychain under a
    /// per-channel account, so switching channels without re-reading it would
    /// leave the previous channel's password in the form.
    func testSelectingAChannelLoadsItsFieldsAndItsKeychainSecret() {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, echo],
            selectedID: allStar.id,
            secrets: [
                allStar.secretAccount(for: vk1xyz): "hunter2",
                echo.secretAccount(for: vk1xyz): "account-password",
            ])
        XCTAssertEqual(harness.session.secret, "hunter2")

        harness.session.select(echo.id)

        XCTAssertEqual(harness.session.settings, echo)
        XCTAssertEqual(harness.session.channels.selectedID, echo.id)

        // **APP-14: an EchoLink channel's password is not loaded into `secret`.**
        // It is app-wide, the settings screen owns it, and it lives in
        // `echoLinkAccountPassword` — one copy, so that connecting cannot write
        // one over the other and the station browser cannot read the wrong one.
        XCTAssertEqual(harness.session.secret, "")
        XCTAssertEqual(harness.session.echoLinkAccountPassword, "account-password")
    }

    /// A channel whose account has no stored secret clears the field rather
    /// than leaving the last channel's password in it, where the operator could
    /// send it to a node it does not belong to.
    func testSelectingAChannelWithNoStoredSecretClearsTheField() {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])

        harness.session.select(other.id)

        XCTAssertEqual(harness.session.secret, "")
    }

    /// **Refused while a link is up.** Changing the destination under a live
    /// connection would leave the form describing one node and the audio coming
    /// from another. The UI disables the list; this is the backstop.
    func testSelectionIsRefusedWhileConnected() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        await harness.connect()
        XCTAssertEqual(harness.session.connection, .connected)

        harness.session.select(other.id)

        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertEqual(harness.session.settings.id, allStar.id)

        // And it works again once the link is down.
        await harness.session.disconnect()
        harness.session.select(other.id)
        XCTAssertEqual(harness.session.channels.selectedID, other.id)
    }

    // MARK: - APP-23, switching to a channel

    /// The gesture the greyed-out list used to refuse: connected to one channel,
    /// tap another, end up there. `select(_:)`'s own refusal is untouched — the
    /// sequence hangs up first, so the selection still only moves while
    /// disconnected.
    func testSwitchingWhileConnectedHangsUpSelectsAndAsksForACall() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        await harness.connect()
        XCTAssertEqual(harness.session.connection, .connected)

        let shouldDial = await harness.session.switchChannel(to: other.id)

        XCTAssertTrue(shouldDial, "a call was up, so the caller must place a new one")
        XCTAssertEqual(harness.session.connection, .disconnected, "the old call must be down")
        XCTAssertEqual(harness.session.channels.selectedID, other.id)
        XCTAssertEqual(harness.session.settings.id, other.id)
        XCTAssertTrue(harness.client.calls.contains(.disconnect))
    }

    /// From a standing start it only selects. A single tap on a list row must
    /// not place a call — that is the gesture that scrolls past it.
    func testSwitchingWhileDisconnectedOnlySelects() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)

        let shouldDial = await harness.session.switchChannel(to: other.id)

        XCTAssertFalse(shouldDial, "nothing was up, so nothing should be dialled")
        XCTAssertEqual(harness.session.channels.selectedID, other.id)
        XCTAssertEqual(harness.session.connection, .disconnected)
    }

    /// The one outcome this must never produce: hanging up on the channel the
    /// operator is already talking on, because they tapped its row.
    func testSwitchingToTheChannelAlreadyConnectedDoesNothing() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        await harness.connect()

        let shouldDial = await harness.session.switchChannel(to: allStar.id)

        XCTAssertFalse(shouldDial)
        XCTAssertEqual(harness.session.connection, .connected, "the live call must survive")
        XCTAssertFalse(harness.client.calls.contains(.disconnect))
    }

    func testSwitchingToAnUnknownChannelChangesNothing() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar], selectedID: allStar.id)
        await harness.connect()

        let shouldDial = await harness.session.switchChannel(to: UUID())

        XCTAssertFalse(shouldDial)
        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
    }

    /// A transmission in progress is not a reason to refuse the switch, but it
    /// must not survive it: `disconnect()` unkeys on the way through, and this
    /// is the assertion that says the switch inherits that.
    func testSwitchingWhileKeyedUnkeysFirst() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        await harness.connect()
        await harness.keyDown()
        XCTAssertTrue(harness.client.isTransmitting)

        _ = await harness.session.switchChannel(to: other.id)

        XCTAssertFalse(harness.client.isTransmitting, "the switch must not carry a keyed radio")
        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
    }

    /// A client reports its own hang-up as a `.disconnected` event. When that
    /// event is handled after the next call has started, it must not be taken
    /// for the new call dropping: no alert, and the new call stays up.
    func testTheOldLinksHangUpIsNotReportedAgainstTheNewCall() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        await harness.connect()
        let oldEvents = harness.eventContinuation!
        harness.client.duringDisconnect = {
            oldEvents.yield(.disconnected(reason: "The link dropped: disconnected locally."))
            // Lets the event pump take the event before `disconnect()` resumes,
            // which is the order a real client produces.
            await Task.yield()
        }

        let shouldDial = await harness.session.switchChannel(to: other.id)
        XCTAssertTrue(shouldDial)
        harness.client.duringDisconnect = nil
        await harness.session.connect()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(harness.session.connection, .connected, "the new call must stay up")
        XCTAssertNil(harness.session.alert, "hanging up to change channel is not news")
        XCTAssertNil(harness.session.lastDisconnectReason)
        XCTAssertEqual(harness.linksMade, 2)
    }

    func testSelectingAnUnknownChannelChangesNothing() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        harness.session.select(UUID())

        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertEqual(harness.session.settings, allStar)
    }

    // MARK: - Adding

    // MARK: - Connecting

    /// The single-node key is written too, so an operator who downgrades — or
    /// runs a build from before APP-4 — still finds the node they last used.
    func testConnectingAlsoWritesTheLegacySingleNodeKey() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = echo
        harness.session.secret = "account-password"

        await harness.session.connect()

        XCTAssertEqual(harness.settingsStore.saved, echo)
    }

    // MARK: - Deleting

    /// The draft follows the selection, so deleting the channel the operator is
    /// on leaves them on its neighbour rather than on a form describing a
    /// channel that no longer exists.
    func testDeletingTheSelectedChannelMovesTheDraftToTheNeighbour() {
        let harness = SessionHarness(
            settings: nil,
            channels: [allStar, other],
            selectedID: allStar.id,
            secrets: [other.secretAccount(for: vk1xyz): "other-secret"])

        harness.session.deleteChannel(allStar.id)

        XCTAssertEqual(harness.session.channels.channels, [other])
        XCTAssertEqual(harness.session.channels.selectedID, other.id)
        XCTAssertEqual(harness.session.settings, other)
        XCTAssertEqual(
            harness.session.secret, "other-secret",
            "the draft's secret has to follow the draft")
    }

    func testDeletingTheLastChannelLeavesAnEmptyDraft() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        harness.session.deleteChannel(allStar.id)

        XCTAssertTrue(harness.session.channels.channels.isEmpty)
        XCTAssertNil(harness.session.channels.selectedID)
        XCTAssertEqual(harness.session.settings.host, "")
        XCTAssertEqual(harness.settingsStore.savedChannels, [])
    }

    /// Deleting a channel the operator is not on leaves the draft alone.
    func testDeletingAnUnselectedChannelDoesNotDisturbTheDraft() {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: other.id)
        harness.session.settings.host = "half-typed.exam"

        harness.session.deleteChannel(allStar.id)

        XCTAssertEqual(harness.session.settings.host, "half-typed.exam")
        XCTAssertEqual(harness.session.channels.selectedID, other.id)
    }

    /// **The Keychain secret is deliberately left behind, and that is not an
    /// oversight.**
    ///
    /// A secret is filed under `NodeSettings.secretAccount(for: vk1xyz)`, which other
    /// channels can share — every EchoLink channel for one callsign does, by
    /// construction, because the EchoLink account form is `echolink:<callsign>`
    /// and names no node. Deleting the Keychain item along with the channel
    /// would therefore log the operator out of channels they never touched.
    ///
    /// The trade is between an orphaned Keychain item, which is invisible and
    /// harmless, and a lost password, which is neither.
    func testDeletingAChannelDoesNotDeleteItsKeychainSecret() {
        var otherEcho = echo
        otherEcho.id = UUID()
        otherEcho.name = "Another EchoLink node"
        otherEcho.peer = "192.0.2.55"
        XCTAssertEqual(
            otherEcho.secretAccount(for: vk1xyz), echo.secretAccount(for: vk1xyz),
            "the premise: two EchoLink channels, one account password")

        let harness = SessionHarness(
            settings: nil,
            channels: [echo, otherEcho],
            selectedID: echo.id,
            secrets: [echo.secretAccount(for: vk1xyz): "account-password"])

        harness.session.deleteChannel(echo.id)

        XCTAssertEqual(
            harness.secretStore.all[echo.secretAccount(for: vk1xyz)], "account-password",
            "the surviving channel still needs the password it shares")
        XCTAssertEqual(harness.session.settings.id, otherEcho.id)
        // APP-14: the password is still there for the surviving channel — in the
        // app-wide field, which is the only place it is now held.
        XCTAssertEqual(harness.session.echoLinkAccountPassword, "account-password")
        XCTAssertEqual(harness.session.secret, "")
    }

    /// Deleting mid-call would take the connected channel out from under the
    /// operator, so it is refused alongside selecting and adding.
    func testDeletingIsRefusedWhileConnected() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        await harness.connect()

        harness.session.deleteChannel(other.id)

        XCTAssertEqual(harness.session.channels.channels.count, 2)
    }

    // MARK: - Choosing from a directory

    /// Choosing somewhere already saved selects it instead of making a second
    /// copy. Two channels for one module are indistinguishable in the list.
    func testChoosingSomewhereAlreadySavedSelectsItInstead() {
        let saved = M17Reflector.fake(designator: "M17-432", host: "m17-432.example.org")
            .channel(module: "H", basedOn: NodeSettings())
        let other = SessionHarness.goodSettings
        let harness = SessionHarness(
            settings: nil, channels: [other, saved], selectedID: other.id)

        // A fresh value for the same place: different id, different name.
        var again = M17Reflector.fake(designator: "M17-432", host: "M17-432.example.org")
            .channel(module: "h", basedOn: NodeSettings())
        again.name = "Sunday net"

        XCTAssertTrue(harness.session.chooseChannel(again))

        XCTAssertEqual(harness.session.channels.channels.count, 2, "no second copy")
        XCTAssertEqual(
            harness.session.channels.selectedID, saved.id,
            "the existing channel is selected, keeping its name and its id")
        XCTAssertEqual(harness.session.settings.id, saved.id)
    }

    /// Repointing the draft mid-call would leave the form describing one place
    /// and the audio coming from another — the rule `select(_:)` already has.
    func testChoosingIsRefusedWhileConnected() async {
        let harness = SessionHarness()
        await harness.connect()

        let before = harness.session.settings
        XCTAssertFalse(harness.session.chooseChannel(SessionHarness.echoLinkSettings))
        XCTAssertEqual(harness.session.settings, before)
    }

    // MARK: - Reordering

    func testReorderingIsPersisted() {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other, echo], selectedID: allStar.id)

        harness.session.moveChannels(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(
            harness.session.channels.channels.map(\.id), [echo.id, allStar.id, other.id])
        XCTAssertEqual(
            harness.settingsStore.savedChannels?.map(\.id), [echo.id, allStar.id, other.id])
        XCTAssertEqual(
            harness.session.channels.selectedID, allStar.id,
            "dragging a row must not change which channel the operator is on")
    }
}
