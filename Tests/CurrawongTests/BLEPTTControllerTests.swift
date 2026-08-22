// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Currawong

/// **BLE-1, BLE-2, BLE-3.** The Bluetooth PTT controller, driven from
/// ``FakeBLECentral`` with no radio and no accessory.
///
/// The requirement these exist for is **SF-2**: a disconnection stops
/// transmission, unconditionally and before anything else. Everything else here
/// — scanning, learn mode, reconnection — is in service of getting an accessory
/// to the point where SF-2 can matter.
@MainActor
final class BLEPTTControllerTests: XCTestCase {

    private var central: FakeBLECentral!
    private var store: InMemoryPTTSettingsStore!
    private var sink: RecordingPTTSink!

    override func setUp() {
        super.setUp()
        central = FakeBLECentral()
        store = InMemoryPTTSettingsStore()
        sink = RecordingPTTSink()
    }

    /// `retryDelay` returns immediately, so the reconnection ladder runs at test
    /// speed rather than in real seconds.
    private func makeController() -> BLEPTTController {
        let controller = BLEPTTController(
            makeCentral: { [central] in central! },
            store: store,
            retryDelay: {})
        controller.sink = sink
        return controller
    }

    /// The controller consumes its central's events on a task, so a test has to
    /// let that task run before asserting.
    private func settle(_ description: String, _ predicate: @MainActor () -> Bool) async {
        await waitUntil(description, predicate)
    }


    // MARK: - Repairing a link that has gone quiet (BU-14)

    /// A clock the test moves by hand, so the repair cooldown does not cost real
    /// seconds.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            value = value.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    /// A mapping already stored and the link up — the state a repair applies to.
    private func makeConnectedController(
        clock: TestClock,
        neverFiringBackstop: DelayGate? = nil,
        isRebuildSafe: (@MainActor () -> Bool)? = nil
    ) async -> (BLEPTTController, BLEPTTMapping) {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = BLEPTTController(
            makeCentral: { [central] in central! },
            store: store,
            retryDelay: {},
            now: { clock.now },
            // A wait that is never released: these tests assert the
            // *event-driven* path, and a deadline that fired would mask it.
            probeDeadline: (neverFiringBackstop ?? DelayGate()).wait)
        controller.sink = sink
        controller.isRebuildSafe = isRebuildSafe
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await waitUntil("connected") { controller.linkState == .connected }
        central.clearCalls()
        return (controller, mapping)
    }

    /// **A route change asks before it acts.** The cheap question first: is this
    /// link still carrying data? Only a failed answer costs a rebuild.
    ///
    /// This test previously asserted an immediate disconnect, because until the
    /// probe worked a rebuild was the only move available. That cost a dead button
    /// for the length of a reconnection after *every over* — 1.6 s and 2.6 s
    /// measured on the device, which is the window a quick reply lands in.
    func testARouteChangeProbesBeforeRebuilding() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()

        XCTAssertEqual(
            central.calls, [.probe(mapping.accessoryID)],
            "a healthy link must not be torn down to find out that it is healthy")
    }

    /// The probe's answer as the device actually sends it: an empty value on
    /// the readable characteristic, not a button signal.
    private func probeEcho(_ mapping: BLEPTTMapping) -> BLECentralEvent {
        .notified(
            id: mapping.accessoryID,
            signal: BLESignal(path: TestSignals.press.path, payload: Data()))
    }

    /// And a probe that answers costs nothing further: no rebuild, no downtime.
    func testAProbeThatAnswersLeavesTheLinkAlone() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        central.clearCalls()
        let echo = probeEcho(mapping)
        central.emit(echo)
        await waitUntil("answer processed") { self.controllerSaw(controller, echo) }
        await Task.yield()

        XCTAssertEqual(central.calls, [], "nothing was wrong, so nothing should happen")
    }

    /// Whether the controller has consumed this event yet — observable through
    /// `lastSignal`, which every arriving signal updates.
    private func controllerSaw(_ controller: BLEPTTController, _ event: BLECentralEvent) -> Bool {
        guard case .notified(_, let signal) = event else { return false }
        return controller.lastSignal == signal
    }

    /// A probe that fails is what buys a rebuild.
    func testAFailedProbeRebuildsTheLink() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        central.clearCalls()
        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))

        await waitUntil("rebuilt") {
            self.central.calls.contains(.disconnect(mapping.accessoryID))
        }
        // And the ordinary disconnection path takes it from there, so there is one
        // reconnection routine rather than two.
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        await waitUntil("reconnecting") {
            self.central.calls.contains(.connect(mapping.accessoryID))
        }
        XCTAssertEqual(controller.linkState, .reconnecting)
    }

    /// **Coalescing by state, not by clock.** A burst of route changes produces
    /// one check, because one is already in flight — nothing to tune wrongly.
    func testABurstOfRouteChangesCoalescesIntoOneCheck() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        for _ in 0..<5 { controller.audioRouteDidChange() }

        XCTAssertEqual(central.calls, [.probe(mapping.accessoryID)])
    }

    /// Once a check resolves, a later route change is free to ask again — the gate
    /// is in-flight state, not a dead period.
    func testAfterACheckResolvesAnotherRouteChangeMayAskAgain() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        let echo = probeEcho(mapping)
        central.emit(echo)
        await waitUntil("answer processed") { self.controllerSaw(controller, echo) }
        central.clearCalls()

        controller.audioRouteDidChange()

        XCTAssertEqual(central.calls, [.probe(mapping.accessoryID)])
    }

    /// **The teardown loop of 2026-08-22.** On a link already verified by real
    /// button data, a probe's answer was swallowed — the code that cancelled the
    /// deadline only ran on the unverified→verified transition — so the deadline
    /// fired one second after the link had answered and tore it down. Measured
    /// on device after every single over. The answer must cancel the deadline
    /// regardless of the verification state.
    func testAProbeAnswerOnAVerifiedLinkCancelsTheDeadline() async {
        let clock = TestClock()
        let gate = DelayGate()
        let (controller, mapping) = await makeConnectedController(
            clock: clock, neverFiringBackstop: gate)

        // Verify the link with the button's own data first — a release, which
        // cannot key the accessory.
        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.release))
        await waitUntil("verified") { controller.isButtonVerified }
        central.clearCalls()

        controller.audioRouteDidChange()
        let echo = probeEcho(mapping)
        central.emit(echo)
        await waitUntil("answer processed") { self.controllerSaw(controller, echo) }

        // Now let the deadline elapse. A cancelled deadline does nothing; the
        // 2026-08-22 bug had it rebuild the link that had just answered.
        gate.open()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(
            central.calls.contains(.disconnect(mapping.accessoryID)),
            "the probe was answered; the deadline must have been cancelled")
    }

    /// **The "Accessory ready" lie of 2026-08-22.** A probe's answer travels the
    /// read path, which the accessory keeps serving even while it suppresses the
    /// button's notifications in HFP call mode — so it must never verify the
    /// button. Only the button's own signals may.
    func testAProbeEchoDoesNotVerifyTheButton() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        let echo = probeEcho(mapping)
        central.emit(echo)
        await waitUntil("answer processed") { self.controllerSaw(controller, echo) }

        XCTAssertFalse(
            controller.isButtonVerified,
            "a read answer says the link is up, not that the button works")

        // The answer still resolves the check — the next route change may probe
        // again rather than being skipped as in-flight.
        central.clearCalls()
        controller.audioRouteDidChange()
        XCTAssertEqual(central.calls, [.probe(mapping.accessoryID)])
    }

    // MARK: - Escalation, driven by the probe's answer (BU-14)

    /// Walk a failed check through one rebuild, to the point where the new link
    /// has been probed.
    private func rebuildAfterFailedCheck(_ mapping: BLEPTTMapping) async {
        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))
        await waitUntil("rebuild started") {
            self.central.calls.contains(.disconnect(mapping.accessoryID))
        }
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        central.emit(.connected(id: mapping.accessoryID))
        central.clearCalls()
        central.emit(.subscribed(id: mapping.accessoryID, paths: [TestSignals.press.path]))
        await waitUntil("probed again") {
            self.central.calls.contains(.probe(mapping.accessoryID))
        }
    }

    /// **A rebuilt link is probed too**, and a probe that fails again escalates —
    /// immediately, with no waiting.
    func testARebuiltLinkIsProbedAndCanEscalate() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        await rebuildAfterFailedCheck(mapping)
        central.clearCalls()

        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))

        await waitUntil("escalated") {
            self.central.calls.contains(.disconnect(mapping.accessoryID))
        }
        _ = controller
    }

    /// It is a ladder, not a loop. Giving up leaves an honest "untested" and a
    /// Reconnect button, which beats retrying invisibly forever.
    func testEscalationGivesUpAfterTheBound() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        for _ in 0..<BLEPTTController.maximumRepairAttempts {
            await rebuildAfterFailedCheck(mapping)
        }
        central.clearCalls()
        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))
        await Task.yield()

        XCTAssertEqual(
            central.calls, [],
            "the ladder must stop at the bound rather than retry forever")
        XCTAssertFalse(controller.isButtonVerified, "and must not claim success")
    }

    /// **SF-2.** A rebuild disconnects, and a disconnection unkeys — so the
    /// session is asked again on every attempt, including one triggered by a probe
    /// failure while the operator was keying up on the on-screen button.
    func testARebuildIsDeclinedWhenTheSessionSaysItIsNotIdle() async {
        let clock = TestClock()
        var isIdle = true
        let (controller, mapping) = await makeConnectedController(
            clock: clock, isRebuildSafe: { isIdle })

        controller.audioRouteDidChange()
        central.clearCalls()

        isIdle = false
        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))
        await Task.yield()

        XCTAssertEqual(
            central.calls, [],
            "a rebuild must never disconnect while the operator is transmitting")
        _ = controller
    }

    /// The operator asking rebuilds directly, without a probe first: they have
    /// already decided the link is not working, which is better information than a
    /// read.
    func testTheOperatorsReconnectRebuildsWithoutProbingFirst() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.reconnectAccessory()

        XCTAssertEqual(central.calls, [.disconnect(mapping.accessoryID)])
    }

    /// **The trap the probe must not walk into.** A read's value arrives as a
    /// notification, and learn mode latches the first signal it sees — so a probe
    /// during learning would be recorded as the operator's press.
    func testNoProbeIsIssuedWhileLearning() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.relearnCurrentAccessory()
        central.clearCalls()
        controller.audioRouteDidChange()
        await Task.yield()

        XCTAssertFalse(
            central.calls.contains(.probe(mapping.accessoryID)),
            "a probe during learn mode would be latched as the operator's press")
    }

    // MARK: - The seam's contract, where the last bug actually lived

    /// **The regression, and the reason the earlier tests missed it.**
    ///
    /// `CoreBluetoothCentral` has no tests by construction — it needs a radio, so
    /// everything above it is exercised against ``FakeBLECentral`` (AU-5). That
    /// works only while the fake honours the same contract, and it did not: the
    /// fake's probe always "works", while the real device delivers `.subscribed`
    /// **eight times** per reconnect and the readable characteristic is not
    /// discovered until the third. The real central reported that as a probe
    /// failure, the controller rebuilt a link that was about to be fine, and the
    /// whole thing looped — measured 2026-08-22.
    ///
    /// The rule, now stated on the protocol and asserted here: **a probe that
    /// cannot run says nothing.** Only an attempted-and-failed read is evidence.
    func testAProbeThatCannotRunYetMustNotCauseARebuild() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        central.emit(.connected(id: mapping.accessoryID))
        central.clearCalls()

        // Discovery arrives service by service, as it does on the device. The
        // first subscription cannot be probed usefully; the central says nothing
        // about it, and that silence must not be read as a dead link.
        central.emit(.subscribed(id: mapping.accessoryID, paths: [TestSignals.press.path]))
        await Task.yield()
        central.emit(.subscribed(id: mapping.accessoryID, paths: [TestSignals.press.path]))
        await Task.yield()

        XCTAssertFalse(
            central.calls.contains(.disconnect(mapping.accessoryID)),
            "silence from a probe that could not run is not evidence of anything")
    }

    /// The device sends `.subscribed` once per service and repeats the whole
    /// round, eight times in all. That must produce **one** rebuild attempt, not
    /// eight — and it is the fake's failure to model this that hid the last bug.
    func testTheDevicesRepeatedSubscriptionsProduceOneAttempt() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        central.emit(.connected(id: mapping.accessoryID))
        central.clearCalls()

        for _ in 0..<8 {
            central.emit(.subscribed(id: mapping.accessoryID, paths: [TestSignals.press.path]))
            await Task.yield()
        }
        // One probe failure, once discovery really has finished, is one retry.
        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))
        await waitUntil("one retry") {
            self.central.calls.contains(.disconnect(mapping.accessoryID))
        }

        let disconnects = central.calls.filter { $0 == .disconnect(mapping.accessoryID) }
        XCTAssertEqual(
            disconnects.count, 1,
            "eight subscriptions must not become eight rebuilds")
    }
    // MARK: - A connection is not a working button (BU-14)

    /// The lesson of `BU-14` as an invariant: `.connected` proves nothing, so the
    /// link starts unverified and only arriving data changes that.
    func testAFreshLinkIsUnverifiedUntilSomethingArrives() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        XCTAssertFalse(
            controller.isButtonVerified,
            "a connection is not evidence that the button works")

        // A signal the mapping ignores does not count either: the accessory
        // serves other traffic even while the button's notifications are
        // suppressed, so only the button's own signals answer the question.
        let unrelated = BLECentralEvent.notified(
            id: mapping.accessoryID, signal: TestSignals.unrelated)
        central.emit(unrelated)
        await waitUntil("unrelated processed") { self.controllerSaw(controller, unrelated) }
        XCTAssertFalse(controller.isButtonVerified)

        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await waitUntil("verified") { controller.isButtonVerified }

        XCTAssertTrue(controller.isButtonVerified)
    }

    /// And a repair puts it back to unproven, because that is exactly what it is.
    func testARepairMakesTheLinkUnverifiedAgain() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)
        // A *release*, not a press: a press would key the accessory, and a
        // repair is rightly refused while the button holds the key.
        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.release))
        await waitUntil("verified") { controller.isButtonVerified }

        controller.reconnectAccessory()

        XCTAssertFalse(controller.isButtonVerified)
    }

    // MARK: - Nothing learned

    /// Constructing a `CBCentralManager` is what triggers the Bluetooth
    /// permission prompt. An operator who has never asked for an accessory must
    /// never be asked for Bluetooth, so a launch with nothing learned must not
    /// touch the central at all.
    func testALaunchWithNothingLearnedTouchesNothing() {
        let controller = makeController()

        controller.activateIfConfigured()

        XCTAssertEqual(central.calls, [])
        XCTAssertEqual(controller.linkState, .noAccessory)
    }

    func testALaunchWithALearnedAccessoryReconnectsIt() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()

        controller.activateIfConfigured()

        XCTAssertEqual(central.calls, [.connect(mapping.accessoryID)])
        XCTAssertEqual(controller.linkState, .connecting)
    }

    // MARK: - Learn mode (BLE-2, PT-3)

    func testLearningTheCommonFobShape() async {
        let controller = makeController()
        let accessory = BLEAccessory(id: UUID(), name: "PTT fob")

        controller.beginLearning(with: accessory)
        central.emit(.connected(id: accessory.id))
        await settle("subscribed") { controller.linkState == .connected }

        // Press, release, press, release: one characteristic, 01 down, 00 up.
        central.emit(.notified(id: accessory.id, signal: TestSignals.press))
        await settle("press seen") { controller.learner?.step == .awaitingRelease }
        central.emit(.notified(id: accessory.id, signal: TestSignals.release))
        await settle("release seen") { controller.learner?.step == .confirmingPress }
        central.emit(.notified(id: accessory.id, signal: TestSignals.press))
        await settle("confirming press") { controller.learner?.step == .confirmingRelease }
        central.emit(.notified(id: accessory.id, signal: TestSignals.release))
        await settle("learned") { controller.learner?.mapping != nil }

        controller.adoptLearnedMapping()

        XCTAssertEqual(controller.mapping?.press, TestSignals.press)
        XCTAssertEqual(controller.mapping?.release, TestSignals.release)
        XCTAssertEqual(store.savedMapping?.accessoryID, accessory.id)
        XCTAssertNil(controller.learner)
        XCTAssertTrue(
            controller.isButtonVerified,
            "the learn sequence was the button speaking — the link starts verified")
    }

    /// An accessory that only reports the button going down would key and never
    /// unkey. The learner must refuse it rather than store a mapping that keys
    /// forever.
    func testAnAccessoryWithNoReleaseEdgeIsRefused() async {
        let controller = makeController()
        let accessory = BLEAccessory(id: UUID(), name: "Broken fob")

        controller.beginLearning(with: accessory)
        central.emit(.connected(id: accessory.id))
        await settle("connected") { controller.linkState == .connected }
        central.emit(.notified(id: accessory.id, signal: TestSignals.press))
        await settle("press seen") { controller.learner?.step == .awaitingRelease }

        controller.nothingElseArrived()

        XCTAssertEqual(controller.learner?.problem, .noReleaseObserved)
        XCTAssertNil(controller.mapping)
        XCTAssertNil(store.savedMapping)
    }

    /// Cancelling learn mode with nothing already in use should not leave a
    /// connection open to an accessory that keys nothing — that is pure battery.
    func testCancellingLearnModeLetsGoOfAHalfLearnedAccessory() async {
        let controller = makeController()
        let accessory = BLEAccessory(id: UUID())
        controller.beginLearning(with: accessory)
        central.clearCalls()

        controller.cancelLearning()

        XCTAssertEqual(central.calls, [.disconnect(accessory.id)])
        XCTAssertNil(controller.learner)
        XCTAssertEqual(controller.linkState, .noAccessory)
    }

    // MARK: - Runtime (BLE-3)

    func testALearnedPressAndReleaseDriveTheSink() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await settle("connected") { controller.linkState == .connected }

        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await settle("press delivered") { !self.sink.calls.isEmpty }
        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.release))
        await settle("release delivered") { self.sink.calls.count >= 2 }

        XCTAssertEqual(
            sink.calls,
            [.pressed(.accessory), .released(.accessory, .accessoryReleased)])
    }

    /// A device that repeats its press payload while the button is held must
    /// produce one press edge, not fifty a second.
    func testARepeatedPressPayloadIsOneEdge() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await settle("connected") { controller.linkState == .connected }

        for _ in 0..<5 {
            central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        }
        await settle("press delivered") { controller.isAccessoryKeyed }

        XCTAssertEqual(sink.calls, [.pressed(.accessory)])
    }

    /// A battery level or a heartbeat on some other characteristic must key
    /// nothing.
    func testAnUnrelatedNotificationChangesNothing() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await settle("connected") { controller.linkState == .connected }

        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.unrelated))
        await settle("the signal was seen") { controller.lastSignal == TestSignals.unrelated }

        XCTAssertEqual(sink.calls, [])
        XCTAssertFalse(controller.isAccessoryKeyed)
    }

    // MARK: - SF-2

    func testADisconnectionStopsTransmissionAndReconnects() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await settle("connected") { controller.linkState == .connected }
        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await settle("keyed") { controller.isAccessoryKeyed }
        sink.clear()
        central.clearCalls()

        central.emit(.disconnected(id: mapping.accessoryID, reason: "out of range"))
        await settle("SF-2 fired") { !self.sink.calls.isEmpty }

        XCTAssertEqual(sink.calls, [.accessoryLinkLost])
        XCTAssertFalse(controller.isAccessoryKeyed)
        XCTAssertEqual(controller.linkState, .reconnecting)
        XCTAssertEqual(central.calls, [.connect(mapping.accessoryID)])
    }

    /// Bluetooth being switched off is not a disconnection event, but it means
    /// the accessory is certainly no longer holding the key. SF-2 does not care
    /// which layer dropped the link.
    func testBluetoothBeingSwitchedOffDropsTheKey() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await settle("connected") { controller.linkState == .connected }
        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await settle("keyed") { controller.isAccessoryKeyed }
        sink.clear()

        central.emit(.availabilityChanged(.poweredOff))
        await settle("the key was dropped") { !self.sink.calls.isEmpty }

        XCTAssertEqual(sink.calls, [.accessoryLinkLost])
        XCTAssertFalse(controller.isAccessoryKeyed)
    }

    /// A reconnect starts from "button up" whatever the accessory was doing when
    /// the link dropped.
    func testAReconnectDoesNotAssumeTheButtonIsStillHeld() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await settle("connected") { controller.linkState == .connected }
        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await settle("keyed") { controller.isAccessoryKeyed }

        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        await settle("reconnecting") { controller.linkState == .reconnecting }
        central.emit(.connected(id: mapping.accessoryID))
        await settle("reconnected") { controller.linkState == .connected }

        XCTAssertFalse(controller.isAccessoryKeyed)
    }

    /// Forgetting an accessory that happens to be holding the key must let go of
    /// it, not leave the radio keyed with nothing able to release it.
    func testForgettingAKeyedAccessoryReleasesIt() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await settle("connected") { controller.linkState == .connected }
        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await settle("keyed") { controller.isAccessoryKeyed }
        sink.clear()

        controller.forgetAccessory()

        XCTAssertEqual(sink.calls, [.released(.accessory, .accessoryReleased)])
        XCTAssertNil(controller.mapping)
        XCTAssertNil(store.savedMapping)
        XCTAssertFalse(controller.isAccessoryKeyed)
    }

    // MARK: - Connection failure

    /// `didFailToConnect` without a cap is a busy loop that holds the radio
    /// awake. After the cap the operator gets a retry button instead.
    func testRepeatedConnectionFailuresGiveUpAndSaySo() async {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = makeController()
        controller.activateIfConfigured()

        for _ in 0..<BLEPTTController.maximumConsecutiveFailures {
            central.emit(.connectionFailed(id: mapping.accessoryID, reason: "nope"))
        }
        await settle("gave up") {
            if case .failed = controller.linkState { return true }
            return false
        }

        controller.retryConnection()
        XCTAssertEqual(controller.linkState, .connecting)
    }

    // MARK: - Stored mappings are not trusted

    /// A mapping whose two signals match would key and never unkey. The
    /// initialiser refuses to build one, and the store refuses to return one, so
    /// a hand-edited plist or an older build cannot produce the one shape that
    /// must never reach the runtime matcher.
    func testAnIndistinguishableMappingCannotExist() {
        let signal = TestSignals.press
        XCTAssertNil(
            BLEPTTMapping(
                accessoryID: UUID(), accessoryName: nil, press: signal, release: signal))
    }
}


/// A delay the test controls, so an escalation ladder can be stepped rather than
/// raced. Cancelled waiters still resume — a `CheckedContinuation` is not
/// cancellable — and bail on their own `Task.isCancelled` check.
private final class DelayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// How many waits are suspended right now.
    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }

    var wait: @Sendable () async -> Void {
        { [self] in
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    /// Let everything through, now and in future — race-free, unlike releasing
    /// only what happens to be suspended at the time.
    func open() {
        lock.lock()
        isOpen = true
        let resuming = waiting
        waiting = []
        lock.unlock()
        resuming.forEach { $0.resume() }
    }
}
