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
    /// The operator. App-wide now, rather than a settings field.
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")


    // MARK: Loading

    func testSettingsAndSecretAreLoadedAtInit() {
        let stored = NodeSettings(
            host: "stored.example.org", port: 4570, node: "1234",
            username: "bob")
        let harness = SessionHarness(
            settings: stored,
            secrets: [stored.secretAccount(for: vk1xyz): "from-the-keychain"])

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

    /// The callsign is app-wide now, so a missing one is refused as a problem
    /// with the operator rather than with the channel — and the alert says so,
    /// because sending somebody to the channel's fields to fix a setting that is
    /// not there is worse than saying nothing.
    func testMissingCallsignIsRefusedBeforeAnythingIsDialled() async {
        let harness = SessionHarness(settings: nil, identity: nil)
        harness.session.settings = NodeSettings(host: "node.example.org", node: "55553")

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.alert?.title, "Check your callsign")
        XCTAssertTrue(harness.client.calls.isEmpty, "nothing should have been dialled")
        XCTAssertEqual(harness.linksMade, 0)
    }

    /// The identity is checked *before* the channel, because it is wrong for
    /// every channel rather than for this one. A form with both problems must
    /// report the callsign, or the operator fixes the host and is refused again.
    func testTheCallsignIsReportedBeforeAChannelProblem() async {
        let harness = SessionHarness(settings: nil, identity: nil)
        harness.session.settings = NodeSettings(host: "", node: "")

        await harness.session.connect()

        XCTAssertEqual(harness.session.alert?.title, "Check your callsign")
    }

    /// The app-wide callsign is what reaches the library, in every mode. If
    /// this regressed, an operator would transmit under a callsign from
    /// whichever channel happened to be selected — or under none at all.
    func testTheAppWideCallsignIsWhatReachesTheLibrary() async {
        let harness = SessionHarness(settings: nil)
        harness.session.settings = SessionHarness.goodSettings
        harness.session.identity = OperatorIdentity(callsign: "VK1ABC")

        await harness.session.connect()

        XCTAssertEqual(harness.identitiesSeen.map(\.callsign), ["VK1ABC"])
    }

    /// Persisted on connect, so it is there on the next launch.
    func testConnectingStoresTheCallsign() async {
        let harness = SessionHarness(settings: nil)
        harness.session.settings = SessionHarness.goodSettings
        harness.session.identity = OperatorIdentity(callsign: " vk1abc ")

        await harness.session.connect()

        XCTAssertEqual(
            harness.settingsStore.savedIdentity, OperatorIdentity(callsign: "VK1ABC"),
            "stored in the form that went on the air, not as typed")
    }

    /// And persisted without connecting, so a callsign typed and then left
    /// alone is not lost. Stored as typed here — validation happens at connect.
    func testSavingTheDraftStoresTheCallsign() {
        let harness = SessionHarness(settings: nil)
        harness.session.identity = OperatorIdentity(callsign: "vk1abc")

        harness.session.saveDraft()

        XCTAssertEqual(harness.settingsStore.savedIdentity?.callsign, "vk1abc")
    }

    /// The EchoLink secret is filed under `echolink:<callsign>`, so the
    /// identity has to be loaded before the secret is looked up. Loading it
    /// after would search for `echolink:` with nothing after the colon and come
    /// back empty — an operator whose stored password had apparently vanished.
    func testTheStoredSecretIsFoundUsingTheStoredCallsign() {
        let echoLink = SessionHarness.echoLinkSettings
        let identity = OperatorIdentity(callsign: "VK1XYZ")
        let harness = SessionHarness(
            settings: echoLink,
            secrets: [echoLink.secretAccount(for: identity): "account-password"],
            identity: identity)

        XCTAssertEqual(harness.session.identity, identity)
        XCTAssertEqual(harness.session.secret, "account-password")
    }

    func testMissingHostAndNodeAreRefused() async {
        for settings in [
            NodeSettings(host: "", node: "55553"),
            NodeSettings(host: "node.example.org", node: ""),
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
            harness.secretStore.all[SessionHarness.goodSettings.secretAccount(for: vk1xyz)],
            "hunter2")
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

    /// One attempt can raise two alerts, and the second must survive the first.
    ///
    /// This is the macOS bug that made it worth fixing: without the Keychain
    /// entitlement the secret write failed, `connect()` warned and carried on
    /// as designed, and then the connection failed for its own reasons — and
    /// the operator was shown only the harmless warning. "It says the secret
    /// wasn't stored, and then doesn't connect", with nothing on screen saying
    /// why.
    func testASecondAlertWaitsBehindTheFirstRatherThanBeingLost() async {
        let harness = SessionHarness()
        harness.secretStore.failWrites = true
        harness.client.connectError = SessionHarness.ConnectFailed()

        await harness.connect()

        XCTAssertEqual(harness.session.connection, .disconnected)
        XCTAssertEqual(harness.session.alert?.title, "Could not save the secret")

        harness.session.dismissAlert()

        XCTAssertEqual(
            harness.session.alert?.title, "Could not connect",
            "the reason the call failed must not be swallowed by the warning before it")
        XCTAssertTrue(harness.session.alert?.message.contains("rejected") == true)
    }

    /// Retrying something that fails the same way must not build a stack of
    /// identical alerts to dismiss one at a time.
    ///
    /// Asserting on what is *not* behind the first alert, rather than on the
    /// queue being empty. A torn-down link can deliver its loss event while the
    /// next attempt is still `.connecting`, which raises a "Disconnected" that
    /// is legitimately queued — a race in the harness rather than a fault, but
    /// one that made the empty-queue version of this test fail on CI and pass
    /// here. What this test is about is the duplicate, so that is what it looks
    /// at.
    func testTheSameAlertRaisedTwiceIsOnlyShownOnce() async {
        let harness = SessionHarness()
        harness.client.connectError = SessionHarness.ConnectFailed()

        await harness.connect()
        await harness.connect()

        XCTAssertEqual(harness.session.alert?.title, "Could not connect")

        harness.session.dismissAlert()

        XCTAssertNotEqual(
            harness.session.alert?.title, "Could not connect",
            "the second identical failure should have been dropped, not queued")
    }

    func testSettingsAreTrimmedAndTheCallsignIsUppercasedBeforeUse() async {
        let harness = SessionHarness(settings: nil, identity: nil)
        harness.session.settings = NodeSettings(
            host: "  node.example.org ", port: 0, node: " 55553 ",
            username: " vk1xyz ")
        harness.session.identity = OperatorIdentity(callsign: " vk1xyz ")

        await harness.session.connect()

        XCTAssertEqual(harness.session.settings.host, "node.example.org")
        XCTAssertEqual(harness.session.settings.port, NodeSettings.defaultPort)

        // Written back so the field shows what actually went on the air.
        XCTAssertEqual(harness.session.identity.callsign, "VK1XYZ")
        XCTAssertEqual(harness.identitiesSeen.map(\.callsign), ["VK1XYZ"])
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
