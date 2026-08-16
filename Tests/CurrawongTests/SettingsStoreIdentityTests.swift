// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// Where the app-wide callsign is kept, and how it is found on the first launch
/// after it stopped being a per-channel field.
///
/// **This is the migration test.** Everything else about the hoist is a
/// compile-time change; this is the part that can silently lose an operator's
/// callsign, and losing it means the app refuses to transmit until they notice
/// which field went blank.
///
/// Against a real `UserDefaultsSettingsStore` rather than the in-memory fake,
/// because what is being tested *is* the reading of stored JSON. Each test gets
/// its own suite, removed afterwards, so nothing leaks into the machine's
/// defaults or into another test.
final class SettingsStoreIdentityTests: XCTestCase {
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

    // MARK: - The ordinary path

    func testAnIdentityRoundTrips() {
        let store = store()
        XCTAssertNil(store.loadIdentity(), "nothing has ever been saved")

        store.saveIdentity(OperatorIdentity(callsign: "VK1XYZ"))

        XCTAssertEqual(store.loadIdentity(), OperatorIdentity(callsign: "VK1XYZ"))
    }

    // MARK: - The migration

    /// A channel list written before the hoist still carries `callsign` in each
    /// entry. `NodeSettings` no longer decodes it, so the store reads the raw
    /// JSON to find it — once.
    func testTheCallsignIsHarvestedFromChannelsWrittenBeforeTheHoist() throws {
        try writeRawChannels([
            ["id": UUID().uuidString, "host": "node.example.org", "port": 4569,
             "node": "55553", "username": "vk1xyz", "callsign": "VK1XYZ"]
        ])

        XCTAssertEqual(store().loadIdentity(), OperatorIdentity(callsign: "VK1XYZ"))
    }

    /// A pre-APP-4 install has no channel list at all — one node under the old
    /// single-node key. That callsign has to come forward too.
    func testTheCallsignIsHarvestedFromAPreChannelListNode() throws {
        try writeRawNode([
            "host": "node.example.org", "port": 4569, "node": "55553",
            "username": "vk1xyz", "callsign": "VK1BOB",
        ])

        XCTAssertEqual(store().loadIdentity(), OperatorIdentity(callsign: "VK1BOB"))
    }

    /// Channels first: they are the newer of the two keys, so if both exist the
    /// channel list is the one that reflects what the operator has been using.
    func testChannelsWinOverTheLegacyNode() throws {
        try writeRawChannels([
            ["id": UUID().uuidString, "host": "a.example.org", "port": 4569,
             "node": "1", "username": "", "callsign": "VK1NEW"]
        ])
        try writeRawNode([
            "host": "b.example.org", "port": 4569, "node": "2", "username": "",
            "callsign": "VK1OLD",
        ])

        XCTAssertEqual(store().loadIdentity(), OperatorIdentity(callsign: "VK1NEW"))
    }

    /// An operator with several channels may have left the callsign blank on
    /// some of them — the form did not insist until Connect. The first one that
    /// has anything is the answer.
    func testTheFirstNonEmptyCallsignIsTaken() throws {
        try writeRawChannels([
            ["id": UUID().uuidString, "host": "a.example.org", "port": 4569,
             "node": "1", "username": "", "callsign": ""],
            ["id": UUID().uuidString, "host": "b.example.org", "port": 4569,
             "node": "2", "username": "", "callsign": "VK1XYZ"],
        ])

        XCTAssertEqual(store().loadIdentity(), OperatorIdentity(callsign: "VK1XYZ"))
    }

    /// A saved identity is authoritative. Once the operator has one of their
    /// own, an old callsign still sitting in the stored channels must not
    /// override it — otherwise changing your callsign would not survive a
    /// relaunch.
    func testASavedIdentityBeatsWhateverIsLeftInTheChannels() throws {
        try writeRawChannels([
            ["id": UUID().uuidString, "host": "a.example.org", "port": 4569,
             "node": "1", "username": "", "callsign": "VK1OLD"]
        ])
        store().saveIdentity(OperatorIdentity(callsign: "VK1NEW"))

        XCTAssertEqual(store().loadIdentity(), OperatorIdentity(callsign: "VK1NEW"))
    }

    func testNothingStoredMeansNoIdentity() throws {
        try writeRawChannels([
            ["id": UUID().uuidString, "host": "a.example.org", "port": 4569,
             "node": "1", "username": "", "callsign": ""]
        ])

        XCTAssertNil(store().loadIdentity(), "a blank callsign is not an identity")
    }

    /// Channels written *after* the hoist have no `callsign` key at all, which
    /// must read as "none" rather than as a decode failure that takes the whole
    /// list with it.
    func testChannelsWithoutACallsignKeyAreFine() throws {
        try writeRawChannels([
            ["id": UUID().uuidString, "host": "a.example.org", "port": 4569,
             "node": "1", "username": ""]
        ])

        XCTAssertNil(store().loadIdentity())
        XCTAssertEqual(store().loadChannels()?.count, 1, "the channel still decodes")
    }

    /// Garbage under the key must not crash the harvest — it is read with
    /// `JSONSerialization`, which is happy to be handed anything.
    func testUnreadableStoredDataIsNotAnIdentity() {
        defaults.set(Data("not json".utf8), forKey: "au.charlesmartin.currawong.channels")
        XCTAssertNil(store().loadIdentity())
    }

    // MARK: - Writing the old shapes

    private func writeRawChannels(_ channels: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: channels)
        defaults.set(data, forKey: "au.charlesmartin.currawong.channels")
    }

    private func writeRawNode(_ node: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: node)
        defaults.set(data, forKey: "au.charlesmartin.currawong.nodeSettings")
    }
}
