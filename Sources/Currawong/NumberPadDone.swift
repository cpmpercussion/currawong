// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A Done button above the number pad.
///
/// The iOS number pad has no return key, so a field that uses it gives the
/// operator no way to put the keyboard away: on iPhone it stayed up over the
/// lower half of Settings until some other field's return key dismissed it.
/// This adds the conventional Done to the keyboard's own toolbar, for the
/// field that has focus and only while it has it.
///
/// A no-op on macOS, which has no software keyboard.
private struct NumberPadDone: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .focused($isFocused)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        // Every number field on screen contributes a group;
                        // only the focused one puts anything in it.
                        if isFocused {
                            Spacer()
                            Button("Done") { isFocused = false }
                                .accessibilityIdentifier("keyboard.done")
                        }
                    }
                }
        #else
            content
        #endif
    }
}

extension View {
    /// Number pad, with a Done button to dismiss it. Use this instead of a bare
    /// `.keyboardType(.numberPad)`, which leaves the keyboard with no way out.
    func numberPadWithDone() -> some View {
        #if os(iOS)
            return keyboardType(.numberPad).modifier(NumberPadDone())
        #else
            return self
        #endif
    }
}
