// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-14, the EchoLink half.** One password, one place, and connecting never
/// writes it.
///
/// The plan entry asked whether the two in-memory copies of the app-wide
/// password could be made to disagree, and said that if they could, "that is a
/// lost password, not a cosmetic alert". They could, three ways, and the third
/// was worse than a lost password: the station browser read the *other* copy, so
/// the ordinary path — type the password on the settings screen, open the
/// Stations pane, press Refresh — sent the directory server an empty string.
@MainActor
final class EchoLinkPasswordTests: XCTestCase {
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")
    private let echo = SessionHarness.echoLinkSettings

    // MARK: - What the directory server is sent

    /// The fault the maintainer reported: the password is stored, the settings
    /// screen says so, and the listing does not work.
    func testTheDirectoryRequestCarriesTheAccountPassword() {
        let harness = SessionHarness(settings: echo)
        harness.session.setEchoLinkAccountPassword("account-password")

        XCTAssertEqual(harness.session.directoryRequest.accountPassword, "account-password")
    }

    /// And it carries it whatever the selected channel is. This is the case that
    /// was broken: the old mirror into `secret` ran only while an EchoLink
    /// channel was selected, so a password typed with an AllStarLink channel
    /// selected — the default, on a fresh app — never reached the browser.
    func testTheDirectoryRequestCarriesItWithAnAllStarLinkChannelSelected() {
        let harness = SessionHarness(settings: SessionHarness.goodSettings)
        harness.session.secret = "a-node-secret"

        harness.session.setEchoLinkAccountPassword("account-password")

        XCTAssertEqual(harness.session.directoryRequest.accountPassword, "account-password")
        XCTAssertEqual(
            harness.session.secret, "a-node-secret",
            "and the node secret in the form is left alone")
    }

    /// The other half of the same fault: a node secret must never be offered to
    /// the directory server as an account password. Under the old code, switching
    /// a draft from AllStarLink to EchoLink left the node secret in `secret`,
    /// which is what the browser read.
    func testANodeSecretIsNeverSentAsTheAccountPassword() {
        let harness = SessionHarness(settings: SessionHarness.goodSettings)
        harness.session.secret = "a-node-secret"

        harness.session.settings.mode = .echoLink

        XCTAssertEqual(harness.session.directoryRequest.accountPassword, "")
    }

    // MARK: - What a connection sends

    func testAnEchoLinkConnectionIsBuiltWithTheAccountPassword() async {
        let harness = SessionHarness(
            settings: echo,
            secrets: [NodeSettings.echoLinkAccount(for: OperatorIdentity(callsign: "VK1XYZ")):
                "account-password"])

        await harness.session.connect()

        XCTAssertEqual(harness.credentialsSeen.last?.secret, "account-password")
    }

    // MARK: - What connecting must not write

    /// **The lost password.** `SecretStore` deletes on an empty value, so under
    /// the old code one connect attempt with an empty form field removed the
    /// account password — while `echoLinkAccountPassword` went on claiming, in
    /// Settings, that it was stored.
    func testConnectingDoesNotWriteTheAppWidePassword() async {
        let account = NodeSettings.echoLinkAccount(for: vk1xyz)
        let harness = SessionHarness(settings: echo, secrets: [account: "account-password"])

        await harness.session.connect()

        XCTAssertEqual(
            harness.secretStore.all[account], "account-password",
            "connecting neither rewrote nor deleted the settings screen's password")
        XCTAssertFalse(
            harness.secretStore.writes.contains { $0.account == account },
            "and did not write to that account at all")
    }

    /// M17's half of APP-14: no write at all, so no alert on the happy path of a
    /// mode that has no secrets.
    func testConnectingAnM17ChannelWritesNothingAndRaisesNothing() async {
        var m17 = NodeSettings(mode: .m17, host: "m17-cbr.example.org", port: 17_000)
        m17.module = "A"
        let harness = SessionHarness(settings: m17)

        await harness.session.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        // **On the write log, not on the contents.** The store treats an empty
        // value as a removal, exactly as the Keychain does, so the old code's
        // write of `""` to `m17:…` left the contents unchanged and was invisible
        // to an assertion about them. It is the write itself that must not
        // happen: it is the one that raised "the secret was not stored" on the
        // happy path of a mode that has no secrets.
        XCTAssertEqual(
            harness.secretStore.writes.map(\.account), [],
            "an unauthenticated mode attempted a Keychain write")
        XCTAssertNil(harness.session.alert)
    }

    /// AllStarLink still stores its own, which is the behaviour APP-14 must not
    /// break.
    func testConnectingAnAllStarLinkChannelStoresItsNodeSecret() async {
        let harness = SessionHarness(settings: SessionHarness.goodSettings)
        harness.session.secret = "hunter2"

        await harness.session.connect()

        XCTAssertEqual(
            harness.secretStore.all[SessionHarness.goodSettings.secretAccount(for: vk1xyz)],
            "hunter2")
    }

    /// And an empty field does not delete what is there. The account string is
    /// shared by every channel with the same username, host, port and node, so
    /// the deletion would not even be about the channel that triggered it — the
    /// reason the Web Transceiver arm always left this slot alone.
    func testConnectingWithAnEmptySecretDoesNotDeleteTheStoredOne() async {
        let account = SessionHarness.goodSettings.secretAccount(for: vk1xyz)
        let harness = SessionHarness(
            settings: SessionHarness.goodSettings, secrets: [account: "hunter2"])
        harness.session.secret = ""

        await harness.session.connect()

        XCTAssertEqual(harness.secretStore.all[account], "hunter2")
    }
}
