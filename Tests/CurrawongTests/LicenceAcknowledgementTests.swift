// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **APP-33.** The once-per-install licence acknowledgement, and the one thing
/// it is allowed to stop.
///
/// The assertions worth having are asymmetric. That an acknowledged operator can
/// transmit is covered by every other PTT test in this suite; what needs proving
/// here is the *refusal* — that it holds from every input, that it leaves the
/// radio unkeyed rather than half-keyed, and that it does not leak into
/// connecting or listening.
final class LicenceAcknowledgementValueTests: XCTestCase {
    func testAFreshInstallHasNotAcknowledged() {
        XCTAssertFalse(LicenceAcknowledgement.isSatisfied(by: nil))
    }

    func testTheCurrentVersionSatisfies() {
        XCTAssertTrue(
            LicenceAcknowledgement.isSatisfied(by: LicenceAcknowledgement.currentVersion))
    }

    /// An operator who acknowledged older wording is asked again. This is the
    /// whole reason the stored value is a number.
    func testAnOlderAcknowledgementDoesNotSatisfy() {
        XCTAssertFalse(
            LicenceAcknowledgement.isSatisfied(by: LicenceAcknowledgement.currentVersion - 1))
    }

    /// A stored version from a *newer* build — an operator who downgraded —
    /// still counts. They have seen at least this much.
    func testANewerAcknowledgementStillSatisfies() {
        XCTAssertTrue(
            LicenceAcknowledgement.isSatisfied(by: LicenceAcknowledgement.currentVersion + 1))
    }

    /// The notice names the operator. A generic one is something to tap past.
    func testTheNoticeNamesTheCallsign() {
        XCTAssertTrue(
            LicenceAcknowledgement.identification(callsign: "VK1XYZ").contains("VK1XYZ"))
    }

    /// It must not read `Your callsign, , is sent…` if it is ever raised without
    /// one. `connect()` makes that unreachable today; a sentence that falls apart
    /// when someone later moves the gate is not worth leaving lying around.
    func testTheNoticeSurvivesAnEmptyCallsign() {
        let text = LicenceAcknowledgement.identification(callsign: "   ")
        XCTAssertFalse(text.contains(",  ,"))
        XCTAssertTrue(text.contains("callsign"))
    }

    /// The RF warning is the half the maintainer asked for, and it must keep
    /// saying *some and not others* rather than promising either way.
    func testTheNoticeWarnsThatSomeDestinationsAreOnAir() {
        XCTAssertTrue(LicenceAcknowledgement.overTheAir.contains("some are not"))
        XCTAssertTrue(LicenceAcknowledgement.overTheAir.contains("radio transmitters"))
    }

    /// Declining is a supported way to use the app, and the button says so.
    func testDecliningIsOfferedAsListening() {
        XCTAssertEqual(LicenceAcknowledgement.declineButton, "Listen only")
    }
}

@MainActor
final class LicenceAcknowledgementGateTests: XCTestCase {

    /// The fresh-install case: connected, pressed, nothing on the air.
    func testAnUnacknowledgedPressDoesNotTransmit() async {
        let harness = SessionHarness(licenceAcknowledged: false)
        await harness.connect()

        harness.session.beginTransmit()
        await harness.settleAll()

        XCTAssertTrue(harness.session.needsLicenceAcknowledgement)
        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.client.calls.contains(.startTransmit))
    }

    /// Every input, not just the button. A fob is the case where nobody is
    /// looking at the screen, and it is the one that must not get through.
    func testTheGateHoldsFromEveryInput() async {
        for source in [PTTSource.onScreen, .accessory, .remoteCommand] {
            let harness = SessionHarness(licenceAcknowledged: false)
            await harness.connect()

            harness.session.beginTransmit(from: source)
            await harness.settleAll()

            XCTAssertFalse(
                harness.session.isTransmitting, "\(source) got past the acknowledgement")
            XCTAssertFalse(
                harness.client.calls.contains(.startTransmit),
                "\(source) reached the link")
            XCTAssertTrue(
                harness.session.needsLicenceAcknowledgement,
                "\(source) did not raise the sheet")
        }
    }

    /// Accepting does not key the radio — the press that raised the sheet is
    /// spent. Keying as a side effect of dismissing a dialogue is exactly the
    /// stuck-microphone shape this app exists to avoid.
    func testAcceptingDoesNotTransmitByItself() async {
        let harness = SessionHarness(licenceAcknowledged: false)
        await harness.connect()

        harness.session.beginTransmit()
        await harness.settleAll()
        harness.session.acknowledgeLicence()
        await harness.settleAll()

        XCTAssertFalse(harness.session.needsLicenceAcknowledgement)
        XCTAssertTrue(harness.session.hasAcknowledgedLicence)
        XCTAssertFalse(harness.session.isTransmitting)
        XCTAssertFalse(harness.client.calls.contains(.startTransmit))
    }

    /// And the next press does.
    func testThePressAfterAcceptingTransmits() async {
        let harness = SessionHarness(licenceAcknowledged: false)
        await harness.connect()

        harness.session.beginTransmit()
        await harness.settleAll()
        harness.session.acknowledgeLicence()

        await harness.keyDown()

        XCTAssertTrue(harness.session.isTransmitting)
        XCTAssertEqual(harness.client.calls.filter { $0 == .startTransmit }.count, 1)
    }

    /// Declining stores nothing, so the next press asks again rather than
    /// locking the operator out of a radio they may well be licensed for.
    func testDecliningIsNotRemembered() async {
        let harness = SessionHarness(licenceAcknowledged: false)
        await harness.connect()

        harness.session.beginTransmit()
        await harness.settleAll()
        harness.session.declineLicence()
        await harness.settleAll()

        XCTAssertFalse(harness.session.needsLicenceAcknowledgement)
        XCTAssertFalse(harness.session.hasAcknowledgedLicence)
        XCTAssertNil(harness.settingsStore.loadLicenceAcknowledgement())

        harness.session.beginTransmit()
        await harness.settleAll()
        XCTAssertTrue(harness.session.needsLicenceAcknowledgement)
        XCTAssertFalse(harness.session.isTransmitting)
    }

    /// **The point of gating transmit rather than launch.** An operator who has
    /// not acknowledged still gets a working, listening radio.
    func testListeningNeedsNoAcknowledgement() async {
        let harness = SessionHarness(licenceAcknowledged: false)
        await harness.connect()

        XCTAssertEqual(harness.session.connection, .connected)
        XCTAssertFalse(harness.session.needsLicenceAcknowledgement)
        XCTAssertEqual(harness.linksMade, 1)
    }

    /// It survives a relaunch — that is what "once per install" means, and the
    /// store is the only thing that can prove it.
    func testAnAcknowledgementSurvivesTheNextLaunch() async {
        let first = SessionHarness(licenceAcknowledged: false)
        first.session.acknowledgeLicence()
        XCTAssertEqual(
            first.settingsStore.loadLicenceAcknowledgement(),
            LicenceAcknowledgement.currentVersion)

        let second = SessionHarness(reusing: first)
        XCTAssertTrue(second.session.hasAcknowledgedLicence)
    }

    /// A press that is refused must leave no trace of a hold behind it: the
    /// gate returns before any of the key-down bookkeeping, and a half-started
    /// hold would confuse the next real press.
    func testARefusedPressStartsNoHold() async {
        let harness = SessionHarness(licenceAcknowledged: false)
        await harness.connect()

        harness.session.beginTransmit()
        await harness.settleAll()

        XCTAssertEqual(harness.session.keyDownsInCurrentHold, 0)
        XCTAssertNil(harness.session.activeSource)
        XCTAssertFalse(harness.session.isKeyDown)
    }
}

/// The stored half, against a real `UserDefaultsSettingsStore` — what is being
/// tested is the reading and writing of a defaults key, which the in-memory fake
/// cannot speak to. Each test gets its own suite, removed afterwards.
final class SettingsStoreLicenceAcknowledgementTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "au.charlesmartin.currawong.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> UserDefaultsSettingsStore {
        UserDefaultsSettingsStore(defaults: defaults)
    }

    func testAnAcknowledgementRoundTrips() {
        let store = store()
        XCTAssertNil(store.loadLicenceAcknowledgement(), "nothing has ever been saved")

        store.saveLicenceAcknowledgement(LicenceAcknowledgement.currentVersion)

        XCTAssertEqual(
            store.loadLicenceAcknowledgement(), LicenceAcknowledgement.currentVersion)
    }

    /// **The reason `loadLicenceAcknowledgement()` checks `object(forKey:)`.**
    /// `integer(forKey:)` answers `0` for a key that was never written, which is
    /// indistinguishable from a stored `0` — and a stored `0` must not read as
    /// "never acknowledged" if the versioning ever starts there.
    func testAStoredZeroIsNotTheSameAsNeverAcknowledged() {
        let store = store()
        store.saveLicenceAcknowledgement(0)

        XCTAssertEqual(store.loadLicenceAcknowledgement(), 0)
        XCTAssertNotNil(store.loadLicenceAcknowledgement())
    }

    /// **APP-33.** The UI-test hook writes the same key the store reads —
    /// two spellings of it would mean the on-air target silently hits the sheet.
    func testTheUITestHookWritesTheKeyTheStoreReads() {
        defaults.set(
            LicenceAcknowledgement.currentVersion,
            forKey: UserDefaultsSettingsStore.licenceAcknowledgementKey)

        XCTAssertTrue(
            LicenceAcknowledgement.isSatisfied(by: store().loadLicenceAcknowledgement()))
    }
}
