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
