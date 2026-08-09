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

        XCTAssertEqual(keys, ["host", "port", "node", "username", "callsign"])
    }

    func testRoundTripsThroughTheDefaultsStore() {
        let defaults = UserDefaults(suiteName: "au.charlesmartin.currawong.tests.\(UUID().uuidString)")!
        let store = UserDefaultsSettingsStore(defaults: defaults)

        XCTAssertNil(store.load())
        store.save(good)
        XCTAssertEqual(store.load(), good)
    }
}
