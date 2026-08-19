// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-13.** Where an EchoLink proxy lives, and where it must not.
///
/// The fault this task exists to fix was not a crash: it was that the first
/// EchoLink connect wrote whichever stranger's public proxy answered quickest
/// into the channel, permanently, so every later connect went back to that one
/// machine and never probed again. Most of what follows is therefore about
/// *absence* — that nothing persists a proxy into a channel — which is the kind
/// of property that only stays true if something asserts it.
final class EchoLinkProxySettingsTests: XCTestCase {

    // MARK: - Validation

    /// Deliberately permissive: a private proxy is very often a machine on the
    /// operator's own network, and a single-label name is the commonest private
    /// setup there is. Refusing it would refuse the thing this feature is for.
    func testASingleLabelHostIsAccepted() throws {
        let validated = try EchoLinkProxySettings(host: " shackpi ").validated()

        XCTAssertEqual(validated.host, "shackpi")
        XCTAssertTrue(validated.isConfigured)
    }

    /// What is refused is what is actually a mistake — a URL pasted in whole, or
    /// a name with a space in it.
    func testAPastedURLOrASpacedNameIsRefused() {
        for bad in ["http://proxy.example.org", "proxy.example.org:8100", "my proxy"] {
            XCTAssertThrowsError(try EchoLinkProxySettings(host: bad).validated(), bad) {
                XCTAssertEqual($0 as? EchoLinkProxySettings.ValidationError, .invalidHost, bad)
            }
        }
    }

    func testAnEmptyHostIsAValidConfigurationMeaningUseAPublicProxy() throws {
        for empty in ["", "   "] {
            let validated = try EchoLinkProxySettings(host: empty).validated()
            XCTAssertFalse(validated.isConfigured)
            XCTAssertNil(validated.route(password: "s3cret"), "nothing to tunnel through")
        }
    }

    /// A cleared port field means the proxy port, not zero.
    func testAZeroPortBecomesTheDefault() throws {
        XCTAssertEqual(try EchoLinkProxySettings(host: "shackpi", port: 0).validated().port, 8100)
        XCTAssertEqual(
            EchoLinkProxySettings(host: "shackpi", port: 0).route(password: "")?.port, 8100)
    }

    func testAConfiguredProxyBecomesAPrivateRoute() {
        let route = EchoLinkProxySettings(host: "shackpi", port: 8101).route(password: "s3cret")

        XCTAssertEqual(route?.host, "shackpi")
        XCTAssertEqual(route?.port, 8101)
        XCTAssertEqual(route?.password, "s3cret")
        XCTAssertEqual(route?.isPrivate, true)
    }

    /// The Keychain account is one fixed string, and not keyed by callsign like
    /// the two credentials that *are* issued to an operator: a proxy's password
    /// does not change when the callsign used from it does.
    func testThePasswordAccountIsFixedAndNamesNoCallsign() {
        XCTAssertEqual(EchoLinkProxySettings.passwordAccount, "echolink-proxy")
    }
}

/// The migration, against a real `UserDefaultsSettingsStore` — because what is
/// being tested *is* the reading of stored JSON. Modelled on
/// ``SettingsStoreIdentityTests``, including the per-test suite.
final class EchoLinkProxyMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "au.charlesmartin.currawong.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> UserDefaultsSettingsStore {
        UserDefaultsSettingsStore(defaults: defaults)
    }

    func testAProxyRoundTripsUnderItsOwnKey() {
        XCTAssertNil(store().loadEchoLinkProxy(), "nothing has ever been saved")

        store().saveEchoLinkProxy(EchoLinkProxySettings(host: "shackpi", port: 8101))

        let loaded = store().loadEchoLinkProxy()
        XCTAssertEqual(loaded?.settings, EchoLinkProxySettings(host: "shackpi", port: 8101))
        XCTAssertNil(
            loaded?.harvestedPassword,
            "a password is only handed up by the migration, and this was saved normally")
    }

    /// **The rescue.** An operator who typed their own proxy into a channel must
    /// not have to go and find those details again.
    func testAPrivateProxyIsRescuedFromAChannelWrittenBeforeTheHoist() throws {
        try writeRawChannels([
            [
                "id": UUID().uuidString, "mode": "echoLink", "host": "shackpi", "port": 8101,
                "node": "*ECHOTEST*", "peer": "13.57.14.183", "proxyPassword": "s3cret",
                "username": "",
            ]
        ])

        let loaded = store().loadEchoLinkProxy()

        XCTAssertEqual(loaded?.settings, EchoLinkProxySettings(host: "shackpi", port: 8101))
        XCTAssertEqual(loaded?.harvestedPassword, "s3cret")
    }

    /// **The discard, and it is the more important half.** `PUBLIC` means the app
    /// itself put a stranger's machine there by probing — the fault — so adopting
    /// it as the operator's own proxy would make the fault permanent instead of
    /// ending it.
    func testACapturedPublicProxyIsDiscardedRatherThanAdopted() throws {
        try writeRawChannels([
            [
                "id": UUID().uuidString, "mode": "echoLink", "host": "203.0.113.7", "port": 8100,
                "node": "*ECHOTEST*", "peer": "13.57.14.183", "proxyPassword": "PUBLIC",
                "username": "",
            ]
        ])

        XCTAssertNil(store().loadEchoLinkProxy())
    }

    /// An AllStarLink channel's `host` is its node, and adopting it as a proxy
    /// would point every EchoLink session at a repeater controller.
    func testAnAllStarLinkChannelIsNotAProxy() throws {
        try writeRawChannels([
            [
                "id": UUID().uuidString, "mode": "allStarLink", "host": "node.example.org",
                "port": 4569, "node": "55553", "username": "vk1xyz",
            ]
        ])

        XCTAssertNil(store().loadEchoLinkProxy())
    }

    /// The own key wins, so the harvest is a one-off rather than something that
    /// re-adopts an old blob on every launch.
    func testTheSavedProxyWinsOverAnythingInTheChannels() throws {
        try writeRawChannels([
            [
                "id": UUID().uuidString, "mode": "echoLink", "host": "shackpi", "port": 8101,
                "node": "*ECHOTEST*", "peer": "13.57.14.183", "proxyPassword": "s3cret",
                "username": "",
            ]
        ])
        store().saveEchoLinkProxy(.none)

        let loaded = store().loadEchoLinkProxy()

        XCTAssertEqual(loaded?.settings, EchoLinkProxySettings.none)
        XCTAssertNil(loaded?.harvestedPassword)
    }

    /// Garbage under the key must not crash the harvest — it is read with
    /// `JSONSerialization`, which is happy to be handed anything.
    func testUnreadableStoredDataIsNotAProxy() {
        defaults.set(Data("not json".utf8), forKey: "au.charlesmartin.currawong.channels")

        XCTAssertNil(store().loadEchoLinkProxy())
    }

    /// The pre-APP-4 single-node key is read too: an operator who ran a private
    /// proxy on the one node that key holds is exactly the operator most likely
    /// to have one.
    func testThePreChannelSingleNodeKeyIsHarvestedToo() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "mode": "echoLink", "host": "shackpi", "port": 8101, "node": "*ECHOTEST*",
            "peer": "13.57.14.183", "proxyPassword": "s3cret", "username": "",
        ])
        defaults.set(data, forKey: "au.charlesmartin.currawong.nodeSettings")

        XCTAssertEqual(store().loadEchoLinkProxy()?.settings.host, "shackpi")
    }

    /// **The other end of the migration.** Whatever a stored channel holds, the
    /// decoded channel names no proxy — so the next thing that saves it cannot
    /// write one back.
    func testAStoredChannelDecodesWithNoProxyInIt() throws {
        try writeRawChannels([
            [
                "id": UUID().uuidString, "mode": "echoLink", "host": "203.0.113.7", "port": 8100,
                "node": "*ECHOTEST*", "peer": "13.57.14.183", "proxyPassword": "PUBLIC",
                "username": "",
            ]
        ])

        let channels = store().loadChannels()

        XCTAssertEqual(channels?.count, 1)
        XCTAssertEqual(channels?.first?.host, "")
        XCTAssertEqual(channels?.first?.peer, "13.57.14.183", "the node itself is untouched")
    }

    private func writeRawChannels(_ channels: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: channels)
        defaults.set(data, forKey: "au.charlesmartin.currawong.channels")
    }
}

/// The session's half: storing the operator's own proxy, carrying one into a
/// connection, and giving a borrowed one back.
@MainActor
final class EchoLinkProxySessionTests: XCTestCase {

    // MARK: - Storing the operator's own

    func testSavingAProxyStoresTheHostInDefaultsAndThePasswordInTheKeychain() {
        let harness = SessionHarness()

        let complaint = harness.session.setEchoLinkProxy(
            EchoLinkProxySettings(host: " shackpi ", port: 8101), password: "s3cret")

        XCTAssertNil(complaint)
        XCTAssertEqual(harness.session.echoLinkProxy.host, "shackpi", "trimmed")
        XCTAssertEqual(
            harness.settingsStore.savedEchoLinkProxy,
            EchoLinkProxySettings(host: "shackpi", port: 8101))
        XCTAssertEqual(
            try? harness.secretStore.secret(for: EchoLinkProxySettings.passwordAccount), "s3cret")
    }

    /// The structural guarantee: a proxy password never reaches `UserDefaults`,
    /// which is the whole reason it moved. Checked against the encoded form
    /// rather than by reading a field, so a future field would fail here.
    func testAStoredProxyCarriesNoPassword() throws {
        let harness = SessionHarness()
        harness.session.setEchoLinkProxy(
            EchoLinkProxySettings(host: "shackpi"), password: "s3cret")

        let encoded = try JSONEncoder().encode(harness.settingsStore.savedEchoLinkProxy)

        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("s3cret"))
    }

    /// A password kept for a proxy that is no longer configured is a credential
    /// held for nothing.
    func testClearingTheHostClearsTheStoredPassword() {
        let harness = SessionHarness()
        harness.session.setEchoLinkProxy(
            EchoLinkProxySettings(host: "shackpi"), password: "s3cret")

        harness.session.setEchoLinkProxy(.none, password: "s3cret")

        XCTAssertFalse(harness.session.echoLinkProxy.isConfigured)
        XCTAssertEqual(harness.session.echoLinkProxyPassword, "")
        XCTAssertNil(try? harness.secretStore.secret(for: EchoLinkProxySettings.passwordAccount))
    }

    func testABadProxyIsRefusedAndNothingIsStored() {
        let harness = SessionHarness()

        let complaint = harness.session.setEchoLinkProxy(
            EchoLinkProxySettings(host: "http://proxy.example.org"), password: "s3cret")

        XCTAssertNotNil(complaint)
        XCTAssertFalse(harness.session.echoLinkProxy.isConfigured)
        XCTAssertNil(harness.settingsStore.savedEchoLinkProxy)
    }

    /// A Keychain that will not take the password is reported and not fatal — the
    /// proxy works for this run, and the operator hears that it will not be there
    /// next time rather than finding out then. The same position as the other two
    /// credentials.
    func testAKeychainFailureIsReportedButTheProxyStillWorksThisRun() {
        let harness = SessionHarness()
        harness.secretStore.failWrites = true

        let complaint = harness.session.setEchoLinkProxy(
            EchoLinkProxySettings(host: "shackpi"), password: "s3cret")

        XCTAssertNotNil(complaint)
        XCTAssertEqual(harness.session.echoLinkProxy.host, "shackpi")
        XCTAssertEqual(harness.session.echoLinkProxyPassword, "s3cret")
    }

    // MARK: - The migration, from the session's side

    /// The launch after the update: the harvested password is filed in the
    /// Keychain and the settings are saved under their own key, which is what
    /// stops the harvest running again.
    func testAHarvestedProxyIsFiledInTheKeychainAtStartup() {
        let harness = SessionHarness(
            echoLinkProxy: StoredEchoLinkProxy(
                settings: EchoLinkProxySettings(host: "shackpi", port: 8101),
                harvestedPassword: "s3cret"))

        XCTAssertEqual(harness.session.echoLinkProxy.host, "shackpi")
        XCTAssertEqual(harness.session.echoLinkProxyPassword, "s3cret")
        XCTAssertEqual(
            try? harness.secretStore.secret(for: EchoLinkProxySettings.passwordAccount), "s3cret")
        XCTAssertEqual(
            harness.settingsStore.savedEchoLinkProxy,
            EchoLinkProxySettings(host: "shackpi", port: 8101))
    }

    /// The ordinary launch: the password comes from the Keychain and nothing is
    /// re-saved.
    func testAnAlreadyMigratedProxyReadsItsPasswordFromTheKeychain() {
        let harness = SessionHarness(
            secrets: [EchoLinkProxySettings.passwordAccount: "s3cret"],
            echoLinkProxy: StoredEchoLinkProxy(
                settings: EchoLinkProxySettings(host: "shackpi"), harvestedPassword: nil))

        XCTAssertEqual(harness.session.echoLinkProxyPassword, "s3cret")
    }

    // MARK: - Connecting

    /// The route the caller resolved is what the link is built with — and, since
    /// the channel names no proxy, the only way it could have got there.
    func testTheResolvedRouteReachesTheLinkFactory() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = SessionHarness.echoLinkSettings
        harness.session.secret = "account-password"
        let route = EchoLinkProxyRoute(
            host: "shackpi", port: 8101, password: "s3cret", isPrivate: true)

        await harness.session.connect(proxy: route)

        XCTAssertEqual(harness.proxiesSeen, [route])
    }

    /// The two modes that need no proxy are handed none, rather than one being
    /// sourced for a field they do not have.
    func testTheOtherModesAreHandedNoProxy() async {
        let harness = SessionHarness()

        await harness.session.connect()

        XCTAssertEqual(harness.proxiesSeen.count, 1)
        XCTAssertNil(harness.proxiesSeen.first ?? nil)
    }

    /// **The fault, asserted directly.** Connecting must leave no proxy in the
    /// channel it saves — neither in the list nor in the legacy single-node key —
    /// because that is what made the first connect's public proxy permanent.
    func testConnectingPersistsNoProxyInTheChannel() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = SessionHarness.echoLinkSettings
        harness.session.secret = "account-password"

        await harness.session.connect(
            proxy: EchoLinkProxyRoute(
                host: "203.0.113.7", port: 8100, password: "PUBLIC", isPrivate: false))

        XCTAssertEqual(harness.session.channels.channels.count, 1)
        XCTAssertEqual(harness.session.channels.channels.first?.host, "")
        XCTAssertEqual(harness.settingsStore.saved?.host, "")
        XCTAssertEqual(
            harness.session.channels.channels.first?.peer, "13.57.14.183",
            "the node it points at is untouched")
    }

    // MARK: - Giving it back

    /// Hanging up returns the machine.
    func testDisconnectingReleasesTheLease() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = SessionHarness.echoLinkSettings
        harness.session.secret = "account-password"
        await harness.session.connect(
            proxy: EchoLinkProxyRoute(
                host: "203.0.113.7", port: 8100, password: "PUBLIC", isPrivate: false))
        XCTAssertEqual(harness.proxyLeaseReleases, 0, "not while the session is up")

        await harness.session.disconnect()

        XCTAssertEqual(harness.proxyLeaseReleases, 1)
    }

    /// And so does the link going away by itself, which is the path that matters:
    /// a lease surviving a dropped link would send the next session back to a
    /// machine somebody else may have taken.
    func testALinkThatDropsByItselfAlsoReleasesTheLease() async {
        let harness = SessionHarness(settings: nil, channels: [])
        harness.session.settings = SessionHarness.echoLinkSettings
        harness.session.secret = "account-password"
        await harness.session.connect(
            proxy: EchoLinkProxyRoute(
                host: "203.0.113.7", port: 8100, password: "PUBLIC", isPrivate: false))

        harness.eventContinuation.yield(.disconnected(reason: "the proxy closed the stream"))
        await waitUntil("the session notices") {
            harness.session.connection == .disconnected
        }

        XCTAssertEqual(harness.proxyLeaseReleases, 1)
    }
}
