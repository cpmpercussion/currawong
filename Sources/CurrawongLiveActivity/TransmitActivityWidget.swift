// SPDX-License-Identifier: Apache-2.0

import ActivityKit
import SwiftUI
import WidgetKit

/// **Three states, not two:** on air, not keyed, and unknown. A `Bool` would
/// force a stale activity — most likely an app that died mid-over — to claim
/// one of the others, and "not keyed" would stop the operator checking. So
/// `unknown` renders as itself in all five presentations.
enum TransmitActivityPresentation: Equatable {
    /// The client is keyed. The only state that may be red.
    case onAir

    /// The client is not keyed, and the app is here to say so.
    case notKeyed

    /// ActivityKit's `isStale`: the app has stopped updating this. Not a
    /// transmit state, and never rendered as one.
    case unknown

    init(state: TransmitActivityState, isStale: Bool) {
        if isStale {
            self = .unknown
        } else {
            self = state.isOnAir ? .onAir : .notKeyed
        }
    }

    /// Never `dot.radiowaves…` unless genuinely on air, and never the *slashed*
    /// antenna unless genuinely not: the slash is a claim.
    var symbol: String {
        switch self {
        case .onAir: return "dot.radiowaves.left.and.right"
        case .notKeyed: return "antenna.radiowaves.left.and.right.slash"
        case .unknown: return "exclamationmark.triangle.fill"
        }
    }

    /// Red means on air and nothing else. `unknown` gets a caution colour: an
    /// instruction to look, not reassurance.
    var accent: Color {
        switch self {
        case .onAir: return .red
        case .notKeyed: return .secondary
        case .unknown: return .orange
        }
    }

    /// The expanded Dynamic Island's label.
    var label: String {
        switch self {
        case .onAir: return "On air"
        case .notKeyed: return "Not keyed"
        case .unknown: return "State unknown"
        }
    }

    /// The lock screen's headline. Louder, and the same three answers.
    var headline: String {
        switch self {
        case .onAir: return "ON AIR"
        case .notKeyed: return "NOT TRANSMITTING"
        case .unknown: return "STATE UNKNOWN"
        }
    }

    /// The compact trailing glyph; `nil` where there is nothing worth showing.
    var badge: String? {
        switch self {
        case .onAir: return "TX"
        case .notKeyed: return nil
        case .unknown: return "?"
        }
    }

    /// Whether to show the watchdog countdown: only when on air and not stale.
    var showsWatchdog: Bool { self == .onAir }
}

/// **SF-4.** Transmit state on a locked iPhone.
///
/// Decides nothing about transmit: that is made in the app
/// (``RadioSession/desiredActivity``, ``TransmitStatusPresentation``), where it
/// is tested, and arrives as ``TransmitActivityState``. The one judgement here
/// is `context.isStale` — an app killed mid-over leaves the activity up until
/// its next launch ends it, and stale must not read as either state.
struct TransmitActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransmitActivityAttributes.self) { context in
            let presentation = TransmitActivityPresentation(
                state: context.state, isStale: context.isStale)
            LockScreenView(
                channel: context.attributes.channel,
                mode: context.attributes.mode,
                state: context.state,
                presentation: presentation)
                .activityBackgroundTint(Self.background(for: presentation))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let presentation = TransmitActivityPresentation(
                state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(presentation.label, systemImage: presentation.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(presentation.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let deadline = context.state.watchdogDeadline,
                        presentation.showsWatchdog
                    {
                        // SF-1 countdown, rendered from the date: no updates.
                        Text(timerInterval: Date()...deadline, countsDown: true)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(Self.detail(for: presentation, state: context.state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.accent)
            } compactTrailing: {
                if let badge = presentation.badge {
                    Text(badge)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(presentation.accent)
                }
            } minimal: {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.accent)
            }
        }
    }

    /// Shown when stale. Claims neither state — nobody knows which.
    static let staleDetail = "Currawong is no longer updating this. Open the app to check."

    /// The app's own sentence, except when the app is the thing that has stopped.
    static func detail(
        for presentation: TransmitActivityPresentation,
        state: TransmitActivityState
    ) -> String {
        presentation == .unknown ? staleDetail : state.detail
    }

    /// Red only while on air; the other states use the dark ground.
    private static func background(for presentation: TransmitActivityPresentation) -> Color {
        presentation == .onAir ? .red : Color(white: 0.12)
    }
}

/// The lock-screen and notification-banner presentation.
struct LockScreenView: View {
    let channel: String
    let mode: String
    let state: TransmitActivityState
    let presentation: TransmitActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: presentation.symbol)
                Text(presentation.headline)
                    .font(.headline.weight(.black))
                    .monospaced()
                Spacer()
                if presentation == .onAir {
                    // Elapsed on the hold, not the key-down; see `holdBegan`.
                    Text(timerInterval: state.holdBegan...Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                }
            }

            Text(TransmitActivityWidget.detail(for: presentation, state: state))
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                // Nominative use only (OQ-1b): the mode names what the app is
                // talking to, and is not a claim of affiliation with any of them.
                Text(mode)
                Text("·")
                Text(channel).lineLimit(1)
                if let deadline = state.watchdogDeadline, presentation.showsWatchdog {
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

    /// What VoiceOver reads — all an operator gets with the phone in a pocket.
    private var accessibilityDescription: String {
        if presentation == .unknown {
            return "Transmit state unknown. \(TransmitActivityWidget.staleDetail)"
        }
        return "\(presentation.headline). \(state.detail) \(mode), \(channel)."
    }
}
