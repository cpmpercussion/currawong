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
            // *event-driven* path, and a backstop that fired would mask it.
            stuckProbeBackstop: (neverFiringBackstop ?? DelayGate()).wait)
        controller.sink = sink
        controller.isRebuildSafe = isRebuildSafe
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await waitUntil("connected") { controller.linkState == .connected }
        central.clearCalls()
        return (controller, mapping)
    }

    /// **The repair itself**, and it happens *now*: an earlier version waited
    /// 1.5 s for the route to settle first, which the operator felt as a button
    /// that stayed dead.
    func testARouteChangeWhileIdleRebuildsTheLinkImmediately() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()

        XCTAssertEqual(
            central.calls, [.disconnect(mapping.accessoryID)],
            "the repair must not wait for anything")
        // And the ordinary disconnection path takes it from there, so there is
        // one reconnection routine rather than two.
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        await waitUntil("reconnecting") {
            self.central.calls.contains(.connect(mapping.accessoryID))
        }
        XCTAssertEqual(controller.linkState, .reconnecting)
    }

    /// **A burst produces one repair.** `BU-17` has route changes flapping about
    /// once a second, and rebuilding on each would thrash the link.
    func testABurstOfRouteChangesCoalescesIntoOneRebuild() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        for _ in 0..<5 { controller.audioRouteDidChange() }

        XCTAssertEqual(central.calls, [.disconnect(mapping.accessoryID)])
    }

    /// The operator has better information than a timer, so their button ignores
    /// the cooldown.
    func testTheOperatorsReconnectIgnoresTheCooldown() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        central.clearCalls()
        controller.reconnectAccessory()

        XCTAssertEqual(central.calls, [.disconnect(mapping.accessoryID)])
    }

    /// **SF-2's own hazard, guarded.** The accessory holding the key means the
    /// operator is on air by way of this button, and a repair disconnects, and a
    /// disconnection unkeys. `RadioSession` is the outer guard; the controller
    /// refuses this one for itself too.
    func testARouteChangeIsIgnoredWhileTheAccessoryIsKeyed() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await waitUntil("keyed") { controller.isAccessoryKeyed }
        central.clearCalls()

        controller.audioRouteDidChange()

        XCTAssertEqual(
            central.calls, [],
            "a repair must never disconnect a link that is holding the key")
    }

    /// Learn mode is a sequence the operator is in the middle of; rebuilding the
    /// link would restart it with no explanation.
    func testARouteChangeIsIgnoredDuringLearnMode() async {
        let clock = TestClock()
        let (controller, _) = await makeConnectedController(clock: clock)

        controller.relearnCurrentAccessory()
        central.clearCalls()
        controller.audioRouteDidChange()

        XCTAssertEqual(central.calls, [])
    }

    /// No accessory in use means no link to repair, and no reason to touch the
    /// central at all.
    func testARouteChangeWithNothingLearnedTouchesNothing() {
        let clock = TestClock()
        let controller = BLEPTTController(
            makeCentral: { [central] in central! },
            store: store,
            retryDelay: {},
            now: { clock.now })

        controller.audioRouteDidChange()

        XCTAssertEqual(central.calls, [])
    }


    // MARK: - Escalation, driven by the probe's answer (BU-14)

    /// Walk a rebuild to the point where it has probed.
    private func rebuildAndProbe(
        _ controller: BLEPTTController, _ mapping: BLEPTTMapping
    ) async {
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        central.emit(.connected(id: mapping.accessoryID))
        central.emit(.subscribed(id: mapping.accessoryID, paths: [TestSignals.press.path]))
        await waitUntil("probed") { self.central.calls.contains(.probe(mapping.accessoryID)) }
    }

    /// **A rebuild whose probe fails is retried at once**, with no waiting.
    ///
    /// The previous design waited three seconds to see whether a notification
    /// turned up, which measured how recently the operator pressed the button —
    /// normal silence read as a dead link. A read either answers or fails, and
    /// both arrive on their own.
    func testARebuildWhoseProbeFailsIsRetriedImmediately() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        await rebuildAndProbe(controller, mapping)
        central.clearCalls()

        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))

        await waitUntil("retried") {
            self.central.calls.contains(.disconnect(mapping.accessoryID))
        }
    }

    /// **A probe that answers ends the ladder**, with no operator involvement —
    /// which is what makes the ladder mean anything.
    func testAProbeThatAnswersEndsTheLadder() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        await rebuildAndProbe(controller, mapping)
        central.clearCalls()

        // The read comes back — empty, because the question is whether bytes
        // flow, not what they say.
        central.emit(
            .notified(
                id: mapping.accessoryID,
                signal: BLESignal(path: TestSignals.press.path, payload: Data())))
        await waitUntil("verified") { controller.isButtonVerified }
        await Task.yield()

        XCTAssertEqual(central.calls, [], "a proven link must not be rebuilt again")
    }

    /// It is a ladder, not a loop. Giving up leaves an honest "untested" and a
    /// Reconnect button, which beats retrying invisibly forever.
    func testEscalationGivesUpAfterTheBound() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        for _ in 0..<BLEPTTController.maximumRepairAttempts {
            await rebuildAndProbe(controller, mapping)
            central.clearCalls()
            central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))
            await Task.yield()
        }

        XCTAssertEqual(
            central.calls, [],
            "the ladder must stop at the bound rather than retry forever")
        XCTAssertFalse(controller.isButtonVerified, "and must not claim success")
    }

    /// **Coalescing by state, not by clock.** A burst of route changes produces
    /// one rebuild because one is already in flight — no cooldown, and so nothing
    /// to tune wrongly.
    func testABurstCoalescesWhileARebuildIsInFlight() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        for _ in 0..<5 { controller.audioRouteDidChange() }

        XCTAssertEqual(central.calls, [.disconnect(mapping.accessoryID)])
    }

    /// And once the rebuild has resolved, a later route change is free to repair
    /// again — the gate is in-flight state, not a dead period.
    func testAfterAProbeResolvesAnotherRouteChangeMayRepair() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        await rebuildAndProbe(controller, mapping)
        central.emit(
            .notified(
                id: mapping.accessoryID,
                signal: BLESignal(path: TestSignals.press.path, payload: Data())))
        await waitUntil("verified") { controller.isButtonVerified }
        central.clearCalls()

        controller.audioRouteDidChange()

        XCTAssertEqual(central.calls, [.disconnect(mapping.accessoryID)])
    }

    /// **SF-2.** A rebuild disconnects, and a disconnection unkeys — so the
    /// session is asked again on every attempt, including one the controller
    /// triggered itself from a probe failure.
    func testARetryIsDeclinedWhenTheSessionSaysItIsNotIdle() async {
        let clock = TestClock()
        var isIdle = true
        let (controller, mapping) = await makeConnectedController(
            clock: clock, isRebuildSafe: { isIdle })

        controller.audioRouteDidChange()
        await rebuildAndProbe(controller, mapping)
        central.clearCalls()

        // The operator keys up on the on-screen button, which this controller
        // cannot see, before the probe's answer arrives.
        isIdle = false
        central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))
        await Task.yield()

        XCTAssertEqual(
            central.calls, [],
            "a rebuild must never disconnect while the operator is transmitting")
    }

    /// The operator asking gets a fresh budget, and clears any wedged in-flight
    /// state — a person pressing a button is new information.
    func testTheOperatorsReconnectRestoresTheBudget() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        await rebuildAndProbe(controller, mapping)
        for _ in 0..<BLEPTTController.maximumRepairAttempts {
            central.emit(.probeFailed(id: mapping.accessoryID, reason: "test"))
            await Task.yield()
        }
        central.clearCalls()

        controller.reconnectAccessory()

        XCTAssertEqual(central.calls, [.disconnect(mapping.accessoryID)])
    }

    // MARK: - The liveness probe (BU-14)

    /// A rebuilt link is asked to prove itself, because neither `.connected` nor a
    /// successful subscribe is evidence — both were observed reporting success
    /// over a dead link.
    func testARebuiltLinkIsProbed() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        await rebuildAndProbe(controller, mapping)
        _ = controller
    }

    /// **The trap the probe must not walk into.** A read's value arrives as a
    /// notification, and learn mode latches the first signal it sees — so a probe
    /// during learning would be recorded as the operator's press.
    func testNoProbeIsIssuedWhileLearning() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        controller.audioRouteDidChange()
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        central.emit(.connected(id: mapping.accessoryID))
        controller.relearnCurrentAccessory()
        central.clearCalls()
        central.emit(.subscribed(id: mapping.accessoryID, paths: [TestSignals.press.path]))
        await Task.yield()

        XCTAssertFalse(
            central.calls.contains(.probe(mapping.accessoryID)),
            "a probe during learn mode would be latched as the operator's press")
    }

    /// No probe on an ordinary connection: nothing was being repaired, and a read
    /// costs the accessory something.
    func testNoProbeOnAnOrdinaryConnection() async {
        let clock = TestClock()
        let (controller, mapping) = await makeConnectedController(clock: clock)

        central.clearCalls()
        central.emit(.subscribed(id: mapping.accessoryID, paths: [TestSignals.press.path]))
        await Task.yield()

        XCTAssertFalse(central.calls.contains(.probe(mapping.accessoryID)))
        _ = controller
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

        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await waitUntil("verified") { controller.isButtonVerified }

        // Anything at all counts, including a signal the mapping ignores: the
        // question is whether the link delivers, not what it delivered.
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
