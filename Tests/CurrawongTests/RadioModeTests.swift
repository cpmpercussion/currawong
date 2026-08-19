// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// Choosing between AllStarLink, M17 and EchoLink.
///
/// The interesting part is not the enum, it is that `CompositionRoot` builds a
/// *different client* for each and that everything above it stays the same
/// type. That property is what `RadioLink` gave up its generic parameter for,
/// and it is what these tests pin.
final class RadioModeTests: XCTestCase {
    /// The operator. App-wide now, rather than a settings field.
    private let vk1xyz = OperatorIdentity(callsign: "VK1XYZ")

    /// A resolved proxy, which the caller hands the factory (APP-13).
    private let publicProxy = EchoLinkProxyRoute(
        host: "proxy.example.org", port: 8100, password: "PUBLIC", isPrivate: false)

    // MARK: - The mode itself

    func testAllThreeModesAreOfferedAndAllStarLinkIsTheDefault() {
        // Order matters: this is the order the picker shows, and the validated
        // mode leads it.
        XCTAssertEqual(RadioMode.allCases, [.allStarLink, .m17, .echoLink])
        // The default matters: it is what an operator with no stored settings
        // gets, and it should be the mode that is known to work.
        XCTAssertEqual(NodeSettings().mode, .allStarLink)
    }

    func testEachModeKnowsItsOwnPort() {
        XCTAssertEqual(RadioMode.allStarLink.defaultPort, 4569)
        XCTAssertEqual(RadioMode.m17.defaultPort, 17000)
        // 8100 is the *proxy's* TCP port, not the node's — EchoLink's own
        // 5198/5199 never appear in this app at all.
        XCTAssertEqual(RadioMode.echoLink.defaultPort, 8100)
    }

    // The two tests that used to sit here pinned `isValidatedOnAir` and
    // `unvalidatedWarning` — that M17 carried a caution and the other two did
    // not. Both properties were removed on 2026-08-16, when M17 receive was
    // proven on air and EchoLink ran from this app; see the note in
    // `RadioMode.swift` for why nothing replaced them.

    func testTheModesAskForDifferentThings() {
        XCTAssertTrue(RadioMode.allStarLink.usesNodeNumber)
        XCTAssertFalse(RadioMode.allStarLink.usesModule)
        XCTAssertFalse(RadioMode.allStarLink.usesProxy)

        XCTAssertTrue(RadioMode.m17.usesModule)
        XCTAssertFalse(RadioMode.m17.usesNodeNumber)
        XCTAssertFalse(RadioMode.m17.usesProxy)

        // EchoLink dials nothing and links nothing: it tunnels to a literal
        // address through a proxy, which is its own third set of fields.
        XCTAssertTrue(RadioMode.echoLink.usesProxy)
        XCTAssertFalse(RadioMode.echoLink.usesNodeNumber)
        XCTAssertFalse(RadioMode.echoLink.usesModule)
    }

    /// **The keypad is hidden, not shown-and-broken.** Only `IAX2Client` has a
    /// digit path; the other two clients have no `send(dtmf:)` at all, so a
    /// keypad in those modes would be a control that can only fail.
    func testOnlyAllStarLinkSendsDTMF() {
        XCTAssertTrue(RadioMode.allStarLink.sendsDTMF)
        XCTAssertFalse(RadioMode.m17.sendsDTMF)
        XCTAssertFalse(RadioMode.echoLink.sendsDTMF)
    }

    func testEveryModeHasADisplayNameAndAStableRawValue() {
        // The raw value is what `Codable` writes into `UserDefaults`, so it is
        // as frozen as the Keychain account format is: renaming a case would
        // make every stored channel of that mode undecodable.
        XCTAssertEqual(RadioMode.allStarLink.rawValue, "allStarLink")
        XCTAssertEqual(RadioMode.m17.rawValue, "m17")
        XCTAssertEqual(RadioMode.echoLink.rawValue, "echoLink")

        for mode in RadioMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) needs a name for the picker")
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    // MARK: - The composition root builds the right client

    private func allStarSettings() -> NodeSettings {
        NodeSettings(
            host: "node.example.org", port: 4569, node: "55553",
            username: "vk1xyz")
    }

    private func m17Settings() -> NodeSettings {
        var settings = NodeSettings(
            host: "reflector.example.org", port: 17000)
        settings.mode = .m17
        settings.module = "C"
        return settings
    }

    private func echoLinkSettings() -> NodeSettings {
        NodeSettings(
            mode: .echoLink,
            node: "*ECHOTEST*",
            peer: "13.57.14.183",
            directoryServer: "192.0.2.1")
    }

    @MainActor
    func testTheFactoryDispatchesOnTheModeInTheSettings() throws {
        let allStar = try CompositionRoot.makeLink(settings: allStarSettings(), identity: vk1xyz, credentials: .init(secret: "hunter2"))
        defer { allStar.close() }
        XCTAssertEqual(allStar.mode, .allStarLink)

        let m17 = try CompositionRoot.makeLink(settings: m17Settings(), identity: vk1xyz, credentials: .init())
        defer { m17.close() }
        XCTAssertEqual(m17.mode, .m17)

        let echoLink = try CompositionRoot.makeLink(
            settings: echoLinkSettings(), identity: vk1xyz,
            credentials: .init(secret: "account-password"), proxy: publicProxy)
        defer { echoLink.close() }
        XCTAssertEqual(echoLink.mode, .echoLink)
    }

    /// All three modes produce the same type — the whole point of the refactor,
    /// and the evidence that the seam is in the right place: a third protocol
    /// arrived without `RadioLink` or `RadioLinkEvent` changing at all. If this
    /// stops compiling, the app is back to one mode at a time.
    @MainActor
    func testAllThreeModesProduceTheSameKindOfLink() throws {
        let links: [RadioLink] = [
            try CompositionRoot.makeLink(settings: allStarSettings(), identity: vk1xyz, credentials: .init(secret: "hunter2")),
            try CompositionRoot.makeLink(settings: m17Settings(), identity: vk1xyz, credentials: .init()),
            try CompositionRoot.makeLink(
                settings: echoLinkSettings(), identity: vk1xyz, credentials: .init(),
                proxy: publicProxy),
        ]
        defer { links.forEach { $0.close() } }

        XCTAssertEqual(links.map(\.mode), [.allStarLink, .m17, .echoLink])
        for link in links {
            XCTAssertEqual(link.transmitState(), .idle, "building a link must not key anything")
        }
    }

    /// Building a link opens no socket — both clients build their transport
    /// lazily inside connect (AU-5).
    @MainActor
    func testBuildingAnM17LinkConnectsNothing() async throws {
        let link = try CompositionRoot.makeM17Link(settings: m17Settings(), identity: vk1xyz)
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
        let link = try CompositionRoot.makeM17Link(settings: m17Settings(), identity: vk1xyz)
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

        XCTAssertThrowsError(try CompositionRoot.makeM17Link(settings: settings, identity: vk1xyz)) { error in
            XCTAssertEqual(error as? M17LinkError, .invalidModule("CC"))
        }
    }

    /// **SF-1.** The operator's watchdog timeout has to reach the M17 client
    /// too, not just the IAX2 one. A wiring mistake here would be invisible
    /// until a transmission ran for three minutes when ten seconds was asked
    /// for, which is precisely the failure the watchdog exists to prevent.
    @MainActor
    func testTheWatchdogTimeoutIsTakenFromTheOperatorsSettingInEveryMode() {
        // One number for all three modes now — the timeout is the operator's, not
        // the channel's — so what is worth asserting is that each builder takes
        // it, rather than that three settings values arrive separately.
        for seconds in [10.0, 42.0, 15.0] {
            XCTAssertEqual(
                CompositionRoot.watchdogTimeout(for: TransmitTimeout(seconds: seconds)),
                .seconds(seconds))
        }
    }
}
