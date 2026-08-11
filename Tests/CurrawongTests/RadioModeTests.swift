// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// Choosing between AllStarLink and M17.
///
/// The interesting part is not the enum, it is that `CompositionRoot` builds a
/// *different client* for each and that everything above it stays the same
/// type. That property is what `RadioLink` gave up its generic parameter for,
/// and it is what these tests pin.
final class RadioModeTests: XCTestCase {

    // MARK: - The mode itself

    func testBothModesAreOfferedAndAllStarLinkIsTheDefault() {
        XCTAssertEqual(RadioMode.allCases, [.allStarLink, .m17])
        // The default matters: it is what an operator with no stored settings
        // gets, and it should be the mode that is known to work.
        XCTAssertEqual(NodeSettings().mode, .allStarLink)
    }

    func testEachModeKnowsItsOwnPort() {
        XCTAssertEqual(RadioMode.allStarLink.defaultPort, 4569)
        XCTAssertEqual(RadioMode.m17.defaultPort, 17000)
    }

    /// **This is a safety property, not a cosmetic one.** One of these two
    /// modes has carried a real conversation and the other has never been
    /// transmitted at all. If M17 ever quietly starts claiming to be
    /// validated, an operator loses the only warning they get.
    func testOnlyAllStarLinkClaimsToBeValidatedOnAir() {
        XCTAssertTrue(RadioMode.allStarLink.isValidatedOnAir)
        XCTAssertNil(RadioMode.allStarLink.unvalidatedWarning)

        XCTAssertFalse(RadioMode.m17.isValidatedOnAir)
        XCTAssertNotNil(
            RadioMode.m17.unvalidatedWarning,
            "M17 must carry a warning until somebody has actually used it on air")
    }

    func testTheModesAskForDifferentThings() {
        XCTAssertTrue(RadioMode.allStarLink.usesNodeNumber)
        XCTAssertFalse(RadioMode.allStarLink.usesModule)

        XCTAssertTrue(RadioMode.m17.usesModule)
        XCTAssertFalse(RadioMode.m17.usesNodeNumber)
    }

    // MARK: - The composition root builds the right client

    private func allStarSettings() -> NodeSettings {
        NodeSettings(
            host: "node.example.org", port: 4569, node: "55553",
            username: "vk1xyz", callsign: "VK1XYZ")
    }

    private func m17Settings() -> NodeSettings {
        var settings = NodeSettings(
            host: "reflector.example.org", port: 17000, callsign: "VK1XYZ")
        settings.mode = .m17
        settings.module = "C"
        return settings
    }

    @MainActor
    func testTheFactoryDispatchesOnTheModeInTheSettings() throws {
        let allStar = try CompositionRoot.makeLink(settings: allStarSettings(), secret: "hunter2")
        defer { allStar.close() }
        XCTAssertEqual(allStar.mode, .allStarLink)

        let m17 = try CompositionRoot.makeLink(settings: m17Settings(), secret: "")
        defer { m17.close() }
        XCTAssertEqual(m17.mode, .m17)
    }

    /// Both modes produce the same type — the whole point of the refactor.
    /// If this stops compiling, the app is back to one mode at a time.
    @MainActor
    func testBothModesProduceTheSameKindOfLink() throws {
        let links: [RadioLink] = [
            try CompositionRoot.makeLink(settings: allStarSettings(), secret: "hunter2"),
            try CompositionRoot.makeLink(settings: m17Settings(), secret: ""),
        ]
        defer { links.forEach { $0.close() } }

        XCTAssertEqual(links.map(\.mode), [.allStarLink, .m17])
        for link in links {
            XCTAssertEqual(link.transmitState(), .idle, "building a link must not key anything")
        }
    }

    /// Building a link opens no socket — both clients build their transport
    /// lazily inside connect (AU-5).
    @MainActor
    func testBuildingAnM17LinkConnectsNothing() async throws {
        let link = try CompositionRoot.makeM17Link(settings: m17Settings())
        defer { link.close() }

        XCTAssertEqual(link.transmitState(), .idle)
        // Documented as safe on a client that was never connected: SF-2 and
        // SF-3 call it from paths that cannot know the current state.
        await link.stopTransmit()
        XCTAssertEqual(link.transmitState(), .idle)
    }

    /// M17 has no DTMF, and the link says so rather than silently doing
    /// nothing. The connect form hides the keypad in this mode, so this is the
    /// backstop rather than the first line of defence.
    @MainActor
    func testM17RefusesDTMFRatherThanSwallowingIt() async throws {
        let link = try CompositionRoot.makeM17Link(settings: m17Settings())
        defer { link.close() }

        do {
            try await link.sendDTMF("1")
            XCTFail("expected M17 to refuse DTMF")
        } catch {
            XCTAssertEqual(error as? M17LinkError, .dtmfUnsupported)
        }
    }

    /// A module that got past validation is still refused at the point it
    /// would become an `M17Destination`.
    @MainActor
    func testAnImpossibleModuleIsRefusedByTheFactory() {
        var settings = m17Settings()
        settings.module = "CC"

        XCTAssertThrowsError(try CompositionRoot.makeM17Link(settings: settings)) { error in
            XCTAssertEqual(error as? M17LinkError, .invalidModule("CC"))
        }
    }

    /// **SF-1.** The operator's watchdog timeout has to reach the M17 client
    /// too, not just the IAX2 one. A wiring mistake here would be invisible
    /// until a transmission ran for three minutes when ten seconds was asked
    /// for, which is precisely the failure the watchdog exists to prevent.
    @MainActor
    func testTheWatchdogTimeoutIsTakenFromTheOperatorsSettingsInBothModes() {
        var settings = m17Settings()
        settings.transmitTimeout = 10
        XCTAssertEqual(CompositionRoot.watchdogTimeout(for: settings), .seconds(10))

        var allStar = allStarSettings()
        allStar.transmitTimeout = 42
        XCTAssertEqual(CompositionRoot.watchdogTimeout(for: allStar), .seconds(42))
    }
}
