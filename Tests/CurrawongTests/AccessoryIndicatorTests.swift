// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-18.** The status panel's accessory light — and above all the third
/// state, which is SF-2: configured, and not able to key the radio.
final class AccessoryIndicatorTests: XCTestCase {
    private func indicator(
        _ linkState: BLEPTTController.LinkState,
        configured: Bool = true,
        keyed: Bool = false,
        remoteCommand: Bool = false,
        verified: Bool = true
    ) -> AccessoryIndicator {
        AccessoryIndicator(
            linkState: linkState,
            isAccessoryConfigured: configured,
            isAccessoryKeyed: keyed,
            isRemoteCommandEnabled: remoteCommand,
            isButtonVerified: verified)
    }

    // MARK: - A connection is not a working button (BU-14)

    /// `.connected` with nothing yet arrived is "untested", not "ready" — after
    /// BU-14 a connection is no evidence at all, and "Accessory ready" over a
    /// dead button sends the operator on air believing they can key.
    func testConnectedButUnverifiedIsUntestedNotReady() {
        let light = indicator(.connected, verified: false)
        XCTAssertEqual(light.title, "Accessory untested")
        XCTAssertEqual(light.emphasis, .working)
    }

    /// And VoiceOver is told the same truth the glyph carries — the label must
    /// not fall through to plain "connected", which is the claim being avoided.
    func testTheUntestedStateIsHonestToVoiceOverToo() {
        let light = indicator(.connected, verified: false)
        XCTAssertTrue(
            light.accessibilityLabel.localizedCaseInsensitiveContains("untested"),
            "got: \(light.accessibilityLabel)")
    }

    // MARK: - The three states

    func testNothingConfiguredIsDimAndSaysSo() {
        let light = indicator(.noAccessory, configured: false)
        XCTAssertEqual(light.emphasis, .dim)
        XCTAssertEqual(light.title, "No accessory")
    }

    func testConfiguredAndConnectedIsSolid() {
        XCTAssertEqual(indicator(.connected).emphasis, .solid)
        XCTAssertEqual(indicator(.connected).title, "Accessory ready")
    }

    /// The state the indicator exists for. An operator whose fob has just
    /// dropped has stopped being able to transmit, and the screen they are
    /// already looking at has to say why.
    func testConfiguredAndLostIsLoud() {
        for state: BLEPTTController.LinkState in [
            .reconnecting, .failed("gave up"), .unavailable("Bluetooth is off"), .noAccessory,
        ] {
            let light = indicator(state)
            XCTAssertEqual(light.emphasis, .loud, "\(state)")
            XCTAssertEqual(light.title, "Accessory lost", "\(state)")
        }
    }

    /// The reason it is not enough to draw the link state: `noAccessory` means
    /// two opposite things, and which one depends on whether a mapping was ever
    /// learned. Same link state, dim or loud.
    func testTheSameLinkStateIsDimOrLoudDependingOnWhetherOneIsConfigured() {
        XCTAssertEqual(indicator(.noAccessory, configured: false).emphasis, .dim)
        XCTAssertEqual(indicator(.noAccessory, configured: true).emphasis, .loud)
    }

    // MARK: - Not one of the three

    func testPairingIsNeitherReadyNorLost() {
        XCTAssertEqual(indicator(.scanning).emphasis, .working)
        XCTAssertEqual(indicator(.connecting).emphasis, .working)
        XCTAssertEqual(indicator(.scanning).title, "Linking…")
    }

    /// While a button is held, what it is doing outranks how it got connected.
    func testKeyedOutranksEverything() {
        let light = indicator(.connected, keyed: true)
        XCTAssertEqual(light.title, "Accessory keyed")
        XCTAssertEqual(light.emphasis, .solid)

        // Including a link state that would otherwise be loud: a press cannot
        // arrive on a link that is down, so this is a race rather than a fault,
        // and reporting "lost" over a live key would be the wrong half of it.
        XCTAssertEqual(indicator(.reconnecting, keyed: true).title, "Accessory keyed")
    }

    // MARK: - PT-4

    /// A headset button is a configured input with no link to lose, and it is
    /// the one thing that makes this solid with no accessory at all.
    func testAnArmedHeadsetButtonIsSolidWithNoAccessory() {
        let light = indicator(.noAccessory, configured: false, remoteCommand: true)
        XCTAssertEqual(light.emphasis, .solid)
        XCTAssertEqual(light.title, "Headset PTT")
    }

    /// Bluetooth being off matters to an operator who has a fob, and to nobody
    /// else. Shouting at somebody who has never set one up teaches them to
    /// ignore the light.
    func testBluetoothOffIsNotShoutedAboutWithNothingConfigured() {
        XCTAssertEqual(indicator(.unavailable("Bluetooth is off"), configured: false).emphasis, .dim)
        XCTAssertEqual(indicator(.unavailable("Bluetooth is off")).emphasis, .loud)
    }

    // MARK: - VoiceOver

    /// The panel has room for three words; VoiceOver does not have that limit,
    /// and the operator asking this question is the one who needs the reason.
    func testTheAccessibilityLabelCarriesTheReasonTheTitleCannot() {
        let light = indicator(.failed("Could not reach the accessory"))
        XCTAssertEqual(light.title, "Accessory lost")
        XCTAssertEqual(light.accessibilityLabel, "PTT accessory: Could not reach the accessory")
    }
}
