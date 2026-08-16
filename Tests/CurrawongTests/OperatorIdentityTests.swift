// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// The operator's callsign, which is app-wide rather than per channel.
final class OperatorIdentityTests: XCTestCase {
    func testACallsignIsTrimmedAndUppercased() throws {
        let validated = try OperatorIdentity(callsign: " vk1xyz\n").validated()
        XCTAssertEqual(validated.callsign, "VK1XYZ")
    }

    /// The one rule this type exists to enforce.
    func testAnEmptyCallsignIsRefused() {
        for empty in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try OperatorIdentity(callsign: empty).validated()) {
                XCTAssertEqual(
                    $0 as? OperatorIdentity.ValidationError, .missingCallsign,
                    "\(empty.debugDescription) is not a callsign")
            }
        }
    }

    func testTheComplaintHasWordsForTheOperator() {
        XCTAssertFalse(OperatorIdentity.ValidationError.missingCallsign.description.isEmpty)
    }

    /// The Keychain account strings are unchanged by the hoist, which is what
    /// keeps every secret already stored findable. The callsign now arrives as
    /// a parameter instead of a field, and that must be the only difference.
    func testTheKeychainAccountsStillReadTheSameWay() {
        let identity = OperatorIdentity(callsign: "VK1XYZ")

        let allStar = NodeSettings(
            host: "node.example.org", port: 4569, node: "55553", username: "vk1xyz")
        XCTAssertEqual(
            allStar.secretAccount(for: identity), "vk1xyz@node.example.org:4569/55553",
            "the AllStarLink form is frozen and does not use the callsign at all")

        let m17 = NodeSettings(
            mode: .m17, host: "ref.example.org", port: 17000, module: "A")
        XCTAssertEqual(m17.secretAccount(for: identity), "m17:VK1XYZ@ref.example.org:17000/A")

        let echoLink = NodeSettings(mode: .echoLink, host: "proxy.example.org", port: 8100)
        XCTAssertEqual(echoLink.secretAccount(for: identity), "echolink:VK1XYZ")
    }

    /// Changing the callsign changes which secret is looked up in two of the
    /// three modes, and must not in the third. Worth pinning: this is what
    /// happens to a stored password when an operator switches to a contest
    /// call, and the answer is "the other account's password is still there".
    func testChangingTheCallsignRepointsOnlyTheModesKeyedByIt() {
        let mine = OperatorIdentity(callsign: "VK1XYZ")
        let contest = OperatorIdentity(callsign: "VK1ABC")

        let allStar = NodeSettings(host: "node.example.org", node: "55553", username: "vk1xyz")
        XCTAssertEqual(allStar.secretAccount(for: mine), allStar.secretAccount(for: contest))

        let echoLink = NodeSettings(mode: .echoLink, host: "proxy.example.org")
        XCTAssertNotEqual(echoLink.secretAccount(for: mine), echoLink.secretAccount(for: contest))
    }

    // MARK: - Name and location

    /// Trimmed, but neither required nor uppercased: they are display text
    /// shown to another human, and blank is a legitimate thing to say.
    func testTheNameAndLocationAreTrimmedButOptional() throws {
        let validated = try OperatorIdentity(
            callsign: "vk1xyz", operatorName: "  Charles ", location: " Canberra\n"
        ).validated()

        XCTAssertEqual(validated.operatorName, "Charles")
        XCTAssertEqual(validated.location, "Canberra")

        let bare = try OperatorIdentity(callsign: "VK1XYZ").validated()
        XCTAssertEqual(bare.operatorName, "")
        XCTAssertEqual(bare.location, "")
    }

    func testAMissingNameAndLocationDoNotBlockValidation() throws {
        XCTAssertNoThrow(
            try OperatorIdentity(callsign: "VK1XYZ", operatorName: "", location: "").validated())
    }

    /// Neither touches the Keychain account. Only the callsign keys a secret,
    /// so an operator who moves house must not be asked for their EchoLink
    /// password again.
    func testChangingTheNameOrLocationDoesNotRepointASecret() {
        let home = OperatorIdentity(
            callsign: "VK1XYZ", operatorName: "Charles", location: "Canberra")
        var away = home
        away.location = "Sydney"
        away.operatorName = "Chas"

        let echoLink = NodeSettings(mode: .echoLink, host: "proxy.example.org")
        XCTAssertEqual(echoLink.secretAccount(for: home), echoLink.secretAccount(for: away))
    }

    func testItRoundTripsThroughCodable() throws {
        let identity = OperatorIdentity(
            callsign: "VK1XYZ", operatorName: "Charles", location: "Canberra")
        let data = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(OperatorIdentity.self, from: data), identity)
    }
}
