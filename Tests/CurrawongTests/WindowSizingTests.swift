// SPDX-License-Identifier: Apache-2.0

// macOS only, and not for want of generality: the fault covered here is a
// `NavigationSplitView` measuring its sidebar, and on iOS a window is the
// screen.
#if os(macOS)

import AppKit
import SwiftUI
import XCTest

@testable import Currawong

/// **BU-12.** The app must not be taller than the window it is in.
///
/// On a 1440×900 display — window content 881×866 — the whole app was laid out
/// **1249.5 points tall at y = −175.5**, and macOS centres what it cannot fit,
/// so the status panel that APP-18 says never hides sat above the top edge of
/// the window and the sidebar's header halfway down an empty column. It showed
/// on a *first launch*, with no channels, which is the worst audience for it.
///
/// ## What these tests measure, and why it is the platform view tree
///
/// The demand and the overflow are two different numbers, and only one of them
/// is the bug. `NSHostingView.fittingSize` is what the app *asks* for; the
/// frame of the hosting view's own subtree is what it *got*. An earlier attempt
/// at this fix capped the ask — `idealHeight` on the root — and every
/// `fittingSize` assertion passed while the split view inside went on
/// overflowing at 1249.5, because `fixedSize` publishes a **minimum** and no
/// ideal caps a minimum. So these tests read the frames, and a fix that only
/// tidies the ask fails them.
@MainActor
final class WindowSizingTests: XCTestCase {

    /// A display an operator actually has: the laptop the fault was found on.
    private static let shortWindow = CGSize(width: 881, height: 866)

    private func rootView() -> some View {
        let root = CompositionRoot(
            audio: FakeAudioIO(),
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore())
        return RootView(
            session: root.session,
            accessory: root.accessory,
            remoteCommand: root.remoteCommand,
            browser: root.stationBrowser,
            reflectorBrowser: root.reflectorBrowser,
            proxyPicker: root.proxyPicker,
            nodeLocator: root.nodeLocator,
            portalLogin: root.portalLogin)
    }

    /// The layout SwiftUI handed AppKit: the hosting view's one child, which is
    /// the split view's platform host and the view whose frame was
    /// `(0, -175.5, 881, 1249.5)` when this was broken.
    private func hostedLayout(_ host: ViewHost) -> NSView? {
        host.contentView.subviews.first
    }

    /// The regression. An empty channel list is deliberate — that is a first
    /// launch, and it is the case that reproduced.
    func testTheAppIsNotTallerThanItsWindow() throws {
        let host = ViewHost(rootView(), size: Self.shortWindow)
        let laid = try XCTUnwrap(hostedLayout(host), "nothing was laid out")
        let window = host.contentView.frame.height

        XCTAssertLessThanOrEqual(
            laid.frame.height, window + 1,
            "the app is taller than its window; it was 1249.5 points in 866")
        XCTAssertGreaterThanOrEqual(
            laid.frame.minY, -1,
            "the overflow is being centred, so the top of the app is above the window's top edge")
    }

    /// And the window still wins in the other direction: a window taller than
    /// anything the app needs is filled, rather than the app sitting at some
    /// natural height with a gap under it.
    func testATallWindowIsFilled() throws {
        let host = ViewHost(rootView(), size: CGSize(width: 881, height: 1400))
        let laid = try XCTUnwrap(hostedLayout(host))

        XCTAssertEqual(laid.frame.height, host.contentView.frame.height, accuracy: 1)
    }

    /// The mechanism, so the missing `fixedSize` in ``ChannelListView`` is not
    /// folklore: wrapping text with `.fixedSize(horizontal: false, vertical:
    /// true)` in a sidebar demands the height it would need with one word per
    /// line, because that is what it measures to at an unspecified width — and
    /// `fixedSize` makes the demand a minimum.
    ///
    /// **A canary, deliberately.** If a future SwiftUI stops measuring a sidebar
    /// this way, this test fails, and that failure is the news: the modifier
    /// could come back. Do not delete it to make a build green — read it, then
    /// re-measure `ChannelListView`.
    func testASidebarMeasuresWrappingTextAtAnUnspecifiedWidth() throws {
        let caption =
            "Fill in the connect form and connect. The details are saved as a channel, and "
            + "coming back to it later is one tap."
        let sidebar = NavigationSplitView {
            Text(caption)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            Text("detail")
        }

        let host = ViewHost(sidebar, size: Self.shortWindow)
        let laid = try XCTUnwrap(hostedLayout(host))

        // Against the window that was *asked* for, not the content view's own
        // height: with nothing to stop it, the hosting view grows to the demand
        // too, so comparing the two would compare the fault with itself.
        XCTAssertGreaterThan(
            laid.frame.height, Self.shortWindow.height,
            "the platform behaviour BU-12's fix exists for appears to have changed")
    }
}

#endif
