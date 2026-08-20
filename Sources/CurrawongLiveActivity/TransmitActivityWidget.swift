// SPDX-License-Identifier: Apache-2.0

import ActivityKit
import SwiftUI
import WidgetKit

/// **SF-4.** Transmit state on a locked iPhone.
///
/// ## This view decides nothing
///
/// Every judgement it could make has already been made in the app, in
/// ``RadioSession/desiredActivity`` and ``TransmitStatusPresentation``, and
/// arrives here as ``TransmitActivityState``. That is not tidiness: a widget
/// extension is a separate process that a unit test cannot drive, so anything
/// decided in here is untested, and the one thing SF-4 cannot tolerate is an
/// untested rule about when the banner is red.
///
/// The one thing it does judge is `context.isStale`, and only because that is
/// information the app cannot supply: it means the app has stopped updating
/// this. That is the **app-termination** case — a Live Activity outlives its
/// process, so a Currawong that was killed mid-over leaves this on the lock
/// screen with nobody behind it. The stale rendering says so instead of going on
/// claiming TX. The app clears the leftover at its next launch
/// (`TransmitActivityPresenting.endOrphans()`); until then, this is what stands
/// between the operator and a display that lies.
struct TransmitActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransmitActivityAttributes.self) { context in
            LockScreenView(
                channel: context.attributes.channel,
                mode: context.attributes.mode,
                state: context.state,
                isStale: context.isStale)
                .activityBackgroundTint(Self.tint(for: context.state, isStale: context.isStale))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let live = context.state.isOnAir && !context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(live ? "On air" : "Not keyed", systemImage: Self.symbol(live: live))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(live ? Color.red : Color.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let deadline = context.state.watchdogDeadline, live {
                        // SF-1's leash, counting down. Rendered from the date
                        // rather than pushed as an update every second, so a
                        // running clock costs no ActivityKit budget at all.
                        Text(timerInterval: Date()...deadline, countsDown: true)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? Self.staleDetail : context.state.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: Self.symbol(live: live))
                    .foregroundStyle(live ? Color.red : Color.secondary)
            } compactTrailing: {
                if live {
                    Text("TX").font(.caption2.weight(.black)).foregroundStyle(.red)
                }
            } minimal: {
                Image(systemName: Self.symbol(live: live))
                    .foregroundStyle(live ? Color.red : Color.secondary)
            }
        }
    }

    /// What the operator is told when the app has stopped driving this.
    ///
    /// Deliberately does **not** say "transmitting" or "not transmitting":
    /// nobody knows which, and guessing either way is the failure this whole
    /// requirement is about. It says the state is unknown and where to find out.
    static let staleDetail = "Currawong is no longer updating this. Open the app to check."

    private static func symbol(live: Bool) -> String {
        live ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }

    /// Red **only** while genuinely on air. Stale is grey, not red: red is the
    /// colour that means "you are transmitting", and it may not be shown by a
    /// view that does not know.
    private static func tint(for state: TransmitActivityState, isStale: Bool) -> Color {
        state.isOnAir && !isStale ? .red : Color(white: 0.12)
    }
}

/// The lock-screen and notification-banner presentation.
struct LockScreenView: View {
    let channel: String
    let mode: String
    let state: TransmitActivityState
    let isStale: Bool

    private var live: Bool { state.isOnAir && !isStale }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: live
                    ? "dot.radiowaves.left.and.right"
                    : "antenna.radiowaves.left.and.right.slash")
                Text(isStale ? "STATE UNKNOWN" : state.headline)
                    .font(.headline.weight(.black))
                    .monospaced()
                Spacer()
                if live {
                    // Elapsed on the *hold*, not the key-down: a route-change
                    // recovery keys down again under a button that was never
                    // released, and a clock that restarted there would tell the
                    // operator their over is younger than it is.
                    Text(timerInterval: state.holdBegan...Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                }
            }

            Text(isStale ? TransmitActivityWidget.staleDetail : state.detail)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                // Nominative use only (OQ-1b): the mode names what the app is
                // talking to, and is not a claim of affiliation with any of them.
                Text(mode)
                Text("·")
                Text(channel).lineLimit(1)
                if let deadline = state.watchdogDeadline, live {
                    Spacer()
                    Text(timerInterval: Date()...deadline, countsDown: true)
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Spoken aloud, and the wording matters more here than on screen: this is
    /// what an operator hears when the phone is in a pocket.
    private var accessibilityDescription: String {
        if isStale { return "Transmit state unknown. \(TransmitActivityWidget.staleDetail)" }
        return "\(state.headline). \(state.detail) \(mode), \(channel)."
    }
}
