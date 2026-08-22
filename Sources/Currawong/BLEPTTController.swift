// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

/// **BLE-1, BLE-2 and BLE-3.** Everything the app knows about Bluetooth PTT,
/// with no CoreBluetooth in sight.
///
/// Scanning, connecting, learn mode, the runtime mapping, reconnection and the
/// SF-2 drop all live here, above the ``BLECentral`` seam, which is what makes
/// them testable: `BLEPTTControllerTests` drives every one of those paths from
/// `FakeBLECentral` with no radio, no accessory and no permission prompt.
///
/// ## SF-2
///
/// One rule, stated once, in ``handle(_:)``: **the first thing done with a
/// disconnection is to stop transmitting.** Not "if the accessory was what
/// keyed us" — unconditionally, synchronously, before the reconnection logic,
/// before the published state changes, before anything is awaited. An accessory
/// that goes out of range while the operator is talking is the failure this
/// requirement exists for, and the reconnect that follows must never be able to
/// delay the unkey.
///
/// ## No press survives a reconnection
///
/// ``isAccessoryKeyed`` is cleared on every disconnection, so a reconnect
/// starts from "button up" no matter what the accessory was doing when the link
/// dropped. A device that re-sends its state on connect will send the press
/// payload and key the radio — deliberately, because that is a genuine press
/// edge arriving on a live link — but nothing in this class *assumes* a press
/// across the gap.
@MainActor
final class BLEPTTController: ObservableObject {

    // MARK: - Types

    /// What to tell the operator about the accessory link. The states an
    /// indicator has different words for, not a mirror of CoreBluetooth's.
    enum LinkState: Equatable {
        /// Nothing has been learned; Bluetooth PTT is not in use.
        case noAccessory
        /// Bluetooth itself is unusable — off, unauthorised, or absent.
        case unavailable(String)
        /// Looking for accessories, during pairing.
        case scanning
        case connecting
        case connected
        /// The link dropped and is being re-established. Transmission has
        /// already stopped (SF-2).
        case reconnecting
        /// Reconnection gave up. The operator can retry.
        case failed(String)

        var isConnected: Bool { self == .connected }

        var label: String {
            switch self {
            case .noAccessory: return "No accessory"
            case .unavailable(let why): return why
            case .scanning: return "Searching…"
            case .connecting: return "Connecting…"
            case .connected: return "Accessory connected"
            case .reconnecting: return "Accessory lost — reconnecting…"
            case .failed(let why): return why
            }
        }
    }

    /// How many failed connection attempts in a row before the controller stops
    /// trying and puts a "Try again" button on screen.
    ///
    /// Retrying is not free — it holds the radio awake — and a `didFailToConnect`
    /// is unusual: CoreBluetooth's `connect` has no timeout and simply pends
    /// until the accessory reappears, which is the behaviour that covers "left
    /// it in the car". This bound is for the case where connecting fails
    /// outright and instantly, which without a cap is a busy loop.
    static let maximumConsecutiveFailures = 5

    // MARK: - Published state

    @Published private(set) var linkState: LinkState = .noAccessory {
        didSet {
            guard oldValue != linkState else { return }
            Diagnostics.route("accessory link \(oldValue) -> \(linkState)")
        }
    }
    @Published private(set) var availability: BLECentralAvailability = .unknown

    /// Accessories seen while scanning, newest RSSI wins. Not a support list —
    /// it is whatever is advertising nearby (PT-3).
    @Published private(set) var discovered: [BLEAccessory] = []

    /// The learned mapping, if there is one.
    @Published private(set) var mapping: BLEPTTMapping?

    /// Learn mode's state, or `nil` when not learning.
    @Published private(set) var learner: PTTLearner?

    /// Whether the accessory's button is currently held, as far as the mapping
    /// can tell. Drives the UI and stops a repeated press payload producing a
    /// second press edge.
    @Published private(set) var isAccessoryKeyed = false

    /// The last notification seen from the connected accessory, whether or not
    /// it matched the mapping. Diagnostic: an operator whose accessory has
    /// stopped working can see whether anything is arriving at all.
    @Published private(set) var lastSignal: BLESignal?

    /// Characteristics currently subscribed to. Diagnostic only — the mapping
    /// is what matters — but "subscribed to seven characteristics and none of
    /// them said anything" is a useful thing for an operator to be able to see.
    @Published private(set) var subscribedPaths: [BLECharacteristicPath] = []

    /// Why the link last went away, when the central said.
    @Published private(set) var lastDisconnectReason: String?

    // MARK: - Dependencies

    /// Where press and release edges go. Weak: the session outlives this
    /// controller in the composition root, and a strong reference here would
    /// make the pair immortal.
    weak var sink: PTTSink?

    private let makeCentral: () -> BLECentral
    private let store: PTTSettingsStore

    /// Injected so a test does not wait real seconds between retries.
    private let retryDelay: @Sendable () async -> Void

    // MARK: - Private state

    private var central: BLECentral?
    private var eventTask: Task<Void, Never>?

    /// The accessory the controller wants connected — the learned one, or the
    /// one being learned. `nil` means "connect nothing".
    private var wantedAccessory: UUID?

    private var consecutiveFailures = 0
    private var isScanning = false

    // MARK: - Init

    init(
        makeCentral: @escaping () -> BLECentral = { CoreBluetoothCentral() },
        store: PTTSettingsStore = UserDefaultsPTTSettingsStore(),
        retryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    ) {
        self.makeCentral = makeCentral
        self.store = store
        self.retryDelay = retryDelay
        self.mapping = store.loadMapping()
    }

    deinit {
        eventTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Brings the Bluetooth stack up and reconnects the learned accessory, if
    /// there is one.
    ///
    /// **Does nothing when nothing has been learned.** Constructing a
    /// `CBCentralManager` is what triggers the Bluetooth permission prompt, and
    /// an operator who has never asked for an accessory should never be asked
    /// for Bluetooth. Called at launch by the composition root.
    func activateIfConfigured() {
        guard mapping != nil else { return }
        activate()
    }

    /// Brings the Bluetooth stack up unconditionally. Called by the accessory
    /// screen, where the operator has just said they want an accessory.
    /// Idempotent.
    func activate() {
        if central == nil {
            let central = makeCentral()
            self.central = central
            availability = central.availability
            let events = central.events
            eventTask = Task { @MainActor [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
        }
        if let mapping, wantedAccessory == nil {
            wantedAccessory = mapping.accessoryID
            connectWanted()
        }
    }

    // MARK: - Scanning (BLE-1)

    func startScanning() {
        activate()
        discovered = []
        isScanning = true
        central?.startScan()
        if case .connected = linkState {} else { linkState = .scanning }
    }

    func stopScanning() {
        isScanning = false
        central?.stopScan()
        guard linkState == .scanning else { return }
        linkState = wantedAccessory == nil ? .noAccessory : .connecting
    }

    /// The operator asked to try the connection again after it gave up.
    func retryConnection() {
        consecutiveFailures = 0
        activate()
        connectWanted()
    }

    // MARK: - Learn mode (BLE-2, PT-3)

    /// Connect to `accessory`, subscribe to everything it notifies on, and
    /// start recording. The mapping in force, if any, is left alone until a new
    /// one is learned, so a failed attempt does not cost the operator a working
    /// accessory.
    func beginLearning(with accessory: BLEAccessory) {
        activate()
        stopScanning()
        learner = PTTLearner(accessoryID: accessory.id, accessoryName: accessory.name)
        wantedAccessory = accessory.id
        consecutiveFailures = 0
        linkState = .connecting
        central?.connect(accessory.id)
    }

    /// Start again with the same accessory — the "that wasn't it, let me try
    /// once more" button.
    func restartLearning() {
        guard let learner else { return }
        self.learner = PTTLearner(
            accessoryID: learner.accessoryID, accessoryName: learner.accessoryName)
        central?.subscribeToAllNotifyingCharacteristics(learner.accessoryID)
    }

    /// Re-learn the accessory already in use.
    func relearnCurrentAccessory() {
        guard let mapping else { return }
        activate()
        learner = PTTLearner(
            accessoryID: mapping.accessoryID, accessoryName: mapping.accessoryName)
        wantedAccessory = mapping.accessoryID
        if linkState.isConnected {
            central?.subscribeToAllNotifyingCharacteristics(mapping.accessoryID)
        } else {
            linkState = .connecting
            central?.connect(mapping.accessoryID)
        }
    }

    /// The operator says they pressed and released and nothing new appeared.
    /// The only way to resolve an accessory whose two edges look the same.
    func nothingElseArrived() {
        learner?.nothingElseArrived()
    }

    /// Abandon learn mode without changing anything.
    ///
    /// If there was already a working mapping, it stays and its accessory stays
    /// connected. If there was not, the half-learned accessory is let go of —
    /// holding a connection to a device that keys nothing is pure battery.
    func cancelLearning() {
        learner = nil
        guard mapping == nil else {
            wantedAccessory = mapping?.accessoryID
            return
        }
        if let id = wantedAccessory { central?.disconnect(id) }
        wantedAccessory = nil
        linkState = idleLinkState
    }

    /// What the link state is when the app wants no accessory connected:
    /// nothing to say, unless Bluetooth itself is the reason nothing is going
    /// to work, in which case say that instead.
    private var idleLinkState: LinkState {
        switch availability {
        case .poweredOn, .unknown: return .noAccessory
        case .poweredOff, .unauthorised, .unsupported:
            return .unavailable(availability.problem ?? "Bluetooth unavailable")
        }
    }

    /// Keep what was just learned. Persists it and switches the runtime over.
    func adoptLearnedMapping() {
        guard let learned = learner?.mapping, learned.isUsable else { return }
        mapping = learned
        store.saveMapping(learned)
        learner = nil
        isAccessoryKeyed = false
        wantedAccessory = learned.accessoryID
        if !linkState.isConnected { connectWanted() }
    }

    /// **Discard the mapping.** The accessory stops keying the radio
    /// immediately, the link is dropped, and nothing is left on disk.
    func forgetAccessory() {
        // Fail safe: if the accessory happened to be holding the key when the
        // operator hit "forget", let go of it.
        if isAccessoryKeyed {
            isAccessoryKeyed = false
            sink?.pttReleased(from: .accessory, reason: .accessoryReleased)
        }
        if let id = wantedAccessory { central?.disconnect(id) }
        wantedAccessory = nil
        mapping = nil
        learner = nil
        store.saveMapping(nil)
        linkState = idleLinkState
    }

    // MARK: - Events

    private func handle(_ event: BLECentralEvent) {
        switch event {

        case .availabilityChanged(let availability):
            self.availability = availability
            if availability != .poweredOn, availability != .unknown {
                // Bluetooth going away is not itself a disconnection event, but
                // it certainly means the accessory is no longer holding the key,
                // and SF-2 does not care which layer dropped the link.
                dropAccessoryKey()
                linkState = idleLinkState
            } else if !linkState.isConnected {
                if isScanning {
                    central?.startScan()
                    linkState = .scanning
                } else if wantedAccessory != nil {
                    connectWanted()
                }
            }

        case .discovered(let accessory):
            guard isScanning else { return }
            if let index = discovered.firstIndex(where: { $0.id == accessory.id }) {
                discovered[index] = accessory
            } else {
                discovered.append(accessory)
            }

        case .connected(let id):
            guard id == wantedAccessory else { return }
            consecutiveFailures = 0
            // A reconnect starts from "button up". Whatever the accessory was
            // doing when the link dropped, the app does not assume it.
            isAccessoryKeyed = false
            linkState = .connected
            central?.subscribeToAllNotifyingCharacteristics(id)

        case .connectionFailed(let id, let reason):
            guard id == wantedAccessory else { return }
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maximumConsecutiveFailures {
                linkState = .failed(
                    reason.map { "Could not connect: \($0)" }
                        ?? "Could not connect to the accessory.")
            } else {
                linkState = .reconnecting
                scheduleReconnect(id)
            }

        case .disconnected(let id, let reason):
            // ─── SF-2 ───────────────────────────────────────────────────────
            // First, before anything else in this method and before anything
            // asynchronous: stop transmitting. Unconditional, because a
            // microphone left open by a dropped accessory is the exact failure
            // the safety requirements exist to prevent.
            sink?.accessoryLinkLost()
            isAccessoryKeyed = false
            // ────────────────────────────────────────────────────────────────

            Diagnostics.route(
                "accessory DISCONNECTED: \(reason ?? "no reason given")")
            guard id == wantedAccessory else { return }
            if reason != nil { lastDisconnectReason = reason }
            linkState = .reconnecting
            central?.connect(id)

        case .subscribed(let id, let paths):
            guard id == wantedAccessory else { return }
            subscribedPaths = paths
            // "Subscribed to seven characteristics and none of them said
            // anything" is a different fault from "subscribe never completed",
            // and on 2026-08-22 there was no way to tell them apart while a
            // re-learn sat there receiving nothing.
            Diagnostics.route(
                "accessory subscribed to \(paths.count): "
                    + paths.map { "\($0.service)/\($0.characteristic)" }
                        .joined(separator: " "))

        case .notified(let id, let signal):
            guard id == wantedAccessory else { return }
            lastSignal = signal
            Diagnostics.route(
                "accessory notify \(signal.path.service)/\(signal.path.characteristic) "
                    + "= \(signal.payloadDescription) "
                    + "(\(learner != nil ? "learning" : "runtime"))")
            if learner != nil {
                learner?.observe(signal)
                if let step = learner?.step {
                    Diagnostics.route("learn step -> \(step)")
                }
            } else {
                applyRuntimeMapping(signal)
            }
        }
    }

    // MARK: - Runtime mapping (BLE-3)

    private func applyRuntimeMapping(_ signal: BLESignal) {
        guard let mapping, mapping.isUsable else { return }

        if signal == mapping.press {
            // Edge, not level: a device that repeats its press payload while
            // held must not produce a press edge fifty times a second.
            guard !isAccessoryKeyed else { return }
            isAccessoryKeyed = true
            Diagnostics.keying("accessory PRESS edge")
            sink?.pttPressed(from: .accessory)
        } else if signal == mapping.release {
            // Deliberately *not* guarded on `isAccessoryKeyed`. A release that
            // arrives when the app thinks the button is already up can only
            // ever stop transmission, and `endTransmit` is idempotent; a
            // release that is swallowed can leave a microphone open.
            let wasKeyed = isAccessoryKeyed
            isAccessoryKeyed = false
            // Logged with what it found, because the Q2L sends its release
            // twice ~1 ms apart: a second line saying `wasKeyed=false` is the
            // duplicate being absorbed, not a fault.
            Diagnostics.keying("accessory RELEASE edge (wasKeyed=\(wasKeyed))")
            sink?.pttReleased(from: .accessory, reason: .accessoryReleased)
        }
        // Anything else — a battery level, a heartbeat, the other button on the
        // fob — changes nothing at all.
    }

    private func dropAccessoryKey() {
        guard isAccessoryKeyed else { return }
        isAccessoryKeyed = false
        sink?.accessoryLinkLost()
    }

    // MARK: - Connecting

    private func connectWanted() {
        guard let id = wantedAccessory else { return }
        linkState = .connecting
        central?.connect(id)
    }

    private func scheduleReconnect(_ id: UUID) {
        let delay = retryDelay
        Task { @MainActor [weak self] in
            await delay()
            guard let self, self.wantedAccessory == id else { return }
            self.central?.connect(id)
        }
    }
}
