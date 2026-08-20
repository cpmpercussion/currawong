// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-3, SF-4.** ``TransmitActivityController``'s policy, on its own.
///
/// The controller is where the lock-screen indicator's identity and ordering
/// live; whether it should be up at all is ``RadioSession``'s question and is
/// tested in ``RadioSessionActivityTests``. Split that way because this half
/// runs identically on both platforms and touches no framework — which is the
/// point of the presenter seam.
@MainActor
final class TransmitActivityControllerTests: XCTestCase {

    private func request(
        channel: String = "55553 at node.example.org",
        mode: String = "AllStarLink",
        onAir: Bool = true,
        detail: String = "Transmitting while held. Let go to stop."
    ) -> TransmitActivityRequest {
        TransmitActivityRequest(
            channel: channel,
            mode: mode,
            state: TransmitActivityState(
                isOnAir: onAir,
                headline: onAir ? "ON AIR" : "NOT TRANSMITTING",
                detail: detail,
                holdBegan: Date(timeIntervalSince1970: 1_000),
                watchdogDeadline: onAir ? Date(timeIntervalSince1970: 1_180) : nil))
    }

    // MARK: Starting, updating, ending

    func testShowingARequestStartsAnActivity() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)
        let wanted = request()

        controller.show(wanted)
        await controller.settle()

        XCTAssertEqual(presenter.calls, [.start(wanted)])
        XCTAssertEqual(controller.showing, wanted)
    }

    func testShowingNilEndsIt() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.show(request())
        controller.show(nil)
        await controller.settle()

        XCTAssertEqual(presenter.calls, [.start(request()), .end])
        XCTAssertNil(controller.showing)
    }

    /// The property that lets ``RadioSession`` call this from every transition
    /// rather than from the ones somebody judged to matter. A judgement about
    /// which transitions matter is a judgement that gets made wrong once and
    /// leaves a banner up.
    func testShowingTheSameThingTwiceIsOneCall() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.show(request())
        controller.show(request())
        controller.show(request())
        await controller.settle()

        XCTAssertEqual(presenter.startCount, 1)
        XCTAssertEqual(presenter.calls.count, 1, "an unchanged state must cost no update")
    }

    func testShowingNilTwiceIsOneEnd() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.show(request())
        controller.show(nil)
        controller.show(nil)
        await controller.settle()

        XCTAssertEqual(presenter.endCount, 1)
    }

    func testEndingWhenNothingIsShowingDoesNothing() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.show(nil)
        await controller.settle()

        XCTAssertTrue(presenter.calls.isEmpty)
    }

    /// The route-change case, at this layer: the state changes, the activity
    /// does not. Nothing is ended and nothing is started, so the lock screen
    /// does not blink.
    func testAChangedStateUpdatesRatherThanRestarting() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.show(request(onAir: true))
        controller.show(request(onAir: false, detail: "Keying back down."))
        controller.show(request(onAir: true))
        await controller.settle()

        XCTAssertEqual(presenter.startCount, 1, "the activity must not be torn down and rebuilt")
        XCTAssertEqual(presenter.endCount, 0)
        XCTAssertEqual(presenter.shownStates.map(\.isOnAir), [true, false, true])
    }

    /// A different channel is a different radio, and one activity cannot honestly
    /// describe both. So it ends and a fresh one starts — in that order, so there
    /// is never a moment with two banners disagreeing about what is keyed.
    func testADifferentChannelEndsTheOldActivityBeforeStartingTheNew() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)
        let first = request(channel: "Repeater")
        let second = request(channel: "Parrot")

        controller.show(first)
        controller.show(second)
        await controller.settle()

        XCTAssertEqual(presenter.calls, [.start(first), .end, .start(second)])
    }

    func testADifferentModeIsAlsoADifferentActivity() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.show(request(mode: "AllStarLink"))
        controller.show(request(mode: "M17"))
        await controller.settle()

        XCTAssertEqual(presenter.startCount, 2)
        XCTAssertEqual(presenter.endCount, 1)
    }

    // MARK: Ordering

    /// The hazard the single task chain exists for: an `end()` that overtakes
    /// the `start()` it was meant to cancel leaves an activity nobody is
    /// tracking — which is to say, a red banner with nothing behind it.
    func testAnEndCannotOvertakeTheStartItCancels() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.show(request())
        controller.show(nil)
        controller.show(request())
        controller.show(nil)
        await controller.settle()

        XCTAssertEqual(presenter.calls, [.start(request()), .end, .start(request()), .end])
        XCTAssertFalse(presenter.isShowing)
    }

    // MARK: App termination

    /// A Live Activity outlives the process that requested it, so the launch
    /// after a termination is where a leftover banner gets cleared.
    func testAdoptEndsWhateverAPreviousRunLeftBehind() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.adopt()
        await controller.settle()

        XCTAssertEqual(presenter.calls, [.endOrphans])
    }

    func testAdoptRunsBeforeAnythingThisLaunchStarts() async {
        let presenter = RecordingActivityPresenter()
        let controller = TransmitActivityController(presenter: presenter)

        controller.adopt()
        controller.show(request())
        await controller.settle()

        XCTAssertEqual(presenter.calls, [.endOrphans, .start(request())])
    }

    // MARK: The disabled controller

    /// macOS, previews, and any ``RadioSession`` built without one. It must be
    /// safe to drive, because every SF-4 call site drives it unconditionally.
    func testTheDisabledControllerIsSafeToDrive() async {
        let controller = TransmitActivityController.disabled

        controller.adopt()
        controller.show(request())
        controller.show(nil)
        await controller.settle()

        XCTAssertNil(controller.showing)
    }
}
