// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

/// Bluetooth PTT (BLE-1, BLE-2, BLE-3): scanning, learn mode, the runtime
/// mapping, reconnection and the SF-2 drop, above the ``BLECentral`` seam so
/// tests can drive all of it from `FakeBLECentral`.
///
/// **SF-2:** the first thing ``handle(_:)`` does with a disconnection is stop
/// transmitting — unconditionally, synchronously, before anything else. No
/// press survives a reconnection: ``isAccessoryKeyed`` is cleared, and only a
/// press edge arriving on the new link keys the radio.
@MainActor
final class BLEPTTController: ObservableObject {

    // MARK: - Types

    /// The accessory link, in the states an indicator has words for.
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

    /// Failed connection attempts in a row before giving up and offering "Try
    /// again". CoreBluetooth's `connect` pends rather than timing out, so a
    /// failure is instant, and uncapped retries would be a busy loop.
    static let maximumConsecutiveFailures = 5

    // MARK: - Published state

    @Published private(set) var linkState: LinkState = .noAccessory {
        didSet {
            guard oldValue != linkState else { return }
            Diagnostics.route("accessory link \(oldValue) -> \(linkState)")
        }
    }
    @Published private(set) var availability: BLECentralAvailability = .unknown

    /// Accessories seen while scanning, newest RSSI wins. Not a support list
    /// (PT-3).
    @Published private(set) var discovered: [BLEAccessory] = []

    /// The learned mapping, if there is one.
    @Published private(set) var mapping: BLEPTTMapping?

    /// Learn mode's state, or `nil` when not learning.
    @Published private(set) var learner: PTTLearner?

    /// Whether the accessory's button is held, as far as the mapping can tell.
    /// Also stops a repeated press payload producing a second press edge.
    @Published private(set) var isAccessoryKeyed = false

    /// Whether the button's own data has arrived since the link came up.
    ///
    /// `.connected` and a successful subscribe are not evidence — both happen
    /// over a link that has stopped delivering (after an HFP route change, for
    /// one). The UI must not promise a working button while this is false.
    @Published private(set) var isButtonVerified = false

    /// The last notification seen, matched or not. Diagnostic: shows whether
    /// anything is arriving at all.
    @Published private(set) var lastSignal: BLESignal?

    /// Characteristics currently subscribed to. Diagnostic only.
    @Published private(set) var subscribedPaths: [BLECharacteristicPath] = []

    /// Why the link last went away, when the central said.
    @Published private(set) var lastDisconnectReason: String?

    // MARK: - Dependencies

    /// Where press and release edges go. Weak, to avoid a cycle with the
    /// session.
    weak var sink: PTTSink?

    private let makeCentral: () -> BLECentral
    private let store: PTTSettingsStore

    /// Injected so a test does not wait real seconds between retries.
    private let retryDelay: @Sendable () async -> Void

    /// Whether a rebuild is safe now, asked of ``RadioSession``. A rebuild
    /// disconnects, and SF-2 makes a disconnection unkey; this controller cannot
    /// see the on-screen button, so it asks every time. `nil` means yes: nothing
    /// wired, no radio to drop.
    var isRebuildSafe: (@MainActor () -> Bool)?

    // MARK: - Private state

    private var central: BLECentral?
    private var eventTask: Task<Void, Never>?

    /// The learned accessory, or the one being learned. `nil`: connect nothing.
    private var wantedAccessory: UUID?

    private var consecutiveFailures = 0
    private var isScanning = false

    /// How long to wait for a probe's answer. CoreBluetooth never times a read
    /// out, so on a dead link silence is the only answer; a second is ample for
    /// a healthy read.
    private let probeDeadline: @Sendable () async -> Void

    /// Whether a check or rebuild is awaiting its answer. Coalesces a burst of
    /// route changes into one.
    private var isRebuildInFlight = false

    /// Whether the current check actually issued a read. An unanswered read is
    /// a dead link; a probe that could not run (discovery still in progress) is
    /// not evidence, and must not tear down a healthy link at the deadline.
    private var hasProbeBeenIssued = false

    /// Repairs since the link last produced anything. Reset by data, or by the
    /// operator asking.
    private var repairAttempts = 0

    /// The pending "did that work?" check.
    private var escalationTask: Task<Void, Never>?

    /// Rebuilds before leaving it to the operator, who then has an honest
    /// indicator and a **Reconnect** button.
    static let maximumRepairAttempts = 3


    // MARK: - Init

    init(
        makeCentral: @escaping () -> BLECentral = { CoreBluetoothCentral() },
        store: PTTSettingsStore = UserDefaultsPTTSettingsStore(),
        retryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        },
        probeDeadline: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    ) {
        self.makeCentral = makeCentral
        self.store = store
        self.retryDelay = retryDelay
        self.probeDeadline = probeDeadline
        self.mapping = store.loadMapping()
    }

    deinit {
        eventTask?.cancel()
        escalationTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Brings Bluetooth up if an accessory has been learned. Otherwise does
    /// nothing, because creating a `CBCentralManager` shows the permission
    /// prompt.
    func activateIfConfigured() {
        guard mapping != nil else { return }
        activate()
    }

    /// Brings Bluetooth up unconditionally, for the accessory screen.
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

    /// Connects to `accessory`, subscribes to everything it notifies on, and
    /// starts learning. The current mapping stays until a new one is adopted.
    func beginLearning(with accessory: BLEAccessory) {
        activate()
        stopScanning()
        learner = PTTLearner(accessoryID: accessory.id, accessoryName: accessory.name)
        wantedAccessory = accessory.id
        consecutiveFailures = 0
        linkState = .connecting
        central?.connect(accessory.id)
    }

    /// Starts learning again with the same accessory.
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

    /// The operator pressed and released and nothing new appeared: resolves an
    /// accessory whose two edges look the same.
    func nothingElseArrived() {
        learner?.nothingElseArrived()
    }

    /// Abandons learn mode. An existing mapping stays connected; otherwise the
    /// half-learned accessory is disconnected.
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

    /// The link state with no accessory wanted: nothing, unless Bluetooth itself
    /// is unusable.
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
        // A press and release just arrived, so the button is verified.
        isButtonVerified = true
        isAccessoryKeyed = false
        wantedAccessory = learned.accessoryID
        if !linkState.isConnected { connectWanted() }
    }

    /// Discards the mapping, drops the link and clears storage.
    func forgetAccessory() {
        // Fail safe: release a key the accessory was holding.
        if isAccessoryKeyed {
            isAccessoryKeyed = false
            sink?.pttReleased(from: .accessory, reason: .accessoryReleased)
        }
        if let id = wantedAccessory { central?.disconnect(id) }
        wantedAccessory = nil
        mapping = nil
        learner = nil
        isButtonVerified = false
        escalationTask?.cancel()
        repairAttempts = 0
        isRebuildInFlight = false
        store.saveMapping(nil)
        linkState = idleLinkState
    }

    // MARK: - Repairing a link that has gone quiet (BU-14)

    /// The audio route changed while idle: check the link (BU-14).
    ///
    /// - After a route change to HFP, notifications can stop with nothing
    ///   reported — still connected, no disconnection — so the route change is
    ///   the only observable trigger.
    /// - A re-subscribe is no repair: it can succeed while delivering nothing.
    ///   Only a full reconnect is reliable.
    /// - Safe against SF-2 only because ``RadioSession`` calls this when nothing
    ///   is on air, held or resuming; a reconnect is a disconnection, which
    ///   unkeys.
    func audioRouteDidChange() {
        checkLink(reason: "route changed")
    }

    /// Probes the link and rebuilds only if the probe fails, so a healthy link
    /// is not torn down after every over. Leaves ``isButtonVerified`` alone
    /// (a rebuild clears it), so the indicator does not flicker.
    private func checkLink(reason: String) {
        guard mapping != nil, learner == nil, linkState.isConnected,
            !isAccessoryKeyed, let id = wantedAccessory
        else { return }

        if isRebuildInFlight {
            Diagnostics.route("accessory check (\(reason)) skipped: already in flight")
            return
        }
        if let isRebuildSafe, !isRebuildSafe() {
            Diagnostics.route("accessory check (\(reason)) declined: not idle")
            return
        }

        isRebuildInFlight = true
        // Armed now so the wait is bounded; `.probeIssued` decides whether its
        // expiry means anything.
        hasProbeBeenIssued = false
        Diagnostics.route("accessory check (\(reason)): probing before rebuilding")
        central?.probeForLiveness(id)
        armProbeDeadline()
    }

    /// The operator asked for a rebuild. Bypasses the in-flight coalescing and
    /// resets the repair budget.
    func reconnectAccessory() {
        // A link that died silently mid-press delivers no release, so the keyed
        // claim would block the repair guards forever. Releasing it can only
        // unkey.
        if isAccessoryKeyed {
            isAccessoryKeyed = false
            sink?.pttReleased(from: .accessory, reason: .accessoryReleased)
        }
        repairAttempts = 0
        isRebuildInFlight = false
        repair(reason: "operator asked", force: true)
    }

    /// The radio unkeyed without the accessory (the SF-1 watchdog). Withdraws
    /// the keyed claim, which nothing else would, since the watchdog fires
    /// exactly when no release arrived. No sink call: the radio is already
    /// unkeyed.
    func radioUnkeyedExternally() {
        guard isAccessoryKeyed else { return }
        isAccessoryKeyed = false
        Diagnostics.keying("accessory keyed claim withdrawn: the radio unkeyed without it")
    }

    /// Rebuilds the link now, on the first change of a burst; the rest are
    /// coalesced by ``isRebuildInFlight``.
    private func repair(reason: String, force: Bool) {
        // Never during learn mode, which a reconnect would restart.
        guard mapping != nil, learner == nil, linkState.isConnected,
            !isAccessoryKeyed, let id = wantedAccessory
        else { return }

        if isRebuildInFlight, !force {
            Diagnostics.route("accessory repair (\(reason)) skipped: rebuild in flight")
            return
        }

        // Asked every time: the operator may have keyed on screen since the
        // repair was scheduled, and a rebuild would unkey them (SF-2).
        if let isRebuildSafe, !isRebuildSafe() {
            Diagnostics.route("accessory repair (\(reason)) declined: not idle")
            return
        }

        repairAttempts += 1
        isRebuildInFlight = true
        hasProbeBeenIssued = false

        // An earlier check's deadline must not fire into the rebuild. The
        // rebuild's own is armed when its probe goes out, after resubscribing.
        escalationTask?.cancel()

        isButtonVerified = false
        Diagnostics.route(
            "accessory repair (\(reason)) attempt \(repairAttempts)"
                + "/\(Self.maximumRepairAttempts): rebuilding the link")
        // Disconnect only: `.disconnected` drives the reconnect through the same
        // path as a real link drop.
        central?.disconnect(id)
    }

    /// A probe answered (`alive`) or failed.
    private func handleProbeOutcome(alive: Bool, detail: String?) {
        escalationTask?.cancel()
        isRebuildInFlight = false

        if alive {
            // The link is alive, but that says nothing about the button: the
            // accessory answers reads even while suppressing notifications.
            repairAttempts = 0
            return
        }

        guard repairAttempts < Self.maximumRepairAttempts else {
            Diagnostics.route(
                "accessory repair gave up after \(repairAttempts) attempts "
                    + "(\(detail ?? "probe failed")) — the link is not coming "
                    + "back on its own")
            return
        }
        repair(reason: "probe failed: \(detail ?? "no reason")", force: true)
    }

    /// Bounds the wait for a probe's answer; see ``probeDeadline``.
    private func armProbeDeadline() {
        escalationTask?.cancel()
        let deadline = probeDeadline
        escalationTask = Task { @MainActor [weak self] in
            await deadline()
            guard !Task.isCancelled, let self, self.isRebuildInFlight else { return }
            guard self.hasProbeBeenIssued else {
                // No read went out, so silence is not evidence: end the check.
                Diagnostics.route(
                    "accessory probe could not run before the deadline; "
                        + "silence is not evidence, leaving the link alone")
                self.isRebuildInFlight = false
                return
            }
            Diagnostics.route("accessory probe did not answer in time")
            self.handleProbeOutcome(alive: false, detail: "no answer within the deadline")
        }
    }

    // MARK: - Events

    private func handle(_ event: BLECentralEvent) {
        switch event {

        case .availabilityChanged(let availability):
            self.availability = availability
            if availability != .poweredOn, availability != .unknown {
                // Not a disconnection event, but SF-2 applies whichever layer
                // dropped the link.
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
            // A new link starts button-up and unproven (BU-14).
            isAccessoryKeyed = false
            isButtonVerified = false
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
            isButtonVerified = false
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
            Diagnostics.route(
                "accessory subscribed to \(paths.count): "
                    + paths.map { "\($0.service)/\($0.characteristic)" }
                        .joined(separator: " "))

            // After a rebuild, make the link prove it carries data. Not while
            // learning: the learner would latch the read's value as a press.
            if repairAttempts > 0, learner == nil {
                Diagnostics.route("accessory liveness probe: reading the link")
                central?.probeForLiveness(id)
                // Re-armed per probe: discovery arrives service by service, so
                // the deadline runs from the last probe, not the first.
                armProbeDeadline()
            }

        case .probeIssued(let id):
            guard id == wantedAccessory else { return }
            hasProbeBeenIssued = true
            // Re-armed so the wait bounds the answer, not the discovery.
            if isRebuildInFlight { armProbeDeadline() }

        case .probeAnswered(let id, let signal):
            guard id == wantedAccessory else { return }
            lastSignal = signal
            Diagnostics.route(
                "accessory probe answered "
                    + "\(signal.path.service)/\(signal.path.characteristic) "
                    + "= \(signal.payloadDescription)")
            // Resolves the check whatever the verification state, and does
            // nothing else: a read never verifies the button, and never reaches
            // the runtime mapping — a press characteristic that reads back the
            // press payload would key the radio with no release to follow.
            if isRebuildInFlight {
                handleProbeOutcome(alive: true, detail: nil)
            }

        case .probeFailed(let id, let reason):
            guard id == wantedAccessory else { return }
            Diagnostics.route("accessory probe failed: \(reason ?? "no reason")")
            // A stray failure would force-rebuild a healthy link.
            guard isRebuildInFlight else { return }
            handleProbeOutcome(alive: false, detail: reason)

        case .notified(let id, let signal):
            guard id == wantedAccessory else { return }
            // Any notification proves the link is alive.
            if isRebuildInFlight {
                handleProbeOutcome(alive: true, detail: nil)
            }
            if !isButtonVerified, isButtonSignal(signal) {
                isButtonVerified = true
                repairAttempts = 0
                Diagnostics.route("accessory button verified by its own data")
            }
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

    /// Whether this is the learned button speaking, the only traffic that
    /// verifies the button. Other traffic continues while the accessory
    /// suppresses button notifications in HFP call mode.
    private func isButtonSignal(_ signal: BLESignal) -> Bool {
        guard let mapping, mapping.isUsable else { return false }
        return signal == mapping.press || signal == mapping.release
    }

    private func applyRuntimeMapping(_ signal: BLESignal) {
        guard let mapping, mapping.isUsable else { return }

        if signal == mapping.press {
            // Edge, not level: a repeated press payload keys once.
            guard !isAccessoryKeyed else { return }
            isAccessoryKeyed = true
            Diagnostics.keying("accessory PRESS edge")
            sink?.pttPressed(from: .accessory)
        } else if signal == mapping.release {
            // Not guarded on `isAccessoryKeyed`: an extra release can only stop
            // transmission, and a swallowed one can leave a microphone open.
            // Some accessories send a release twice; `wasKeyed=false` in the
            // log is the duplicate.
            let wasKeyed = isAccessoryKeyed
            isAccessoryKeyed = false
            Diagnostics.keying("accessory RELEASE edge (wasKeyed=\(wasKeyed))")
            sink?.pttReleased(from: .accessory, reason: .accessoryReleased)
        }
        // Anything else changes nothing.
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
