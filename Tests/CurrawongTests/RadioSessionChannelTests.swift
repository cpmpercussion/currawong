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
        XCTAssertEqual(harness.session.secret, "account-password")
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

    /// The draft is saved on the way out, so typing in the form and then
    /// switching channels does not lose the typing. Unvalidated on purpose —
    /// `connect()` is where the gate is.
    func testSelectingSavesTheDraftItIsLeaving() {
        let harness = SessionHarness(
            settings: nil, channels: [allStar, other], selectedID: allStar.id)
        harness.session.settings.host = "half-typed.exam"

        harness.session.select(other.id)

        XCTAssertEqual(harness.session.channels.channels.first?.host, "half-typed.exam")
        XCTAssertEqual(harness.settingsStore.savedChannels?.first?.host, "half-typed.exam")
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

    func testSelectingAnUnknownChannelChangesNothing() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        harness.session.select(UUID())

        XCTAssertEqual(harness.session.channels.selectedID, allStar.id)
        XCTAssertEqual(harness.session.settings, allStar)
    }

    // MARK: - Adding

    func testAddingAChannelSelectsItAndPointsTheDraftAtIt() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        let added = harness.session.addChannel(echo)

        XCTAssertEqual(added, echo.id)
        XCTAssertEqual(harness.session.channels.channels.map(\.id), [allStar.id, echo.id])
        XCTAssertEqual(harness.session.settings, echo)
        XCTAssertEqual(harness.settingsStore.savedChannels?.count, 2)
    }

    /// Adding selects, and selecting mid-call is the thing that must not
    /// happen — so adding is refused for the same reason selecting is.
    func testAddingIsRefusedWhileConnected() async {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        await harness.connect()

        XCTAssertNil(harness.session.addChannel(echo))
        XCTAssertEqual(harness.session.channels.channels.count, 1)
    }

    // MARK: - Connecting

    /// **Connecting is what turns a draft into a saved channel.** An operator
    /// who typed a node into an empty app and pressed Connect has said "this is
    /// a place I go"; making them press a separate Save as well would be a
    /// second step for a decision they already made.
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

    /// The other half of it: a channel that is already in the list is updated
    /// in place, not added a second time. The id is what makes that possible,
    /// and `validated()` preserving the id is what makes the id useful.
    func testConnectingUpdatesAnExistingChannelInPlace() async {
        let harness = SessionHarness(
            settings: nil, channels: [other, allStar], selectedID: allStar.id)
        harness.session.settings.host = "  moved.example.org "
        harness.session.secret = "hunter2"

        await harness.session.connect()

        XCTAssertEqual(
            harness.session.channels.channels.map(\.id), [other.id, allStar.id],
            "an edit must not reorder the list")
        XCTAssertEqual(harness.session.channels.channels[1].host, "moved.example.org")
        XCTAssertEqual(harness.settingsStore.savedChannels?[1].host, "moved.example.org")
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
        XCTAssertEqual(harness.session.secret, "account-password")
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

    /// Unsaved edits to a real channel must survive being pointed elsewhere.
    func testChoosingKeepsUnsavedEditsToTheChannelItLeaves() {
        let existing = SessionHarness.goodSettings
        let harness = SessionHarness(
            settings: nil, channels: [existing], selectedID: existing.id)
        harness.session.settings.name = "Renamed"

        harness.session.chooseChannel(
            M17Reflector.fake(designator: "M17-432").channel(
                module: "H", basedOn: NodeSettings()))

        XCTAssertEqual(
            harness.settingsStore.savedChannels?.first?.name, "Renamed",
            "the channel being left keeps what was typed into it")
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
