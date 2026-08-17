// SPDX-License-Identifier: Apache-2.0

import IAX2Kit
import XCTest

@testable import Currawong

/// The translation layer between IAX-13's token fetch and the app's own login
/// vocabulary — `AllStarLinkPortalLogin` and `PortalLoginFailure.init(_:)`.
///
/// **This file imports `IAX2Kit`, and it is the only test file that has cause
/// to.** `CompositionRootTests` deliberately does not, because it is asserting
/// that the app reaches the library through `RadioCore` alone. What is under test
/// here is the adapter itself — the one place whose whole job is to name a
/// library type and turn it into an app one — so the import is the subject rather
/// than a leak. `M17CodecIntegrationTests` imports `M17Kit` on the same grounds.
///
/// No request is made: a stub `WebTransceiverTokenSource` is injected, which is
/// what that seam is for (AU-5).
@MainActor
final class PortalLoginAdapterTests: XCTestCase {
    private let token = "1b59df18107e"

    /// Answers from a script, and records the credentials it was handed.
    private final class StubSource: WebTransceiverTokenSource, @unchecked Sendable {
        private let lock = NSLock()
        private let result: Result<WebTransceiverToken, WebTransceiverTokenError>
        private var asked: [(username: String, password: String)] = []

        init(_ result: Result<WebTransceiverToken, WebTransceiverTokenError>) {
            self.result = result
        }

        var calls: [(username: String, password: String)] {
            lock.lock()
            defer { lock.unlock() }
            return asked
        }

        func token(username: String, password: String) async throws -> WebTransceiverToken {
            lock.lock()
            asked.append((username, password))
            lock.unlock()
            return try result.get()
        }
    }

    private func failure(from error: WebTransceiverTokenError) async -> PortalLoginFailure? {
        let login = AllStarLinkPortalLogin(source: StubSource(.failure(error)))
        do {
            _ = try await login.token(callsign: "VK1XYZ", password: "portal-password")
            XCTFail("expected \(error) to be translated, not swallowed")
            return nil
        } catch let translated as PortalLoginFailure {
            return translated
        } catch {
            XCTFail("expected a PortalLoginFailure, got \(error)")
            return nil
        }
    }

    // MARK: - The happy path

    /// The callsign goes in as the username — portal logins are
    /// callsign/password — and the token comes back as the bare string the app
    /// stores.
    func testASuccessfulLoginPassesTheCallsignThroughAndReturnsTheToken() async throws {
        let source = StubSource(.success(WebTransceiverToken(token)))
        let login = AllStarLinkPortalLogin(source: source)

        let fetched = try await login.token(callsign: "VK1XYZ", password: "portal-password")

        XCTAssertEqual(fetched, token)
        XCTAssertEqual(source.calls.map(\.username), ["VK1XYZ"])
        XCTAssertEqual(source.calls.map(\.password), ["portal-password"])
    }

    /// The library hands back whatever the portal said, shape unchecked, and the
    /// adapter must not start policing it — that decision belongs to the node,
    /// and the settings screen only warns.
    func testAnUnfamiliarlyShapedTokenIsPassedThrough() async throws {
        let login = AllStarLinkPortalLogin(
            source: StubSource(.success(WebTransceiverToken("ZZZZ-not-hex"))))

        let fetched = try await login.token(callsign: "VK1XYZ", password: "portal-password")

        XCTAssertEqual(fetched, "ZZZZ-not-hex")
        XCTAssertFalse(NodeSettings.isPlausibleWebTransceiverToken(fetched))
    }

    // MARK: - The mapping

    /// The one case where re-typing is the answer, and the only one that clears
    /// the password field.
    func testAFailedLoginBecomesWrongPassword() async {
        let translated = await failure(from: .loginFailed)
        XCTAssertEqual(translated, .wrongPassword)
        XCTAssertTrue(translated?.wantsPasswordAgain ?? false)
    }

    /// Both rejected-request cases are the same news to an operator: the login
    /// service has changed and nothing they type will help.
    func testBothRejectedRequestCasesBecomeEndpointChanged() async {
        let fromPayload = await failure(from: .invalidJSONPayload)
        let fromFields = await failure(from: .invalidJSONFields)
        XCTAssertEqual(fromPayload, .endpointChanged)
        XCTAssertEqual(fromFields, .endpointChanged)
    }

    func testAnUnseenRefusalCarriesItsMessage() async {
        let translated = await failure(from: .rejected(message: "account suspended"))
        XCTAssertEqual(translated, .refused("account suspended"))
    }

    func testAnUnreadableOrUnreachableAnswerBecomesUnreachable() async {
        let fromMalformed = await failure(from: .malformedResponse("14 bytes that did not decode"))
        let fromRequestFailure = await failure(from: .requestFailed("timed out"))
        XCTAssertEqual(fromMalformed, .unreachable("14 bytes that did not decode"))
        XCTAssertEqual(fromRequestFailure, .unreachable("timed out"))
    }

    /// Not reachable from the shipping wiring — the library refuses a non-HTTPS
    /// endpoint before sending — but the case exists, so the mapping is total
    /// rather than relying on a `default:` that would silently absorb a future
    /// case.
    func testAnInsecureEndpointIsReportedAsAChangedEndpoint() async {
        let translated = await failure(from: .insecureEndpoint(scheme: "http"))
        XCTAssertEqual(translated, .endpointChanged)
    }

    /// Every case reaches the operator as prose, and none of them arrives empty.
    func testEveryTranslatedFailureSaysSomething() async {
        let all: [WebTransceiverTokenError] = [
            .loginFailed, .invalidJSONPayload, .invalidJSONFields,
            .rejected(message: "account suspended"), .malformedResponse("x"),
            .requestFailed("y"), .insecureEndpoint(scheme: "http"),
        ]
        for error in all {
            let translated = await failure(from: error)
            XCTAssertFalse(
                (translated?.description ?? "").isEmpty, "\(error) produced no message")
        }
    }

    // MARK: - The wiring

    /// The point of this whole change: the app ships with logging in switched on,
    /// because its dependency floor is the release that carries the fetch.
    func testTheShippingWiringCanLogIn() {
        let root = CompositionRoot(
            audio: FakeAudioIO(),
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore())

        XCTAssertTrue(root.portalLogin.isAvailable)
    }

    /// And withholding it is still meaningful, which is what a preview or a test
    /// with no business talking to allstarlink.org uses.
    func testALoginCanStillBeWithheld() {
        let root = CompositionRoot(
            audio: FakeAudioIO(),
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore(),
            portalLogin: nil)

        XCTAssertFalse(root.portalLogin.isAvailable)
    }
}
