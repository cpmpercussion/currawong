// SPDX-License-Identifier: Apache-2.0

import XCTest
#if os(macOS)
import CoreGraphics
#endif

/// The App Store screenshots: each ``ScreenshotStage`` scene, light and dark,
/// attached to the result bundle for `scripts/screenshots.sh` to export.
///
/// Nothing here goes on air. The stage replaces every link with a local fake
/// and the audio with a synthetic one, so these run anywhere, and are kept out
/// of the `Currawong` scheme only because they are slow and produce files
/// rather than verdicts.
final class AppStoreScreenshots: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func test1Channels() throws { try capture(scene: "channels", number: 1) }
    func test2Receiving() throws { try capture(scene: "receiving", number: 2) }
    func test3Transmitting() throws { try capture(scene: "transmitting", number: 3) }

    private func capture(scene: String, number: Int) throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += [
                "-currawong-defaults-suite", "au.charlesmartin.currawong.screenshots",
                "-currawong-screenshot-scene", scene,
                "-currawong-appearance", appearance,
                "-ApplePersistenceIgnoreState", "YES",
            ]
            app.launch()

            try waitUntilReady(app, scene: scene)
            // The meters and the on-air clock have something to show.
            Thread.sleep(forTimeInterval: 2)

            #if os(macOS)
            // The pointer, left over the PTT button, draws its hover effect.
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).hover()
            Thread.sleep(forTimeInterval: 0.5)
            try waitForNoPanels()
            let image = window.screenshot()
            #else
            let image = XCUIScreen.main.screenshot()
            #endif
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = "\(number)-\(scene)-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)

            app.terminate()
        }
    }

    #if os(macOS)
    /// Fails unless the app's only on-screen window is its main one.
    ///
    /// A window screenshot is a crop of the screen, so anything the app floats
    /// over its window is in it — BU-11's AutoFill panel in particular, which
    /// the stage hides but cannot stop AppKit showing. The panel is at layer
    /// 101; the main window is at 0.
    private func waitForNoPanels() throws {
        func panels() -> [[String: Any]] {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] ?? []
            return list.filter {
                ($0[kCGWindowOwnerName as String] as? String) == "Currawong"
                    && ($0[kCGWindowLayer as String] as? Int ?? 0) != 0
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !panels().isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let left = panels()
        XCTAssertTrue(left.isEmpty, "A window floats over the app: \(left)")
    }
    #endif

    private func waitUntilReady(_ app: XCUIApplication, scene: String) throws {
        let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
        switch scene {
        case "channels":
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Canberra hub")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "The seeded channels never appeared.")
        case "transmitting":
            let strip = app.descendants(matching: .any)["session.transmitStrip"].firstMatch
            XCTAssertTrue(strip.waitForExistence(timeout: 10), "No transmit strip.")
            let onAir = NSPredicate(format: "label BEGINSWITH %@", "Transmitting")
            expectation(for: onAir, evaluatedWith: strip)
            waitForExpectations(timeout: 10)
        default:
            XCTAssertTrue(ptt.waitForExistence(timeout: 10), "No PTT button.")
            let disconnect = app.buttons["Disconnect"].firstMatch
            XCTAssertTrue(disconnect.waitForExistence(timeout: 10), "Never connected.")
        }
    }
}
