// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The macOS/iOS differences in *driving* the app, in one place.
///
/// This target was macOS-only until 2026-08-23. `XCUIElement.click()`,
/// `typeKey(_:modifierFlags:)` and `rightClick()` do not exist off macOS, so a
/// test written against them does not merely behave differently on iOS — it
/// does not compile. Rather than fork every call site, the four operations that
/// actually differ live here and the tests read the same on both.
///
/// **The rule for adding to this file:** only put something here if the two
/// platforms genuinely differ in mechanism. Anything that differs in *meaning*
/// belongs in a test guarded by `#if os(macOS)` — `BU-9`'s delete bug is about
/// the macOS context menu, and pretending it is a cross-platform test would
/// make it assert nothing on either.
extension XCUIElement {

    /// Click on macOS, tap on iOS.
    func activate() {
        #if os(macOS)
            click()
        #else
            tap()
        #endif
    }

    /// Open the row's own menu: right-click on macOS, long press on iOS, which
    /// is what SwiftUI's `.contextMenu` binds to on each.
    func openContextMenu() {
        #if os(macOS)
            rightClick()
        #else
            press(forDuration: 1.0)
        #endif
    }

    /// What the field currently holds, distinguished from its placeholder.
    ///
    /// An empty SwiftUI `TextField` reports its *placeholder* in `value`, so a
    /// clear loop that trusts `value` blindly tries to delete a prompt that was
    /// never typed and sends as many backspaces as the placeholder is long.
    var typedText: String {
        guard let text = value as? String, text != placeholderValue else { return "" }
        return text
    }
}

/// Put the software keyboard away.
///
/// **On iPhone this is the difference between a test that works and one that
/// silently taps the keyboard.** Measured 2026-08-23: with the keyboard up
/// after filling the connect form, `Save` reports `exists=true hittable=false`
/// and the tab bar is behind it, so a tap meant for `Session` lands on a key
/// and nothing appears to happen. Nothing throws — the tap succeeds, just not
/// on what the test meant.
func dismissKeyboard(in app: XCUIApplication) {
    #if !os(macOS)
        guard app.keyboards.element(boundBy: 0).exists else { return }
        let returnKey = app.keyboards.buttons["return"].firstMatch
        if returnKey.exists {
            returnKey.tap()
        }
        // Give the dismissal animation time to finish, or the very next tap is
        // still aimed at where the keyboard was.
        _ = waitForKeyboardToGo(in: app)
    #endif
}

#if !os(macOS)
    private func waitForKeyboardToGo(in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !app.keyboards.element(boundBy: 0).exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
#endif

/// Bring the session pane into view, where the link button, the PTT slab and
/// Disconnect live.
///
/// **A no-op on macOS, and load-bearing on iPhone.** The Mac shows the channel
/// list and the session pane side by side, so everything a test wants is on
/// screen at once. iPhone puts them in separate tabs — measured 2026-08-23 on
/// an iPhone 13 Pro: `Channels`, `Session`, `Keypad`, `Settings`, with
/// `Channels` selected at launch. So a test that fills the form and then
/// reaches for `Connect to <channel>` finds nothing, which is exactly how this
/// first failed on the device.
func showSessionPane(in app: XCUIApplication) {
    #if !os(macOS)
        dismissKeyboard(in: app)
        let session = app.tabBars.buttons["Session"].firstMatch
        if session.waitForExistence(timeout: 5) { session.tap() }
    #endif
}

/// Bring the channel list into view — the other half of ``showSessionPane(in:)``,
/// for counting rows and deleting the test's own channel.
func showChannelList(in app: XCUIApplication) {
    #if !os(macOS)
        dismissKeyboard(in: app)
        let channels = app.tabBars.buttons["Channels"].firstMatch
        if channels.waitForExistence(timeout: 5) { channels.tap() }

        // **The tab is not the screen.** `Add channel` *pushes* the connect
        // form inside the Channels tab, and switching tabs and back leaves that
        // form on top — so the channel list, and every row query against it, is
        // still covered. Measured 2026-08-23: this is why the on-air test
        // reported "the test's channel vanished before it could be deleted"
        // after an over that had otherwise gone perfectly.
        let back = app.buttons["BackButton"].firstMatch
        if back.waitForExistence(timeout: 2), back.isHittable {
            back.tap()
        }
    #endif
}

/// Replaces a field's contents rather than appending to them: these come back
/// from the app's saved settings, so they are rarely empty.
///
/// The two platforms clear a field by completely different means. macOS has
/// select-all; iOS has no key equivalent from a UI test, so the only portable
/// clear is one backspace per character — which is why ``XCUIElement/typedText``
/// has to tell real text from a placeholder.
func replace(_ text: String, in field: XCUIElement) {
    #if os(macOS)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        if text.isEmpty {
            field.typeKey(.delete, modifierFlags: [])
        } else {
            field.typeText(text)
        }
    #else
        field.tap()
        // Tapping does not always land the caret in a field that is already
        // first responder, and typing into an unfocused field silently goes
        // nowhere. Wait for the keyboard rather than assume it.
        _ = field.waitForExistence(timeout: 2)
        let existing = field.typedText
        if !existing.isEmpty {
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        if !text.isEmpty {
            field.typeText(text)
        }
    #endif
}
