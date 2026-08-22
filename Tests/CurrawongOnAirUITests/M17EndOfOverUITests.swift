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
        // transmits must not invent a callsign. This skips rather than
        // transmits when nobody has said who is on the air; see
        // ``IsolatedApp/requireOperatorCallsign()``, which is also the only
        // route that works on iOS.
        let callsign = try IsolatedApp.requireOperatorCallsign()

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

        // **APP-23: the form's Connect button is gone**, and `app.buttons["Connect"]`
        // must not be reached for again — the pane switcher has a radio button
        // with that exact label, so the query still matches and clicking it
        // changes pane instead of placing a call. The one control that connects
        // is the link button under the PTT slab, and it names its destination
        // (APP-17), which is what makes this query unambiguous.
        // iPhone puts the session pane in its own tab; on macOS this is a no-op.
        showSessionPane(in: app)
        let connect = app.buttons["Connect to \(channelName)"].firstMatch
        XCTAssertTrue(
            connect.waitForExistence(timeout: 5),
            "no link button naming this channel — the session pane's Connect is the only one now")
        connect.activate()

        // The link is up when the PTT control stops saying "Connect to a node
        // first" — the control exists either way, so its existence proves
        // nothing and its enabled-ness is the real signal.
        let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
        XCTAssertTrue(ptt.waitForExistence(timeout: 20), "no PTT control")
        XCTAssertTrue(
            waitUntil(timeout: 30) { ptt.isEnabled && ptt.isHittable },
            "the link never came up — PTT stayed disabled")

        ptt.press(forDuration: overDuration)

        // **APP-23: the strip no longer disappears**, so its absence has stopped
        // being the app's statement that the over ended — it is permanent now,
        // and what changes is what it says. The statement is the wording: it
        // reads "Not transmitting" once the key is up.
        //
        // Give SwiftUI a moment before believing either answer: a snapshot taken
        // the instant the press returns still shows the keyed strip, which reads
        // like a stuck key and is only a frame that has not re-rendered.
        //
        // Narrow query, deliberately: a `descendants(matching: .any)` with a
        // predicate takes minutes against this tree and times out. The strip is
        // one combined accessibility element carrying
        // `TransmitBanner.accessibilityDescription`, so it is matched on the
        // label here — but `value` is checked too, because a SwiftUI `Text`
        // arrives with an empty label and its string in `value`, and an earlier
        // version of this test reported a release it had never checked because
        // it matched neither.
        let idleStrip = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Not transmitting", "Not transmitting")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 5) { idleStrip.exists },
            "the transmit strip still does not say the radio is unkeyed after PTT was released")


        // Hold the session open long enough for the observer to have printed,
        // then hang up so the reflector is not left with a dangling link.
        Thread.sleep(forTimeInterval: 2)

        let disconnect = app.buttons["Disconnect"].firstMatch
        if disconnect.exists { disconnect.activate() }

        // Back to the channel list for the lock check and the delete below —
        // on iPhone those are a different tab from the Disconnect just pressed.
        showChannelList(in: app)

        // Deleting is refused while a link is up, so wait for the list to say
        // it is editable again. Read that from the lock label the channel list
        // shows while connected, and *not* from the connect button: the pane
        // switcher has a radio button labelled "Connect" too, so
        // `app.buttons["Connect"].exists` is true the whole time and waiting on
        // it silently waits for nothing.
        // APP-23 reworded this label — switching is no longer refused, only the
        // operations that change what the list contains — and a stale string
        // here would wait for nothing and pass vacuously, which is the exact
        // failure mode the note above is about.
        XCTAssertTrue(
            waitUntil(timeout: 30) {
                !app.staticTexts["Disconnect to add, edit or delete channels."].exists
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
        add.activate()
        replace(name, in: field("connect.channelName", in: app))
    }

    /// Deletes it again. **The one place the two platforms differ in mechanism
    /// rather than in wording**, which is why it is forked here and the rest of
    /// this test is not: `ChannelListView` offers `onDelete`, which iOS renders
    /// as the swipe every operator expects, and a `.contextMenu`, which is how
    /// macOS reaches the same command because it has no swipe.
    private func deleteChannel(named name: String, in app: XCUIApplication) {
        guard row(named: name, in: app).exists else {
            XCTFail("the test's channel vanished before it could be deleted")
            return
        }
        #if os(macOS)
            deleteViaContextMenu(named: name, in: app)
        #else
            deleteViaSwipe(named: name, in: app)
        #endif
        XCTAssertTrue(
            waitUntil(timeout: 10) { !self.row(named: name, in: app).exists },
            "the channel was still listed after Delete")
    }

    #if !os(macOS)
        /// Swipe-to-delete, and then the confirming `Delete` button the swipe
        /// reveals. Two elements of that name can be on screen at once — the
        /// revealed action and, if the row also carries a context menu, its
        /// item — so this takes the one inside the row.
        private func deleteViaSwipe(named name: String, in app: XCUIApplication) {
            let row = self.row(named: name, in: app)
            row.swipeLeft()
            let delete = row.buttons["Delete"].firstMatch
            if delete.waitForExistence(timeout: 3) {
                delete.tap()
                return
            }
            // Some SwiftUI versions hoist the revealed action out of the row.
            let loose = app.buttons["Delete"].firstMatch
            guard loose.waitForExistence(timeout: 3) else {
                XCTFail("the swipe on '\(name)' revealed no Delete")
                return
            }
            loose.tap()
        }
    #endif

    #if os(macOS)
    private func deleteViaContextMenu(named name: String, in app: XCUIApplication) {
        row(named: name, in: app).openContextMenu()

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
    #endif

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

    /// The mode picker is a segmented `Picker`. macOS surfaces its options as
    /// radio buttons; iOS surfaces them as buttons inside a segmented control.
    /// Each candidate is tried in turn rather than assumed, because the element
    /// type a SwiftUI `Picker` reports has changed between OS versions before.
    private func selectM17Mode(in app: XCUIApplication) {
        let candidates = [
            app.radioButtons["M17"].firstMatch,
            app.segmentedControls.buttons["M17"].firstMatch,
            app.buttons["M17"].firstMatch,
            app.descendants(matching: .any)["M17"].firstMatch,
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            candidate.activate()
            return
        }
        XCTFail("no M17 mode control")
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
