// SPDX-License-Identifier: Apache-2.0

import EchoLinkKit
import IAX2Kit
import M17Kit
import XCTest

@testable import Currawong

/// What the operator is told when a call cannot be placed, one test per
/// cause.
///
/// The assertions are on what the advice names, not its whole wording: the
/// point of each is that the operator is sent to the right thing to check, and
/// that a symptom with two causes names both.
final class ConnectFailureTests: XCTestCase {
    // MARK: IAX2

    /// A wrong secret and a disallowed account are both a REJECT, so the
    /// advice sends the operator to both.
    func testAnIAX2RejectionNamesTheSecretAndTheAccount() throws {
        let error = IAX2ClientError.rejected(cause: "No authority found", causeCode: 50)
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(iax2: error, webTransceiver: false))

        XCTAssertTrue(failure.advice.contains("secret"))
        XCTAssertTrue(failure.advice.contains("account"))
        XCTAssertTrue(failure.detail.contains("No authority found"), "the node's text is kept")
    }

    func testARejectionWithNoCauseGetsTheSameAdvice() throws {
        let bare = try XCTUnwrap(
            CompositionRoot.connectFailure(
                iax2: IAX2ClientError.rejected(cause: nil, causeCode: nil),
                webTransceiver: false))
        let caused = try XCTUnwrap(
            CompositionRoot.connectFailure(
                iax2: IAX2ClientError.rejected(cause: "No authority found", causeCode: 50),
                webTransceiver: false))

        XCTAssertEqual(bare.advice, caused.advice)
    }

    /// A Web Transceiver channel has no secret of its own to check.
    func testAWebTransceiverRejectionNamesTheSignInNotASecret() throws {
        let error = IAX2ClientError.rejected(cause: nil, causeCode: nil)
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(iax2: error, webTransceiver: true))

        XCTAssertTrue(failure.advice.contains("Web Transceiver"))
        XCTAssertTrue(failure.advice.contains("Sign in"))
        XCTAssertFalse(failure.advice.contains("secret"))
    }

    /// An unreachable host and a silent node are the same timeout.
    func testAnIAX2TimeoutNamesTheAddressAndTheNetwork() throws {
        let error = IAX2ClientError.connectTimedOut(.seconds(10))
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(iax2: error, webTransceiver: false))

        XCTAssertTrue(failure.advice.contains("host or port"))
        XCTAssertTrue(failure.advice.contains("offline"))
        XCTAssertTrue(failure.advice.contains("online"))
    }

    func testAnIAX2ErrorThatIsNotAboutConnectingPassesThrough() {
        XCTAssertNil(
            CompositionRoot.connectFailure(
                iax2: IAX2ClientError.alreadyConnected, webTransceiver: false))
    }

    // MARK: M17

    func testAnM17RefusalNamesTheModule() throws {
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(
                m17: M17ReflectorClientError.connectionRefused(module: "C")))

        XCTAssertTrue(failure.advice.contains("module C"))
        XCTAssertTrue(failure.advice.contains("callsign"))
    }

    func testAnM17TimeoutNamesTheAddressAndTheNetwork() throws {
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(
                m17: M17ReflectorClientError.connectTimedOut(.seconds(5))))

        XCTAssertTrue(failure.advice.contains("host or port"))
        XCTAssertTrue(failure.advice.contains("online"))
    }

    // MARK: EchoLink

    /// Offline, busy and ignoring us are all silence.
    func testAnEchoLinkStationThatDoesNotAnswerNamesAllThreeReasons() throws {
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(echoLink: EchoLinkClientError.nodeDidNotAnswer))

        XCTAssertTrue(failure.advice.contains("offline"))
        XCTAssertTrue(failure.advice.contains("busy"))
        XCTAssertFalse(failure.advice.contains("SDES"), "protocol words stay in the detail")
        XCTAssertTrue(failure.detail.contains("SDES"))
    }

    /// A refused proxy password arrives as a closed stream, and so does a
    /// proxy that is in use.
    func testAClosedProxyStreamNamesThePasswordAndContention() throws {
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(
                echoLink: EchoLinkClientError.proxy(.streamClosed)))

        XCTAssertTrue(failure.advice.contains("password"))
        XCTAssertTrue(failure.advice.contains("in use"))
    }

    func testAProxyThatDoesNotAnswerNamesItsAddress() throws {
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(
                echoLink: EchoLinkClientError.proxy(.timedOut(operation: "login"))))

        XCTAssertTrue(failure.advice.contains("address and port"))
        XCTAssertFalse(failure.advice.contains("password"))
    }

    func testARefusedDirectoryLoginNamesTheEchoLinkPassword() throws {
        let failure = try XCTUnwrap(
            CompositionRoot.connectFailure(
                echoLink: EchoLinkClientError.directory(.loginRejected(reply: "NO"))))

        XCTAssertTrue(failure.advice.contains("EchoLink password"))
        XCTAssertTrue(failure.advice.contains("validated"))
    }

    // MARK: What the alert reads

    func testTheAdviceLeadsAndTheLibrarysWordsFollow() {
        let failure = ConnectFailure(advice: "Check the address.", detail: "no ACKN within 5 s")

        XCTAssertEqual("\(failure)", "Check the address.\n\nDetail: no ACKN within 5 s.")
    }
}
