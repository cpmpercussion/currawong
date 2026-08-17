// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **SF-1.** The transmit watchdog timeout, now the operator's app-wide setting
/// rather than a field of each channel.
///
/// The clamping rules moved here from `NodeSettings` unchanged — an out-of-range
/// timeout is not worth refusing to connect over, and refusing would be a safety
/// feature that prevents transmitting at all.
final class TransmitTimeoutTests: XCTestCase {
    func testTheDefaultIsThreeMinutes() {
        XCTAssertEqual(TransmitTimeout.default.seconds, 180)
        XCTAssertEqual(TransmitTimeout.default.wholeSeconds, 180)
    }

    func testAnOutOfRangeTimeoutIsClamped() {
        XCTAssertEqual(
            TransmitTimeout(seconds: 99_999).seconds, TransmitTimeout.range.upperBound)
        XCTAssertEqual(TransmitTimeout(seconds: 0).seconds, TransmitTimeout.range.lowerBound)
        XCTAssertEqual(TransmitTimeout(seconds: -30).seconds, TransmitTimeout.range.lowerBound)
    }

    /// A short timeout is the quickest way to prove SF-1 works against a real
    /// node, so the range has to permit one.
    func testAShortTimeoutIsAllowedForTesting() {
        XCTAssertEqual(TransmitTimeout(seconds: 10).seconds, 10)
    }

    func testANonFiniteTimeoutFallsBackToTheDefault() {
        XCTAssertEqual(TransmitTimeout(seconds: .nan), .default)
        XCTAssertEqual(TransmitTimeout(seconds: .infinity), .default)
    }

    func testParsingATimeoutTheOperatorTyped() {
        XCTAssertEqual(TransmitTimeout.parse("30"), TransmitTimeout(seconds: 30))
        XCTAssertEqual(TransmitTimeout.parse(" 45 "), TransmitTimeout(seconds: 45))
        // Empty means the default, as with the port — a cleared field should not
        // fail, it should mean "whatever you would have used anyway".
        XCTAssertEqual(TransmitTimeout.parse(""), .default)
        XCTAssertNil(TransmitTimeout.parse("soon"))
        XCTAssertNil(TransmitTimeout.parse("-5"))
        XCTAssertNil(TransmitTimeout.parse("0"))
    }

    /// Typed rather than rejected: the settings field accepts `9999` and lands on
    /// ten minutes, instead of refusing the keystroke and leaving the operator
    /// unable to finish typing.
    func testAnOutOfRangeTypedValueParsesAndClamps() {
        XCTAssertEqual(TransmitTimeout.parse("9999"), TransmitTimeout(seconds: 600))
        XCTAssertEqual(TransmitTimeout.parse("1"), TransmitTimeout(seconds: 5))
    }
}

/// How the app-wide watchdog timeout is stored, and how it is found on the first
/// launch after it stopped being a per-channel field.
///
/// **This is the migration test**, and the reason it matters is asymmetric: a
/// migration that lengthens a limit the operator deliberately shortened is a
/// safety setting quietly relaxed by an app update. Hence the rule below.
///
/// Against a real `UserDefaultsSettingsStore` rather than the in-memory fake,
/// because what is being tested *is* the reading of stored JSON. Each test gets
/// its own suite, removed afterwards.
final class SettingsStoreTimeoutTests: XCTestCase {
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

    func testATimeoutRoundTrips() {
        let store = store()
        XCTAssertNil(store.loadTransmitTimeout(), "nothing has ever been saved")

        store.saveTransmitTimeout(TransmitTimeout(seconds: 45))

        XCTAssertEqual(store.loadTransmitTimeout(), TransmitTimeout(seconds: 45))
    }

    /// **The rule.** Several channels, several timeouts, and no single right
    /// answer to migrate — so the shortest wins, because it is the only choice
    /// that cannot lengthen a limit the operator had chosen.
    func testTheShortestStoredTimeoutIsTheOneHarvested() throws {
        try writeRawChannels([
            channelBlob(node: "55553", timeout: 180),
            channelBlob(node: "12345", timeout: 20),
            channelBlob(node: "23456", timeout: 300),
        ])

        XCTAssertEqual(store().loadTransmitTimeout(), TransmitTimeout(seconds: 20))
    }

    /// A pre-APP-4 install has no channel list at all — one node under the old
    /// single-node key. Its timeout has to come forward too.
    func testATimeoutIsHarvestedFromAPreChannelListNode() throws {
        try writeRawNode(channelBlob(node: "55553", timeout: 30))

        XCTAssertEqual(store().loadTransmitTimeout(), TransmitTimeout(seconds: 30))
    }

    /// Once the operator has set one, the stored channels are irrelevant — they
    /// are a fossil of the old shape and must not override a live setting.
    func testASavedTimeoutWinsOverTheStoredChannels() throws {
        try writeRawChannels([channelBlob(node: "55553", timeout: 20)])
        let store = store()
        store.saveTransmitTimeout(TransmitTimeout(seconds: 240))

        XCTAssertEqual(store.loadTransmitTimeout(), TransmitTimeout(seconds: 240))
    }

    /// Harvested values go through the same clamp as typed ones. A stored blob is
    /// not necessarily a value this app wrote — a downgrade, or a hand-edited
    /// plist, and the range is the range.
    func testAHarvestedTimeoutIsClamped() throws {
        try writeRawChannels([channelBlob(node: "55553", timeout: 1)])

        XCTAssertEqual(store().loadTransmitTimeout(), TransmitTimeout(seconds: 5))
    }

    /// Channels written *after* the hoist have no timeout key at all, and neither
    /// has a fresh install: nothing to harvest means the default, decided by the
    /// caller rather than invented here.
    func testNoTimeoutAnywhereIsNil() throws {
        try writeRawChannels([
            ["id": UUID().uuidString, "host": "node.example.org", "port": 4569,
             "node": "55553", "username": "vk1xyz"]
        ])

        XCTAssertNil(store().loadTransmitTimeout())
    }

    // MARK: - Helpers

    private func channelBlob(node: String, timeout: Double) -> [String: Any] {
        [
            "id": UUID().uuidString, "host": "node.example.org", "port": 4569,
            "node": node, "username": "vk1xyz", "callsign": "VK1XYZ",
            "transmitTimeout": timeout,
        ]
    }

    private func writeRawChannels(_ channels: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: channels)
        defaults.set(data, forKey: "au.charlesmartin.currawong.channels")
    }

    private func writeRawNode(_ node: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: node)
        defaults.set(data, forKey: "au.charlesmartin.currawong.nodeSettings")
    }
}

/// The session's end of the same setting: loaded once, persisted on change, and
/// handed to the link factory when a connection is built.
@MainActor
final class RadioSessionTimeoutTests: XCTestCase {
    func testAStoredTimeoutIsLoaded() {
        let harness = SessionHarness(timeout: TransmitTimeout(seconds: 45))

        XCTAssertEqual(harness.session.transmitTimeout, TransmitTimeout(seconds: 45))
    }

    func testNoStoredTimeoutMeansTheDefault() {
        XCTAssertEqual(SessionHarness().session.transmitTimeout, .default)
    }

    /// A safety limit that quietly reverts to three minutes on relaunch is worse
    /// than no setting at all, so this persists on change rather than at connect.
    func testChangingTheTimeoutPersistsIt() {
        let harness = SessionHarness()

        harness.session.transmitTimeout = TransmitTimeout(seconds: 60)

        XCTAssertEqual(harness.settingsStore.savedTransmitTimeout, TransmitTimeout(seconds: 60))
    }

    /// The wiring that actually enforces SF-1: the operator's number has to reach
    /// the factory, which is where it becomes the library's watchdog timeout. A
    /// mistake here is invisible until a transmission runs for three minutes when
    /// ten seconds were asked for.
    func testTheTimeoutReachesTheLinkFactory() async {
        let harness = SessionHarness(timeout: TransmitTimeout(seconds: 15))

        await harness.session.connect()

        XCTAssertEqual(harness.timeoutsSeen, [TransmitTimeout(seconds: 15)])
    }
}
