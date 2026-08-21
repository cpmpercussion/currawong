// SPDX-License-Identifier: Apache-2.0

import XCTest

/// BU-8's app half: drive a real over from Currawong and let somebody else
/// watch it end.
///
/// ## This transmits
///
/// It is a UI test only in mechanism. What it actually does is key a live M17
/// reflector under the operator's callsign, which is why this target is **not
/// in the `Currawong` scheme's `testTargets`** and never runs under `make test`
/// or in CI. It runs from the `CurrawongOnAir` scheme, on purpose, when
/// somebody means it:
///
/// ```sh
/// xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
///     -derivedDataPath DerivedData -destination 'platform=macOS' test
/// ```
///
/// ## It proves nothing on its own
///
/// The whole question — does the far end see the stream *end*, or does the
/// audio just stop — is invisible from the transmitting side, which is the
/// point of BU-8. **Run an observer against the same module while this runs:**
///
/// ```sh
/// cd ../swift-hamvoip
/// swift run hamvoip-cli m17 --host m17-cbr.charlesmartin.au --module A \
///     --callsign <yours-with-a-suffix> --no-audio --duration 120
/// ```
///
/// A pass is the observer printing `RX <callsign> ended — end of over` within a
/// moment of the release. This test's own assertions cover the half it can
/// see: the app connected, keyed, stayed keyed, and unkeyed.
///
/// ## It brings its own channel
///
/// An earlier version typed over whatever channel happened to be selected, and
/// silently repointed a real one at a test reflector — the connect form edits
/// the selected channel in place, and the channel keeps its old name while
/// doing it. So this adds a channel, uses it, and deletes it again. The
/// operator's own channels are not touched.
///
/// ## Microphone
///
/// The app must have microphone permission, and an app launched by a test
/// runner does not get to ask for it. Without it every over carries no frames
/// at all and the observer hears nothing — the same shape as the CLI's
/// `--no-audio`. Run Currawong by hand once, key it, answer the prompt.
final class M17EndOfOverUITests: XCTestCase {

    private let reflector = "m17-cbr.charlesmartin.au"
    private let module = "A"
    private let channelName = "BU-8 on-air test"

    /// How long PTT is held. Long enough to be unambiguous at the observer —
    /// 40 ms per datagram, so three seconds is about 75 of them — and short
    /// enough to be nowhere near the transmit watchdog.
    private let overDuration: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
    }

    func testAnOverEndsWhenPTTIsReleased() throws {
        // **Its own callsign, before anything else.** The suite is wiped at
        // launch, so the identity field comes up empty — and a test that
        // transmits must not invent a callsign. Read the operator's own out of
        // the app's real defaults, or stop: putting a made-up callsign on a
        // reflector is not a thing to do by accident.
        guard let callsign = IsolatedApp.operatorCallsign() else {
            XCTFail(
                "no operator callsign in the app's own defaults, and this test "
                + "transmits. Run Currawong normally, set your callsign, then run this.")
            return
        }

        let app = IsolatedApp.launched()

        // ``IsolatedApp`` empties the suite first, so this says the isolation
        // works rather than cleaning anything up. It is the assertion that stops
        // this test ever again deleting a row it did not create.
        XCTAssertEqual(
            rowCount(named: channelName, in: app), 0,
            "the app did not start from an empty channel list — see IsolatedApp")

        addChannel(named: channelName, in: app)
        selectM17Mode(in: app)
        replace(callsign, in: field("connect.callsign", in: app))
        replace(reflector, in: field("connect.host", in: app))
        replace(module, in: field("connect.module", in: app))

        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "no Connect button")
        connect.click()

        // The link is up when the PTT control stops saying "Connect to a node
        // first" — the control exists either way, so its existence proves
        // nothing and its enabled-ness is the real signal.
        let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
        XCTAssertTrue(ptt.waitForExistence(timeout: 20), "no PTT control")
        XCTAssertTrue(
            waitUntil(timeout: 30) { ptt.isEnabled && ptt.isHittable },
            "the link never came up — PTT stayed disabled")

        ptt.press(forDuration: overDuration)

        // The banner renders only while transmitting, so its disappearance is
        // the app's own statement that the over ended. Give SwiftUI a moment
        // before believing either answer: a snapshot taken the instant the
        // press returns still shows the banner, which reads like a stuck key
        // and is only a frame that has not re-rendered.
        //
        // Narrow query, deliberately: a `descendants(matching: .any)` with a
        // predicate takes minutes against this tree and times out.
        // Match on `value`, not on the subscript: SwiftUI `Text` arrives with an
        // empty accessibility *label* and its string in `value`, so
        // `app.staticTexts["On air."]` matches nothing at all and every
        // assertion built on it passes vacuously. That mistake is why an
        // earlier run of this test reported the release as confirmed when it
        // had checked nothing.
        let onAir = app.staticTexts.matching(
            NSPredicate(format: "value == %@", "On air.")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 5) { !onAir.exists },
            "the app still shows a transmit banner after PTT was released")


        // Hold the session open long enough for the observer to have printed,
        // then hang up so the reflector is not left with a dangling link.
        Thread.sleep(forTimeInterval: 2)

        let disconnect = app.buttons["Disconnect"].firstMatch
        if disconnect.exists { disconnect.click() }

        // Deleting is refused while a link is up, so wait for the list to say
        // it is editable again. Read that from the lock label the channel list
        // shows while connected, and *not* from the connect button: the pane
        // switcher has a radio button labelled "Connect" too, so
        // `app.buttons["Connect"].exists` is true the whole time and waiting on
        // it silently waits for nothing.
        XCTAssertTrue(
            waitUntil(timeout: 30) {
                !app.staticTexts["Disconnect to switch, add or delete channels."].exists
            },
            "the channel list stayed locked after Disconnect")

        XCTAssertTrue(
            waitUntil(timeout: 15) { self.row(named: self.channelName, in: app).exists },
            "the test's channel vanished before it could be deleted")
        deleteChannel(named: channelName, in: app)
        XCTAssertEqual(
            rowCount(named: channelName, in: app), 0,
            "left a '\(channelName)' row in the operator's channel list")
    }

    // MARK: - The test's own channel

    /// Adds a channel and names it. It points the form at a new channel, so
    /// everything typed after this lands on the new one.
    ///
    /// **APP-19: `Add channel` no longer writes to the list** — Save or Connect
    /// does, and here it is the connect below. Pressing Save *here* is the wrong
    /// move and was tried: the Save button is at the bottom of the form, so
    /// clicking it scrolls the form, and the fields this test then types into
    /// report frames outside the visible scroll area. Clicks at those points land
    /// on the session pane above and the field never takes focus — a failure that
    /// reads like a broken text field and is a scrolled one.
    private func addChannel(named name: String, in app: XCUIApplication) {
        let add = app.buttons["Add channel"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add channel button")
        add.click()
        replace(name, in: field("connect.channelName", in: app))
    }

    /// Deletes it again through the context menu, which is how macOS reaches
    /// this: there is no swipe-to-delete off iOS and no key binding.
    private func deleteChannel(named name: String, in app: XCUIApplication) {
        guard row(named: name, in: app).exists else {
            XCTFail("the test's channel vanished before it could be deleted")
            return
        }
        row(named: name, in: app).rightClick()

        // Scoped to the menu that just opened — and **`app.menus` is not that
        // scope.** It holds every menu-bar menu whether open or not, so its
        // count is about thirteen before anything has been right-clicked and
        // `app.menus.firstMatch` is the *Apple* menu, whose items contain no
        // Delete. `app.menuItems["Delete"]` is the other half of the same trap:
        // it matches the menu bar's always-greyed `Edit ▸ Delete`, so it finds a
        // disabled Delete whether or not a context menu opened — which is how
        // BU-9 item 3 came to be reported as "the item is disabled" rather than
        // "no menu appeared". A modal alert left over from the session is enough
        // to produce the second, and only a properly scoped query tells them
        // apart.
        //
        // The row's menu is told apart by its contents: one item, Delete.
        guard let menu = openedRowMenu(in: app) else {
            XCTFail(
                "no context menu opened on '\(name)' — not a disabled Delete, no menu at all. "
                + "Check for an alert still up from the session.")
            return
        }
        let delete = menu.menuItems["Delete"].firstMatch
        guard delete.waitForExistence(timeout: 5) else {
            XCTFail("no Delete item in the channel's context menu")
            return
        }
        XCTAssertTrue(
            delete.isEnabled,
            "Delete is disabled in the channel's own context menu after the link came down")
        delete.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) { !self.row(named: name, in: app).exists },
            "the channel was still listed after Delete")
    }

    /// The row's own context menu, if one is open, told apart from the menu-bar
    /// menus by holding exactly one item — which is its whole contents.
    private func openedRowMenu(in app: XCUIApplication) -> XCUIElement? {
        var found: XCUIElement?
        _ = waitUntil(timeout: 5) {
            let menus = app.menus
            for index in 0..<menus.count {
                let menu = menus.element(boundBy: index)
                if menu.menuItems.count == 1, menu.menuItems["Delete"].firstMatch.exists {
                    found = menu
                    return true
                }
            }
            return false
        }
        return found
    }

    /// A channel row is a button labelled with the channel described in full —
    /// name, mode, where it points, whether it is connected — so match on the
    /// name it begins with rather than on the whole string.
    private func row(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    private func rowCount(named name: String, in app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).count
    }

    // MARK: - Driving the form

    /// The mode picker is a segmented `Picker`, which surfaces as radio buttons
    /// on macOS rather than as a segmented control.
    private func selectM17Mode(in app: XCUIApplication) {
        let m17 = app.radioButtons["M17"].firstMatch
        if m17.waitForExistence(timeout: 5) {
            m17.click()
            return
        }
        let fallback = app.descendants(matching: .any)["M17"].firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 5), "no M17 mode control")
        fallback.click()
    }

    /// The fields carry both an accessibility label — for anyone using a
    /// screen reader — and an identifier, for this test. Queries go through the
    /// identifier: labels are user-facing text and get reworded, identifiers
    /// are a contract.
    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(identifier)")
        return field
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}

/// Replaces a field's contents rather than appending to them: these come back
/// from the app's saved settings, so they are rarely empty.
func replace(_ text: String, in field: XCUIElement) {
    field.click()
    field.typeKey("a", modifierFlags: .command)
    if text.isEmpty {
        field.typeKey(.delete, modifierFlags: [])
    } else {
        field.typeText(text)
    }
}
