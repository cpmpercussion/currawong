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

    /// The controller with a gate-controlled settle delay, and a mapping already
    /// stored and connected — the state a repair applies to.
    private func makeConnectedController(
        gate: DelayGate
    ) async -> (BLEPTTController, BLEPTTMapping) {
        let mapping = TestSignals.mapping()
        store = InMemoryPTTSettingsStore(mapping: mapping)
        let controller = BLEPTTController(
            makeCentral: { [central] in central! },
            store: store,
            retryDelay: {},
            routeSettleDelay: gate.wait)
        controller.sink = sink
        controller.activateIfConfigured()
        central.emit(.connected(id: mapping.accessoryID))
        await waitUntil("connected") { controller.linkState == .connected }
        central.clearCalls()
        return (controller, mapping)
    }

    /// **The repair itself.** A route change while idle rebuilds the link,
    /// because the subscription has probably stopped delivering and nothing will
    /// ever say so.
    func testARouteChangeWhileIdleRebuildsTheLink() async {
        let gate = DelayGate()
        let (controller, mapping) = await makeConnectedController(gate: gate)

        controller.audioRouteDidChange()
        gate.open()

        await waitUntil("disconnected for repair") {
            self.central.calls.contains(.disconnect(mapping.accessoryID))
        }
        // And the ordinary disconnection path takes it from there, so there is
        // one reconnection routine rather than two.
        central.emit(.disconnected(id: mapping.accessoryID, reason: nil))
        await waitUntil("reconnecting") {
            self.central.calls.contains(.connect(mapping.accessoryID))
        }
        XCTAssertEqual(controller.linkState, .reconnecting)
    }

    /// **A burst produces one reconnect, not one per change.** `BU-17` has route
    /// changes flapping about once a second; repairing on each would thrash the
    /// link it is trying to fix.
    func testABurstOfRouteChangesCoalescesIntoOneRebuild() async {
        let gate = DelayGate()
        let (controller, mapping) = await makeConnectedController(gate: gate)

        for _ in 0..<5 { controller.audioRouteDidChange() }
        // All five must be suspended before any is released: the guarantee under
        // test is that the later ones cancel the earlier ones, which cannot
        // happen if the earlier ones have already run.
        await waitUntil("all five waiting") { gate.waiterCount == 5 }
        gate.releaseAll()

        await waitUntil("disconnected once") {
            self.central.calls.contains(.disconnect(mapping.accessoryID))
        }
        let disconnects = central.calls.filter { $0 == .disconnect(mapping.accessoryID) }
        XCTAssertEqual(disconnects.count, 1, "a burst must coalesce into one repair")
    }

    /// **SF-2's own hazard, guarded.** The accessory holding the key means the
    /// operator is on air by way of this button; a repair would disconnect, and a
    /// disconnection unkeys. `RadioSession` is the outer guard, but the
    /// controller refuses this one for itself too.
    func testARouteChangeIsIgnoredWhileTheAccessoryIsKeyed() async {
        let gate = DelayGate()
        let (controller, mapping) = await makeConnectedController(gate: gate)

        central.emit(.notified(id: mapping.accessoryID, signal: TestSignals.press))
        await waitUntil("keyed") { controller.isAccessoryKeyed }

        controller.audioRouteDidChange()
        gate.open()
        await Task.yield()

        XCTAssertFalse(
            central.calls.contains(.disconnect(mapping.accessoryID)),
            "a repair must never disconnect a link that is holding the key")
    }

    /// Learn mode is a sequence the operator is in the middle of. Rebuilding the
    /// link under them would restart it with no explanation.
    func testARouteChangeIsIgnoredDuringLearnMode() async {
        let gate = DelayGate()
        let (controller, mapping) = await makeConnectedController(gate: gate)

        controller.relearnCurrentAccessory()
        controller.audioRouteDidChange()
        gate.open()
        await Task.yield()

        XCTAssertFalse(central.calls.contains(.disconnect(mapping.accessoryID)))
    }

    /// No accessory in use means no link to repair — and, as with launch, no
    /// reason to touch the central at all.
    func testARouteChangeWithNothingLearnedTouchesNothing() async {
        let gate = DelayGate()
        let controller = BLEPTTController(
            makeCentral: { [central] in central! },
            store: store,
            retryDelay: {},
            routeSettleDelay: gate.wait)

        controller.audioRouteDidChange()
        gate.open()
        await Task.yield()

        XCTAssertEqual(central.calls, [])
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

/// A `routeSettleDelay` the test controls, so coalescing can be asserted rather
/// than raced.
///
/// An immediate delay would not test anything: the guarantee is that a *burst*
/// of route changes produces one reconnect, and that only holds while the
/// earlier waits are still suspended when the later one cancels them. Cancelled
/// waiters still resume here — a `CheckedContinuation` is not cancellable — and
/// are expected to bail on their own `Task.isCancelled` check.
private final class DelayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private var isOpen = false

    /// How many waits are currently suspended. A test that means to hold several
    /// at once must wait for them to arrive: releasing before the task under test
    /// has reached its `await` releases nothing, and it then hangs.
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

    /// Let everything through, now and in future. Race-free: a wait that has not
    /// started yet returns immediately rather than hanging.
    func open() {
        lock.lock()
        isOpen = true
        let resuming = waiting
        waiting = []
        lock.unlock()
        resuming.forEach { $0.resume() }
    }

    /// Release only what is suspended right now, leaving the gate shut. For the
    /// coalescing test, which must hold a burst and then let it go.
    func releaseAll() {
        lock.lock()
        let resuming = waiting
        waiting = []
        lock.unlock()
        resuming.forEach { $0.resume() }
    }
}
