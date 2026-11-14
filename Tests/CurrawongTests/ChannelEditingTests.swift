// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-42.** How a channel comes to exist and how it is edited: first run
/// asks for the callsign, `Add channel` and a directory choice put a channel in
/// the list, and an edit to a channel is saved as it is made.
///
/// Every one of these runs against ``FakeNetworkClient``. No socket, no node.
@MainActor
final class ChannelEditingTests: XCTestCase {
    private var allStar: NodeSettings { SessionHarness.goodSettings }
    private var other: NodeSettings { SessionHarness.otherSettings }
    private var echo: NodeSettings { SessionHarness.echoLinkSettings }

    private var reflector: NodeSettings {
        M17Reflector.fake(designator: "M17-CBR", host: "m17-cbr.example.org")
            .channel(module: "A", basedOn: .blank(for: .m17))
    }

    // MARK: - First run

    func testALaunchWithNoCallsignAsksForOne() {
        let harness = SessionHarness(settings: nil, channels: [], identity: nil)

        XCTAssertTrue(harness.session.needsCallsign)
    }

    func testALaunchWithACallsignDoesNotAsk() {
        let harness = SessionHarness()

        XCTAssertFalse(harness.session.needsCallsign)
    }

    func testGivingACallsignStoresItNormalisedAndStopsAsking() {
        let harness = SessionHarness(settings: nil, channels: [], identity: nil)

        harness.session.setCallsign(" vk1abc ")

        XCTAssertFalse(harness.session.needsCallsign)
        XCTAssertEqual(harness.session.identity.callsign, "VK1ABC")
        XCTAssertEqual(harness.settingsStore.loadIdentity()?.callsign, "VK1ABC")
    }

    func testAnEmptyCallsignIsNotAnAnswer() {
        let harness = SessionHarness(settings: nil, channels: [], identity: nil)

        harness.session.setCallsign("   ")

        XCTAssertTrue(harness.session.needsCallsign)
    }

    /// The Keychain outlives a deleted app, so the credentials filed under a
    /// callsign are looked for once the callsign is known. Without this the
    /// add flow asks a returning operator for a password the app already has.
    func testGivingACallsignFindsTheCredentialsFiledUnderIt() {
        let returning = OperatorIdentity(callsign: "VK1ABC")
        let harness = SessionHarness(
            settings: nil, channels: [],
            secrets: [
                NodeSettings.echoLinkAccount(for: returning): "account-password",
                NodeSettings.webTransceiverAccount(for: returning): "1b59df18107e",
            ],
            identity: nil)
        XCTAssertEqual(harness.session.echoLinkAccountPassword, "", "precondition")

        harness.session.setCallsign("vk1abc")

        XCTAssertEqual(harness.session.echoLinkAccountPassword, "account-password")
        XCTAssertEqual(harness.session.webTransceiverToken, "1b59df18107e")
    }

    /// Clearing the field in Settings is an edit in progress, not a first run.
    func testEmptyingTheCallsignLaterDoesNotAskAgain() {
        let harness = SessionHarness()

        harness.session.identity.callsign = ""

        XCTAssertFalse(harness.session.needsCallsign)
    }

    func testTheIdentityIsSavedAsItIsEdited() {
        let harness = SessionHarness()

        harness.session.identity.location = "Canberra"

        XCTAssertEqual(harness.settingsStore.loadIdentity()?.location, "Canberra")
    }

    // MARK: - Edits are saved as they are made

    func testAnEditToTheSelectedChannelIsSavedAtOnce() {
        let harness = SessionHarness(
            settings: nil, channels: [other, allStar], selectedID: allStar.id)

        harness.session.settings.name = "Sunday net"

        XCTAssertEqual(harness.session.channels.channels[1].name, "Sunday net")
        XCTAssertEqual(harness.settingsStore.savedChannels?[1].name, "Sunday net")
        XCTAssertEqual(
            harness.session.channels.channels.map(\.id), [other.id, allStar.id],
            "no second copy, and no reordering")
    }

    /// Saved as typed: a half-typed host is kept, and ``RadioSession/connect()``
    /// is where it is judged.
    func testAHalfTypedEditIsSavedAsTyped() {
        let harness = SessionHarness()

        harness.session.settings.host = "node.exam"
        harness.session.settings.node = ""

        XCTAssertEqual(harness.settingsStore.savedChannels?.first?.host, "node.exam")
        XCTAssertEqual(harness.settingsStore.savedChannels?.first?.node, "")
    }

    func testAnEditSurvivesAQuit() {
        let first = SessionHarness()
        first.session.settings.host = "moved.example.org"

        let second = SessionHarness(reusing: first)

        XCTAssertEqual(second.session.settings.host, "moved.example.org")
        XCTAssertEqual(second.session.channels.channels.map(\.host), ["moved.example.org"])
    }

    func testAnEditStaysWithItsChannelWhenAnotherIsSelected() {
        let harness = SessionHarness(
            settings: nil, channels: [other, allStar], selectedID: allStar.id)
        harness.session.settings.host = "moved.example.org"

        harness.session.select(other.id)

        XCTAssertEqual(harness.session.settings, other, "the other channel is untouched")
        XCTAssertEqual(harness.session.channels.channels[1].host, "moved.example.org")
    }

    /// The form shows a blank channel when the list is empty. Typing into it
    /// must not conjure a channel; `Add channel` is how one is made.
    func testEditingWithNoChannelsAddsNothing() {
        let harness = SessionHarness(settings: nil, channels: [])
        XCTAssertFalse(harness.session.isShowingStoredChannel)

        harness.session.settings.host = "node.example.org"

        XCTAssertTrue(harness.session.channels.channels.isEmpty)
    }

    func testConnectingSavesTheValidatedForm() async {
        let harness = SessionHarness(
            settings: nil, channels: [other, allStar], selectedID: allStar.id)
        harness.session.settings.host = "  moved.example.org "
        harness.session.secret = "hunter2"

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.settingsSeen.map(\.host), ["moved.example.org"])
        XCTAssertEqual(harness.settingsStore.savedChannels?[1].host, "moved.example.org")
        XCTAssertEqual(harness.session.channels.channels.count, 2)
    }

    /// The one way the form shows a channel that is not in the list: the last
    /// connected channel, deleted since, brought back to reconnect to.
    func testReconnectingToADeletedChannelPutsItBack() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.session.disconnect()
        harness.session.deleteChannel(allStar.id)
        XCTAssertTrue(harness.session.channels.channels.isEmpty, "precondition")

        XCTAssertTrue(harness.session.restoreLastConnectedChannel())
        await harness.session.connect()

        XCTAssertEqual(harness.session.channels.channels.map(\.id), [allStar.id])
    }

    // MARK: - Adding

    func testAddingPutsTheChannelInTheListSelectedAndInTheForm() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)

        let id = harness.session.addChannel(other)

        XCTAssertEqual(id, other.id)
        XCTAssertEqual(harness.session.channels.channels.map(\.id), [allStar.id, other.id])
        XCTAssertEqual(harness.session.channels.selectedID, other.id)
        XCTAssertEqual(harness.session.settings, other)
        XCTAssertTrue(harness.session.isShowingStoredChannel)
        XCTAssertEqual(harness.settingsStore.savedChannels?.map(\.id), [allStar.id, other.id])
        XCTAssertEqual(harness.settingsStore.savedSelectedID, other.id)
    }

    func testAddingFilesTheSecretTypedWithIt() {
        let harness = SessionHarness(settings: nil, channels: [])

        harness.session.addChannel(allStar, secret: "hunter2")

        XCTAssertEqual(harness.session.secret, "hunter2")
        XCTAssertEqual(
            try harness.secretStore.secret(
                for: allStar.secretAccount(for: harness.session.identity)),
            "hunter2")
    }

    func testAddingWithNoSecretShowsTheStoredOne() {
        let account = allStar.secretAccount(for: OperatorIdentity(callsign: "VK1XYZ"))
        let harness = SessionHarness(
            settings: nil, channels: [], secrets: [account: "already-there"])

        harness.session.addChannel(allStar)

        XCTAssertEqual(harness.session.secret, "already-there")
    }

    func testAddingIsRefusedWhileConnected() async {
        let harness = SessionHarness()
        await harness.connect()

        XCTAssertNil(harness.session.addChannel(other))

        XCTAssertEqual(harness.session.channels.channels.map(\.id), [allStar.id])
        XCTAssertEqual(harness.session.settings.id, allStar.id)
    }

    // MARK: - Choosing from a directory

    func testChoosingFromADirectoryAddsTheChannel() {
        let harness = SessionHarness(settings: nil, channels: [allStar], selectedID: allStar.id)
        let chosen = reflector

        XCTAssertTrue(harness.session.chooseChannel(chosen))

        XCTAssertEqual(harness.session.channels.channels.map(\.id), [allStar.id, chosen.id])
        XCTAssertEqual(harness.session.channels.selectedID, chosen.id)
        XCTAssertEqual(harness.session.settings, chosen)
        XCTAssertEqual(harness.settingsStore.savedChannels?.last, chosen)
    }

    /// **The done-when of APP-42, at the model:** a callsign and a tap in the
    /// reflector list are enough to connect.
    func testACallsignAndAChosenReflectorAreEnoughToConnect() async {
        let harness = SessionHarness(settings: nil, channels: [], identity: nil)
        harness.session.setCallsign("vk1abc")

        XCTAssertTrue(harness.session.chooseChannel(reflector))
        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertNil(harness.session.alert)
        XCTAssertEqual(harness.settingsSeen.map(\.mode), [.m17])
    }

    /// EchoLink addresses change as stations come and go, so the same callsign
    /// at a new address is the saved channel with a new address.
    func testChoosingAStationThatHasMovedUpdatesItsChannel() {
        var named = echo
        named.name = "The repeater"
        let harness = SessionHarness(settings: nil, channels: [allStar, named], selectedID: allStar.id)

        var moved = NodeSettings.blank(for: .echoLink)
        moved.name = echo.node
        moved.node = echo.node.lowercased()
        moved.peer = "203.0.113.9"

        XCTAssertTrue(harness.session.chooseChannel(moved))

        XCTAssertEqual(harness.session.channels.channels.count, 2, "no second copy")
        XCTAssertEqual(harness.session.channels.selectedID, named.id)
        XCTAssertEqual(harness.session.settings.peer, "203.0.113.9")
        XCTAssertEqual(harness.session.settings.name, "The repeater", "the operator's name is kept")
        XCTAssertEqual(harness.settingsStore.savedChannels?[1].peer, "203.0.113.9")
    }

    // MARK: - Credentials typed and not yet connected with

    func testSelectingAwayFilesTheSecretTypedForTheChannelBeingLeft() {
        let harness = SessionHarness(
            settings: nil, channels: [other, allStar], selectedID: allStar.id)
        harness.session.secret = "typed-not-connected"

        harness.session.select(other.id)
        harness.session.select(allStar.id)

        XCTAssertEqual(harness.session.secret, "typed-not-connected")
    }

    /// `SecretStore` deletes on an empty value, and the account may be shared.
    func testAnEmptySecretFieldNeverDeletesAStoredSecret() {
        let account = allStar.secretAccount(for: OperatorIdentity(callsign: "VK1XYZ"))
        let harness = SessionHarness(secrets: [account: "hunter2"])
        harness.session.secret = ""

        harness.session.persistCredentials()

        XCTAssertEqual(try harness.secretStore.secret(for: account), "hunter2")
    }

    // MARK: - The directory request

    /// The station list is read before any EchoLink channel exists, so it
    /// cannot depend on the selected channel being one.
    func testTheDirectoryRequestDoesNotNeedAnEchoLinkChannel() {
        let harness = SessionHarness()

        let request = harness.session.directoryRequest

        XCTAssertEqual(request.settings.mode, .echoLink)
        XCTAssertEqual(request.settings.directoryServer, NodeSettings.defaultDirectoryServer)
    }

    func testTheDirectoryRequestKeepsAnEchoLinkChannelsOwnServer() {
        let harness = SessionHarness(settings: nil, channels: [echo], selectedID: echo.id)

        XCTAssertEqual(harness.session.directoryRequest.settings.directoryServer, "192.0.2.1")
    }

    // MARK: - A new channel's shape

    func testABlankChannelCarriesItsNetworksDefaults() {
        for mode in RadioMode.allCases {
            let blank = NodeSettings.blank(for: mode)
            XCTAssertEqual(blank.mode, mode)
            XCTAssertEqual(blank.port, mode.defaultPort)
            XCTAssertFalse(blank.hasDestination, "\(mode) starts with nowhere to go")
        }
        XCTAssertEqual(
            NodeSettings.blank(for: .echoLink).directoryServer,
            NodeSettings.defaultDirectoryServer,
            "blank would mean no directory login")
        XCTAssertEqual(NodeSettings.blank(for: .m17).directoryServer, "")
    }

    func testAChannelHasADestinationOnceItSaysWhereItGoes() {
        var node = NodeSettings.blank(for: .allStarLink)
        node.node = "55553"
        XCTAssertTrue(node.hasDestination)

        var m17 = NodeSettings.blank(for: .m17)
        m17.module = "A"
        XCTAssertFalse(m17.hasDestination, "a module with no reflector goes nowhere")
        m17.host = " "
        XCTAssertFalse(m17.hasDestination)
        m17.host = "m17-cbr.example.org"
        XCTAssertTrue(m17.hasDestination)
    }

    // MARK: - What the list calls a channel

    func testAnEmptyChannelIsCalledNewChannelInTheList() {
        XCTAssertEqual(NodeSettings().listDisplayName, "New channel")
    }

    func testANamedChannelKeepsItsName() {
        var settings = NodeSettings()
        settings.name = "Sunday net"
        XCTAssertEqual(settings.listDisplayName, "Sunday net")
    }

    /// A channel with no name but a destination is described by where it goes.
    func testAnUnnamedChannelWithAHostIsStillDescribedByIt() {
        XCTAssertEqual(allStar.listDisplayName, "55553 at node.example.org")
    }
}
