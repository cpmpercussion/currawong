// SPDX-License-Identifier: Apache-2.0

// **macOS only, and the fault was reported on an iPad.** What is measured here
// is a demand in points — a `minHeight` on the detail column — and that number
// is the same on both platforms, so measuring it where it can be measured is
// enough. It cannot be measured under UIKit: a `UIHostingController` in a test
// is attached to the test host's window scene, and `sizeThatFits(in:)` answers
// with the scene's geometry rather than the view's. Run on an iPad Pro
// simulator, every case here reported the identical 716.5 whatever the mode and
// whatever the connection state — the same number before and after the fix.
// A test that cannot tell the fault from its fix is worse than no test.
//
// What iOS *does* carry is the tighter budget: the PTT button's floor is 190
// points there against 120 on macOS. So the numbers below are the forgiving
// platform's, and a column that fits here has 70 points less margin on the
// device the fault came from.
#if os(macOS)

import SwiftUI
import XCTest

@testable import Currawong

/// **The iPad mini fault.** The split layout's detail column must never demand
/// more height than it is given.
///
/// The same mechanism as `BU-12`, one level in and on the other platform: a
/// child taller than its parent is not clipped at the bottom and does not
/// scroll — the parent **centres** it, so the overflow is split between both
/// edges and the *top* of the column goes off the screen. The top of the column
/// is the status panel, which APP-18 says never hides, and the state that
/// pushed the column over the line was **connecting**: the meters, the PTT
/// button and the link button all arrive at once, under a `minHeight` of 620
/// that had been sized for a Mac window.
///
/// The window here is shorter than any real iPad, deliberately. Reproducing the
/// device exactly would mean guessing at a navigation bar and two safe-area
/// insets — numbers that move with the OS — and the fault was only ~25 points
/// of overrun on the mini, which is the sort of margin a test can pass by
/// accident. A window with no room to spare tests the property that actually
/// matters: the column takes what it is given.
///
/// The size class is forced rather than inferred, so what is measured is the
/// split layout — the same layout an iPad gets — rather than whatever the host
/// platform would have chosen.
@MainActor
final class DetailColumnSizingTests: XCTestCase {

    /// Shorter than an iPad mini in landscape has after its chrome, and
    /// narrower, so the split layout still has both columns.
    private static let shortWindow = CGSize(width: 1024, height: 560)

    /// A channel that validates in each mode, so `connect()` reaches
    /// `.connected` rather than stopping at an alert with the column half
    /// built. AllStarLink is the harness's own; the other two are the shapes
    /// their validators want.
    private static func settings(for mode: RadioMode) -> NodeSettings {
        switch mode {
        case .allStarLink: return SessionHarness.goodSettings
        case .m17:
            return NodeSettings(
                name: "M17-CBR", mode: .m17, host: "m17-cbr.example.org", port: 17_000,
                module: "A")
        case .echoLink: return SessionHarness.echoLinkSettings
        }
    }

    private func connected(_ mode: RadioMode) async -> SessionHarness {
        let harness = SessionHarness(settings: Self.settings(for: mode))
        harness.session.secret = "hunter2"
        await harness.session.connect()
        return harness
    }

    private func rootView(_ harness: SessionHarness) -> some View {
        RootView(
            session: harness.session,
            accessory: BLEPTTController(
                makeCentral: { FakeBLECentral() },
                store: InMemoryPTTSettingsStore(),
                retryDelay: {}),
            remoteCommand: RemoteCommandPTTController(
                makeSource: { FakeRemoteCommandSource() },
                store: InMemoryPTTSettingsStore()),
            browser: StationBrowser(directory: FakeStationDirectory()),
            reflectorBrowser: ReflectorBrowser(directory: FakeReflectorDirectory()),
            proxyPicker: ProxyPicker(finder: FakeProxyFinder()),
            nodeLocator: NodeLocator(lookup: SilentNodeLookup()),
            portalLogin: PortalLoginController())
            // See the note on the type: the split layout, on whichever
            // simulator the suite is running.
            .environment(\.horizontalSizeClass, .regular)
    }

    /// The union of what SwiftUI handed the platform, as ``WindowSizingTests``
    /// measures it: the ask is not the bug, the frame is.
    private func hostedLayout(_ host: ViewHost) -> CGRect? {
        let frames = host.contentView.subviews.map(\.frame)
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private func assertFits(
        _ host: ViewHost, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // **The ask, and it is the load-bearing assertion here.** The note in
        // ``WindowSizingTests`` says the ask is not the bug and the frame is —
        // that was true of BU-12, where a `fixedSize` published a minimum no
        // ideal could cap. This fault is the other kind: the demand *is* a
        // `minHeight`, and a `NavigationSplitView` clips its own contents, so
        // the overflow never reaches the platform subviews this file can see.
        // Measured with the 620 back in place, this read **660 against a
        // 560-point window**; without it, 416.5 connected and 220.5
        // disconnected. Delete this assertion and the file tests nothing.
        //
        // Against ``shortWindow`` and **not** `contentView.frame.height`: with
        // nothing to stop it a hosting view grows to its own demand, taking the
        // window with it, so the frame would be the fault measured against
        // itself. ``WindowSizingTests`` has the same trap in its third test.
        XCTAssertLessThanOrEqual(
            host.fittingHeight, Self.shortWindow.height,
            "\(what): the app demands more height than the window has, so the overflow is centred "
                + "and the status panel goes off the top edge",
            file: file, line: line)

        let laid = try XCTUnwrap(hostedLayout(host), "nothing was laid out", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            laid.minY, -1,
            "\(what): the overflow is centred, so the status panel is above the top edge",
            file: file, line: line)
        XCTAssertLessThanOrEqual(
            laid.maxY, max(host.contentView.frame.height, Self.shortWindow.height) + 1,
            "\(what): the column is taller than the window", file: file, line: line)
    }

    /// The reported case: M17, connected, on a display with nothing to spare.
    func testAConnectedM17ColumnFitsAShortWindow() async throws {
        let harness = await connected(.m17)
        XCTAssertEqual(harness.session.connection, .connected, "precondition: a link")

        let host = ViewHost(rootView(harness), size: Self.shortWindow)
        try assertFits(host, "connected on M17")
    }

    /// And the state it came from, which had the connect form in the column
    /// instead — the pane that was there when the 620 was measured.
    func testADisconnectedColumnFitsAShortWindow() throws {
        let harness = SessionHarness()
        let host = ViewHost(rootView(harness), size: Self.shortWindow)
        try assertFits(host, "disconnected")
    }

    /// Every mode, connected, because the panes under the session pane differ
    /// by mode and the tallest one is not the same on all three.
    func testEveryModeFitsAShortWindowWhileConnected() async throws {
        for mode in RadioMode.allCases {
            let harness = await connected(mode)
            XCTAssertEqual(harness.session.connection, .connected, "precondition: \(mode)")

            let host = ViewHost(rootView(harness), size: Self.shortWindow)
            try assertFits(host, "connected on \(mode)")
        }
    }
}

/// A node lookup that is never called — the sizing tests type nothing into the
/// form, and a real one would reach the network if they did.
private struct SilentNodeLookup: NodeLookup {
    func registration(forNode node: String) async throws -> NodeRegistration {
        throw NodeLookupError.notListed(node: node)
    }
}

#endif
