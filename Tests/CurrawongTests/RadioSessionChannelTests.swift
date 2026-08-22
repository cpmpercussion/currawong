// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The channel half of ``RadioSession`` (APP-4): the draft, the list, and the
/// rules about moving between them.
///
/// The distinction everything here turns on is **draft versus channel**.
/// `session.settings` is the connect form's working copy and holds half-typed
/// hostnames; `session.channels` is what was saved. Selecting replaces the
/// draft, connecting writes it back, and neither may happen mid-call.
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

    /// **BU-9.** The draft is *kept* on the way out, not saved: switching
    /// channels does not lose the typing, and does not apply it to the channel
    /// either. It used to do the second, which is how this app repointed a named
    /// channel while looking like it had done nothing.
    func testSelectingKeepsTheDraftWithoutWritingItToTheList() {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        harness.session.settings.host = "half-typed.exam"

        harness.session.select(other.id)

        XCTAssertEqual(
            harness.session.channels.channels.first?.host, allStar.host,
            "the channel being left keeps describing where it actually goes")
        XCTAssertEqual(harness.settingsStore.savedChannels?.first?.host, allStar.host)
        XCTAssertEqual(
            harness.settingsStore.savedDrafts[allStar.id]?.host, "half-typed.exam",
            "and the edit is kept, on disk, as a draft")
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

    func testSelectingAnUnknownChannelChangesNothing() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        harness.session.select(UUID())

        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertEqual(harness.session.settings, allStar)
    }

    // MARK: - Adding

    /// **APP-19.** `Add channel` points the form at a new channel and writes
    /// nothing. It used to add the blank channel to the list and persist it,
    /// which is where the "Unnamed channel" rows came from: one tap left a row
    /// with no host that nothing could connect to and only Delete could remove.
    func testANewChannelIsADraftAndIsNotInTheListYet() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        let added = harness.session.newChannel(echo)

        XCTAssertEqual(added, echo.id)
        XCTAssertEqual(harness.session.settings, echo, "the form is pointed at it")
        XCTAssertEqual(
            harness.session.channels.channels.map(\.id), [allStar.id],
            "and the list is untouched")
        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertEqual(
            harness.settingsStore.savedChannels?.map(\.id), [allStar.id],
            "and nothing new was written")
        XCTAssertTrue(
            harness.session.isDraftAnUnsavedChannel,
            "so the form can say it is not saved")
    }

    /// And Save is what puts it there — the same path a channel picked out of a
    /// directory takes.
    func testSavingANewChannelIsWhatAddsItToTheList() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        harness.session.newChannel()
        harness.session.settings.host = "typed.example.org"
        harness.session.settings.name = "Typed"
        XCTAssertTrue(harness.session.isDraftDirty, "Save is offered")

        harness.session.saveDraft()

        XCTAssertEqual(harness.session.channels.channels.count, 2)
        XCTAssertEqual(harness.session.channels.channels.last?.host, "typed.example.org")
        XCTAssertEqual(harness.settingsStore.savedChannels?.count, 2)
        XCTAssertFalse(harness.session.isDraftAnUnsavedChannel)
    }

    /// A blank form nobody has typed into is not an unsaved change, so tapping
    /// `+` and stopping there offers nothing to save and leaves nothing behind.
    func testANewChannelNobodyTypedIntoIsNotDirty() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        harness.session.newChannel()

        XCTAssertFalse(harness.session.isDraftDirty)
        XCTAssertEqual(harness.settingsStore.savedChannels?.map(\.id), [allStar.id])
    }

    /// `Add channel` moves where the form is pointed, and doing that mid-call
    /// would leave the form describing one place and the audio coming from
    /// another — so it is refused for the reason selecting is.
    func testANewChannelIsRefusedWhileConnected() async {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        await harness.connect()

        XCTAssertNil(harness.session.newChannel(echo))
        XCTAssertEqual(harness.session.channels.channels.count, 1)
        XCTAssertEqual(harness.session.settings.id, allStar.id, "and the form did not move")
    }

    // MARK: - Connecting

    /// **Connecting adds a draft that is in no channel.** An operator who typed
    /// a node into an empty app and pressed Connect has said "this is a place I
    /// go"; making them press a separate Save as well would be a second step for
    /// a decision they already made. This is the one thing BU-9 deliberately
    /// *kept*: adding is not overwriting, and there is nothing here to lose.
    func testConnectingAddsAnUnsavedDraftToTheList() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = allStar
        harness.session.secret = "hunter2"

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.session.channels.channels, [allStar])
        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertEqual(harness.settingsStore.savedChannels, [allStar])
        XCTAssertEqual(harness.settingsStore.savedSelectedID, allStar.id)
    }

    /// **The other half of it, and the half BU-9 changed: connecting never
    /// overwrites a channel that is already in the list.**
    ///
    /// The call goes where the form says — that is what the operator pressed the
    /// button for — but the stored channel is left describing where it goes, and
    /// the edit waits as a draft until Save is asked for. Connecting used to
    /// write it back, which is how a channel called `M17-432 H` ended up pointed
    /// at a different reflector with its name and its row unchanged.
    func testConnectingDoesNotOverwriteAnExistingChannel() async {
        let harness = SessionHarness(
            settings: nil, channels: [other, allStar], selectedID: allStar.id)
        harness.session.settings.host = "  moved.example.org "
        harness.session.secret = "hunter2"

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(
            harness.settingsSeen.map(\.host), ["moved.example.org"],
            "the call goes where the form says")
        XCTAssertEqual(
            harness.session.channels.channels.map(\.id), [other.id, allStar.id],
            "no second copy, and no reordering")
        XCTAssertEqual(
            harness.session.channels.channels[1].host, allStar.host,
            "the stored channel is untouched")
        XCTAssertEqual(harness.settingsStore.savedChannels?[1].host, allStar.host)
        XCTAssertEqual(
            harness.settingsStore.savedDrafts[allStar.id]?.host, "moved.example.org",
            "the edit is kept as a draft — validated, since that is what went on the air")
    }

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

    // MARK: - Saving and reordering

    /// Saving the draft is unvalidated on purpose: it happens as the operator
    /// moves around the app, and refusing to remember a half-typed host would
    /// lose their typing every time they looked at another pane.
    func testSavingTheDraftKeepsHalfTypedFields() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        harness.session.settings.host = "half-ty"

        harness.session.saveDraft()

        XCTAssertEqual(harness.settingsStore.savedChannels?.first?.host, "half-ty")
        XCTAssertNil(harness.session.alert, "saving a draft is not a validation gate")
    }

    // MARK: - Choosing from a directory

    /// **The bug this exists to prevent.** Browsing used to save a channel per
    /// tap, so reading the modules on six reflectors left six channels behind
    /// and tapping one twice left two copies of it.
    func testChoosingFromADirectorySavesNothing() {
        let harness = SessionHarness(settings: nil, channels: [], selectedID: nil)

        let chosen = M17Reflector.fake(designator: "M17-432", host: "m17-432.example.org")
            .channel(module: "H", basedOn: harness.session.settings)
        XCTAssertTrue(harness.session.chooseChannel(chosen))

        XCTAssertEqual(harness.session.settings.host, "m17-432.example.org")
        XCTAssertEqual(harness.session.settings.module, "H")
        XCTAssertTrue(
            harness.session.channels.channels.isEmpty,
            "looking around must not leave a channel behind")
    }

    /// Six taps, no channels. The draft simply follows the last one.
    func testBrowsingSeveralReflectorsLeavesNothingBehind() {
        let harness = SessionHarness(settings: nil, channels: [], selectedID: nil)

        for letter in ["A", "B", "C", "D", "E", "H"] {
            let reflector = M17Reflector.fake(designator: "M17-432")
            harness.session.chooseChannel(
                reflector.channel(module: letter, basedOn: harness.session.settings))
        }

        XCTAssertTrue(harness.session.channels.channels.isEmpty)
        XCTAssertEqual(harness.session.settings.module, "H")
    }

    /// Connecting is what saves it — the channel list means "places I have
    /// been", which is the definition that stays useful.
    func testConnectingSavesTheChosenChannel() async {
        let harness = SessionHarness(settings: nil, channels: [], selectedID: nil)
        harness.session.chooseChannel(SessionHarness.goodSettings)

        await harness.session.connect()

        XCTAssertEqual(harness.session.channels.channels.count, 1)
        XCTAssertEqual(harness.settingsStore.savedChannels?.count, 1)
    }

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

    /// Unsaved edits to a real channel must survive being pointed elsewhere —
    /// and, since BU-9, must not be written into that channel on the way out.
    func testChoosingKeepsUnsavedEditsToTheChannelItLeaves() {
        let existing = SessionHarness.goodSettings
        let harness = SessionHarness(
            settings: nil, channels: [existing], selectedID: existing.id)
        harness.session.settings.name = "Renamed"

        harness.session.chooseChannel(
            M17Reflector.fake(designator: "M17-432").channel(
                module: "H", basedOn: NodeSettings()))

        XCTAssertEqual(
            harness.settingsStore.savedDrafts[existing.id]?.name, "Renamed",
            "what was typed is kept")
        XCTAssertEqual(
            harness.settingsStore.savedChannels?.first?.name, existing.name,
            "and the channel itself is not renamed by being navigated away from")

        // And it is there again on the way back.
        harness.session.select(existing.id)
        XCTAssertEqual(harness.session.settings.name, "Renamed")
    }

    // MARK: - BU-9: the draft is a working copy

    /// **The report, in one test.** Correct a channel's host, quit, come back:
    /// the correction is still in the form, and the channel still describes where
    /// it actually goes. Both halves matter — BU-9 is one fault with two faces,
    /// the edit lost when you wanted it and applied when you did not.
    ///
    /// The relaunch is a second `RadioSession` over the same store and Keychain,
    /// which is the only way to exercise the launch path that chooses between a
    /// stored channel and a stashed draft.
    func testAnEditSurvivesAQuitAndLeavesTheStoredChannelAlone() {
        let first = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        first.session.settings.host = "corrected.example.org"

        // What `RootView`'s scene-phase hook does when the app goes away.
        first.session.stashDraft()

        let second = SessionHarness(reusing: first)

        XCTAssertEqual(
            second.session.settings.host, "corrected.example.org",
            "the correction is still in the form after a relaunch")
        XCTAssertEqual(
            second.session.channels.channels.first?.host, allStar.host,
            "and the stored channel was never overwritten")
        XCTAssertTrue(second.session.isDraftDirty)
        XCTAssertTrue(second.session.hasUnsavedEdits(for: allStar.id))
    }

    /// A draft belonging to no channel — a directory browse — is **not**
    /// restored across a quit, and does not accumulate in the defaults either.
    ///
    /// The limit of the mechanism, written down rather than left to be
    /// discovered: a draft is found again by selecting the channel it belongs
    /// to, and nothing stored says which draft was on screen, so one with no
    /// channel behind it cannot be reached after a relaunch. That is consistent
    /// with the rule browsing already has — looking around leaves nothing
    /// behind — and the launch prunes it rather than keeping an entry no code
    /// can read. A draft made by `Add channel` is a different case and does
    /// survive: adding puts the channel in the list.
    func testADraftBelongingToNoChannelIsPrunedAtLaunch() {
        let first = SessionHarness(settings: nil, channels: [])
        first.session.chooseChannel(
            M17Reflector.fake(designator: "M17-432", host: "m17-432.example.org")
                .channel(module: "H", basedOn: NodeSettings()))
        first.session.stashDraft()
        XCTAssertEqual(first.settingsStore.savedDrafts.count, 1, "kept for this run")

        let second = SessionHarness(reusing: first)

        XCTAssertEqual(second.session.settings.host, "")
        XCTAssertTrue(
            second.session.channels.channels.isEmpty,
            "looking around still leaves nothing behind")
        XCTAssertTrue(
            second.settingsStore.savedDrafts.isEmpty,
            "and nothing unreachable is left in the defaults")
    }

    /// **APP-19 changed this one.** The `Add channel` case used to survive,
    /// because adding put the blank channel in the list — which is exactly the
    /// fault APP-19 fixed. A new channel that is typed into and neither saved
    /// nor connected is now as durable as a reflector picked out of the
    /// directory: it is a draft belonging to no channel, and BU-9 decided those
    /// are dropped at launch.
    ///
    /// The cost is deliberate and it is on screen — "Not saved. Connecting will
    /// add this to your channels" — from the moment there is anything to lose.
    func testAnEditToANewChannelDoesNotSurviveAQuitUnlessItIsSaved() {
        let first = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        first.session.newChannel()
        first.session.settings.host = "half-typed.exam"
        first.session.settings.name = "New one"
        first.session.stashDraft()

        let second = SessionHarness(reusing: first)

        XCTAssertEqual(second.session.channels.channels.map(\.id), [allStar.id])
        XCTAssertEqual(second.session.settings.id, allStar.id, "back on the stored channel")
        XCTAssertTrue(
            second.settingsStore.savedDrafts.isEmpty,
            "and nothing unreachable is left in the defaults")

        // Saved, it is an ordinary channel and survives like one.
        let third = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        third.session.newChannel()
        third.session.settings.host = "half-typed.exam"
        third.session.saveDraft()

        let fourth = SessionHarness(reusing: third)
        XCTAssertEqual(fourth.session.channels.channels.count, 2)
        XCTAssertEqual(fourth.session.channels.channels.last?.host, "half-typed.exam")
    }

    /// Tapping the highlighted row after a directory browse goes back to that
    /// channel. It is the same id as the selection, so the old guard treated it
    /// as a no-op — the one tap in the list that did nothing.
    func testSelectingTheAlreadySelectedChannelReturnsToItAfterABrowse() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        harness.session.chooseChannel(
            M17Reflector.fake(designator: "M17-432", host: "m17-432.example.org")
                .channel(module: "H", basedOn: NodeSettings()))
        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertNotEqual(harness.session.settings.id, allStar.id)

        harness.session.select(allStar.id)

        XCTAssertEqual(harness.session.settings, allStar)
    }

    /// Away and back, within one run. `select(_:)` stashes on the way out and
    /// reads the stash on the way in, so the form is where the operator left it.
    func testAnEditComesBackAfterSelectingAwayAndBack() {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        harness.session.settings.name = "Sunday net"
        harness.session.settings.host = "half-typed.exam"

        harness.session.select(other.id)
        XCTAssertEqual(harness.session.settings, other, "the other channel arrives clean")

        harness.session.select(allStar.id)

        XCTAssertEqual(harness.session.settings.name, "Sunday net")
        XCTAssertEqual(harness.session.settings.host, "half-typed.exam")
        XCTAssertEqual(
            harness.session.channels.channels.first, allStar,
            "and none of that reached the list")
    }

    /// **Save is the only path that changes a stored channel.** Everything else
    /// an operator can do while a draft is dirty is tried here first, and the
    /// stored channel is the same after all of them.
    func testOnlySavingChangesAStoredChannel() async {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        harness.session.settings.host = "moved.example.org"
        harness.session.secret = "hunter2"

        harness.session.stashDraft()
        harness.session.select(other.id)
        harness.session.select(allStar.id)
        harness.session.chooseChannel(other)
        harness.session.select(allStar.id)
        harness.session.newChannel()
        harness.session.select(allStar.id)
        await harness.session.connect()
        await harness.session.disconnect()
        harness.session.restoreLastConnectedChannel()

        XCTAssertEqual(
            harness.session.channels.channels.first, allStar,
            "not one of those may write an edit into a channel")
        XCTAssertEqual(harness.settingsStore.savedChannels?.first, allStar)

        harness.session.select(allStar.id)
        harness.session.saveDraft()

        XCTAssertEqual(harness.session.channels.channels.first?.host, "moved.example.org")
        XCTAssertEqual(harness.settingsStore.savedChannels?.first?.host, "moved.example.org")
    }

    /// Saving drops the pending draft with it: there is no longer a difference
    /// to remember, and a leftover entry would leave the list marking a row that
    /// matches what the form shows.
    func testSavingClearsThePendingDraft() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        harness.session.settings.host = "moved.example.org"
        harness.session.stashDraft()
        XCTAssertEqual(harness.settingsStore.savedDrafts.count, 1)

        harness.session.saveDraft()

        XCTAssertTrue(harness.settingsStore.savedDrafts.isEmpty)
        XCTAssertFalse(harness.session.isDraftDirty)
        XCTAssertFalse(harness.session.hasUnsavedEdits(for: allStar.id))
    }

    /// Saving a draft that is in no channel **adds** it. Save is the operator
    /// saying "keep this", and a Save that silently did nothing on a channel
    /// picked out of a directory would be the same class of fault BU-9 reports.
    func testSavingADraftThatIsInNoChannelAddsIt() {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.chooseChannel(
            M17Reflector.fake(designator: "M17-432", host: "m17-432.example.org")
                .channel(module: "H", basedOn: NodeSettings()))

        harness.session.saveDraft()

        XCTAssertEqual(harness.session.channels.channels.count, 1)
        XCTAssertEqual(harness.session.channels.channels.first?.host, "m17-432.example.org")
        XCTAssertEqual(harness.session.channels.selectedID, harness.session.settings.id)
        XCTAssertTrue(harness.settingsStore.savedDrafts.isEmpty)
    }

    /// `Add channel` is a fresh start — which means the edit that was on screen
    /// is neither carried into the new channel nor lost.
    func testANewChannelGivesABlankDraftAndKeepsThePreviousEdit() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        harness.session.settings.host = "half-typed.exam"

        let added = harness.session.newChannel()

        XCTAssertNotNil(added)
        XCTAssertEqual(harness.session.settings.host, "", "a blank form to fill in")
        XCTAssertEqual(harness.session.settings.name, "")
        XCTAssertEqual(
            harness.session.channels.channels.first, allStar,
            "and the channel that was on screen is unchanged")
        XCTAssertEqual(
            harness.settingsStore.savedDrafts[allStar.id]?.host, "half-typed.exam",
            "with its edit kept")
    }

    /// An untouched blank form is not an unsaved change. The app opens on one
    /// when there are no channels at all, and an indicator that is lit on a form
    /// nobody has typed into is an indicator nobody reads.
    func testABlankFormIsNotDirty() {
        let harness = SessionHarness(settings: nil, channels: [])

        XCTAssertFalse(harness.session.isDraftDirty)

        harness.session.settings.host = "a"
        XCTAssertTrue(harness.session.isDraftDirty)
    }

    /// A draft equal to its channel is not dirty either, so typing something and
    /// undoing it puts the indicator out — and clears the stash rather than
    /// leaving a draft that says nothing.
    func testUndoingAnEditClearsTheDirtyState() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        harness.session.settings.host = "typo.example.org"
        harness.session.stashDraft()
        XCTAssertEqual(harness.settingsStore.savedDrafts.count, 1)

        harness.session.settings.host = allStar.host
        XCTAssertFalse(harness.session.isDraftDirty)

        harness.session.stashDraft()
        XCTAssertTrue(harness.settingsStore.savedDrafts.isEmpty)
    }

    /// The list marks the row an edit belongs to, and only that row: the whole
    /// point of the marker is that the row is describing the *stored* channel.
    func testTheListKnowsWhichRowHasUnsavedEdits() {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        harness.session.settings.host = "moved.example.org"

        XCTAssertTrue(harness.session.hasUnsavedEdits(for: allStar.id))
        XCTAssertFalse(harness.session.hasUnsavedEdits(for: other.id))

        // Still marked once the operator has moved to a different channel — that
        // is exactly when they cannot see it in the form.
        harness.session.select(other.id)
        XCTAssertTrue(harness.session.hasUnsavedEdits(for: allStar.id))
        XCTAssertFalse(harness.session.hasUnsavedEdits(for: other.id))
    }

    /// A pending draft is dropped with the channel it belongs to. It is only ever
    /// reached by selecting that channel, so one for a channel that no longer
    /// exists could never surface again — and deleting is the operator saying
    /// they do not want it, unsaved edits included.
    func testDeletingAChannelDropsItsPendingDraft() {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        harness.session.settings.host = "moved.example.org"
        harness.session.select(other.id)
        XCTAssertEqual(harness.settingsStore.savedDrafts.count, 1)

        harness.session.deleteChannel(allStar.id)

        XCTAssertTrue(harness.settingsStore.savedDrafts.isEmpty)
        XCTAssertFalse(harness.session.hasUnsavedEdits(for: allStar.id))
    }

    /// Connecting to a draft that is not in the list clears the draft with it —
    /// the list now holds what it said, so there is nothing left over to mark a
    /// row with.
    func testConnectingToANewChannelClearsItsDraft() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = allStar
        harness.session.secret = "hunter2"
        harness.session.stashDraft()

        await harness.session.connect()

        XCTAssertEqual(harness.session.channels.channels, [allStar])
        XCTAssertTrue(harness.settingsStore.savedDrafts.isEmpty)
        XCTAssertFalse(harness.session.isDraftDirty)
    }

    /// Connecting normalises what it dials — `validated()` trims and uppercases
    /// — so the channel it adds is the *trimmed* one. If the draft kept the raw
    /// text it would differ from the channel by whitespace alone, and the app
    /// would report unsaved edits on a channel the operator had just made by
    /// connecting to it. Claiming an edit nobody made is the same class of lie
    /// as BU-9 itself.
    func testConnectingLeavesNoEditsClaimedOverWhitespaceAlone() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = NodeSettings(
            name: "  Sunday net  ", mode: .m17, host: "  m17.example.org  ", module: "a")
        harness.session.secret = "hunter2"

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.session.channels.channels.first?.host, "m17.example.org")
        XCTAssertEqual(harness.session.channels.channels.first?.module, "A")
        XCTAssertFalse(
            harness.session.isDraftDirty,
            "the form claims unsaved edits over trimming the operator never did")
        XCTAssertTrue(harness.settingsStore.savedDrafts.isEmpty)
    }

    /// The form has to describe the rule correctly in both directions, and the
    /// two directions are opposite: connecting *adds* a draft that is in no
    /// channel, and *does not touch* one that is.
    func testTheDraftKnowsWhetherItIsInTheChannelListAtAll() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        XCTAssertFalse(
            harness.session.isDraftAnUnsavedChannel, "a stored channel is in the list")

        harness.session.settings.host = "half-typed.exam"
        XCTAssertFalse(
            harness.session.isDraftAnUnsavedChannel,
            "editing a stored channel does not make it a new one — its id is unchanged")

        XCTAssertTrue(harness.session.chooseChannel(other))
        XCTAssertTrue(
            harness.session.isDraftAnUnsavedChannel,
            "a directory browse points the draft somewhere the list does not hold")

        harness.session.saveDraft()
        XCTAssertFalse(harness.session.isDraftAnUnsavedChannel, "and saving puts it there")
    }

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
