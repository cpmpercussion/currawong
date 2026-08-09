// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// Proves the app is genuinely wired to the library: these tests only compile
/// if the local SPM path dependency resolved and linked, and only pass if what
/// the composition root builds starts in a safe state.
///
/// No socket is opened and no audio device is touched. `IAX2Client` builds its
/// transport lazily, inside `connect(to:)`, so constructing one costs nothing
/// but memory; the audio pipeline is injected as a fake for the same reason.
///
/// Note what is *not* imported here: `IAX2Kit`. These tests reach the client
/// through `RadioCore`'s vocabulary alone, which is the same constraint the
/// rest of the app is under.
@MainActor
final class CompositionRootTests: XCTestCase {
    private func makeRoot() -> CompositionRoot {
        CompositionRoot(
            audio: FakeAudioIO(),
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore())
    }

    func testAFreshRootIsIdleAndNotTransmitting() {
        let root = makeRoot()

        XCTAssertEqual(root.transmitState, .idle)
        XCTAssertFalse(TransmitStatusPresentation(state: root.transmitState).isTransmitting)
        XCTAssertEqual(root.session.connection, .disconnected)
        XCTAssertFalse(root.session.isTransmitting)
    }

    /// The link factory is where `IAX2Kit` is named, so this is where it gets
    /// exercised: it must build a whole connection's worth of plumbing without
    /// opening anything.
    func testTheLinkFactoryBuildsAClientWithoutConnectingIt() async {
        let link = CompositionRoot.makeIAX2Link(
            settings: NodeSettings(
                host: "node.example.org", port: 4569, node: "55553",
                username: "vk1xyz", callsign: "VK1XYZ"),
            secret: "hunter2")
        defer { link.close() }

        XCTAssertEqual(link.client.state, .idle)
        let isConnected = await link.client.isConnected
        XCTAssertFalse(isConnected)
    }

    /// Stopping transmit is documented as safe on a client that was never
    /// connected — SF-2 and SF-3 both call it from paths that cannot know the
    /// current state, so it must not trap here either.
    func testStopTransmitOnAnUnconnectedClientIsHarmless() async {
        let link = CompositionRoot.makeIAX2Link(
            settings: NodeSettings(host: "node.example.org", node: "55553", callsign: "VK1XYZ"),
            secret: "")
        defer { link.close() }

        await link.client.stopTransmit()

        XCTAssertEqual(link.client.state, .idle)
    }

    /// The captured-frame path must be safe to call when nothing is
    /// transmitting: the microphone does not know about PTT, and the client is
    /// documented to drop frames it is not keyed for rather than throwing.
    func testHandingFramesToAnUnkeyedLinkIsHarmless() {
        let link = CompositionRoot.makeIAX2Link(
            settings: NodeSettings(host: "node.example.org", node: "55553", callsign: "VK1XYZ"),
            secret: "")
        defer { link.close() }

        link.sendCapturedFrame(Array(repeating: 0, count: 160))
    }
}
