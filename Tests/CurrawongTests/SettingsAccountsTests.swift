// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// APP-12 — the settings screen's two stored accounts and the portal login.
///
/// Nothing here touches the network: ``PortalLogin`` is the app's own seam over
/// the library's token fetch, substituted with a stub, which is the whole reason
/// that protocol exists.
@MainActor
final class SettingsAccountsTests: XCTestCase {
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")
    private let token = "1b59df18107e"

    // MARK: - Helpers

    /// A login that answers from a script and records what it was asked.
    private final class StubLogin: PortalLogin, @unchecked Sendable {
        private let lock = NSLock()
        private let result: Result<String, PortalLoginFailure>
        private var asked: [(callsign: String, password: String)] = []
        /// Held until released, for the test about state while a login is in
        /// flight.
        private let gate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?

        init(_ result: Result<String, PortalLoginFailure>, gated: Bool = false) {
            self.result = result
            if gated {
                var escape: AsyncStream<Void>.Continuation!
                let stream = AsyncStream<Void> { escape = $0 }
                self.gate = (stream, escape)
            } else {
                self.gate = nil
            }
        }

        var calls: [(callsign: String, password: String)] {
            lock.lock()
            defer { lock.unlock() }
            return asked
        }

        func release() { gate?.continuation.finish() }

        func token(callsign: String, password: String) async throws -> String {
            lock.lock()
            asked.append((callsign, password))
            lock.unlock()
            if let gate {
                for await _ in gate.stream {}  // finishes when released
            }
            return try result.get()
        }
    }

    private func settleLogin(_ controller: PortalLoginController) async {
        // The controller runs its fetch in a `Task`; yielding lets it finish.
        for _ in 0 ..< 50 where controller.isWorking {
            await Task.yield()
        }
    }

    // MARK: - The portal login

    /// The shipping wiring has no `PortalLogin` — IAX-13 is not in a released
    /// library tag — and the pane must then offer only the paste field rather
    /// than a button that cannot work.
    func testLoggingInIsUnavailableWithoutAFetcher() {
        let controller = PortalLoginController()

        XCTAssertFalse(controller.isAvailable)
        controller.password = "hunter2"
        controller.logIn(callsign: "VK1XYZ") { _ in XCTFail("nothing to log in with") }
        XCTAssertFalse(controller.isWorking)
    }

    func testASuccessfulLoginHandsTheTokenToItsCallerAndForgetsThePassword() async {
        let login = StubLogin(.success(token))
        let controller = PortalLoginController(login: login)
        controller.password = "portal-password"
        var applied: String?

        controller.logIn(callsign: "VK1XYZ") { applied = $0 }
        await settleLogin(controller)

        XCTAssertEqual(applied, token)
        XCTAssertEqual(login.calls.map(\.callsign), ["VK1XYZ"])
        XCTAssertEqual(login.calls.map(\.password), ["portal-password"])
        XCTAssertEqual(controller.password, "", "the portal password is not kept")
        XCTAssertTrue(controller.didSucceed)
        XCTAssertNil(controller.failure)
    }

    /// The one failure where re-typing is the answer, so it is the one that
    /// clears the field.
    func testAWrongPasswordIsReportedAndTheFieldIsCleared() async {
        let controller = PortalLoginController(login: StubLogin(.failure(.wrongPassword)))
        controller.password = "wrong"

        controller.logIn(callsign: "VK1XYZ") { _ in XCTFail("should not have got a token") }
        await settleLogin(controller)

        XCTAssertEqual(controller.password, "")
        XCTAssertEqual(controller.failure, PortalLoginFailure.wrongPassword.description)
        XCTAssertFalse(controller.didSucceed)
    }

    /// A changed endpoint is not the operator's fault, so their password stays
    /// in the field: nothing they retype would help, and clearing it would
    /// suggest otherwise.
    func testAChangedEndpointKeepsThePasswordAndSaysWhatStillWorks() async {
        let controller = PortalLoginController(login: StubLogin(.failure(.endpointChanged)))
        controller.password = "portal-password"

        controller.logIn(callsign: "VK1XYZ") { _ in XCTFail("should not have got a token") }
        await settleLogin(controller)

        XCTAssertEqual(controller.password, "portal-password")
        XCTAssertTrue(try XCTUnwrap(controller.failure).contains("pasted"))
    }

    func testTheFourFailuresReadDifferently() {
        let all: [PortalLoginFailure] = [
            .wrongPassword, .endpointChanged, .refused("account suspended"),
            .unreachable("timed out"),
        ]
        XCTAssertEqual(Set(all.map(\.description)).count, all.count)
        XCTAssertTrue(PortalLoginFailure.wrongPassword.wantsPasswordAgain)
        XCTAssertFalse(PortalLoginFailure.endpointChanged.wantsPasswordAgain)
    }

    func testAnEmptyCallsignOrPasswordIsRefusedBeforeAnythingIsSent() {
        let login = StubLogin(.success(token))
        let controller = PortalLoginController(login: login)

        controller.password = "portal-password"
        controller.logIn(callsign: "   ") { _ in XCTFail("nothing should be sent") }
        XCTAssertNotNil(controller.failure)

        controller.password = ""
        controller.logIn(callsign: "VK1XYZ") { _ in XCTFail("nothing should be sent") }
        XCTAssertNotNil(controller.failure)
        XCTAssertTrue(login.calls.isEmpty)
    }

    func testASecondAttemptIsIgnoredWhileOneIsInFlightAndCancelStopsIt() async {
        let login = StubLogin(.success(token), gated: true)
        let controller = PortalLoginController(login: login)
        controller.password = "portal-password"

        controller.logIn(callsign: "VK1XYZ") { _ in }
        await Task.yield()
        XCTAssertTrue(controller.isWorking)

        controller.logIn(callsign: "VK1XYZ") { _ in }
        XCTAssertEqual(login.calls.count, 1, "one login at a time")

        controller.cancel()
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(
            controller.password, "portal-password",
            "a cancelled attempt is usually one about to be retried")
        login.release()
    }

    // MARK: - Where the token is stored

    /// The settings screen is not a connect form: an operator who fetches a
    /// token and switches away expects it to still be there.
    func testSavingTheTokenReachesTheKeychainWithoutConnecting() {
        let harness = SessionHarness()

        XCTAssertTrue(harness.session.saveWebTransceiverToken(" \(token) "))

        XCTAssertEqual(harness.session.webTransceiverToken, token, "trimmed")
        XCTAssertEqual(
            harness.secretStore.all[NodeSettings.webTransceiverAccount(for: vk1xyz)], token)
        XCTAssertEqual(harness.linksMade, 0, "nothing was connected")
    }

    func testForgettingTheTokenClearsTheSlot() {
        let harness = SessionHarness(
            secrets: [NodeSettings.webTransceiverAccount(for: vk1xyz): token])
        XCTAssertEqual(harness.session.webTransceiverToken, token)

        harness.session.saveWebTransceiverToken("")

        XCTAssertEqual(harness.session.webTransceiverToken, "")
        XCTAssertNil(harness.secretStore.all[NodeSettings.webTransceiverAccount(for: vk1xyz)])
    }

    func testAFailedTokenWriteIsReportedButTheTokenStillWorksThisRun() {
        let harness = SessionHarness()
        harness.secretStore.failWrites = true

        XCTAssertFalse(harness.session.saveWebTransceiverToken(token))

        XCTAssertEqual(harness.session.webTransceiverToken, token)
        XCTAssertEqual(harness.session.alert?.title, "Could not save the token")
    }

    /// The whole login path, as the screen drives it: controller fetches,
    /// session stores.
    func testTheLoginPathEndsWithTheTokenInTheKeychain() async {
        let harness = SessionHarness()
        let controller = PortalLoginController(login: StubLogin(.success(token)))
        controller.password = "portal-password"

        controller.logIn(callsign: harness.session.identity.callsign) { fetched in
            harness.session.saveWebTransceiverToken(fetched)
        }
        await settleLogin(controller)

        XCTAssertEqual(
            harness.secretStore.all[NodeSettings.webTransceiverAccount(for: vk1xyz)], token)
        XCTAssertEqual(harness.session.webTransceiverToken, token)
    }

    // MARK: - The EchoLink account

    /// One password per callsign, which is how the Keychain has always held it —
    /// the settings screen is only the first place to say so.
    func testTheEchoLinkAccountIsFiledUnderTheCallsignAndLoadedAtLaunch() {
        let harness = SessionHarness(
            secrets: [NodeSettings.echoLinkAccount(for: vk1xyz): "account-password"])

        XCTAssertEqual(harness.session.echoLinkAccountPassword, "account-password")
        XCTAssertEqual(
            NodeSettings.echoLinkAccount(for: OperatorIdentity(callsign: "vk1xyz")),
            NodeSettings.echoLinkAccount(for: vk1xyz),
            "normalised, so a lower-case callsign finds what it stored")
    }

    func testSavingTheEchoLinkPasswordReachesTheKeychain() {
        let harness = SessionHarness()

        XCTAssertTrue(harness.session.setEchoLinkAccountPassword("account-password"))

        XCTAssertEqual(
            harness.secretStore.all[NodeSettings.echoLinkAccount(for: vk1xyz)],
            "account-password")
    }

    /// The mirroring that stops the app connecting with the old password:
    /// `connect()` sends `secret`, and the settings screen writes the account.
    func testChangingItWhileAnEchoLinkChannelIsSelectedUpdatesWhatWillBeSent() {
        let echo = SessionHarness.echoLinkSettings
        let harness = SessionHarness(
            settings: echo,
            secrets: [echo.secretAccount(for: vk1xyz): "old-password"])
        XCTAssertEqual(harness.session.secret, "old-password", "precondition")

        harness.session.setEchoLinkAccountPassword("new-password")

        XCTAssertEqual(harness.session.secret, "new-password")
        XCTAssertEqual(harness.session.echoLinkAccountPassword, "new-password")
    }

    /// And it must *not* reach into a channel of another mode, whose `secret` is
    /// a node secret that has nothing to do with EchoLink.
    func testChangingItLeavesAnAllStarChannelsSecretAlone() {
        let allStar = SessionHarness.goodSettings
        let harness = SessionHarness(
            settings: allStar,
            secrets: [allStar.secretAccount(for: vk1xyz): "hunter2"])

        harness.session.setEchoLinkAccountPassword("account-password")

        XCTAssertEqual(harness.session.secret, "hunter2")
        XCTAssertEqual(
            harness.secretStore.all[allStar.secretAccount(for: vk1xyz)], "hunter2",
            "and nothing was written over the node secret")
    }

    func testAFailedEchoLinkWriteIsReportedButWorksThisRun() {
        let harness = SessionHarness()
        harness.secretStore.failWrites = true

        XCTAssertFalse(harness.session.setEchoLinkAccountPassword("account-password"))

        XCTAssertEqual(harness.session.echoLinkAccountPassword, "account-password")
        XCTAssertEqual(harness.session.alert?.title, "Could not save the password")
    }

    /// The two credentials the settings screen holds must not be filed together:
    /// one is a portal token, the other an EchoLink password.
    func testTheTwoAccountsAreSeparateSlots() {
        XCTAssertNotEqual(
            NodeSettings.webTransceiverAccount(for: vk1xyz),
            NodeSettings.echoLinkAccount(for: vk1xyz))
    }
}
