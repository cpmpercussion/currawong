// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One activity's worth of what to show: the parts that cannot change for its
/// lifetime, and the part that can.
///
/// The split mirrors `ActivityKit`'s own — attributes versus content state — but
/// this type does not import it, so the policy below can be tested on macOS.
struct TransmitActivityRequest: Equatable, Sendable {
    /// The channel's display name. Changing it means a different radio, so it
    /// ends one activity and starts another rather than being updated into
    /// place.
    var channel: String

    /// The mode's display name.
    var mode: String

    /// Everything that moves.
    var state: TransmitActivityState

    /// Whether `other` describes the same activity, or a different one that
    /// would have to be started fresh.
    func isSameActivity(as other: TransmitActivityRequest) -> Bool {
        channel == other.channel && mode == other.mode
    }
}

/// What ``TransmitActivityController`` talks to.
///
/// The seam exists for the same reason ``BLECentral`` does: the interesting part
/// is the state logic, the framework underneath it cannot be driven from a test,
/// and on macOS it does not exist at all. `ActivityKitPresenter` is the real
/// conformer; `RecordingActivityPresenter` in the tests is the one the
/// assertions read.
@MainActor
protocol TransmitActivityPresenting: AnyObject {
    /// Starts an activity. Called only when none is showing.
    func start(_ request: TransmitActivityRequest) async

    /// Updates the one that is showing.
    func update(_ state: TransmitActivityState) async

    /// Ends it, and dismisses it immediately rather than leaving it on the lock
    /// screen in its final state. A transmit indicator that lingers after the
    /// transmission is the stale-state hazard SF-4 is most exposed to.
    func end() async

    /// Ends every activity this app has left running, whether or not this
    /// process started it.
    ///
    /// **This is the app-termination path.** A Live Activity outlives the
    /// process that requested it — that is the whole point of one — so a
    /// Currawong that was killed while transmitting leaves a red banner on the
    /// lock screen with nothing behind it. Called once at launch, before
    /// anything else can start an activity.
    func endOrphans() async
}

/// **SF-4.** Decides when the lock screen shows a transmitter, and — the part
/// that matters — when it stops.
///
/// ## Why this is a separate object
///
/// ``RadioSession`` knows the transmit state; it does not need to also know
/// about activity identity, ordering, or the difference between starting one and
/// updating one. What the session hands over is a single desired value:
/// ``show(_:)`` with a request, or with `nil` for "nothing is on air". Every
/// path that ends transmission — release, watchdog (SF-1), accessory loss
/// (SF-2), interruption and route change (SF-3), disconnection — reaches that
/// one call, so there is no per-path activity teardown to forget.
///
/// ## Ordering
///
/// The three presenter operations are `async` and must not overtake one
/// another: an `end()` that lands before the `start()` it was meant to cancel
/// leaves an activity nobody is tracking. So they are chained through a single
/// task, the same shape ``RadioSession/scheduleTransmitWork()`` uses, and
/// ``settle()`` is what a test waits on.
///
/// ## Update rate
///
/// ActivityKit budgets updates, and this pushes one per *transition* rather than
/// one per tick: the elapsed and remaining times are rendered by the widget from
/// the two dates in ``TransmitActivityState``, so a running clock costs no
/// updates at all.
@MainActor
final class TransmitActivityController {
    private let presenter: any TransmitActivityPresenting

    /// What the presenter has been asked for, not what the system has got
    /// around to showing. `nil` means no activity.
    private(set) var showing: TransmitActivityRequest?

    private var work: Task<Void, Never>?
    private var generation = 0

    init(presenter: any TransmitActivityPresenting) {
        self.presenter = presenter
    }

    /// A controller wired to nothing, for the platforms and the tests that want
    /// no Live Activity at all. The default ``RadioSession`` is built with one
    /// of these, so nothing gets a lock-screen banner by accident.
    static var disabled: TransmitActivityController {
        TransmitActivityController(presenter: NullActivityPresenter())
    }

    /// Clears anything a previous run of the app left behind. Call once, at
    /// launch. See ``TransmitActivityPresenting/endOrphans()``.
    func adopt() {
        enqueue { [presenter] in await presenter.endOrphans() }
    }

    /// The single entry point: what should be on the lock screen right now.
    ///
    /// Idempotent — handed the same value twice it does nothing the second time,
    /// which is what lets the session call it from every state transition
    /// without working out which ones matter.
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
            // A different radio. End the old one before the new one appears,
            // rather than leaving two banners to disagree about what is keyed.
            showing = desired
            enqueue { [presenter] in
                await presenter.end()
                await presenter.start(desired)
            }
        }
    }

    /// Waits for every queued presenter call to land. Test support, and the one
    /// thing a shutdown path needs.
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
