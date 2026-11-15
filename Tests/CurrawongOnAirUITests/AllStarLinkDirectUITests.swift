// SPDX-License-Identifier: Apache-2.0

import XCTest

#if os(macOS)
    import AppKit
#endif

/// AllStarLink through the app, with a real node secret: add a channel, connect
/// with IAX Direct, and check the link is still up half a minute later.
///
/// ## It does not transmit
///
/// Nothing is keyed. It places a call to a node, which is what a credentials
/// check does, so point it at a node of your own. It lives in the on-air target
/// because it needs a live node and a credential, not because it keys.
///
/// ## Where the credential comes from, and where it goes
///
/// Four values, supplied per run and never committed. Without all four the
/// test skips:
///
/// ```sh
/// xcodebuild ... \
///     TEST_RUNNER_CURRAWONG_ONAIR_IAX_HOST=<host> \
///     TEST_RUNNER_CURRAWONG_ONAIR_IAX_NODE=<node number> \
///     TEST_RUNNER_CURRAWONG_ONAIR_IAX_USER=<username> \
///     TEST_RUNNER_CURRAWONG_ONAIR_IAX_SECRET=<secret>
/// ```
///
/// The app stores the secret in the Keychain, and ``IsolatedApp`` gives it a
/// throwaway Keychain service along with the throwaway defaults suite, so the
/// operator's own stored secret is neither overwritten nor deleted. The test
/// relaunches with a reset at the end so the copy does not outlive the run.
///
/// ## Pasted, not typed, and so macOS only
///
/// `typeText` writes what it typed into the test log and the result bundle. A
/// secret must not go there, so it is put on the pasteboard and pasted, which
/// logs a keystroke and nothing else, and the pasteboard is cleared straight
/// after. Whatever was on the clipboard before the run is lost. iOS has no paste a UI test can drive without a permission prompt, so
/// there this skips.
final class AllStarLinkDirectUITests: XCTestCase {

    private let channelName = "IAX Direct on-air test"

    /// How long the link must stay up. A rejected call is answered by some
    /// nodes before being dropped, so "connected" for an instant proves little.
    private let holdDuration: TimeInterval = 30

    override func setUp() {
        continueAfterFailure = false
    }

    func testIAXDirectConnectsAndStaysConnected() throws {
        #if os(macOS)
            let callsign = try IsolatedApp.requireOperatorCallsign()
            let host = try require("CURRAWONG_ONAIR_IAX_HOST")
            let node = try require("CURRAWONG_ONAIR_IAX_NODE")
            let username = try require("CURRAWONG_ONAIR_IAX_USER")
            let secret = try require("CURRAWONG_ONAIR_IAX_SECRET")

            let app = IsolatedApp.launched()
            giveCallsign(callsign, in: app)

            let add = app.buttons["Add channel"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
            add.activate()

            let network = app.buttons["addChannel.network.allStarLink"].firstMatch
            XCTAssertTrue(
                network.waitForExistence(timeout: 5), "Add channel did not offer AllStarLink")
            network.activate()

            let sheet = app.sheets.firstMatch
            let scope: XCUIElement = sheet.exists ? sheet : app
            for (identifier, text) in [
                ("connect.channelName", channelName), ("connect.host", host),
                ("connect.node", node), ("connect.username", username),
            ] {
                let field = scope.textFields[identifier].firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
                replace(text, in: field)
            }

            let secretField = scope.secureTextFields["connect.secret"].firstMatch
            XCTAssertTrue(secretField.waitForExistence(timeout: 5), "no secret field")
            paste(secret, into: secretField)

            let confirm = app.buttons["addChannel.add"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no Add button")
            XCTAssertTrue(confirm.isEnabled, "Add is disabled on a channel with an address")
            confirm.activate()

            let connect = app.buttons["Connect to \(channelName)"].firstMatch
            XCTAssertTrue(
                connect.waitForExistence(timeout: 5), "no link button naming this channel")
            connect.activate()

            // The PTT control exists either way; enabled is what says the link
            // is up. It is never pressed.
            let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
            XCTAssertTrue(ptt.waitForExistence(timeout: 20), "no PTT control")
            XCTAssertTrue(
                waitUntil(timeout: 30) { ptt.isEnabled },
                "the call never came up — PTT stayed disabled")

            Thread.sleep(forTimeInterval: holdDuration)
            XCTAssertTrue(
                ptt.isEnabled,
                "the link dropped within \(Int(holdDuration)) seconds of connecting")

            let disconnect = app.buttons["Disconnect"].firstMatch
            XCTAssertTrue(disconnect.exists, "no Disconnect while connected")
            disconnect.activate()
            // The link button changes back when the call is down. Not read from
            // the PTT control: it leaves the hierarchy on disconnect, and asking
            // a missing element whether it is enabled is itself a failure.
            XCTAssertTrue(
                waitUntil(timeout: 30) {
                    // "Reconnect to" for the channel just left, which this is.
                    app.buttons["Reconnect to \(self.channelName)"].firstMatch.exists
                        || app.buttons["Connect to \(self.channelName)"].firstMatch.exists
                },
                "the link button never offered to connect again after Disconnect")

            // A reset launch empties the throwaway Keychain service, so the
            // secret does not sit there until the next run.
            app.terminate()
            IsolatedApp.launched().terminate()
        #else
            throw XCTSkip("macOS only: the secret is pasted, and iOS cannot paste unprompted.")
        #endif
    }

    #if os(macOS)
        private func require(_ variable: String) throws -> String {
            let value = (ProcessInfo.processInfo.environment[variable] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw XCTSkip(
                    "No \(variable). Pass TEST_RUNNER_\(variable)=<value> to xcodebuild, "
                        + "with the other three; see this file's header.")
            }
            return value
        }

        /// Through the pasteboard, so the value never reaches the test log.
        private func paste(_ secret: String, into field: XCUIElement) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(secret, forType: .string)
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey("v", modifierFlags: .command)
            // The paste is handled by the app, a moment after the keystroke.
            Thread.sleep(forTimeInterval: 0.5)
            pasteboard.clearContents()
        }

        private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return condition()
        }
    #endif
}
