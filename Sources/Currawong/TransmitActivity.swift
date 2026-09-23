// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One activity's content: the fixed parts and the part that moves, mirroring
/// ActivityKit's attributes and content state without importing it, so the
/// policy is testable on macOS.
struct TransmitActivityRequest: Equatable, Sendable {
    /// The channel's display name. A change ends the activity and starts another.
    var channel: String

    /// The mode's display name.
    var mode: String

    /// Everything that moves.
    var state: TransmitActivityState

    /// Whether `other` can be an update to this activity rather than a new one.
    func isSameActivity(as other: TransmitActivityRequest) -> Bool {
        channel == other.channel && mode == other.mode
    }
}

/// What ``TransmitActivityController`` talks to: `ActivityKitPresenter` in the
/// app, a recording fake in the tests. ActivityKit cannot be driven from a test
/// and does not exist on macOS.
@MainActor
protocol TransmitActivityPresenting: AnyObject {
    /// Starts an activity. Called only when none is showing.
    func start(_ request: TransmitActivityRequest) async

    /// Updates the one that is showing.
    func update(_ state: TransmitActivityState) async

    /// Ends it and dismisses it immediately: a transmit indicator that lingers
    /// after the transmission is SF-4's worst stale state.
    func end() async

    /// Ends every activity this app has left running, including a previous
    /// process's: a Live Activity outlives an app killed mid-transmission.
    /// Called once at launch, before anything can start one.
    func endOrphans() async
}

/// **SF-4.** Decides when the lock screen shows a transmitter, and when it
/// stops.
///
/// ``RadioSession`` passes one desired value to ``show(_:)`` — a request, or
/// `nil` for nothing on air — from every path that ends transmission (SF-1,
/// SF-2, SF-3, release, disconnect), so no path has its own teardown to forget.
///
/// Presenter calls are chained through one task: an `end()` that overtook the
/// `start()` it cancels would leave an untracked activity. One update per
/// transition, not per tick — the widget renders the clocks from
/// ``TransmitActivityState``'s dates, since ActivityKit budgets updates.
@MainActor
final class TransmitActivityController {
    private let presenter: any TransmitActivityPresenting

    /// What the presenter has been asked for (not what the system shows yet).
    private(set) var showing: TransmitActivityRequest?

    private var work: Task<Void, Never>?
    private var generation = 0

    init(presenter: any TransmitActivityPresenting) {
        self.presenter = presenter
    }

    /// A controller wired to nothing: the default for ``RadioSession``, so no
    /// test or platform gets a lock-screen banner by accident.
    static var disabled: TransmitActivityController {
        TransmitActivityController(presenter: NullActivityPresenter())
    }

    /// Clears what a previous run left behind; call once at launch. Also clears
    /// ``showing``, or the next identical ``show(_:)`` would be skipped.
    func adopt() {
        showing = nil
        enqueue { [presenter] in await presenter.endOrphans() }
    }

    /// What should be on the lock screen now. Idempotent, so the session can
    /// call it on every state transition.
    func show(_ desired: TransmitActivityRequest?) {
        guard let desired else {
            guard showing != nil else { return }
            showing = nil
            enqueue { [presenter] in await presenter.end() }
            return
        }

        guard let current = showing else {
            showing = desired
            enqueue { [presenter] in await presenter.start(desired) }
            return
        }

        guard current != desired else { return }

        if current.isSameActivity(as: desired) {
            showing = desired
            enqueue { [presenter] in await presenter.update(desired.state) }
        } else {
            // A different radio: end the old one first, so two banners never
            // disagree about what is keyed.
            showing = desired
            enqueue { [presenter] in
                await presenter.end()
                await presenter.start(desired)
            }
        }
    }

    /// Waits for every queued presenter call to land.
    func settle() async {
        var seen = -1
        while generation != seen {
            seen = generation
            await work?.value
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = work
        generation += 1
        work = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }
}

/// The no-op presenter behind ``TransmitActivityController/disabled``.
@MainActor
final class NullActivityPresenter: TransmitActivityPresenting {
    func start(_ request: TransmitActivityRequest) async {}
    func update(_ state: TransmitActivityState) async {}
    func end() async {}
    func endOrphans() async {}
}
