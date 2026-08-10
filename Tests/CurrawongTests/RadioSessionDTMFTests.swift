// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// DTMF, in and out (FR-1.5).
///
/// The behaviour worth pinning is the one that is easy to get wrong by
/// accident: **sending a digit must not key the transmitter.** DTMF travels as
/// its own reliable frame, and a keypad that quietly puts the operator on air
/// would be the worst kind of surprise in this app.
@MainActor
final class RadioSessionDTMFTests: XCTestCase {

    private func connectedHarness() async -> SessionHarness {
        let harness = SessionHarness()
        await harness.connect()
        return harness
    }

    func testSendingADigitReachesTheClientAndIsLogged() async {
        let harness = await connectedHarness()

        await harness.session.sendDTMF("*")
        await harness.session.sendDTMF("3")

        XCTAssertEqual(harness.client.sentDigits, "*3")
        XCTAssertEqual(harness.session.sentDTMF, "*3")
        XCTAssertNil(harness.session.alert)
    }

    /// The one that matters. Nothing about a keypad press may open the
    /// microphone or key the client.
    func testSendingADigitDoesNotTransmit() async {
        let harness = await connectedHarness()

        await harness.session.sendDTMF("5")

        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.audio.isCapturing)
        XCTAssertEqual(harness.audio.startCaptureCount, 0)
        XCTAssertFalse(harness.client.calls.contains(.startTransmit))
    }

    /// The library is deliberately strict about the RFC's `A`–`D` and says the
    /// layer that owns a keypad should normalise. This is that layer.
    func testLowerCaseLettersAreUpperCasedOnTheWayOut() async {
        let harness = await connectedHarness()

        await harness.session.sendDTMF("d")

        XCTAssertEqual(harness.client.sentDigits, "D")
        XCTAssertEqual(harness.session.sentDTMF, "D")
    }

    /// Upper-casing is not one-to-one, and `Character.init` traps on a
    /// multi-character string. Unreachable from the keypad, but the method takes
    /// any `Character` and must not be a way to crash the app.
    func testACharacterWhoseUpperCaseIsTwoCharactersDoesNotTrap() async {
        let harness = await connectedHarness()

        await harness.session.sendDTMF("ß")

        // Passed through unchanged and refused by the client, which is the
        // library's job. The point of the test is that we got here at all.
        XCTAssertEqual(harness.client.sentDigits, "ß")
    }

    func testSendingWithNoConnectionIsRefusedAndSaysSo() async {
        let harness = SessionHarness()

        await harness.session.sendDTMF("1")

        XCTAssertEqual(harness.client.sentDigits, "")
        XCTAssertEqual(harness.session.sentDTMF, "")
        XCTAssertEqual(harness.session.alert?.title, "Not connected")
    }

    /// A digit that the client refused was not sent, so it must not appear in
    /// the sent log — the log's only value is answering "did that go out?".
    func testAFailedSendIsNotLoggedAsSent() async {
        let harness = await connectedHarness()
        harness.client.dtmfError = SessionHarness.ConnectFailed()

        await harness.session.sendDTMF("7")

        XCTAssertEqual(harness.session.sentDTMF, "")
        XCTAssertEqual(harness.session.alert?.title, "Could not send 7")
    }

    func testInboundDigitsAreLogged() async {
        let harness = await connectedHarness()

        harness.eventContinuation.yield(.dtmfReceived("1"))
        harness.eventContinuation.yield(.dtmfReceived("#"))

        await waitUntil("both inbound digits arrived") {
            harness.session.receivedDTMF == "1#"
        }
        XCTAssertEqual(harness.session.sentDTMF, "", "inbound digits must not appear as sent")
    }

    /// The log is a recent history for the operator's eyes, not a record, and an
    /// unbounded one would grow for the length of a net.
    func testTheLogsAreTrimmedToTheirLimit() async {
        let harness = await connectedHarness()
        let limit = RadioSession<FakeNetworkClient>.dtmfLogLimit

        for _ in 0..<(limit + 5) {
            await harness.session.sendDTMF("1")
        }

        XCTAssertEqual(harness.session.sentDTMF.count, limit)
    }

    /// The newest digits are the ones being watched, so trimming drops the
    /// oldest.
    func testTrimmingKeepsTheMostRecentDigits() async {
        let harness = await connectedHarness()
        let limit = RadioSession<FakeNetworkClient>.dtmfLogLimit

        for _ in 0..<limit { await harness.session.sendDTMF("0") }
        await harness.session.sendDTMF("9")

        XCTAssertEqual(harness.session.sentDTMF.last, "9")
        XCTAssertEqual(harness.session.sentDTMF.count, limit)
    }

    /// A fresh call starts with fresh logs. Digits from a previous connection
    /// hanging around would be read as this node's answers.
    func testConnectingClearsTheLogsAndTheCodec() async {
        let harness = await connectedHarness()
        await harness.session.sendDTMF("1")
        harness.eventContinuation.yield(.connected(codec: "G.711 µ-law"))
        harness.eventContinuation.yield(.dtmfReceived("2"))
        await waitUntil("the first session logged something") {
            harness.session.receivedDTMF == "2" && harness.session.negotiatedCodec != nil
        }

        await harness.session.disconnect()
        await harness.connect()

        XCTAssertEqual(harness.session.sentDTMF, "")
        XCTAssertEqual(harness.session.receivedDTMF, "")
        XCTAssertNil(harness.session.negotiatedCodec)
    }

    // MARK: - Codec

    func testTheNegotiatedCodecIsRecordedForDisplay() async {
        let harness = await connectedHarness()

        harness.eventContinuation.yield(.connected(codec: "G.711 µ-law"))

        await waitUntil("the codec arrived") {
            harness.session.negotiatedCodec == "G.711 µ-law"
        }
    }

    /// A node that does not say which codec it chose must not blank a codec the
    /// app already knows.
    func testAConnectedEventWithoutACodecDoesNotEraseOne() async {
        let harness = await connectedHarness()
        harness.eventContinuation.yield(.connected(codec: "G.711 µ-law"))
        await waitUntil("the codec arrived") { harness.session.negotiatedCodec != nil }

        harness.eventContinuation.yield(.connected(codec: nil))
        harness.eventContinuation.yield(.receiving)
        await waitUntil("the later events were processed") {
            harness.session.transmitState == harness.client.state
        }

        XCTAssertEqual(harness.session.negotiatedCodec, "G.711 µ-law")
    }

    // MARK: - The keypad's own model

    /// The keypad's alphabet must be a subset of what the library will accept,
    /// or a key on screen throws when pressed. The library's own list is not
    /// importable here — the app does not import `IAX2Kit` — so this asserts the
    /// §8.2 domain by hand, which is the same check `IAX2DTMFDigit` makes.
    func testEveryKeypadDigitIsAValidDTMFSymbol() {
        let valid = Set("0123456789ABCD*#")
        for digit in DTMF.keypadDigits {
            XCTAssertTrue(valid.contains(digit), "\(digit) is not a DTMF symbol")
        }
        XCTAssertEqual(DTMF.keypadDigits.count, 12)
        XCTAssertEqual(Set(DTMF.keypadDigits).count, 12, "a digit appears twice")
    }

    /// `*` and `#` are the two most important keys — nearly every node command
    /// starts with one — and VoiceOver reads them as punctuation or not at all.
    func testStarAndHashAreSpokenAloud() {
        XCTAssertEqual(DTMF.spoken("*"), "star")
        XCTAssertEqual(DTMF.spoken("#"), "hash")
        XCTAssertEqual(DTMF.spoken("7"), "7")
    }
}
