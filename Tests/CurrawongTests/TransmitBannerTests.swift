// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import XCTest

@testable import Currawong

/// **APP-23 / SF-4.** The transmit strip is always on screen, and it is the
/// same height in both of its states.
///
/// The fault this covers is a layout one with a safety edge. The banner used to
/// be inserted into the hierarchy at key-down, which pushed every control below
/// it down the screen — the PTT button under the operator's held finger
/// included. A button that slides out from under a finger is a button the finger
/// drags off, and dragging off is a release
/// (``TransmitStopReason/draggedOffButton``): the operator's over ends because
/// the UI moved.
///
/// So there is nothing here about *whether* the strip appears. It always does.
/// What is asserted is that neither state can change the layout around it.
@MainActor
final class TransmitBannerTests: XCTestCase {

    /// The measurement that matters: every state is the same size, so the change
    /// between them cannot move anything.
    ///
    /// Measured through a hosting view rather than by reading the branches,
    /// because the thing that would break this is a line appearing in one state
    /// and not another — which is exactly what the first version of this strip
    /// did, and what the operator asked to have removed.
    func testEveryStateIsTheSameHeight() throws {
        let standby = fittingSize(TransmitBanner(isTransmitting: false))

        XCTAssertEqual(
            fittingSize(TransmitBanner(isTransmitting: true)).height,
            standby.height, accuracy: 1,
            "keying changed the strip's height — everything below it moves")
    }

    func testTheTrailingWordFollowsTheKey() {
        XCTAssertEqual(TransmitBanner(isTransmitting: true).trailingWord, "ON AIR")
        XCTAssertEqual(TransmitBanner(isTransmitting: false).trailingWord, "STANDBY")
    }

    /// VoiceOver has no colour to read, so it gets the full sentence the strip
    /// does not draw: that letting go is what unkeys.
    func testVoiceOverGetsTheHoldDescriptionTheStripDoesNotDraw() {
        let banner = TransmitBanner(isTransmitting: true)
        XCTAssertTrue(banner.accessibilityDescription.contains(RadioSession.holdDescription))
        XCTAssertTrue(banner.accessibilityDescription.contains("On air"))
    }

    /// And the idle strip says the opposite in as many words. SF-4 is about
    /// answering "am I on air?" without unlocking, and an operator using
    /// VoiceOver gets that answer from here.
    func testTheIdleStripSaysItIsNotTransmitting() {
        let banner = TransmitBanner(isTransmitting: false)

        XCTAssertTrue(banner.accessibilityDescription.contains("Not transmitting"))
        XCTAssertFalse(banner.accessibilityDescription.contains("On air"))
    }

    private func fittingSize<V: View>(_ view: V) -> CGSize {
        #if os(macOS)
            let host = NSHostingView(rootView: view.frame(width: 400))
            return host.fittingSize
        #else
            let controller = UIHostingController(rootView: view.frame(width: 400))
            return controller.sizeThatFits(
                in: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        #endif
    }
}
