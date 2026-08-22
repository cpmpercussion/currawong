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

    /// The measurement that matters: the two states are the same size, so the
    /// change between them cannot move anything.
    ///
    /// Both are measured through a hosting view rather than compared by
    /// inspection, because the thing that would break this is a subtitle
    /// appearing in one state and not the other — a difference no amount of
    /// reading the two branches reliably catches.
    func testBothStatesAreTheSameHeight() throws {
        let onAir = fittingSize(TransmitBanner(isTransmitting: true, source: .onScreen))
        let standby = fittingSize(TransmitBanner(isTransmitting: false, source: nil))

        XCTAssertEqual(
            onAir.height, standby.height, accuracy: 1,
            "keying must not change the strip's height — everything below it would move")
    }

    /// A keyed strip with no known source still gets a subtitle, for the same
    /// reason: the height must not depend on whether PT-4 could name the input.
    func testAKeyedStripWithNoKnownSourceIsStillTheSameHeight() throws {
        let known = fittingSize(TransmitBanner(isTransmitting: true, source: .accessory))
        let unknown = fittingSize(TransmitBanner(isTransmitting: true, source: nil))

        XCTAssertEqual(known.height, unknown.height, accuracy: 1)
    }

    /// **PT-4.** While keyed, the strip names the input holding the key and says
    /// whether letting go stops it. A latched transmission the operator believes
    /// is momentary is how this app would leave a microphone open.
    func testTheKeyedStripCarriesTheSourcesHoldDescription() {
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
