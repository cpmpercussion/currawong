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
        let standby = fittingSize(TransmitBanner(isTransmitting: false, source: nil))

        for source in [PTTSource.onScreen, .accessory, .remoteCommand] {
            XCTAssertEqual(
                fittingSize(TransmitBanner(isTransmitting: true, source: source)).height,
                standby.height, accuracy: 1,
                "keying from \(source) changed the strip's height — everything below it moves")
        }

        // And with no source known, which is the state a resumed transmission
        // can be in.
        XCTAssertEqual(
            fittingSize(TransmitBanner(isTransmitting: true, source: nil)).height,
            standby.height, accuracy: 1)
    }

    /// **PT-4.** The one thing worth saying beyond "on air": a latched key does
    /// not stop when the operator lets go. An operator who believes a latched
    /// key is momentary is how this app would leave a microphone open.
    func testALatchedTransmissionSaysSoInPlaceOfOnAir() {
        let latched = TransmitBanner(isTransmitting: true, source: .remoteCommand)
        XCTAssertEqual(latched.trailingWord, "LATCHED")

        // And the momentary inputs do not, because for them TRANSMITTING is the
        // whole truth and a second word would be noise.
        for source in [PTTSource.onScreen, .accessory] {
            XCTAssertEqual(
                TransmitBanner(isTransmitting: true, source: source).trailingWord, "ON AIR",
                "\(source) is momentary and must not claim to be latched")
        }
        XCTAssertEqual(
            TransmitBanner(isTransmitting: true, source: nil).trailingWord, "ON AIR",
            "an unknown source must not be called latched")

        XCTAssertEqual(TransmitBanner(isTransmitting: false, source: nil).trailingWord, "STANDBY")
    }

    /// VoiceOver has no colour to read, so it still gets PT-4's full sentence —
    /// the wording that was clutter on screen and is the requirement when spoken.
    func testVoiceOverGetsTheHoldDescriptionTheStripNoLongerDraws() {
        for source in [PTTSource.onScreen, .accessory, .remoteCommand] {
            let banner = TransmitBanner(isTransmitting: true, source: source)
            XCTAssertTrue(
                banner.accessibilityDescription.contains(source.holdDescription),
                "\(source) must say whether letting go unkeys")
            XCTAssertTrue(banner.accessibilityDescription.contains("On air"))
        }
    }

    /// And the idle strip says the opposite in as many words. SF-4 is about
    /// answering "am I on air?" without unlocking, and an operator using
    /// VoiceOver gets that answer from here.
    func testTheIdleStripSaysItIsNotTransmitting() {
        let banner = TransmitBanner(isTransmitting: false, source: nil)

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
                in: CGSize(width: 400, height: .greatestFiniteMagnitude))
        #endif
    }
}
