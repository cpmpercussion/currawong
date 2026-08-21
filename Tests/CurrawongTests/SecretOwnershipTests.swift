// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-14.** Whose secret a channel connects with, and what connecting is
/// therefore allowed to write.
///
/// The question `connect()` used to ask was "is this Web Transceiver?". These
/// tests are the three answers it should have been asking for.
final class SecretOwnershipTests: XCTestCase {
    private let identity = OperatorIdentity(callsign: "VK1XYZ")

    // MARK: - The decision

    func testAnAllStarLinkChannelOwnsItsOwnNodeSecret() {
        let settings = NodeSettings(host: "node.example.org", node: "55553", username: "vk1xyz")
        XCTAssertEqual(
            settings.secretOwnership(for: identity),
            .channel(account: settings.secretAccount(for: identity)))
    }

    /// A Web Transceiver channel authenticates with a token, which is not a
    /// secret and has an account of its own — so the node-secret slot is not
    /// this channel's to write. That was already true and already commented; it
    /// is now the same rule as the other two.
    func testAWebTransceiverChannelOwnsNoSecret() {
        var settings = NodeSettings(host: "node.example.org", node: "55553")
        settings.allStarAccess = .webTransceiver
        XCTAssertEqual(settings.secretOwnership(for: identity), NodeSettings.SecretOwnership.none)
    }

    /// The form says "M17 reflectors are unauthenticated. Your callsign
    /// identifies you." This is the storage layer agreeing with it.
    func testAnM17ChannelOwnsNoSecret() {
        var settings = NodeSettings(mode: .m17, host: "m17-cbr.example.org")
        settings.module = "A"
        XCTAssertEqual(settings.secretOwnership(for: identity), NodeSettings.SecretOwnership.none)
    }

    /// One password for the whole app, under the callsign, which the settings
    /// screen owns.
    func testAnEchoLinkChannelUsesTheAppWidePassword() {
        let settings = NodeSettings(mode: .echoLink, node: "9999")
        XCTAssertEqual(
            settings.secretOwnership(for: identity),
            .appWide(account: NodeSettings.echoLinkAccount(for: identity)))
    }

    /// Two EchoLink channels are the same account, which is the whole reason it
    /// is app-wide — and the reason connecting must not write it: the write would
    /// not be about the channel it came from.
    func testEveryEchoLinkChannelIsTheSameAccount() {
        let one = NodeSettings(mode: .echoLink, node: "9999")
        var two = NodeSettings(mode: .echoLink, node: "1234")
        two.peer = "somewhere.example.org"
        XCTAssertEqual(one.secretOwnership(for: identity), two.secretOwnership(for: identity))
    }
}
