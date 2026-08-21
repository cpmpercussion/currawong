// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit
import SwiftUI
import XCTest

@testable import Currawong

/// **BU-9 item 3.** What the channel row's context menu actually contains after
/// a link has been up and come down again.
///
/// macOS has no swipe-to-delete, so this menu is the *only* way to remove a
/// channel on that platform, and the bring-up report says it is dead for any
/// channel the launch has connected to. That claim came from an XCUITest, which
/// can only see what the accessibility tree offers it; this looks at the AppKit
/// object the platform will actually display.
///
/// `.contextMenu` is realised as an `NSMenu` on the row's `CellHostingView`, and
/// SwiftUI rebuilds it on demand: every read of `view.menu` hands back a fresh
/// instance carrying the enabled-ness of the environment at the moment it was
/// read. Which is the interesting part — a menu built while the list was locked
/// keeps `isEnabled == false` and a `nil` action **for ever**, so anything
/// holding on to one is looking at a permanently dead Delete. What this test
/// pins down is that the row itself does not: read again after the disconnect
/// and the item comes back enabled, with a live action, and firing it deletes
/// the channel.
///
/// **Runs headless, transmits nothing, opens no socket** — the link is
/// `SessionHarness`'s fake. macOS only, because there is no `NSMenu` on iOS and
/// no defect there either: iOS deletes by swipe.
@MainActor
final class ChannelListContextMenuTests: XCTestCase {

    private let bystander = NodeSettings(
        name: "Bystander", mode: .allStarLink, host: "bystander.example.org", node: "1")

    /// The row views that carry a context menu, in list order. One per channel.
    private func rowsWithMenus(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view.menu != nil { found.append(view) }
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    /// The row's Delete item, freshly built — which is the only kind the
    /// platform ever displays.
    private func deleteItem(ofRow index: Int, in host: NSView) throws -> NSMenuItem {
        let rows = rowsWithMenus(in: host)
        let row = try XCTUnwrap(
            index < rows.count ? rows[index] : nil, "no row \(index) with a context menu")
        let menu = try XCTUnwrap(row.menu, "row \(index) has no context menu")
        menu.update()
        return try XCTUnwrap(
            menu.items.first { $0.title == "Delete" }, "no Delete item in row \(index)'s menu")
    }

    func testDeleteComesBackAfterALinkHasBeenUpAndDown() async throws {
        let connected = SessionHarness.goodSettings
        let harness = SessionHarness(
            settings: nil, channels: [bystander, connected], selectedID: connected.id)

        // Hosted the way `RootView.splitLayout` hosts it on macOS: the channel
        // list is the sidebar of a `NavigationSplitView`, which is a different
        // list representation from a bare `List`.
        // Hosted by `ViewHost`, which owns the window and the "never close it"
        // rule that the long note below is about.
        let hosted = ViewHost(
            NavigationSplitView {
                ChannelListView(session: harness.session)
            } detail: {
                Text("detail")
            },
            size: CGSize(width: 480, height: 480))
        let host = hosted.contentView

        XCTAssertTrue(
            try deleteItem(ofRow: 0, in: host).isEnabled,
            "Delete should be live before anything has connected")

        await harness.session.connect()
        XCTAssertEqual(harness.session.connection, .connected)
        hosted.settle()

        // The lock reaches the menu, which is the behaviour that is wanted:
        // deleting a channel under a live call is refused, and the menu says so
        // rather than offering an item that would do nothing.
        let lockedItem = try deleteItem(ofRow: 0, in: host)
        XCTAssertFalse(lockedItem.isEnabled, "Delete should be dead while a link is up")

        await harness.session.disconnect()
        XCTAssertEqual(harness.session.connection, .disconnected)
        hosted.settle()

        // The row that was merely sitting in the list while it was locked.
        let bystanderItem = try deleteItem(ofRow: 0, in: host)
        XCTAssertTrue(
            bystanderItem.isEnabled,
            "Delete stayed dead on a row that existed while the list was locked")
        XCTAssertNotNil(
            bystanderItem.action, "the item is enabled but has no action to send")

        // And the row that was actually connected to — the one the report says
        // cannot be deleted at all.
        XCTAssertTrue(
            try deleteItem(ofRow: 1, in: host).isEnabled,
            "Delete stayed dead on the channel this session connected to")

        // The menu instance that was read while the list was locked is a
        // different object and stays disabled for ever. Recorded because it is
        // the one way this can still present as a permanently greyed Delete:
        // whatever holds a menu from the locked state is holding a corpse.
        XCTAssertFalse(
            lockedItem.isEnabled,
            "a menu built while locked is expected to stay disabled — SwiftUI builds a new one")

        // Firing the item is what proves the whole path, not just its
        // enabled-ness: an enabled menu item whose action deletes nothing would
        // look identical from the accessibility tree.
        let action = try XCTUnwrap(bystanderItem.action)
        XCTAssertTrue(
            NSApp.sendAction(action, to: bystanderItem.target, from: bystanderItem),
            "the Delete item's action was not accepted")
        hosted.settle()

        XCTAssertFalse(
            harness.session.channels.channels.contains { $0.id == bystander.id },
            "Delete fired but the channel is still in the list")
    }
}
#endif
