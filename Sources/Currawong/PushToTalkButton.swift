// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The on-screen momentary PTT (PT-1): hold to transmit, release to stop.
///
/// Not a `Button`, which has no press edge and says nothing on cancellation. A
/// `DragGesture(minimumDistance: 0)` begins on touch-down, and drives a
/// `@GestureState`, which **SwiftUI resets when the gesture ends or is
/// cancelled, unconditionally** — the release runs off that reset, never off an
/// `onEnded` a cancellation would skip. `onEnded` only labels the release.
///
/// Dragging off the button releases and latches; coming back does not re-key.
struct PushToTalkButton: View {
    /// Whether a press should do anything. A disabled button never keys.
    let isEnabled: Bool

    /// Whether the client confirms it is transmitting: the "on air" styling.
    /// ``isKeyDown`` drives the immediate "pressed" styling.
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
                    // Reached on every end of the gesture, cancelled or not.
                    onRelease(endedCleanly ? .released : .gestureCancelled)
                    endedCleanly = false
                }
            }
        }
        // Thumb-sized on iOS; a pointer needs less height on macOS.
        #if os(macOS)
            .frame(minHeight: 120)
        #else
            .frame(minHeight: 190)
        #endif
        .accessibilityElement()
        .accessibilityLabel("Push to talk")
        .accessibilityValue(isTransmitting ? "Transmitting" : "Not transmitting")
        .accessibilityHint("Press and hold to transmit. Release to stop.")
        // A view torn down under a held finger never resets `@GestureState`,
        // so the release must come from here — including when a dropped link
        // removes the button. Harmless when nothing was keyed: `endTransmit`
        // records a stop only if something was transmitting
        // (`SessionPaneStateTests`).
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
