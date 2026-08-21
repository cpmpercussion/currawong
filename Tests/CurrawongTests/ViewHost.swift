// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit
#else
import UIKit
#endif

import SwiftUI
import XCTest

/// A real SwiftUI view in a real window, on either platform, so that a test can
/// assert on behaviour a view model cannot be asked about — `onAppear`,
/// `onDisappear`, and what leaves the hierarchy when state changes.
///
/// ## Why this exists as one type
///
/// The two hosted-view tests in this suite were `#if os(macOS)` for no better
/// reason than that `NSHostingView` was what got written first — and the
/// behaviour they cover is *more* interesting on iOS, not less:
/// ``PushToTalkButton``'s `onDisappear` release is the app's answer to leaving
/// the Session tab while keyed, which is a case only the compact layout has.
/// Testing it on macOS alone tested the platform that does not have the problem.
///
/// So the platform difference lives here, in three lines of `#if`, and the tests
/// above it are ordinary tests that run in both `make test` and
/// `make test-macos`.
///
/// ## The window is never closed
///
/// On macOS, `close()` starts an `_NSWindowTransformAnimation` that over-releases
/// once the hosting view goes away; the SIGSEGV lands in whichever *unrelated*
/// test happened to be holding the run loop, and that test passes in isolation
/// every time. It cost an afternoon. The window is moved off the display instead
/// and left to die with the process, which is a test host that is about to exit
/// anyway. The iOS side keeps the same rule for consistency; a simulator window
/// bothers nobody either way.
@MainActor
final class ViewHost {

    #if os(macOS)
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    #else
    private let window: UIWindow
    private let hosting: UIHostingController<AnyView>
    #endif

    /// - Parameter size: the hosted view's size. Big enough that a pane's
    ///   contents are laid out rather than compressed to nothing, which is the
    ///   one way a hosted-view test can pass while measuring a view that never
    ///   really appeared.
    init<V: View>(_ view: V, size: CGSize = CGSize(width: 420, height: 900)) {
        #if os(macOS)
        hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        // Live, so SwiftUI really builds the hierarchy — and off the display, so
        // `make test-macos` does not throw a panel over whatever the operator is
        // doing. That happened, for every run, for days.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        #else
        hosting = UIHostingController(rootView: AnyView(view))
        // Attached to the test host's own scene where there is one: a window with
        // no scene is not guaranteed to lay out, and a hosted view that never
        // lays out is a test that measures nothing.
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = hosting
        window.isHidden = false
        #endif
        settle()
    }

    /// Lets SwiftUI commit the change a `@Published` property just made, or a
    /// root-view swap. The hosting view needs a turn of the run loop, not just a
    /// layout pass.
    func settle() {
        #if os(macOS)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        #else
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.view.layoutIfNeeded()
        #endif
    }

    /// Replaces what is hosted, which is how a test takes a view *out* of the
    /// hierarchy — the only way to observe `onDisappear`.
    func replaceRootView<V: View>(with view: V) {
        hosting.rootView = AnyView(view)
        settle()
    }

    /// The hosted view's root, for a test that needs to walk the platform view
    /// tree. Only `ChannelListContextMenuTests` does, and only on macOS.
    #if os(macOS)
    var contentView: NSView { hosting }
    #endif
}
