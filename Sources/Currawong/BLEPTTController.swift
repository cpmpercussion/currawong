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
/// disconnection is to stop transmitting** — unconditionally, synchronously,
/// before the reconnection logic, before the published state changes, before
/// anything is awaited. The reconnect that follows must never be able to delay
/// the unkey.
///
/// ## No press survives a reconnection
///
/// ``isAccessoryKeyed`` is cleared on every disconnection, so a reconnect
/// starts from "button up" no matter what the accessory was doing when the link
/// dropped. A device that re-sends its state on connect will send the press
/// payload and key the radio — deliberately, that is a genuine press edge on a
/// live link — but nothing here *assumes* a press across the gap.
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
    /// CoreBluetooth's `connect` has no timeout and simply pends until the
    /// accessory reappears — the behaviour that covers "left it in the car" —
    /// so a `didFailToConnect` means connecting failed outright and instantly,
    /// which without a cap is a busy loop.
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

    /// **Whether anything has actually arrived on this link since it came up.**
    ///
    /// `CBPeripheral` can report `.connected`, and a re-subscribe can report
    /// success, over a link whose accessory has stopped delivering — after the
    /// audio route moves to HFP, for instance. So neither is evidence; **only
    /// arriving data is evidence.**
    ///
    /// False from the moment a link is established or rebuilt until the first
    /// notification arrives. The UI must not promise a working button while
    /// this is false — saying "Accessory ready" over a dead button sends the
    /// operator on air believing they can key.
    @Published private(set) var isButtonVerified = false

    /// The last notification seen from the connected accessory, whether or not
    /// it matched the mapping. Diagnostic: an operator whose accessory has
    /// stopped working can see whether anything is arriving at all.
    @Published private(set) var lastSignal: BLESignal?

    /// Characteristics currently subscribed to. Diagnostic only.
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

    /// The clock, injected so a test does not wait real seconds for a cooldown.
    private let now: @Sendable () -> Date

    /// **Whether a rebuild is safe right now**, asked of whoever knows what is on
    /// air — ``RadioSession`` in the app, via the composition root.
    ///
    /// A rebuild disconnects, and SF-2 makes a disconnection unkey
    /// unconditionally. This controller can see only whether the *accessory* is
    /// holding the key, not the on-screen button, so the question is re-asked
    /// every time rather than assumed still true. Absent, the answer is taken
    /// as yes: a controller with nothing wired to it has no radio to drop.
    var isRebuildSafe: (@MainActor () -> Bool)?

    // MARK: - Private state

    private var central: BLECentral?
    private var eventTask: Task<Void, Never>?

    /// The accessory the controller wants connected — the learned one, or the
    /// one being learned. `nil` means "connect nothing".
    private var wantedAccessory: UUID?

    private var consecutiveFailures = 0
    private var isScanning = false

    /// When the last repair was started, so a burst of route changes coalesces
    /// into one reconnect instead of one per change.
    private var lastRepairAt: Date?

    /// **How long to wait for a probe's answer.**
    ///
    /// CoreBluetooth does not time reads out, so a read on a dead link calls
    /// back not at all — silence *is* the negative answer, and silence can only
    /// be recognised by deciding how long is long enough. Short on purpose: a
    /// second is comfortably more than a healthy read needs, so a dead link
    /// costs roughly a second plus a rebuild rather than the length of an
    /// unconditional rebuild on every over, healthy or not.
    private let probeDeadline: @Sendable () async -> Void

    /// Whether a rebuild is between its disconnect and its answer.
    ///
    /// A route-change burst is coalesced by this flag, not by a clock: it fires
    /// once because a rebuild is already happening, not because too little time
    /// has passed.
    private var isRebuildInFlight = false

    /// Whether the current check or rebuild has actually issued a read.
    ///
    /// The deadline needs the distinction: a probe that was issued and never
    /// answered is a dead link, but a probe that could not run — nothing
    /// readable discovered yet — is silence, and silence is not evidence. An
    /// accessory whose two radio halves connect independently can fire a route
    /// change while BLE discovery is still in progress; without this flag that
    /// tears down a healthy link on the deadline.
    private var hasProbeBeenIssued = false

    /// Repairs attempted since the link last produced anything, so escalation is
    /// bounded. Reset by data arriving, and by the operator asking directly.
    private var repairAttempts = 0

    /// The pending "did that work?" check.
    private var escalationTask: Task<Void, Never>?

    /// How many rebuilds to try before giving up and leaving it to the operator.
    ///
    /// Small on purpose: each attempt costs the accessory a reconnection, and a
    /// long ladder would mostly hide that the link is not coming back. Giving up
    /// is not a failure to act — `isButtonVerified` drives an honest indicator
    /// and a **Reconnect** button, which beats retrying invisibly forever.
    static let maximumRepairAttempts = 3


    // MARK: - Init

    init(
        makeCentral: @escaping () -> BLECentral = { CoreBluetoothCentral() },
        store: PTTSettingsStore = UserDefaultsPTTSettingsStore(),
        retryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        },
        now: @escaping @Sendable () -> Date = Date.init,
        probeDeadline: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    ) {
        self.makeCentral = makeCentral
        self.store = store
        self.retryDelay = retryDelay
        self.now = now
        self.probeDeadline = probeDeadline
        self.mapping = store.loadMapping()
    }

    deinit {
        eventTask?.cancel()
        escalationTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Brings the Bluetooth stack up and reconnects the learned accessory, if
    /// there is one. Does nothing when nothing has been learned: constructing a
    /// `CBCentralManager` triggers the Bluetooth permission prompt, and an
    /// operator who never asked for an accessory should never see it.
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
        // The learn sequence *was* the button speaking — a press and a release
        // arrived moments ago — so the link starts its runtime life verified.
        isButtonVerified = true
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
        isButtonVerified = false
        escalationTask?.cancel()
        repairAttempts = 0
        isRebuildInFlight = false
        store.saveMapping(nil)
        linkState = idleLinkState
    }

    // MARK: - Repairing a link that has gone quiet (BU-14)

    /// **The audio route changed while nothing was transmitting.** Reconnect the
    /// accessory (BU-14): after the audio session takes the route to HFP, an
    /// accessory's notifications can stop arriving with **nothing reporting
    /// it** — the peripheral stays connected, no disconnection is delivered, and
    /// the button is simply dead until the link is rebuilt. See the Bluetooth
    /// audio document under `docs` for detail.
    ///
    /// A bare re-subscribe is not a fix: it can report success — completes
    /// without error, ``subscribedPaths`` fills in — while delivering nothing.
    /// Neither `.connected` nor a successful subscribe is evidence the link
    /// works; only arriving data is, and a PTT button is legitimately silent for
    /// minutes, so silence cannot be the trigger either. A full reconnect is the
    /// reliable repair, so this acts on the *observable* signal — the route
    /// change — rather than the cheap one.
    ///
    /// **Safe against SF-2** only because ``RadioSession`` calls this exclusively
    /// when idle — no transmission, no hold, no resume in flight. A reconnect
    /// means a disconnection, and a disconnection unkeys unconditionally; this
    /// class adds only what it can see for itself, that the accessory is not the
    /// thing currently keyed. Keeping the idle decision in the class that knows
    /// the answer is what lets SF-2 stay unconditional.
    func audioRouteDidChange() {
        checkLink(reason: "route changed")
    }

    /// **Ask before rebuilding.** Probe the link; rebuild only if the probe fails
    /// — an unconditional rebuild on every route change costs the operator a
    /// dead button for a full reconnection after every over, healthy or not.
    ///
    /// **``isButtonVerified`` is deliberately not cleared here.** A check is a
    /// silent health question, and flipping the indicator to "untested" after
    /// every over would make it flicker on a link that is fine. It is cleared
    /// when a rebuild actually starts, which is when the claim really has
    /// stopped being true.
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
        // The deadline is armed now, so a link whose probe never answers is
        // still bounded — but whether its expiry *means* anything depends on a
        // read having actually been issued, which `.probeIssued` reports.
        hasProbeBeenIssued = false
        Diagnostics.route("accessory check (\(reason)): probing before rebuilding")
        central?.probeForLiveness(id)
        armProbeDeadline()
    }

    /// **The operator asked for the link to be rebuilt.** Ignores the cooldown,
    /// because a person pressing a button has better information than a timer.
    func reconnectAccessory() {
        // A keyed claim the accessory can no longer withdraw is let go of first.
        // Every ordinary clear path needs an event from the link — a release, a
        // disconnection — and a link that died silently mid-press delivers
        // neither, so without this the claim held the `!isAccessoryKeyed` guard
        // closed forever and disabled the one button meant to fix a dead link.
        // Fail-safe: this can only ever *unkey* the radio.
        if isAccessoryKeyed {
            isAccessoryKeyed = false
            sink?.pttReleased(from: .accessory, reason: .accessoryReleased)
        }
        // A fresh budget: the operator pressing a button is new information.
        repairAttempts = 0
        isRebuildInFlight = false
        repair(reason: "operator asked", force: true)
    }

    /// **The radio stopped transmitting without the accessory saying so** — the
    /// SF-1 watchdog, via the composition root.
    ///
    /// The claim is withdrawn because nothing else can withdraw it: the
    /// watchdog fires precisely when no release has arrived, and a link that
    /// died silently mid-press delivers neither a release nor a disconnection.
    /// Left standing, the claim keeps the repair guards closed and the
    /// indicator saying "Accessory keyed" over a radio that is no longer
    /// transmitting. No sink call — the radio has already unkeyed; this is the
    /// controller catching up, not a release edge.
    func radioUnkeyedExternally() {
        guard isAccessoryKeyed else { return }
        isAccessoryKeyed = false
        Diagnostics.keying("accessory keyed claim withdrawn: the radio unkeyed without it")
    }

    /// Rebuild the link now.
    ///
    /// Repairs on the *first* change of a burst, and coalesces the rest by
    /// noticing that a rebuild is already in flight — not by waiting for the
    /// burst to go quiet first, which puts a dead button on the operator's
    /// critical path for nothing a coalesce doesn't already buy.
    private func repair(reason: String, force: Bool) {
        // No accessory in use, or no link to repair: nothing to do. In
        // particular this must not fire during learn mode, where the operator is
        // mid-sequence and a reconnect would restart it under them.
        guard mapping != nil, learner == nil, linkState.isConnected,
            !isAccessoryKeyed, let id = wantedAccessory
        else { return }

        // Coalescing by state, not by clock: a burst of route changes produces
        // one rebuild because one is already happening.
        if isRebuildInFlight, !force {
            Diagnostics.route("accessory repair (\(reason)) skipped: rebuild in flight")
            return
        }

        // Asked every time, including for a repair this class scheduled itself:
        // an escalation fires on a timer, and by then the operator may have keyed
        // up on the on-screen button, which this class cannot see. `SF-2` makes a
        // disconnection unkey, so a rebuild must never race a live transmission.
        if let isRebuildSafe, !isRebuildSafe() {
            Diagnostics.route("accessory repair (\(reason)) declined: not idle")
            return
        }

        lastRepairAt = now()
        repairAttempts += 1
        isRebuildInFlight = true
        hasProbeBeenIssued = false

        // A deadline armed for an earlier check dies here rather than running
        // on into the rebuild, where its expiry would falsely clear the
        // in-flight flag or issue a second disconnect into the link being
        // rebuilt. The rebuild's own deadline is armed when its probe actually
        // goes out, after the new link subscribes.
        escalationTask?.cancel()

        // The link is not to be trusted again until something arrives on it.
        isButtonVerified = false
        Diagnostics.route(
            "accessory repair (\(reason)) attempt \(repairAttempts)"
                + "/\(Self.maximumRepairAttempts): rebuilding the link")
        // Disconnect only. The `.disconnected` event drives the reconnect
        // through `handle(_:)`, which is the same path a real link drop takes —
        // so there is exactly one reconnection routine, not two.
        // No deadline armed here: a rebuild has not issued a probe yet — probes
        // go out only once the new link finishes subscribing, after the
        // reconnection completes.
        central?.disconnect(id)
    }

    /// **The rebuild's answer arrived: act on it.**
    ///
    /// Called when a probe answers (`alive`) or fails. No waiting and no
    /// guessing — which is the whole reason `probeFailed` exists on the seam.
    private func handleProbeOutcome(alive: Bool, detail: String?) {
        escalationTask?.cancel()
        isRebuildInFlight = false

        if alive {
            // The link answers, so the repair ladder ends and the budget is
            // whole again. Note what this does *not* say: nothing about the
            // button. `isButtonVerified` is set only by the button's own
            // signals, because the accessory answers reads even while it
            // suppresses notifications in call mode.
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

    /// Bound the wait for a probe's answer. See ``probeDeadline`` for why a bound
    /// is required rather than merely convenient.
    private func armProbeDeadline() {
        escalationTask?.cancel()
        let deadline = probeDeadline
        escalationTask = Task { @MainActor [weak self] in
            await deadline()
            guard !Task.isCancelled, let self, self.isRebuildInFlight else { return }
            guard self.hasProbeBeenIssued else {
                // No read ever went out — nothing readable had been discovered
                // when the probe ran. That is silence, not evidence, so the
                // check simply ends; a later route change is free to ask again.
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
            // And it starts from "unproven": a connection is not a working
            // button, which is the whole lesson of BU-14.
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

            // Make the link prove itself: a rebuild is only worth anything if the
            // new link carries data, and neither this event nor `.connected`
            // shows that. Not while learning — the read's value arrives as a
            // notification, and the learner would latch it as the operator's
            // press.
            if repairAttempts > 0, learner == nil {
                Diagnostics.route("accessory liveness probe: reading the link")
                central?.probeForLiveness(id)
                // Re-armed per probe, deliberately. Characteristic discovery
                // arrives service by service and the earliest probes of a
                // rebuild cannot issue a read at all — so the deadline must be
                // measured from the *last* probe attempted, not the first.
                armProbeDeadline()
            }

        case .probeIssued(let id):
            guard id == wantedAccessory else { return }
            hasProbeBeenIssued = true
            // Re-armed from the moment a read actually went out, so the wait
            // bounds the answer rather than the discovery that preceded it.
            if isRebuildInFlight { armProbeDeadline() }

        case .probeAnswered(let id, let signal):
            guard id == wantedAccessory else { return }
            lastSignal = signal
            Diagnostics.route(
                "accessory probe answered "
                    + "\(signal.path.service)/\(signal.path.characteristic) "
                    + "= \(signal.payloadDescription)")
            // The answer resolves the check whatever the verification state —
            // gating this on `isButtonVerified` leaves an already-verified
            // link's deadline armed, and a later route change tears it down a
            // second after it last answered.
            //
            // And that is *all* it does. The answer travels the read path,
            // which the accessory keeps serving even while it suppresses
            // notifications in HFP call mode, so it never verifies the button —
            // and it never reaches the runtime mapping, because a device whose
            // press characteristic reads back the press payload would otherwise
            // be keyed by every post-over probe, with no release ever coming.
            if isRebuildInFlight {
                handleProbeOutcome(alive: true, detail: nil)
            }

        case .probeFailed(let id, let reason):
            guard id == wantedAccessory else { return }
            Diagnostics.route("accessory probe failed: \(reason ?? "no reason")")
            // Only a probe this controller has in flight can fail. The central
            // filters too, but the belt matters: acting on a stray failure
            // force-rebuilds a healthy link and clears its verification.
            guard isRebuildInFlight else { return }
            handleProbeOutcome(alive: false, detail: reason)

        case .notified(let id, let signal):
            guard id == wantedAccessory else { return }
            // A notification during a check is the accessory speaking, which
            // answers the liveness question at least as well as the probe does:
            // the link demonstrably carries data.
            if isRebuildInFlight {
                handleProbeOutcome(alive: true, detail: nil)
            }
            // And only the button's own signals verify the *button* — the
            // accessory serves other traffic even while it suppresses the
            // button's notifications in HFP call mode, so a battery level
            // proves the link, not the button.
            if !isButtonVerified, isButtonSignal(signal) {
                isButtonVerified = true
                // Restores the full budget for the next time the link dies.
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

    /// Whether this signal is the learned button speaking — the only traffic
    /// that can verify the button. A probe's read answer, a battery level, or a
    /// heartbeat all prove the link, but the accessory serves reads even while
    /// it suppresses the button's notifications in HFP call mode, so none of
    /// them prove the thing the operator is about to trust their transmitter to.
    private func isButtonSignal(_ signal: BLESignal) -> Bool {
        guard let mapping, mapping.isUsable else { return false }
        return signal == mapping.press || signal == mapping.release
    }

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
            // Logged with what it found: some accessories send a release twice
            // milliseconds apart, and a second line saying `wasKeyed=false` is
            // the duplicate being absorbed, not a fault.
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
