// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// APP-11 — Web Transceiver: reaching a node with nothing but an
/// allstarlink.org portal account.
///
/// The parameter mapping is the substance here. Four of the five values a WT
/// call presents are not what anyone would guess — a shared guest username, a
/// static secret, the start extension instead of the node number, and the node
/// number carried in CALLING NUMBER instead — and every one was established by
/// observation against a live node (IAX-12, `swift-hamvoip/docs/CLI.md` §11.2).
/// Nothing here can be checked against a document, so it is pinned against a
/// test.
///
/// Deliberately no `import IAX2Kit`, as with `CompositionRootTests`:
/// `CompositionRoot.webTransceiverCall` describes the call in the app's own
/// vocabulary so this file stays under the same constraint the app is.
@MainActor
final class WebTransceiverTests: XCTestCase {
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")
    private let token = "1b59df18107e"

    private func wtChannel() -> NodeSettings {
        NodeSettings(
            name: "Guest to 55553",
            host: "node.example.org",
            port: 4569,
            node: "55553",
            allStarAccess: .webTransceiver)
    }

    // MARK: - The channel

    func testWebTransceiverIsAnAllStarLinkRouteAndNotAFourthMode() {
        XCTAssertEqual(RadioMode.allCases.count, 3)
        XCTAssertTrue(wtChannel().usesWebTransceiver)
        XCTAssertEqual(wtChannel().mode, .allStarLink)
    }

    /// The flag cannot mean anything in a mode that has no such route, so a
    /// channel switched to M17 with the access left behind is just an M17
    /// channel.
    func testTheAccessFlagIsIgnoredOutsideAllStarLink() {
        var settings = wtChannel()
        settings.mode = .m17
        XCTAssertFalse(settings.usesWebTransceiver)
    }

    /// The migration: every channel saved before this existed is a node-secret
    /// channel rather than an undecodable one.
    func testAChannelSavedBeforeWebTransceiverDecodesAsNodeSecret() throws {
        let json = """
            {"host":"node.example.org","port":4569,"node":"55553","username":"vk1xyz"}
            """
        let decoded = try JSONDecoder().decode(NodeSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.allStarAccess, .nodeSecret)
        XCTAssertFalse(decoded.usesWebTransceiver)
    }

    /// The same node reached two ways is two channels: they carry different
    /// credentials, so collapsing them would let a browse re-point a working
    /// node-secret channel at the guest account.
    func testTheSameNodeReachedTwoWaysIsTwoChannels() {
        var direct = wtChannel()
        direct.allStarAccess = .nodeSecret

        XCTAssertFalse(wtChannel().isSamePlace(as: direct))
        XCTAssertTrue(wtChannel().isSamePlace(as: wtChannel()))
    }

    /// One token per operator, not per channel: it resolves to their callsign on
    /// any WT-enabled node, so two WT channels share a Keychain slot and neither
    /// shares the slot that holds a node secret.
    func testTheTokenIsFiledUnderTheCallsignAndNotWithAnyNodeSecret() {
        let other = NodeSettings(
            host: "other.example.org", node: "12345", allStarAccess: .webTransceiver)

        XCTAssertEqual(
            wtChannel().webTransceiverAccount(for: vk1xyz),
            other.webTransceiverAccount(for: vk1xyz))
        XCTAssertNotEqual(
            wtChannel().webTransceiverAccount(for: vk1xyz),
            wtChannel().secretAccount(for: vk1xyz))
        XCTAssertEqual(
            wtChannel().webTransceiverAccount(for: OperatorIdentity(callsign: "vk1xyz")),
            wtChannel().webTransceiverAccount(for: vk1xyz),
            "normalised, so a lower-case callsign finds the token it stored")
    }

    /// Advisory, never a gate — the endpoint that issues tokens is expected to be
    /// replaced, and only the node decides whether a token works.
    func testTokenPlausibilityIsAShapeCheckIncludingCase() {
        XCTAssertTrue(NodeSettings.isPlausibleWebTransceiverToken(token))
        XCTAssertTrue(NodeSettings.isPlausibleWebTransceiverToken(" \(token) "))
        XCTAssertFalse(NodeSettings.isPlausibleWebTransceiverToken("1B59DF18107E"))
        XCTAssertFalse(NodeSettings.isPlausibleWebTransceiverToken("1b59df1810"))
        XCTAssertFalse(NodeSettings.isPlausibleWebTransceiverToken(""))
    }

    // MARK: - The call the node sees

    /// The whole observed mapping, in one assertion. If AllStarLink changes any
    /// of it, this is the test that should fail.
    func testTheGuestCallPresentsTheObservedParameters() throws {
        let call = try XCTUnwrap(
            CompositionRoot.webTransceiverCall(
                settings: wtChannel(),
                identity: vk1xyz,
                credentials: .init(webTransceiverToken: token)))

        XCTAssertEqual(call.username, "allstar-public", "a shared guest account, not the callsign")
        XCTAssertEqual(call.secret, "allstar", "static, ships in every node's iax.conf")
        XCTAssertEqual(call.dialledExtension, "s", "the start extension; never the node number")
        XCTAssertEqual(call.callingNumber, "55553", "CALLING NUMBER selects the node")
        XCTAssertEqual(call.callingName, token, "CALLING NAME is the identity proof")
        XCTAssertEqual(call.callsign, "VK1XYZ")
    }

    /// The mistake this rules out is the expensive one: `callsign` is upper-cased
    /// on the way out, so a token routed through it would reach the node
    /// corrupted and the call would be refused for no visible reason.
    func testTheTokenIsNotUpperCasedOnTheWayOut() throws {
        let call = try XCTUnwrap(
            CompositionRoot.webTransceiverCall(
                settings: wtChannel(),
                identity: OperatorIdentity(callsign: "vk1xyz"),
                credentials: .init(webTransceiverToken: token)))

        XCTAssertEqual(call.callingName, token)
        XCTAssertNotEqual(call.callingName, token.uppercased())
    }

    /// The node secret never reaches a WT call, and the token never reaches a
    /// node-secret one.
    func testTheTwoRoutesDoNotBorrowEachOthersCredentials() throws {
        let call = try XCTUnwrap(
            CompositionRoot.webTransceiverCall(
                settings: wtChannel(),
                identity: vk1xyz,
                credentials: .init(secret: "hunter2", webTransceiverToken: token)))
        XCTAssertNotEqual(call.secret, "hunter2")

        var direct = wtChannel()
        direct.allStarAccess = .nodeSecret
        XCTAssertNil(
            CompositionRoot.webTransceiverCall(
                settings: direct, identity: vk1xyz,
                credentials: .init(secret: "hunter2", webTransceiverToken: token)),
            "a node-secret channel is built the way it always was")
    }

    // MARK: - The session

    func testTheTokenReachesTheLinkFactory() async {
        let harness = SessionHarness(settings: wtChannel())
        harness.session.webTransceiverToken = token

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.credentialsSeen.last?.webTransceiverToken, token)
    }

    /// Same class of problem as an empty host: nothing further can succeed, and
    /// the message says which of the two routes the channel is on.
    func testConnectingWithNoTokenIsRefusedWithAMessageAboutTheRoute() async {
        let harness = SessionHarness(settings: wtChannel())
        harness.session.webTransceiverToken = "   "

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.alert?.title, "No Web Transceiver token")
        XCTAssertEqual(harness.linksMade, 0)
    }

    /// A token of an unfamiliar shape is passed on rather than refused: the node
    /// decides, and the form has already said it looks wrong.
    func testAnImplausibleTokenStillConnects() async {
        let harness = SessionHarness(settings: wtChannel())
        harness.session.webTransceiverToken = "not-a-token"

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.credentialsSeen.last?.webTransceiverToken, "not-a-token")
    }

    func testTheTokenIsStoredUnderItsOwnAccountAndComesBackOnRelaunch() async {
        let channel = wtChannel()
        let harness = SessionHarness(settings: channel)
        harness.session.webTransceiverToken = " \(token) "

        await harness.session.connect()

        XCTAssertEqual(
            harness.secretStore.all[channel.webTransceiverAccount(for: vk1xyz)], token,
            "trimmed, and under the callsign's account")
        XCTAssertEqual(harness.session.webTransceiverToken, token)

        // The relaunch: a fresh session over the same stores.
        let relaunched = SessionHarness(
            settings: channel,
            secrets: [channel.webTransceiverAccount(for: vk1xyz): token])
        XCTAssertEqual(relaunched.session.webTransceiverToken, token)
    }

    /// The trap this avoids: an AllStarLink node secret is filed under
    /// `username@host:port/node`, so writing an empty secret while connecting as
    /// a guest would delete the password of the node-secret channel to the same
    /// node.
    func testConnectingAsAGuestDoesNotEraseAStoredNodeSecret() async {
        var direct = wtChannel()
        direct.allStarAccess = .nodeSecret
        direct.username = "vk1xyz"
        var guest = direct
        guest.allStarAccess = .webTransceiver

        let harness = SessionHarness(
            settings: guest,
            secrets: [direct.secretAccount(for: vk1xyz): "hunter2"])
        harness.session.webTransceiverToken = token

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(
            harness.secretStore.all[direct.secretAccount(for: vk1xyz)], "hunter2",
            "the node secret is untouched by a guest connection")
    }

    /// The token is app-wide, so unlike the secret it does not follow the
    /// channel selection.
    func testSelectingAnotherChannelKeepsTheToken() async {
        let guest = wtChannel()
        let other = SessionHarness.otherSettings
        let harness = SessionHarness(
            settings: nil,
            channels: [guest, other],
            selectedID: guest.id,
            secrets: [
                guest.webTransceiverAccount(for: vk1xyz): token,
                other.secretAccount(for: vk1xyz): "hunter2",
            ])
        XCTAssertEqual(harness.session.webTransceiverToken, token)

        harness.session.select(other.id)

        XCTAssertEqual(harness.session.secret, "hunter2", "the secret is per channel")
        XCTAssertEqual(harness.session.webTransceiverToken, token, "the token is not")
    }
}
