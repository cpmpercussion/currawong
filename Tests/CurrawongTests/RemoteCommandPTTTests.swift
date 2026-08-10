// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **PT-4.** The headset / remote-command input.
///
/// Two things are being pinned. First, that it is **off until asked for** — a
/// radio app that swallows the pause button by default breaks everybody's
/// podcast, and it must not touch `MPRemoteCommandCenter` before the operator
/// says so. Second, that a **latched transmission cannot outlive the input that
/// latched it**.
@MainActor
final class RemoteCommandPTTTests: XCTestCase {

    private var source: FakeRemoteCommandSource!
    private var store: InMemoryPTTSettingsStore!
    private var sink: RecordingPTTSink!

    override func setUp() {
        super.setUp()
        source = FakeRemoteCommandSource()
        store = InMemoryPTTSettingsStore()
        sink = RecordingPTTSink()
    }

    private func makeController() -> RemoteCommandPTTController {
        let controller = RemoteCommandPTTController(
            makeSource: { [source] in source! },
            store: store)
        controller.sink = sink
        return controller
    }

    func testItIsOffByDefaultAndTouchesNothing() {
        let controller = makeController()

        controller.activateIfEnabled()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(source.enableCount, 0)
    }

    func testItRearmsAtLaunchWhenTheOperatorLeftItOn() {
        store = InMemoryPTTSettingsStore(remoteCommandEnabled: true)
        let controller = makeController()

        controller.activateIfEnabled()

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(source.enableCount, 1)
    }

    func testEnablingIsPersisted() {
        let controller = makeController()

        controller.setEnabled(true)

        XCTAssertTrue(store.loadRemoteCommandEnabled())
        XCTAssertEqual(source.enableCount, 1)
    }

    func testATogglePressBecomesAToggleOnTheSink() async {
        let controller = makeController()
        controller.setEnabled(true)

        source.emit(.toggle)
        await waitUntil("the toggle arrived") { !self.sink.calls.isEmpty }

        XCTAssertEqual(sink.calls, [.toggled(.remoteCommand)])
    }

    /// A media remote with separate transport keys gives real edges, and where
    /// the app is given edges it uses them rather than toggling.
    func testSeparatePlayAndPauseKeysBecomePressAndRelease() async {
        let controller = makeController()
        controller.setEnabled(true)

        source.emit(.key)
        await waitUntil("the key arrived") { !self.sink.calls.isEmpty }
        source.emit(.unkey)
        await waitUntil("the unkey arrived") { self.sink.calls.count >= 2 }

        XCTAssertEqual(
            sink.calls,
            [
                .pressed(.remoteCommand),
                .released(.remoteCommand, .remoteCommandToggled),
            ])
    }

    /// Switching the input off while it might be holding a latched transmission
    /// must release it. Otherwise the operator has just removed the only control
    /// that could unkey them.
    func testSwitchingItOffReleasesTheKey() {
        let controller = makeController()
        controller.setEnabled(true)
        sink.clear()

        controller.setEnabled(false)

        XCTAssertEqual(sink.calls, [.released(.remoteCommand, .remoteCommandToggled)])
        XCTAssertEqual(source.disableCount, 1)
        XCTAssertFalse(store.loadRemoteCommandEnabled())
    }

    /// Commands that arrive after the operator switched the input off must do
    /// nothing — a stale `MPRemoteCommandCenter` target firing once more should
    /// not key a transmitter.
    func testCommandsAfterBeingDisabledAreIgnored() async {
        let controller = makeController()
        controller.setEnabled(true)
        controller.setEnabled(false)
        sink.clear()

        source.emit(.toggle)
        // Nothing to wait *for*, so wait for the stream hand-off to have had
        // every chance to happen and assert it produced nothing.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sink.calls, [])
    }

    /// PT-4's contract, as a value: this source does not end when the button is
    /// let go, and the UI is required to say so.
    func testTheSourceDeclaresItselfNonMomentary() {
        XCTAssertFalse(PTTSource.remoteCommand.isMomentary)
        XCTAssertTrue(PTTSource.onScreen.isMomentary)
        XCTAssertTrue(PTTSource.accessory.isMomentary)
        XCTAssertTrue(PTTSource.remoteCommand.holdDescription.contains("Latched"))
    }
}
