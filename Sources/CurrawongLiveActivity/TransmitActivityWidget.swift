// SPDX-License-Identifier: Apache-2.0

import ActivityKit
import SwiftUI
import WidgetKit

/// **There are three states here, not two.**
///
/// On air, not keyed, and *nobody knows* — and the third one is why this is an
/// enum rather than the `Bool` this started as. A `Bool` forces stale into one
/// of the other two, and whichever one you pick, it is an assertion the view
/// has no grounds for. Picking "not keyed" is the worse of the two, because a
/// stale activity's likeliest cause is an app that died mid-over: the reading
/// that says "you are not transmitting" is the reading that gets an operator to
/// stop checking.
///
/// So `unknown` renders as itself, in every one of the five places the activity
/// is drawn — expanded, compact leading, compact trailing, minimal, and the lock
/// screen. Caught in review of the APP-3 PR; the lock screen had this right and
/// the Dynamic Island did not.
enum TransmitActivityPresentation: Equatable {
    /// The client is keyed. The only state that may be red.
    case onAir

    /// The client is not keyed, and the app is here to say so.
    case notKeyed

    /// The app has stopped updating this — `ActivityKit`'s `isStale`. It is not
    /// a transmit state and must not be rendered as one.
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

    /// **Red means "your voice is going out" and nothing else may borrow it.**
    /// `unknown` gets a caution colour rather than a calm one — it is not
    /// reassurance, it is an instruction to go and look.
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

    /// The compact trailing glyph, which is the whole of the activity on a
    /// phone doing something else. `nil` where there is nothing worth two
    /// characters.
    var badge: String? {
        switch self {
        case .onAir: return "TX"
        case .notKeyed: return nil
        case .unknown: return "?"
        }
    }

    /// Whether the watchdog countdown means anything. It does not if nothing is
    /// keyed, and it does not if the app has stopped driving this — a leash
    /// counting down against a transmission nobody can confirm is worse than no
    /// number at all.
    var showsWatchdog: Bool { self == .onAir }
}

/// **SF-4.** Transmit state on a locked iPhone.
///
/// ## This view decides nothing about the radio
///
/// Every judgement it could make about *transmit* has already been made in the
/// app, in ``RadioSession/desiredActivity`` and ``TransmitStatusPresentation``,
/// and arrives as ``TransmitActivityState``. That is not tidiness: a widget
/// extension is a separate process a unit test cannot drive, so anything decided
/// in here is untested, and the one thing SF-4 cannot tolerate is an untested
/// rule about when the banner is red.
///
/// The one thing it must judge is `context.isStale`, because that is the one
/// piece of information the app cannot supply: it means the app has stopped
/// updating this. That is the **app-termination** case — a Live Activity outlives
/// its process, so a Currawong killed mid-over leaves this on the lock screen
/// with nobody behind it. The app clears the leftover at its next launch
/// (`TransmitActivityPresenting.endOrphans()`); until then, this is what stands
/// between the operator and a display that lies.
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
                        // SF-1's leash, counting down. Rendered from the date
                        // rather than pushed as an update every second, so a
                        // running clock costs no ActivityKit budget at all.
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

    /// What the operator is told when the app has stopped driving this.
    ///
    /// Deliberately does **not** say "transmitting" or "not transmitting":
    /// nobody knows which, and guessing either way is the failure this whole
    /// requirement is about. It says the state is unknown and where to find out.
    static let staleDetail = "Currawong is no longer updating this. Open the app to check."

    /// The app's own sentence, except when the app is the thing that has stopped.
    static func detail(
        for presentation: TransmitActivityPresentation,
        state: TransmitActivityState
    ) -> String {
        presentation == .unknown ? staleDetail : state.detail
    }

    /// Red **only** while genuinely on air. Both other states get the dark
    /// ground and say what they mean in the foreground — red is the colour that
    /// means "you are transmitting", and it may not be shown by a view that does
    /// not know.
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
                    // Elapsed on the *hold*, not the key-down: a route-change
                    // recovery keys down again under a button that was never
                    // released, and a clock that restarted there would tell the
                    // operator their over is younger than it is.
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

    /// Spoken aloud, and the wording matters more here than on screen: this is
    /// what an operator hears when the phone is in a pocket.
    private var accessibilityDescription: String {
        if presentation == .unknown {
            return "Transmit state unknown. \(TransmitActivityWidget.staleDetail)"
        }
        return "\(presentation.headline). \(state.detail) \(mode), \(channel)."
    }
}
