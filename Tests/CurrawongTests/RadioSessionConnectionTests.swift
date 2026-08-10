// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// The connection half of ``RadioSession``: validation, credentials, connect,
/// disconnect, and the link going away by itself.
///
/// Every one of these runs against ``FakeNetworkClient``. No socket, no node,
/// no simulator interaction.
@MainActor
final class RadioSessionConnectionTests: XCTestCase {

    // MARK: Loading

    func testSettingsAndSecretAreLoadedAtInit() {
        let stored = NodeSettings(
            host: "stored.example.org", port: 4570, node: "1234",
            username: "bob", callsign: "VK1BOB")
        let harness = SessionHarness(
            settings: stored,
            secrets: [stored.secretAccount: "from-the-keychain"])

        XCTAssertEqual(harness.session.settings, stored)
        XCTAssertEqual(harness.session.secret, "from-the-keychain")
    }

    func testAFreshSessionIsDisconnectedAndIdle() {
        let harness = SessionHarness(settings: nil)

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.transmitState, .idle)
        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertNil(harness.session.alert)
    }

    // MARK: Connecting

    func testConnectSucceedsAndPassesTheTypedDetailsThrough() async {
        let harness = SessionHarness()
        harness.session.settings = SessionHarness.goodSettings
        harness.session.secret = "hunter2"

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertNil(harness.session.alert)
        XCTAssertEqual(
            harness.client.calls,
            [
                .connect(
                    FakeNetworkClient.Destination(
                        host: "node.example.org", port: 4569, node: "55553",
                        username: "vk1xyz", callsign: "VK1XYZ", secret: "hunter2"))
            ])
    }

    func testConnectFailurePresentsTheErrorAndStaysDisconnected() async {
        let harness = SessionHarness()
        harness.client.connectError = SessionHarness.ConnectFailed()

        await harness.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertNotNil(harness.session.alert, "a failed connection must not be swallowed")
        XCTAssertEqual(harness.session.alert?.title, "Could not connect")
        XCTAssertTrue(
            harness.session.alert?.message.contains("rejected") == true,
            "the underlying error's own words should reach the operator")
        XCTAssertEqual(harness.closedLinks.value, 1, "a failed connect must release its link")
    }

    func testAFailedConnectCanBeRetried() async {
        let harness = SessionHarness()
        harness.client.connectError = SessionHarness.ConnectFailed()
        await harness.connect()
        XCTAssertEqual(harness.session.connection, .disconnected)

        harness.client.connectError = nil
        harness.session.dismissAlert()
        await harness.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.linksMade, 2, "a second connect needs a second link")
    }

    func testMissingCallsignIsRefusedBeforeAnythingIsDialled() async {
        let harness = SessionHarness(settings: nil)
        harness.session.settings = NodeSettings(host: "node.example.org", node: "55553")

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.alert?.title, "Check the connection details")
        XCTAssertTrue(harness.client.calls.isEmpty, "nothing should have been dialled")
        XCTAssertEqual(harness.linksMade, 0)
    }

    func testMissingHostAndNodeAreRefused() async {
        for settings in [
            NodeSettings(host: "", node: "55553", callsign: "VK1XYZ"),
            NodeSettings(host: "node.example.org", node: "", callsign: "VK1XYZ"),
        ] {
            let harness = SessionHarness(settings: nil)
            harness.session.settings = settings

            await harness.session.connect()

            XCTAssertEqual(harness.session.connection, .disconnected)
            XCTAssertNotNil(harness.session.alert)
            XCTAssertTrue(harness.client.calls.isEmpty)
        }
    }

    /// SF-3's precondition. If the audio session cannot be configured then
    /// nothing can be transmitted or heard, and a connection in that state is
    /// a PTT button that lights up and sends silence.
    func testAudioSessionFailureAbortsTheConnection() async {
        let harness = SessionHarness()
        harness.audio.configureSessionError = SessionHarness.AudioFailed()

        await harness.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.alert?.title, "Audio unavailable")
        XCTAssertTrue(harness.client.calls.isEmpty, "nothing should have been dialled")
    }

    /// The microphone is asked for before the session is configured, because
    /// asking is the only thing that makes iOS show the prompt — and the
    /// capture path cannot ask on its own. See
    /// ``AudioIO/requestRecordPermission()`` for the deadlock this avoids.
    func testTheMicrophoneIsRequestedBeforeTheSessionIsConfigured() async {
        let harness = SessionHarness()

        await harness.connect()

        XCTAssertEqual(harness.audio.recordPermissionRequestCount, 1)
        XCTAssertEqual(harness.audio.configureSessionCount, 1)
    }

    /// A connection whose microphone is denied is a PTT button that lights up
    /// and sends silence — the same failure `testAudioSessionFailureAborts…`
    /// guards, reached a different way.
    func testADeniedMicrophoneAbortsTheConnection() async {
        let harness = SessionHarness()
        harness.audio.recordPermissionGranted = false

        await harness.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.alert?.title, "Microphone access is off")
        XCTAssertTrue(harness.client.calls.isEmpty, "nothing should have been dialled")
        XCTAssertEqual(
            harness.audio.configureSessionCount, 0,
            "the session must not be configured once the microphone is refused")
    }

    func testALinkFactoryFailureIsPresented() async {
        let harness = SessionHarness()
        harness.makeLinkError = SessionHarness.LinkFailed()

        await harness.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertNotNil(harness.session.alert)
        XCTAssertTrue(harness.client.calls.isEmpty)
    }

    func testConnectingTwiceDoesNothingTheSecondTime() async {
        let harness = SessionHarness()
        await harness.connect()
        await harness.connect()

        XCTAssertEqual(harness.linksMade, 1)
        XCTAssertEqual(harness.client.calls.count, 1)
    }

    // MARK: Credentials

    func testTheSecretGoesToTheSecretStoreAndTheSettingsGoToTheSettingsStore() async {
        let harness = SessionHarness()
        await harness.connect()

        XCTAssertEqual(harness.settingsStore.saved, SessionHarness.goodSettings)
        XCTAssertEqual(
            harness.secretStore.all[SessionHarness.goodSettings.secretAccount], "hunter2")
    }

    /// The structural guarantee, not just the behavioural one: the type that
    /// gets persisted has no secret field, so there is no encoding of it that
    /// could contain a password.
    func testPersistedSettingsCannotContainTheSecret() throws {
        let settings = SessionHarness.goodSettings
        let encoded = try JSONEncoder().encode(settings)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.lowercased().contains("secret"))
        XCTAssertFalse(text.contains("hunter2"))
    }

    func testAFailedSecretWriteIsReportedButDoesNotBlockTheCall() async {
        let harness = SessionHarness()
        harness.secretStore.failWrites = true

        await harness.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertEqual(harness.session.alert?.title, "Could not save the secret")
    }

    func testSettingsAreTrimmedAndTheCallsignIsUppercasedBeforeUse() async {
        let harness = SessionHarness(settings: nil)
        harness.session.settings = NodeSettings(
            host: "  node.example.org ", port: 0, node: " 55553 ",
            username: " vk1xyz ", callsign: " vk1xyz ")

        await harness.session.connect()

        XCTAssertEqual(harness.session.settings.host, "node.example.org")
        XCTAssertEqual(harness.session.settings.callsign, "VK1XYZ")
        XCTAssertEqual(harness.session.settings.port, NodeSettings.defaultPort)
    }

    // MARK: Disconnecting

    func testDisconnectReturnsEverythingToRest() async {
        let harness = SessionHarness()
        await harness.connect()

        await harness.session.disconnect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.transmitState, .idle)
        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertTrue(harness.client.calls.contains(.disconnect))
        XCTAssertEqual(harness.closedLinks.value, 1)
    }

    func testDisconnectingWhenNotConnectedDoesNothing() async {
        let harness = SessionHarness()

        await harness.session.disconnect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertTrue(harness.client.calls.isEmpty)
    }

    func testToggleConnects_thenDisconnects() async {
        let harness = SessionHarness()
        harness.session.settings = SessionHarness.goodSettings

        await harness.session.toggleConnection()
        XCTAssertEqual(harness.session.connection, .connected)

        await harness.session.toggleConnection()
        XCTAssertEqual(harness.session.connection, .disconnected)
    }

    // MARK: The far end leaving

    func testARemoteDisconnectTearsDownAndTellsTheOperator() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.eventContinuation.yield(.disconnected(reason: "The node ended the call."))

        await waitUntil("the session notices the link went away") {
            harness.session.connection == .disconnected
        }
        XCTAssertEqual(harness.session.alert?.title, "Disconnected")
        XCTAssertEqual(harness.session.lastDisconnectReason, "The node ended the call.")
        XCTAssertEqual(harness.session.transmitState, .idle)
    }

    func testTheEventStreamFinishingAlsoTearsDown() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.eventContinuation.finish()

        await waitUntil("the session notices the event stream ended") {
            harness.session.connection == .disconnected
        }
        XCTAssertNotNil(harness.session.alert)
    }

    func testAMediaRejectionIsSurfacedRatherThanSwallowed() async {
        let harness = SessionHarness()
        await harness.connect()

        harness.eventContinuation.yield(.mediaRejected("Incoming audio is being dropped: bad codec."))

        await waitUntil("the media warning appears") {
            harness.session.mediaWarning != nil
        }
        XCTAssertEqual(
            harness.session.mediaWarning, "Incoming audio is being dropped: bad codec.")
    }

    // MARK: Received audio

    func testReceivedAudioIsPlayedAndShowsAsActivity() async throws {
        let harness = SessionHarness()
        await harness.connect()

        harness.audioContinuation.yield(Array(repeating: Int16(7), count: 160))

        await waitUntil("received audio reaches the speaker") {
            !harness.audio.playedFrames.isEmpty
        }
        XCTAssertEqual(harness.audio.playedFrames.first?.count, 160)

        await waitUntil("received audio is noted as activity") {
            harness.session.lastReceivedAudioAt != nil
        }
        let arrival = try XCTUnwrap(harness.session.lastReceivedAudioAt)
        XCTAssertTrue(harness.session.isReceivingAudio(asOf: arrival))
        XCTAssertFalse(
            harness.session.isReceivingAudio(asOf: arrival.addingTimeInterval(5)),
            "the indicator must go out when audio stops arriving")
    }

    func testNoReceivedAudioMeansNoActivity() {
        let harness = SessionHarness()
        XCTAssertFalse(harness.session.isReceivingAudio(asOf: Date()))
    }
}
