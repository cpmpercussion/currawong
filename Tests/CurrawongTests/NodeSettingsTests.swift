// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// ``NodeSettings`` is a pure value, so this is all arithmetic and string
/// handling — no session, no client, no network.
final class NodeSettingsTests: XCTestCase {
    private let good = NodeSettings(
        host: "node.example.org", port: 4569, node: "55553",
        username: "vk1xyz", callsign: "VK1XYZ")

    func testAGoodSetOfSettingsValidates() throws {
        XCTAssertEqual(try good.validated(), good)
    }

    func testWhitespaceIsTrimmedAndTheCallsignIsUppercased() throws {
        let messy = NodeSettings(
            host: " node.example.org\n", port: 4569, node: "\t55553 ",
            username: " vk1xyz ", callsign: " vk1xyz ")

        XCTAssertEqual(try messy.validated(), good)
    }

    func testTheRequiredFieldsAreRequired() {
        var noHost = good
        noHost.host = "   "
        XCTAssertThrowsError(try noHost.validated()) {
            XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingHost)
        }

        var noNode = good
        noNode.node = ""
        XCTAssertThrowsError(try noNode.validated()) {
            XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingNode)
        }

        var noCallsign = good
        noCallsign.callsign = ""
        XCTAssertThrowsError(try noCallsign.validated()) {
            XCTAssertEqual($0 as? NodeSettings.ValidationError, .missingCallsign)
        }
    }

    /// A node with no account configured expects no username and no secret,
    /// and the library omits empty fields rather than sending blank ones.
    func testAnEmptyUsernameIsAllowed() throws {
        var anonymous = good
        anonymous.username = ""
        XCTAssertEqual(try anonymous.validated().username, "")
    }

    func testAZeroPortBecomesTheDefault() throws {
        var zeroed = good
        zeroed.port = 0
        XCTAssertEqual(try zeroed.validated().port, NodeSettings.defaultPort)
    }

    func testPortParsing() {
        XCTAssertEqual(NodeSettings.parsePort("4569"), 4569)
        XCTAssertEqual(NodeSettings.parsePort(" 4570 "), 4570)
        XCTAssertEqual(
            NodeSettings.parsePort(""), NodeSettings.defaultPort,
            "a cleared field should mean the default, not a failure")
        XCTAssertNil(NodeSettings.parsePort("0"))
        XCTAssertNil(NodeSettings.parsePort("70000"))
        XCTAssertNil(NodeSettings.parsePort("not a port"))
    }

    func testTheSecretAccountIdentifiesTheNodeAndCarriesNoSecret() {
        XCTAssertEqual(good.secretAccount, "vk1xyz@node.example.org:4569/55553")

        var other = good
        other.node = "12345"
        XCTAssertNotEqual(good.secretAccount, other.secretAccount)
    }

    /// The structural guarantee behind "the secret is never in UserDefaults":
    /// the persisted type has no field to put it in.
    func testTheCodableFormHasNoSecretField() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let keys = Set((json as? [String: Any])?.keys.map { $0 } ?? [])

        XCTAssertEqual(
            keys, ["host", "port", "node", "username", "callsign", "transmitTimeout"])
    }

    func testRoundTripsThroughTheDefaultsStore() {
        let defaults = UserDefaults(suiteName: "au.charlesmartin.currawong.tests.\(UUID().uuidString)")!
        let store = UserDefaultsSettingsStore(defaults: defaults)

        XCTAssertNil(store.load())
        store.save(good)
        XCTAssertEqual(store.load(), good)
    }

    // MARK: - Transmit watchdog (SF-1, APP-4)

    func testTheWatchdogTimeoutDefaultsToThreeMinutes() {
        XCTAssertEqual(NodeSettings().transmitTimeout, 180)
        XCTAssertEqual(NodeSettings.defaultTransmitTimeout, 180)
    }

    /// **The migration test.** Settings written before this type had a watchdog
    /// timeout must still decode — otherwise `load()` returns nil and the
    /// operator finds their node details wiped by an app update.
    func testSettingsWrittenWithoutATimeoutStillDecode() throws {
        let json = """
            {"host":"node.example.org","port":4569,"node":"55553",\
            "username":"vk1xyz","callsign":"VK1XYZ"}
            """

        let decoded = try JSONDecoder().decode(NodeSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.host, "node.example.org")
        XCTAssertEqual(decoded.transmitTimeout, NodeSettings.defaultTransmitTimeout)
    }

    /// Clamped rather than rejected: an out-of-range timeout is not worth
    /// refusing to connect over, and refusing would be a safety feature that
    /// prevents transmitting at all.
    func testAnOutOfRangeTimeoutIsClamped() throws {
        var tooLong = good
        tooLong.transmitTimeout = 99_999
        XCTAssertEqual(
            try tooLong.validated().transmitTimeout,
            NodeSettings.transmitTimeoutRange.upperBound)

        var tooShort = good
        tooShort.transmitTimeout = 0
        XCTAssertEqual(
            try tooShort.validated().transmitTimeout,
            NodeSettings.transmitTimeoutRange.lowerBound)
    }

    /// A short timeout is the quickest way to prove SF-1 works against a real
    /// node, so the range has to permit one.
    func testAShortTimeoutIsAllowedForTesting() throws {
        var settings = good
        settings.transmitTimeout = 10
        XCTAssertEqual(try settings.validated().transmitTimeout, 10)
    }

    func testANonFiniteTimeoutFallsBackToTheDefault() throws {
        var settings = good
        settings.transmitTimeout = .nan
        XCTAssertEqual(
            try settings.validated().transmitTimeout, NodeSettings.defaultTransmitTimeout)
    }

    func testParsingATimeoutTheOperatorTyped() {
        XCTAssertEqual(NodeSettings.parseTransmitTimeout("30"), 30)
        XCTAssertEqual(NodeSettings.parseTransmitTimeout(" 45 "), 45)
        // Empty means the default, as with the port — a cleared field should not
        // fail, it should mean "whatever you would have used anyway".
        XCTAssertEqual(
            NodeSettings.parseTransmitTimeout(""), NodeSettings.defaultTransmitTimeout)
        XCTAssertNil(NodeSettings.parseTransmitTimeout("soon"))
        XCTAssertNil(NodeSettings.parseTransmitTimeout("-5"))
        XCTAssertNil(NodeSettings.parseTransmitTimeout("0"))
    }

    /// The timeout is not part of the node's identity, so changing it must not
    /// orphan the secret in the Keychain.
    func testTheTimeoutDoesNotAffectTheKeychainAccount() {
        var slower = good
        slower.transmitTimeout = 60
        XCTAssertEqual(good.secretAccount, slower.secretAccount)
    }
}
