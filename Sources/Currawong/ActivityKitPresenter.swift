// SPDX-License-Identifier: Apache-2.0

#if os(iOS)

import ActivityKit
import Foundation

/// **SF-4.** The real ``TransmitActivityPresenting``, over `ActivityKit`.
///
/// Nothing here decides anything: it starts, updates and ends the one activity
/// the controller asks for. That is deliberate — this file cannot be run by a
/// test (there is no ActivityKit on macOS and no lock screen in a simulator test
/// run), so the less judgement it holds, the more of APP-3 is covered by
/// ``TransmitActivityControllerTests`` and by the six end-path tests in
/// ``RadioSessionActivityTests``.
///
/// ## Why the deployment floor is 16.2 and not 16.1
///
/// ActivityKit itself arrived in iOS 16.1, and the maintainer's decision of
/// 2026-08-16 was to raise the app's floor to 16.1 rather than scatter
/// availability guards. The plan asked for the floor to be whatever the
/// implementation actually calls, and it calls three things that landed in
/// **16.2**:
///
/// * `ActivityContent`, which is the only way to set a **stale date** — and a
///   stale date is the app-termination half of the stale-state hazard. A
///   Live Activity outlives its process, so an activity with no stale date on a
///   Currawong that was killed mid-over is a red TRANSMITTING banner with
///   nothing behind it, indefinitely.
/// * `update(_:)` taking that content, so the stale date moves with each
///   key-down instead of being fixed at the start of the over.
/// * `end(_:dismissalPolicy:)`, so an ended activity is **dismissed** rather
///   than left on the lock screen showing its final state.
///
/// All three are about the activity not lying. The 16.1-only API set would meet
/// the letter of SF-4 and lose its point, so the floor is 16.2 — one patch
/// release further, on an OS four years old.
@MainActor
final class ActivityKitPresenter: TransmitActivityPresenting {

    /// The activity this process started, if any.
    private var activity: Activity<TransmitActivityAttributes>?

    /// How long past the watchdog deadline the shown state may still be
    /// believed.
    ///
    /// Once the watchdog has fired the library has unkeyed and the app has
    /// ended the activity, so anything still on screen after this is an app that
    /// is no longer running. The grace is for the round trip, not for the
    /// operator.
    private static let staleGrace: TimeInterval = 5

    /// How long a state that is not on air may be believed. A route-change
    /// recovery either keys back down or gives up within
    /// `RadioSession.routeSettleNanoseconds`; anything longer than this and
    /// nobody is driving.
    private static let unkeyedStaleWindow: TimeInterval = 10

    func start(_ request: TransmitActivityRequest) async {
        // The operator can turn Live Activities off for the app, or for the
        // device. Asking anyway throws, and a thrown error here is not news.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = TransmitActivityAttributes(
            channel: request.channel, mode: request.mode)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: Self.content(for: request.state),
                pushType: nil)  // PD-2: no push entitlement, no `voip` mode.
        } catch {
            // Fail *closed*: no activity is the safe failure, because the app's
            // own transmit banner is still on screen and the operator has not
            // been told something false.
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
        // Not `self.activity` — the point is the activities this process did
        // *not* start, left behind by one that was terminated mid-over.
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
