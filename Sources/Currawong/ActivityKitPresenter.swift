// SPDX-License-Identifier: Apache-2.0

#if os(iOS)

import ActivityKit
import Foundation

/// **SF-4.** The real ``TransmitActivityPresenting``, over ActivityKit.
///
/// Decides nothing: no test can run it, so the judgement lives in
/// ``TransmitActivityController`` where tests can reach it.
///
/// The iOS floor is 16.2 for three APIs used here: `ActivityContent` (the only
/// way to set a stale date, so an app killed mid-over does not leave a red
/// banner up indefinitely), `update(_:)` taking it (so the stale date moves
/// with each key-down), and `end(_:dismissalPolicy:)` (so an ended activity is
/// dismissed rather than left showing its final state).
@MainActor
final class ActivityKitPresenter: TransmitActivityPresenting {

    /// The activity this process started, if any.
    private var activity: Activity<TransmitActivityAttributes>?

    /// How long past the watchdog deadline the shown state may be believed.
    /// Past it, the app that should have ended the activity is not running.
    private static let staleGrace: TimeInterval = 5

    /// How long a not-on-air state may be believed: a route-change recovery
    /// resolves within `RadioSession.routeSettleNanoseconds`.
    private static let unkeyedStaleWindow: TimeInterval = 10

    func start(_ request: TransmitActivityRequest) async {
        // Live Activities may be turned off for the app or the device.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = TransmitActivityAttributes(
            channel: request.channel, mode: request.mode)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: Self.content(for: request.state),
                pushType: nil)  // PD-2: no push entitlement, no `voip` mode.
        } catch {
            // No activity is the safe failure: nothing false is shown, and the
            // in-app banner still is.
            activity = nil
        }
    }

    func update(_ state: TransmitActivityState) async {
        await activity?.update(Self.content(for: state))
    }

    func end() async {
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }

    func endOrphans() async {
        // Every activity, including ones a terminated process left behind.
        for orphan in Activity<TransmitActivityAttributes>.activities {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    private static func content(
        for state: TransmitActivityState
    ) -> ActivityContent<TransmitActivityState> {
        ActivityContent(state: state, staleDate: staleDate(for: state))
    }

    private static func staleDate(for state: TransmitActivityState) -> Date {
        if let deadline = state.watchdogDeadline, state.isOnAir {
            return deadline.addingTimeInterval(staleGrace)
        }
        return Date().addingTimeInterval(unkeyedStaleWindow)
    }
}

#endif
