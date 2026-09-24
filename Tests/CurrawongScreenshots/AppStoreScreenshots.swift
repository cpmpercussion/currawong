// SPDX-License-Identifier: Apache-2.0

import XCTest

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
                "-currawong-defaults-reset", "YES",
                "-currawong-screenshot-scene", scene,
                "-currawong-appearance", appearance,
                "-ApplePersistenceIgnoreState", "YES",
            ]
            app.launch()

            try waitUntilReady(app, scene: scene)
            // The meters and the on-air clock have something to show.
            Thread.sleep(forTimeInterval: 2)

            #if os(macOS)
            let image = app.windows.firstMatch.screenshot()
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

    private func waitUntilReady(_ app: XCUIApplication, scene: String) throws {
        let ptt = app.descendants(matching: .any)["Push to talk"].firstMatch
        switch scene {
        case "channels":
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Canberra hub")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "The seeded channels never appeared.")
        case "transmitting":
            XCTAssertTrue(ptt.waitForExistence(timeout: 10), "No PTT button.")
            let onAir = NSPredicate(format: "value == %@", "Transmitting")
            expectation(for: onAir, evaluatedWith: ptt)
            waitForExpectations(timeout: 10)
        default:
            XCTAssertTrue(ptt.waitForExistence(timeout: 10), "No PTT button.")
            let disconnect = app.buttons["Disconnect"].firstMatch
            XCTAssertTrue(disconnect.waitForExistence(timeout: 10), "Never connected.")
        }
    }
}
