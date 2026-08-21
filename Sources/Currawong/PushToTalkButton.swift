// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **PT-1.** The on-screen momentary PTT. Press and hold to transmit; release
/// to stop.
///
/// ## Why this is not a `Button`
///
/// `Button` fires on touch-*up*, after the system has decided the gesture was
/// a tap. There is no press edge, no release edge, and no notification at all
/// if the touch is cancelled. A momentary PTT needs all three.
///
/// So: a `DragGesture(minimumDistance: 0)` driving a `@GestureState`.
/// `minimumDistance: 0` makes it begin on touch-down, which is the press edge.
/// `@GestureState` is the important half — **SwiftUI resets it to its initial
/// value when the gesture ends *or is cancelled*, unconditionally**. That is
/// the property this button is built on: there is no way for the gesture to
/// stop without the state going back to ``PressPhase/up``, and the release
/// handler runs off that transition rather than off an `onEnded` that a
/// cancellation would skip.
///
/// `onEnded` is still attached, but only to *label* the release: a reset that
/// arrives without a preceding `onEnded` was a cancellation. Both spellings
/// stop transmission; the distinction is for the operator's benefit, not the
/// repeater's.
///
/// Dragging out of the button's bounds latches ``PressPhase/draggedOff`` and
/// releases. It does not re-key on the way back in — a finger that has slid
/// off the button is not a finger that is paying attention to it, and
/// re-keying under it would be a genuine surprise.
struct PushToTalkButton: View {
    /// Whether a press should do anything. A disabled button never keys.
    let isEnabled: Bool

    /// Whether the client has confirmed it is transmitting. Drives the "on
    /// air" styling; ``isKeyDown`` drives the "pressed" styling, so the button
    /// responds to the finger immediately and to the network honestly.
    let isTransmitting: Bool

    /// Whether the operator's finger is currently down on the button.
    let isKeyDown: Bool

    let onPress: () -> Void
    let onRelease: (TransmitStopReason) -> Void

    private enum PressPhase: Equatable {
        case up
        case holding
        case draggedOff
    }

    @GestureState private var phase: PressPhase = .up
    @State private var endedCleanly = false

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(fill)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(border, lineWidth: isTransmitting ? 5 : 2)

                VStack(spacing: 6) {
                    Image(systemName: isTransmitting ? "dot.radiowaves.left.and.right" : "mic.fill")
                        .font(.system(size: 40, weight: .semibold))
                    Text(isTransmitting ? "ON AIR" : "PUSH TO TALK")
                        .font(.title3.weight(.bold))
                        .monospaced()
                    Text(isEnabled ? "Hold to transmit" : "Connect to a node first")
                        .font(.caption)
                        .opacity(0.85)
                }
                .foregroundStyle(foreground)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .scaleEffect(isKeyDown ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: isKeyDown)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($phase) { value, state, _ in
                        guard isEnabled else {
                            state = .up
                            return
                        }
                        switch state {
                        case .draggedOff:
                            // Latched. Coming back inside does not re-key.
                            break
                        case .up, .holding:
                            state = bounds.contains(value.location) ? .holding : .draggedOff
                        }
                    }
                    .onEnded { _ in endedCleanly = true }
            )
            .onChange(of: phase) { newPhase in
                switch newPhase {
                case .holding:
                    endedCleanly = false
                    onPress()
                case .draggedOff:
                    onRelease(.draggedOffButton)
                case .up:
                    // Reached on every possible end of the gesture, cancelled
                    // or not. This is the guarantee the button rests on.
                    onRelease(endedCleanly ? .released : .gestureCancelled)
                    endedCleanly = false
                }
            }
        }
        // **A touch target on iOS, a pointer target on macOS.** 190 points was
        // chosen for a thumb, and a Mac has no thumbs — it cost most of a short
        // window's detail column for a control a mouse hits at any size. The
        // button stays full-width in both, which is the part that makes it
        // findable without looking; only the height differs.
        #if os(macOS)
            .frame(minHeight: 120)
        #else
            .frame(minHeight: 190)
        #endif
        .accessibilityElement()
        .accessibilityLabel("Push to talk")
        .accessibilityValue(isTransmitting ? "Transmitting" : "Not transmitting")
        .accessibilityHint("Press and hold to transmit. Release to stop.")
        // **Not belt and braces any more.** If this view leaves the hierarchy
        // while the finger is still down, the gesture is torn down with it and
        // `@GestureState` never gets to reset, so the release has to come from
        // here. That used to mean one thing — switching tabs while keyed, in the
        // compact layout — and since APP-18 it means another: the button is on
        // screen only while there is a link, so **a link that drops under a held
        // finger takes this button away**, and this line is what unkeys.
        //
        // It fires whether or not anything was keyed, which is harmless:
        // `endTransmit(reason:)` records a stop reason only when something was
        // actually transmitting, so an ordinary disconnect does not leave the
        // status panel reporting a transmission that ended because a view went
        // away. `SessionPaneStateTests` pins both halves of that.
        .onDisappear { onRelease(.viewDisappeared) }
    }

    private var fill: some ShapeStyle {
        if isTransmitting { return AnyShapeStyle(Color.red) }
        if !isEnabled { return AnyShapeStyle(Color.gray.opacity(0.18)) }
        return AnyShapeStyle(isKeyDown ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.15))
    }

    private var border: some ShapeStyle {
        if isTransmitting { return AnyShapeStyle(Color.red) }
        if !isEnabled { return AnyShapeStyle(Color.gray.opacity(0.3)) }
        return AnyShapeStyle(Color.accentColor)
    }

    private var foreground: some ShapeStyle {
        if isTransmitting { return AnyShapeStyle(Color.white) }
        if !isEnabled { return AnyShapeStyle(Color.secondary) }
        return AnyShapeStyle(Color.accentColor)
    }
}
