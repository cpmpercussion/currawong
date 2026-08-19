// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// Proves the app is genuinely wired to the library: these tests only compile
/// if the local SPM path dependency resolved and linked, and only pass if what
/// the composition root builds starts in a safe state.
///
/// No socket is opened and no audio device is touched. `IAX2Client` builds its
/// transport lazily, inside `connect(to:)`, so constructing one costs nothing
/// but memory; the audio pipeline is injected as a fake for the same reason.
///
/// Note what is *not* imported here: `IAX2Kit`. These tests reach the client
/// through `RadioCore`'s vocabulary alone, which is the same constraint the
/// rest of the app is under.
@MainActor
final class CompositionRootTests: XCTestCase {
    /// The operator. App-wide now, and passed to every factory rather than
    /// living in the settings.
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")

    /// A resolved public proxy. Supplied by the caller (APP-13) — a channel names
    /// no proxy, so every EchoLink factory call has to be handed one.
    private let publicProxy = EchoLinkProxyRoute(
        host: "proxy.example.org", port: 8100, password: "PUBLIC", isPrivate: false)

    private func makeRoot() -> CompositionRoot {
        CompositionRoot(
            audio: FakeAudioIO(),
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore())
    }

    func testAFreshRootIsIdleAndNotTransmitting() {
        let root = makeRoot()

        XCTAssertEqual(root.transmitState, .idle)
        XCTAssertFalse(TransmitStatusPresentation(state: root.transmitState).isTransmitting)
        XCTAssertEqual(root.session.connection, .disconnected)
        XCTAssertFalse(root.session.isTransmitting)
    }

    /// The link factory is where `IAX2Kit` is named, so this is where it gets
    /// exercised: it must build a whole connection's worth of plumbing without
    /// opening anything.
    func testTheLinkFactoryBuildsAClientWithoutConnectingIt() async {
        let link = CompositionRoot.makeIAX2Link(
            settings: NodeSettings(
                host: "node.example.org", port: 4569, node: "55553",
                username: "vk1xyz"),
            identity: vk1xyz,
            credentials: .init(secret: "hunter2"))
        defer { link.close() }

        // The link exposes operations, not the client, so what is
        // observable here is that nothing has been keyed and nothing throws.
        XCTAssertEqual(link.transmitState(), .idle)
        XCTAssertEqual(link.mode, .allStarLink)
    }

    /// Stopping transmit is documented as safe on a client that was never
    /// connected — SF-2 and SF-3 both call it from paths that cannot know the
    /// current state, so it must not trap here either.
    func testStopTransmitOnAnUnconnectedClientIsHarmless() async {
        let link = CompositionRoot.makeIAX2Link(
            settings: NodeSettings(host: "node.example.org", node: "55553"),
            identity: vk1xyz,
            credentials: .init())
        defer { link.close() }

        await link.stopTransmit()

        XCTAssertEqual(link.transmitState(), .idle)
    }

    /// The captured-frame path must be safe to call when nothing is
    /// transmitting: the microphone does not know about PTT, and the client is
    /// documented to drop frames it is not keyed for rather than throwing.
    func testHandingFramesToAnUnkeyedLinkIsHarmless() {
        let link = CompositionRoot.makeIAX2Link(
            settings: NodeSettings(host: "node.example.org", node: "55553"),
            identity: vk1xyz,
            credentials: .init())
        defer { link.close() }

        link.sendCapturedFrame(Array(repeating: 0, count: 160))
    }

    /// DTMF on a client that was never connected must be refused rather than
    /// trapping — the keypad is on screen before a connection exists, and a view
    /// that can crash the app by being tapped early is not acceptable.
    func testSendingDTMFToAnUnconnectedLinkThrowsRatherThanTrapping() async {
        let link = CompositionRoot.makeIAX2Link(
            settings: NodeSettings(host: "node.example.org", node: "55553"),
            identity: vk1xyz,
            credentials: .init())
        defer { link.close() }

        do {
            try await link.sendDTMF("*")
            XCTFail("expected an unconnected client to refuse a digit")
        } catch {
            // Which error is the library's business; that it is an error and not
            // a crash is this test's.
        }
    }

    // MARK: - EchoLink

    private func echoLinkSettings() -> NodeSettings {
        NodeSettings(
            mode: .echoLink,
            node: "*ECHOTEST*",
            peer: "13.57.14.183",
            directoryServer: "192.0.2.1")
    }

    /// The third mode builds the same ``RadioLink`` as the other two, and
    /// building it opens nothing — `EchoLinkClient`, like the others, makes its
    /// transport inside `connect(to:)`.
    func testTheEchoLinkFactoryBuildsALinkWithoutConnectingIt() throws {
        let link = try CompositionRoot.makeEchoLinkLink(
            settings: echoLinkSettings(), identity: vk1xyz, secret: "account-password",
            proxy: publicProxy)
        defer { link.close() }

        XCTAssertEqual(link.mode, .echoLink)
        XCTAssertEqual(link.transmitState(), .idle, "building a link must not key anything")
    }

    /// **A hostname cannot be made to work here by trying harder.** The proxy
    /// carries the peer as four raw address bytes and nothing in the path
    /// resolves DNS, so this is a refusal with an explanation rather than a
    /// force-unwrap that traps or a connect that fails inside the transport.
    func testANodeAddressThatIsNotADottedQuadIsRefused() {
        for bad in ["node.example.org", "13.57.14", "", "13.57.14.999"] {
            var settings = echoLinkSettings()
            settings.peer = bad

            XCTAssertThrowsError(
                try CompositionRoot.makeEchoLinkLink(
                    settings: settings, identity: vk1xyz, secret: "", proxy: publicProxy), bad
            ) { error in
                XCTAssertEqual(error as? EchoLinkLinkError, .invalidPeerAddress(bad), bad)
            }
        }
    }

    /// A caller that sourced no proxy is stopped here. `ProxyPicker` is what
    /// resolves one and `RootView` stops when it cannot, so this is the backstop
    /// — and it earns its keep: without it the failure happens inside the
    /// transport, where the message is about a socket rather than about a proxy.
    func testALinkWithNoProxyIsRefused() {
        for proxy in [nil, EchoLinkProxyRoute(host: "", port: 8100, password: "PUBLIC", isPrivate: false)] {
            XCTAssertThrowsError(
                try CompositionRoot.makeEchoLinkLink(
                    settings: echoLinkSettings(), identity: vk1xyz, secret: "", proxy: proxy)
            ) { error in
                XCTAssertEqual(error as? EchoLinkLinkError, .missingProxyHost)
            }
        }
    }

    /// The proxy the caller resolved is the one the destination is built from.
    /// Nothing reads a proxy off the channel any more — `echoLinkSettings()` above
    /// has no host in it, which is the point.
    func testTheResolvedProxyIsWhatTheLinkIsBuiltWith() throws {
        let own = EchoLinkProxyRoute(
            host: "shackpi", port: 8101, password: "s3cret", isPrivate: true)
        let link = try CompositionRoot.makeEchoLinkLink(
            settings: echoLinkSettings(), identity: vk1xyz, secret: "", proxy: own)
        defer { link.close() }

        // The destination is inside the client, so what is assertable here is
        // that a proxy naming a private machine builds at all — the wire-level
        // check is `EchoLinkKit`'s. What matters at this seam is that the route
        // came from the parameter: with the channel carrying no host, a factory
        // still reading `settings.host` would have thrown above.
        XCTAssertEqual(link.mode, .echoLink)
    }

    /// EchoLink has no digit path at all, so the link says so rather than
    /// silently doing nothing. The connect form hides the keypad in this mode —
    /// `RadioMode.sendsDTMF` — so this is the backstop rather than the first
    /// line of defence.
    func testEchoLinkRefusesDTMFRatherThanSwallowingIt() async throws {
        let link = try CompositionRoot.makeEchoLinkLink(
            settings: echoLinkSettings(), identity: vk1xyz, secret: "", proxy: publicProxy)
        defer { link.close() }

        do {
            try await link.sendDTMF("1")
            XCTFail("expected EchoLink to refuse DTMF")
        } catch {
            XCTAssertEqual(error as? EchoLinkLinkError, .dtmfUnsupported)
        }
    }

    /// The browser is owned by the root rather than by the view, because a
    /// fetch is a network session that takes seconds and has to survive the
    /// pane being scrolled away from. This is the wiring test for that: the
    /// injected directory is the one it actually asks.
    func testTheStationBrowserIsBuiltOverTheInjectedDirectory() async {
        let directory = FakeStationDirectory(stations: [.fake(callsign: "*ECHOTEST*")])
        let root = CompositionRoot(
            audio: FakeAudioIO(),
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore(),
            stationDirectory: directory)

        root.stationBrowser.load(
            for: echoLinkSettings(), identity: vk1xyz, accountPassword: "pw", proxy: publicProxy)
        await waitUntil("the injected directory answers") {
            !root.stationBrowser.stations.isEmpty
        }

        XCTAssertEqual(directory.fetches.count, 1)
        XCTAssertEqual(root.stationBrowser.stations.map(\.callsign), ["*ECHOTEST*"])
    }

    /// Every EchoLink complaint has to read as advice, because each one is
    /// something the operator can act on in the form in front of them.
    func testTheEchoLinkErrorsHaveWordsForTheOperator() {
        for error in [
            EchoLinkLinkError.invalidPeerAddress("node.example.org"),
            .invalidPeerAddress(""),
            .missingProxyHost,
            .dtmfUnsupported,
        ] {
            XCTAssertFalse(error.description.isEmpty)
        }
    }

    /// Stopping transmit is safe on a client that was never connected here too
    /// — SF-2 and SF-3 call it from paths that cannot know the current state,
    /// and they do not know which mode is up either.
    func testStopTransmitOnAnUnconnectedEchoLinkClientIsHarmless() async throws {
        let link = try CompositionRoot.makeEchoLinkLink(
            settings: echoLinkSettings(), identity: vk1xyz, secret: "", proxy: publicProxy)
        defer { link.close() }

        await link.stopTransmit()
        link.sendCapturedFrame(Array(repeating: 0, count: 160))

        XCTAssertEqual(link.transmitState(), .idle)
    }

    // MARK: - The SF-2 wire

    /// **The wiring test SF-2 depends on.** Both input controllers take a *weak*
    /// sink, and before this was assembled `BLEPTTController` computed perfectly
    /// correct press and release edges and delivered them to `nil`. A test that
    /// only exercises the controller cannot catch that; this one can.
    func testTheInputControllersAreWiredToTheSession() {
        let root = makeRoot()

        XCTAssertIdentical(root.accessory.sink, root.session)
        XCTAssertIdentical(root.remoteCommand.sink, root.session)
    }

    /// Activation must not construct a `CBCentralManager` or take over the
    /// system's media controls for an operator who has configured neither.
    func testActivatingWithNothingConfiguredArmsNothing() {
        let root = CompositionRoot(
            audio: FakeAudioIO(),
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore(),
            accessory: BLEPTTController(
                makeCentral: { XCTFail("a central was built"); return FakeBLECentral() },
                store: InMemoryPTTSettingsStore(),
                retryDelay: {}),
            remoteCommand: RemoteCommandPTTController(
                makeSource: {
                    XCTFail("a remote command source was built")
                    return FakeRemoteCommandSource()
                },
                store: InMemoryPTTSettingsStore()))

        root.activate()

        XCTAssertEqual(root.accessory.linkState, .noAccessory)
        XCTAssertFalse(root.remoteCommand.isEnabled)
    }

    /// **AU-4.** The library's leveller targets −18 dBFS RMS, which is 6 dB
    /// quieter than a phone speaker wants. Pinned because the symptom of losing
    /// this — audio that is merely a bit quiet — is one nobody files a bug about
    /// for months.
    func testReceivedAudioIsLevelledForAPhoneSpeakerRatherThanAMixingDesk() {
        XCTAssertEqual(CompositionRoot.receiveLeveller.targetRMSdBFS, -12)
    }

    /// SF-1's number is the operator's, and it is app-wide rather than a field of
    /// the channel. This is the seam where it becomes the library's watchdog
    /// timeout — a mistake here would be invisible until a transmission ran for
    /// three minutes when ten seconds were asked for.
    func testTheWatchdogTimeoutComesFromTheOperatorsSetting() {
        XCTAssertEqual(
            CompositionRoot.watchdogTimeout(for: TransmitTimeout(seconds: 12)), .seconds(12))
        XCTAssertEqual(
            CompositionRoot.watchdogTimeout(for: .default),
            .seconds(TransmitTimeout.default.seconds))
    }
}
