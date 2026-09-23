// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation
import RadioCore

/// Everything Currawong knows how to do, with no view attached.
///
/// Holds no client and names no protocol: the five operations it needs travel
/// as closures on ``RadioLink``, built by `CompositionRoot`. That keeps the
/// view model testable against a fake that opens no socket.
///
/// ## The rule this type exists to enforce
///
/// **Transmission stops.** Every path that could conceivably leave a
/// microphone open funnels through ``endTransmit(reason:)``, which is
/// idempotent, is safe to call when nothing is transmitting, and closes the
/// microphone *synchronously* before it does anything asynchronous. The paths
/// are: touch-up, dragging off the button, gesture cancellation, the view
/// disappearing, the app leaving the foreground, an audio interruption, a
/// route change, the transmit watchdog, disconnecting, the link dropping, and
/// a keying failure. Each has a case in ``TransmitStopReason`` and a test.
///
/// ## Ordering
///
/// Start and stop are serialised through a single chained task, so a fast
/// press-release cannot end with the stop landing before the start and leaving
/// the client keyed. The chain is the reason ``settle()`` exists.
@MainActor
final class RadioSession: ObservableObject {

    // MARK: - Types

    /// Where the connection is. Distinct from `TransmitState`, which is about
    /// the microphone; a connection can be up with nothing being transmitted,
    /// and briefly the other way round while it is being torn down.
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case disconnecting

        var isBusy: Bool { self == .connecting || self == .disconnecting }
        var isConnected: Bool { self == .connected }

        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .disconnecting: return "Disconnecting…"
            }
        }
    }

    /// An error worth stopping the operator for.
    struct OperatorAlert: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String

        static func == (lhs: OperatorAlert, rhs: OperatorAlert) -> Bool {
            lhs.title == rhs.title && lhs.message == rhs.message
        }
    }

    /// A safety event that unkeyed the operator. Shown as a banner rather than
    /// an alert: it is not a question, it is an explanation, and it must be
    /// visible without being dismissed first.
    struct SafetyNotice: Equatable, Identifiable {
        enum Kind: Equatable {
            /// SF-1.
            case transmitWatchdog
            /// SF-3.
            case audioInterruption
            /// SF-3.
            case routeChange
            /// SF-2.
            case accessoryLinkLost
        }

        let kind: Kind
        let message: String

        var id: Kind { kind }
    }

    /// How the composition root turns a destination, an operator and a secret
    /// into a link. Throws, because building a destination can reject what was
    /// typed.
    ///
    /// The timeout and the proxy are parameters rather than settings fields:
    /// the timeout is app-wide (SF-1), and the proxy is resolved per session,
    /// not per channel (APP-13).
    typealias LinkFactory =
        @MainActor (
            NodeSettings, OperatorIdentity, LinkCredentials, TransmitTimeout,
            EchoLinkProxyRoute?
        ) throws -> RadioLink

    /// What a link is built with, beyond the settings and the identity.
    ///
    /// A type rather than two `String` parameters, so a call site cannot swap
    /// them and still compile. Which one is used is decided by
    /// ``NodeSettings/usesWebTransceiver``.
    struct LinkCredentials: Equatable, Sendable {
        /// The node secret, or an EchoLink account password. Empty for a mode or
        /// a route that does not authenticate.
        var secret: String = ""

        /// The Web Transceiver token, when the channel is reached that way.
        /// Empty otherwise, and never sent as a secret.
        var webTransceiverToken: String = ""
    }

    /// How long after the last inbound frame the receive indicator stays lit.
    /// Two and a half frames — long enough not to flicker on the 20 ms grid,
    /// short enough to go out promptly when the far end unkeys.
    static let receiveActivityWindow: TimeInterval = 0.5

    /// How many DTMF digits of history to keep in each direction. Enough for a
    /// long node command and its reply, short enough to read at a glance.
    static let dtmfLogLimit = 24

    // MARK: - Published state

    /// The connect form's working copy of the selected channel (BU-9).
    ///
    /// A draft, not the stored channel: it may hold half-typed values, and only
    /// ``saveDraft()`` writes it back into ``channels``. ``connect()`` adds a
    /// draft that is in no channel yet, but never overwrites one.
    @Published var settings: NodeSettings

    /// Every saved channel and which one is selected (APP-4). Persisted on
    /// every change, since iOS has no reliable "at quit".
    @Published private(set) var channels: ChannelSet

    /// Unsaved edits, keyed by channel id (BU-9). An id in no channel is a
    /// channel never saved, and needs no special case.
    ///
    /// Written by ``stashDraft()``, cleared by ``saveDraft()``, and loaded in
    /// preference to the stored channel, so an edit survives a quit.
    @Published private(set) var drafts: [UUID: NodeSettings]

    /// The secret, in memory only. It reaches the Keychain in ``connect()``
    /// and `UserDefaults` never.
    @Published var secret: String

    /// The Web Transceiver token (APP-11), in memory only, like ``secret``.
    ///
    /// App-wide: one token stands for the operator's callsign on every
    /// WT-enabled node, so it is filed under the callsign
    /// (``NodeSettings/webTransceiverAccount(for:)``) and not reloaded on a
    /// channel change. Typed, pasted, or filled in by the portal login.
    @Published var webTransceiverToken: String

    /// The EchoLink account password, in memory only and app-wide: filed under
    /// `echolink:<callsign>` and edited in Settings (APP-12).
    ///
    /// The only copy (APP-14): nothing mirrors it into ``secret``;
    /// ``credentialSecret(for:identity:)`` and the station browser read it here.
    @Published private(set) var echoLinkAccountPassword: String

    /// The operator's own EchoLink proxy, if they run one (APP-13). App-wide
    /// and persisted on change; empty means "find a public one".
    /// ``ProxyPicker/route(privateProxy:privatePassword:)`` prefers it.
    @Published private(set) var echoLinkProxy: EchoLinkProxySettings

    /// The private proxy's password, in memory only, from the Keychain: a real
    /// credential, unlike a public proxy's literal `PUBLIC`. Empty when no
    /// private proxy is set.
    @Published private(set) var echoLinkProxyPassword: String

    /// What the microphone is putting on the air, after ``transmitGain``.
    /// Not `@Published`: the audio thread writes it 50 times a second and the
    /// views poll it. See ``AudioLevelMeter``.
    let transmitMeter = AudioLevelMeter()

    /// What is arriving from the far end.
    let receiveMeter = AudioLevelMeter()

    /// Software gain on captured audio (0 to +30 dB). App-wide, since it
    /// compensates for this device and voice; persisted on change.
    @Published var transmitGain: TransmitGain {
        didSet {
            guard transmitGain != oldValue else { return }
            // The box is what the audio thread reads.
            gainBox.gain = transmitGain
            settingsStore.saveTransmitGain(transmitGain)
        }
    }

    /// The gain as the capture tap sees it. See ``GainBox``.
    private let gainBox = GainBox<TransmitGain>(.unity)

    /// Software gain on received audio (0 to +20 dB). See ``ReceiveGain``.
    @Published var receiveGain: ReceiveGain {
        didSet {
            guard receiveGain != oldValue else { return }
            receiveGainBox.gain = receiveGain
            settingsStore.saveReceiveGain(receiveGain)
        }
    }

    /// The receive gain as the playback pump sees it. See ``GainBox``.
    private let receiveGainBox = GainBox<ReceiveGain>(.unity)

    /// **SF-1.** How long one transmission may last before the library unkeys.
    ///
    /// App-wide and persisted, so a safety limit does not revert on relaunch.
    /// Passed to the library when a link is built, so a change applies to the
    /// next connection; the settings screen says so.
    @Published var transmitTimeout: TransmitTimeout {
        didSet {
            guard transmitTimeout != oldValue else { return }
            settingsStore.saveTransmitTimeout(transmitTimeout)
        }
    }

    /// Who is operating. App-wide, so it has no draft of its own: persisted by
    /// ``connect()``, ``saveDraft()`` and ``stashDraft()``.
    @Published var identity: OperatorIdentity

    @Published private(set) var connection: ConnectionStatus = .disconnected

    /// The client's own view of transmit state, mirrored for the views.
    @Published private(set) var transmitState: TransmitState = .idle

    /// Whether the client has actually been keyed. Lags ``isKeyDown`` by the
    /// round trip to the client.
    @Published private(set) var isTransmitting = false

    /// Whether the operator is holding the button down. Drives the button's
    /// own appearance so it responds on touch-down rather than on the network.
    @Published private(set) var isKeyDown = false

    /// How many times the radio was keyed during the current hold; one press
    /// should produce exactly one (BU-15).
    ///
    /// Reset only by an operator press, so it outlives the release: XCUITest
    /// cannot inspect the app during `press(forDuration:)`, and
    /// `BU15FirstOverUITests` reads it off the transmit strip afterwards.
    @Published private(set) var keyDownsInCurrentHold = 0

    /// Route changes during this hold's preparation, before key-down (BU-15).
    /// They are this over's own doing and cost nothing, since nothing is on
    /// air yet. Reset with ``keyDownsInCurrentHold``.
    @Published private(set) var routeSignalsDuringPreparation = 0

    /// Route changes that arrived with the radio on air during this hold — the
    /// ones SF-3 acts on. See ``routeSignalsDuringPreparation``.
    @Published private(set) var routeSignalsWhileTransmitting = 0

    /// How long this over's audio bring-up took, press to settled, in
    /// milliseconds. A fast warm hold is `BU-16`'s fast path being intact.
    @Published private(set) var lastPreparationMilliseconds = 0

    /// The audio route the last key-down went out on (`route=BluetoothHFP`,
    /// `route=none`, …).
    ///
    /// An accessory can be connected over BLE while its Classic side is not the
    /// audio route; this is how a device test tells the two BU-15 cases apart.
    @Published private(set) var lastKeyDownRoute = ""

    /// What the last connect's input warm-up managed (BU-22, BU-24).
    ///
    /// A connect never fails over this: the microphone is asked for again at
    /// key-down, behind `AudioIO.startCapture`'s repair. Published so a cold
    /// first over has a visible cause. Set on every exit from ``connect()``
    /// that started a warm-up.
    @Published private(set) var inputWarmUp: InputWarmUpOutcome = .warmed

    /// How long opening the microphone took, from ``AudioIO``. Compared
    /// against `AudioPipelineIO.captureSlowThresholdNanoseconds`; not
    /// inferrable from the gaps in ``holdTrace``, which bracket the settle
    /// wait too.
    @Published private(set) var lastCaptureStartMilliseconds = 0

    /// DEBUG only: what happened during this hold, in milliseconds after the
    /// press (BU-15). Published on the transmit strip's accessibility value
    /// for tests that cannot read the device log. Zeroed by an operator press.
    @Published private(set) var holdTrace: [String] = []

    /// Picks the `route=` field out of ``AudioIO/audioStateDescription``, for
    /// display only — nothing may branch on it (BU-13).
    private static func routeField(of state: String) -> String {
        state.split(separator: " ").first { $0.hasPrefix("route=") }.map(String.init) ?? state
    }

    /// Appends to ``holdTrace``, stamped from the start of the hold.
    private func trace(_ event: String) {
        #if DEBUG
            guard let holdBegan else { return }
            let ms = Int(now().timeIntervalSince(holdBegan) * 1000)
            holdTrace.append("\(event)@\(ms)")
            if holdTrace.count > 24 { holdTrace.removeFirst() }
        #endif
    }

    /// **PT-4.** Which input keyed the radio, or `nil`. Lets the banner say
    /// whether letting go will unkey: a remote-command button latches, the
    /// others are momentary.
    @Published private(set) var activeSource: PTTSource?

    /// The codec the far end agreed to, as a name to display. `nil` until a
    /// connection reports one.
    @Published private(set) var negotiatedCodec: String?

    /// DTMF digits sent and received on this connection, oldest first, so an
    /// operator commanding a node can see what went out and what came back.
    /// Trimmed to ``dtmfLogLimit``.
    @Published private(set) var sentDTMF: String = ""
    @Published private(set) var receivedDTMF: String = ""

    @Published private(set) var alert: OperatorAlert?

    /// Alerts raised while another was already on screen, oldest first. Drained
    /// by ``dismissAlert()``; see ``present(title:message:)`` for why this has
    /// to exist rather than the newest simply winning.
    private var pendingAlerts: [OperatorAlert] = []

    /// SF-1 / SF-3. Why the operator was unkeyed by something other than
    /// themselves.
    @Published private(set) var safetyNotice: SafetyNotice?

    /// Whether the licence acknowledgement sheet is waiting (APP-33). Set by
    /// ``beginTransmit(from:)``; cleared by ``acknowledgeLicence()`` or
    /// ``declineLicence()``. Not in ``alert``'s queue.
    @Published private(set) var needsLicenceAcknowledgement = false

    /// Which version of the acknowledgement wording is on file. `nil` until
    /// one is accepted. Not published: the sheet is driven by the flag above.
    private var acknowledgedLicenceVersion: Int?

    /// Whether the operator has accepted the current wording (APP-33). Only
    /// ``beginTransmit(from:)`` reads it, so declining leaves a working
    /// receive-only radio.
    var hasAcknowledgedLicence: Bool {
        LicenceAcknowledgement.isSatisfied(by: acknowledgedLicenceVersion)
    }

    /// The last reason transmission ended. Diagnostic, and what the tests
    /// assert against to prove each release path is wired up.
    @Published private(set) var lastStopReason: TransmitStopReason?

    /// When the last frame of received audio arrived.
    @Published private(set) var lastReceivedAudioAt: Date?

    /// Why the link went away, when it went away by itself.
    @Published private(set) var lastDisconnectReason: String?

    /// Inbound media the client is discarding, if any.
    @Published private(set) var mediaWarning: String?

    /// The channel of the last successful call this run, for the Reconnect
    /// button (``SessionLinkControl``).
    ///
    /// Successful connects only, so Reconnect never returns somewhere that
    /// refused us. Held as typed, before resolution. In memory only, so a
    /// fresh launch shows no Reconnect.
    @Published private(set) var lastConnectedChannel: NodeSettings?

    /// The station transmitting on a shared channel — M17 only, since a
    /// reflector module is shared. `nil` when nobody is.
    @Published private(set) var receivingFrom: String?

    // MARK: - Dependencies

    private let audio: AudioIO

    /// Called after an audio route change that found the session idle; wired
    /// to the accessory controller's repair. A closure, so this class need not
    /// know Bluetooth exists.
    ///
    /// Only called when ``isIdleForAccessoryRepair``: a repair is a reconnect,
    /// and SF-2 makes a disconnection unkey, so a repair mid-over would drop
    /// the operator.
    var onIdleAudioRouteChange: (@MainActor () -> Void)?

    /// Called when the SF-1 watchdog unkeys; wired to the accessory
    /// controller's `radioUnkeyedExternally()`. An accessory link that dies
    /// silently mid-press delivers no release, so without this its "keyed"
    /// claim would outlive the transmission and block every repair.
    var onWatchdogUnkey: (@MainActor () -> Void)?

    /// Whether the accessory link may be rebuilt right now.
    ///
    /// A rebuild is a disconnection, and SF-2 makes a disconnection unkey, so
    /// a rebuild while anything is on air drops the operator. Answered here
    /// because this class knows. Gates ``onIdleAudioRouteChange``, and the
    /// controller also asks before a repair on its own timer, since it cannot
    /// see the on-screen button.
    var isIdleForAccessoryRepair: Bool {
        // Nothing on air, no hold the operator is still making, no automatic
        // resume about to key back down. **And nothing else:** no quiet period
        // after an over. The accessory link dies during the unkey, so a quiet
        // period suppresses exactly the repair it needs (BU-14;
        // `testARouteChangeJustAfterAnOverDoesAskForARepair` holds it).
        !isTransmitting && heldSource == nil && !routeResumeInFlight
    }

    private let settingsStore: SettingsStore
    private let secretStore: SecretStore
    private let makeLink: LinkFactory

    /// Gives up the leased public proxy when a link ends (APP-13). A closure,
    /// so this type knows nothing of ``ProxyPicker``.
    private let releaseProxyLease: @MainActor () -> Void

    /// Turns the directory server's host name into the address the library
    /// takes. See ``HostResolver``.
    private let resolver: any HostResolver
    private let now: @MainActor () -> Date

    // MARK: - Private state

    private var link: RadioLink?

    /// The desired key state. `isTransmitting` is the applied one; these
    /// differ for as long as it takes the client to answer.
    private var transmitDesired = false

    /// Serialises key-up and key-down so they cannot be applied out of order.
    private var transmitWork: Task<Void, Never>?
    private var transmitWorkGeneration = 0

    /// Where the *hold* came from, as distinct from ``activeSource``.
    ///
    /// They differ while recovering from a route change: transmission has
    /// stopped (SF-3) but the operator has not let go. Cleared by every other
    /// stop reason — see `TransmitStopReason.leavesTheHoldAlive`.
    private var heldSource: PTTSource?

    /// Automatic key-downs used by the current hold. Reset by a press the
    /// operator makes; never by one this class makes.
    private var automaticResumes = 0

    private var resumeWork: Task<Void, Never>?

    /// **SF-4.** The lock-screen half of the transmit indicator (APP-3).
    ///
    /// Driven only by ``refreshActivity()``, called from every transition that
    /// could change whether the radio is keyed, rather than by each release
    /// path: a per-path teardown is one somebody forgets, leaving an activity
    /// that goes on claiming TX.
    private let activity: TransmitActivityController

    /// Whether a route-change recovery is between the stop and the key-down.
    ///
    /// The activity stays up through this gap rather than flickering. Tracked
    /// explicitly rather than inferred from ``heldSource``, because an
    /// unrecoverable route change also leaves the hold alive and must **not**
    /// keep the activity.
    private var routeResumeInFlight = false

    /// **BU-15.** Whether the app is between the press and the key-down:
    /// escalating the session policy, opening the microphone, and waiting for
    /// the route changes they cause to go quiet.
    ///
    /// The one window in which a route change is expected and ignored:
    ///
    /// * **Nothing is on air.** `OnAirGate` drops every captured frame, and
    ///   SF-3 is about dropping *transmission*, of which there is none.
    /// * **It cannot overlap transmitting.** The wait completes before
    ///   ``RadioLink/startTransmit()``; the guard checks both anyway.
    /// * **It cannot outlive the press:** a release clears the hold and
    ///   abandons the key-down.
    ///
    /// Without it, those route changes land under a live carrier and SF-3
    /// unkeys mid-press.
    private var routePreparationInFlight = false

    /// When the current hold began, for the activity's elapsed clock. Survives
    /// a route-change resume, so it times the over.
    private var holdBegan: Date?

    /// When the library's watchdog will unkey the current key-down (SF-1).
    /// Re-set on every key-down, since each starts its own watchdog.
    private var watchdogDeadline: Date?

    /// How many times one hold may be keyed back down after a route change.
    /// A route that flaps is a broken audio path, not something to key a
    /// transmitter into repeatedly.
    private static let maximumAutomaticResumes = 3

    /// How long to let the audio graph settle before asking for the microphone
    /// again. The route-change notification says the graph is *being* rebuilt,
    /// not that it is finished.
    private static let routeSettleNanoseconds: UInt64 = 300_000_000

    private var signalTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    // MARK: - Init

    init(
        audio: AudioIO,
        settingsStore: SettingsStore,
        secretStore: SecretStore,
        makeLink: @escaping LinkFactory,
        releaseProxyLease: @escaping @MainActor () -> Void = {},
        resolver: any HostResolver = SystemHostResolver(),
        now: @escaping @MainActor () -> Date = { Date() },
        // Optional rather than a default expression: a default argument is
        // evaluated nonisolated, and the controller is `@MainActor`. `nil`
        // means no lock-screen indicator (macOS, previews, most tests).
        activity: TransmitActivityController? = nil
    ) {
        self.audio = audio
        self.settingsStore = settingsStore
        self.secretStore = secretStore
        self.makeLink = makeLink
        self.releaseProxyLease = releaseProxyLease
        self.resolver = resolver
        self.now = now
        self.activity = activity ?? .disabled

        let loaded = ChannelSet.loaded(from: settingsStore)
        self.channels = loaded

        // Drafts load before the draft is chosen, since it is chosen from
        // them. Duplicate ids keep the last rather than trapping at launch.
        let storedDrafts = settingsStore.loadDrafts() ?? []
        let allDrafts = Dictionary(
            storedDrafts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        // Drafts for channels not in the list are dropped here, at launch
        // only: nothing can select them, so they would sit in the defaults for
        // ever. Within a run they are how a directory browse is kept.
        let liveDrafts = allDrafts.filter { id, _ in loaded.channels.contains { $0.id == id } }
        self.drafts = liveDrafts
        if liveDrafts.count != allDrafts.count {
            settingsStore.saveDrafts(Array(liveDrafts.values))
        }

        // An unsaved edit wins over the stored channel: it is what the
        // operator was last looking at.
        let stored = loaded.selected ?? NodeSettings()
        let current = liveDrafts[stored.id] ?? stored
        self.settings = current

        // Before the secret is fetched: some Keychain accounts are derived from
        // the callsign.
        let identity = settingsStore.loadIdentity() ?? .empty
        self.identity = identity
        let storedGain = settingsStore.loadTransmitGain() ?? .unity
        self.transmitGain = storedGain
        self.gainBox.gain = storedGain
        self.transmitTimeout = settingsStore.loadTransmitTimeout() ?? .default
        self.acknowledgedLicenceVersion = settingsStore.loadLicenceAcknowledgement()
        let storedReceiveGain = settingsStore.loadReceiveGain() ?? .unity
        self.receiveGain = storedReceiveGain
        self.receiveGainBox.gain = storedReceiveGain
        // Inline `storedSecret(for:)`, which cannot be called before every
        // property is initialised.
        if case .channel(let account) = current.secretOwnership(for: identity) {
            self.secret = (try? secretStore.secret(for: account)) ?? ""
        } else {
            self.secret = ""
        }
        // Loaded whatever the channel's mode: it belongs to the operator.
        self.webTransceiverToken =
            (try? secretStore.secret(for: current.webTransceiverAccount(for: identity))) ?? ""
        self.echoLinkAccountPassword =
            (try? secretStore.secret(for: NodeSettings.echoLinkAccount(for: identity))) ?? ""

        // APP-13's migration: a private proxy harvested from an old channel is
        // filed in the Keychain and resaved, so the harvest runs once.
        let storedProxy = settingsStore.loadEchoLinkProxy()
        self.echoLinkProxy = storedProxy?.settings ?? .none
        if let harvested = storedProxy?.harvestedPassword {
            self.echoLinkProxyPassword = harvested
            try? secretStore.setSecret(harvested, for: EchoLinkProxySettings.passwordAccount)
            settingsStore.saveEchoLinkProxy(storedProxy?.settings ?? .none)
        } else {
            self.echoLinkProxyPassword =
                (try? secretStore.secret(for: EchoLinkProxySettings.passwordAccount)) ?? ""
        }
    }

    // MARK: - The stored accounts (APP-12)

    /// Stores the Web Transceiver token now, rather than at the next connect.
    /// Trimmed, since a pasted token carries clipboard whitespace. A failed
    /// write is reported, not fatal: the token still works this run.
    ///
    /// - Returns: whether it reached the Keychain.
    @discardableResult
    func saveWebTransceiverToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        webTransceiverToken = trimmed
        do {
            try secretStore.setSecret(
                trimmed, for: NodeSettings.webTransceiverAccount(for: identity))
            return true
        } catch {
            present(
                title: "Could not save the token",
                message:
                    "\(error) The token will work for this run, but was not stored — you will have "
                    + "to fetch or paste it again next time.")
            return false
        }
    }

    /// Stores the EchoLink account password; the one place it is written
    /// (APP-14).
    ///
    /// Trimmed: a trailing newline passes every emptiness check, then fails
    /// the digest at the directory server as a right-but-rejected password.
    ///
    /// - Returns: whether it reached the Keychain.
    @discardableResult
    func setEchoLinkAccountPassword(_ password: String) -> Bool {
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        echoLinkAccountPassword = password
        do {
            try secretStore.setSecret(password, for: NodeSettings.echoLinkAccount(for: identity))
            return true
        } catch {
            present(
                title: "Could not save the password",
                message:
                    "\(error) It will work for this run, but was not stored — you will have to "
                    + "type it again next time.")
            return false
        }
    }

    /// Stores the operator's own EchoLink proxy (APP-13): host and port in
    /// `UserDefaults`, password in the Keychain, as one setting.
    ///
    /// Validated here, so a bad value is refused while the operator is at the
    /// field. Clearing the host clears the password.
    ///
    /// - Returns: `nil` on success, or the complaint to show.
    @discardableResult
    func setEchoLinkProxy(_ proxy: EchoLinkProxySettings, password: String) -> String? {
        let validated: EchoLinkProxySettings
        do {
            validated = try proxy.validated()
        } catch let error as EchoLinkProxySettings.ValidationError {
            return error.description
        } catch {
            return "\(error)"
        }

        let storedPassword = validated.isConfigured ? password : ""
        echoLinkProxy = validated
        echoLinkProxyPassword = storedPassword
        settingsStore.saveEchoLinkProxy(validated)

        do {
            try secretStore.setSecret(storedPassword, for: EchoLinkProxySettings.passwordAccount)
        } catch {
            // Not fatal: the proxy works from memory for this run.
            return
                "\(error) The proxy will work for this run, but its password was not stored — you "
                + "will have to type it again next time."
        }
        return nil
    }

    // MARK: - Channels (APP-4)

    /// Switches to a saved channel, loading its details and its secret.
    ///
    /// Refused while a link is up, so the form never describes one node while
    /// the audio comes from another. The UI disables the list too.
    func select(_ id: UUID) {
        guard connection == .disconnected else { return }
        // Nothing to do only if selected *and* in the form: after
        // ``chooseChannel(_:)`` the two can differ, and tapping the highlighted
        // row means "go back to it".
        guard id != channels.selectedID || settings.id != id else { return }
        guard channels.channels.contains(where: { $0.id == id }) else { return }

        stashDraft()
        channels.select(id)
        loadSelectedIntoDraft()
        persistChannels()
    }

    /// Go to a channel whatever the link is doing (APP-23): hang up if there is
    /// a call, then ``select(_:)``, which still refuses while connected.
    ///
    /// Connected, the operator ends up connected to the new channel;
    /// disconnected, a tap only selects. The caller dials, because an EchoLink
    /// channel needs a proxy sourced first and ``RootView`` knows how.
    ///
    /// - Returns: `true` when a call was up and the caller should now place one
    ///   to the newly selected channel.
    @discardableResult
    func switchChannel(to id: UUID) async -> Bool {
        guard channels.channels.contains(where: { $0.id == id }) else { return false }
        // Already there, as `select(_:)` means it: never hang up and redial
        // the channel the operator is talking on.
        guard id != channels.selectedID || settings.id != id else { return false }

        let wasLinked = connection != .disconnected
        if wasLinked { await disconnect() }
        select(id)
        // A selection that did not move is not followed by a call.
        return wasLinked && channels.selectedID == id
    }

    /// Whether the draft differs from its stored channel (BU-9). A draft in no
    /// channel counts as dirty, except an untouched blank form, which is what
    /// the app opens on with no channels.
    var isDraftDirty: Bool {
        if let stored = channels.channels.first(where: { $0.id == settings.id }) {
            return stored != settings
        }
        return settings != NodeSettings(id: settings.id)
    }

    /// Whether the draft is in no channel at all — a directory browse, or an
    /// `Add channel` not yet saved or connected. Connecting adds such a draft
    /// to the list, unlike edits to a stored channel.
    var isDraftAnUnsavedChannel: Bool {
        !channels.channels.contains { $0.id == settings.id }
    }

    /// Whether a channel has an unsaved edit waiting, for ``ChannelListView``'s
    /// row marker.
    func hasUnsavedEdits(for id: UUID) -> Bool {
        if id == settings.id { return isDraftDirty }
        guard let draft = drafts[id] else { return false }
        return channels.channels.first(where: { $0.id == id }) != draft
    }

    /// **Save.** The only thing that overwrites a stored channel (BU-9). A
    /// draft in no channel is added.
    ///
    /// Unvalidated, so a half-typed channel can be kept; ``connect()`` is the
    /// validation gate.
    func saveDraft() {
        if channels.channels.contains(where: { $0.id == settings.id }) {
            channels.update(settings)
        } else {
            channels.add(settings)
        }
        drafts[settings.id] = nil
        persistChannels()
        persistDrafts()

        // Stored as typed; `connect()` validates and uppercases.
        settingsStore.saveIdentity(identity)
    }

    /// Keeps the draft in ``drafts`` without touching the channel list (BU-9).
    /// Called by every path that moves the form away from the draft, so none
    /// overwrites a channel or loses what was typed. A clean draft clears its
    /// stash.
    func stashDraft() {
        drafts[settings.id] = isDraftDirty ? settings : nil
        persistDrafts()

        // The callsign is app-wide, so it has no draft; save it as we pass.
        settingsStore.saveIdentity(identity)
    }

    /// **`Add channel`.** Points the draft at a new, blank channel, and writes
    /// nothing to the list.
    ///
    /// Identical to ``chooseChannel(_:)`` otherwise: the channel reaches the
    /// list when it is saved or connected to (BU-9's rule, APP-19). So a new
    /// channel that is neither saved nor connected does not survive a quit, and
    /// the form says so ("Not saved") as soon as there is anything to lose.
    ///
    /// Refused while connected, as ``select(_:)`` is: the form would describe
    /// one channel while the audio came from another.
    ///
    /// - Returns: the new channel's id, or `nil` if a link is up and nothing
    ///   changed.
    @discardableResult
    func newChannel(_ channel: NodeSettings = NodeSettings()) -> UUID? {
        guard connection == .disconnected else { return nil }

        // The draft being replaced may be a real channel with unsaved edits, and
        // they are kept without being applied to it.
        stashDraft()

        settings = channel
        secret = storedSecret(for: channel)
        return channel.id
    }

    /// Throws away a draft that is in no channel and puts the form back on the
    /// selected channel: the provisional row's Discard (APP-22). A no-op for a
    /// stored channel, which is ``deleteChannel(_:)``'s job.
    ///
    /// - Returns: whether anything was discarded.
    @discardableResult
    func discardDraftChannel() -> Bool {
        guard connection == .disconnected, isDraftAnUnsavedChannel else { return false }

        // Its stash entry would otherwise be unreachable.
        drafts[settings.id] = nil
        persistDrafts()
        loadSelectedIntoDraft()
        return true
    }

    /// Points the draft at somewhere chosen from a directory, without saving
    /// it: only ``saveDraft()`` and ``connect()`` add to the channel list, so
    /// browsing leaves nothing behind. Like ``newChannel(_:)``, the draft does
    /// not survive a quit unless saved or connected to.
    ///
    /// - Returns: whether the draft now points at `channel`. `false` means a
    ///   link is up and nothing changed.
    @discardableResult
    func chooseChannel(_ channel: NodeSettings) -> Bool {
        // Refused while connected, as `select(_:)` is.
        guard connection == .disconnected else { return false }

        // Keep the replaced draft's edits without applying them.
        stashDraft()

        // Already in the list: select it rather than add an indistinguishable
        // second copy.
        if let existing = channels.channels.first(where: { $0.isSamePlace(as: channel) }) {
            channels.select(existing.id)
            loadSelectedIntoDraft()
            persistChannels()
            return true
        }

        settings = channel
        secret = storedSecret(for: channel)
        return true
    }

    /// Deletes a channel and its pending draft (BU-9).
    ///
    /// The Keychain secret is left alone: its account may be shared by other
    /// channels, so deleting it could log the operator out of those. An
    /// orphaned Keychain item is harmless; a lost password is not.
    func deleteChannel(_ id: UUID) {
        guard connection == .disconnected else { return }

        let wasSelected = channels.selectedID == id
        channels.remove(id)
        drafts[id] = nil
        persistDrafts()
        if wasSelected { loadSelectedIntoDraft() }
        persistChannels()
    }

    /// Reorders the channel list. Allowed while connected: it changes neither
    /// the selection nor what it points at.
    func moveChannels(fromOffsets source: IndexSet, toOffset destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
        persistChannels()
    }

    /// What the station browser needs to ask the directory server for a
    /// listing (APP-14). Decides here, testably, which password goes, so a view
    /// cannot pick the channel's secret by mistake.
    struct DirectoryRequest: Equatable {
        let settings: NodeSettings
        let identity: OperatorIdentity
        /// The app-wide EchoLink account password, the only directory credential.
        let accountPassword: String
    }

    var directoryRequest: DirectoryRequest {
        DirectoryRequest(
            settings: settings, identity: identity, accountPassword: echoLinkAccountPassword)
    }

    /// Which password a link is built with (APP-14): the form's `secret` for a
    /// channel-owned credential, the app-wide account password for EchoLink.
    private func credentialSecret(
        for settings: NodeSettings, identity: OperatorIdentity
    ) -> String {
        switch settings.secretOwnership(for: identity) {
        case .channel:
            return secret
        case .appWide:
            return echoLinkAccountPassword
        case .none:
            return ""
        }
    }

    /// The stored secret to put in the form for a channel, if it has one of its
    /// own. An app-wide password stays in ``echoLinkAccountPassword`` only, so
    /// the two cannot disagree (APP-14).
    private func storedSecret(for settings: NodeSettings) -> String {
        switch settings.secretOwnership(for: identity) {
        case .channel(let account):
            return (try? secretStore.secret(for: account)) ?? ""
        case .appWide, .none:
            return ""
        }
    }

    /// Loads the selected channel, or its pending draft, into the form (BU-9).
    private func loadSelectedIntoDraft() {
        let stored = channels.selected ?? NodeSettings()
        let current = drafts[stored.id] ?? stored
        settings = current
        secret = storedSecret(for: current)
    }

    private func persistChannels() {
        channels.save(to: settingsStore)
    }

    /// Writes the drafts out, on every change like the channel list.
    private func persistDrafts() {
        settingsStore.saveDrafts(Array(drafts.values))
    }

    // MARK: - Lifecycle

    /// Starts observing SF-3 signals for the app's lifetime, not the
    /// connection's, so an interruption while connecting is still seen.
    /// Idempotent; called from the root view's `.task` and by tests.
    func start() {
        guard signalTask == nil else { return }
        // **SF-4.** A Live Activity outlives a process killed mid-over, still
        // claiming TX; clear it before anything can key up.
        activity.adopt()
        let signals = audio.signals
        signalTask = Task { @MainActor [weak self] in
            for await signal in signals {
                self?.handle(signal)
            }
        }
    }

    // MARK: - Connecting

    /// - Parameter proxy: the EchoLink proxy, already resolved by
    ///   ``ProxyPicker``; `nil` for other modes. Passed per connect, since a
    ///   proxy is not part of a channel and a public one is leased per sitting.
    func toggleConnection(proxy: EchoLinkProxyRoute? = nil) async {
        switch connection {
        case .disconnected: await connect(proxy: proxy)
        case .connected: await disconnect()
        case .connecting, .disconnecting: break
        }
    }

    /// Validates, persists, and places the call.
    ///
    /// The audio session is configured before the call goes out, and a failure
    /// aborts the connection: a microphone that will never open is
    /// indistinguishable from a quiet channel.
    func connect(proxy: EchoLinkProxyRoute? = nil) async {
        guard connection == .disconnected else { return }

        // Identity first: a bad callsign is wrong for every channel.
        let validatedIdentity: OperatorIdentity
        do {
            validatedIdentity = try identity.validated()
        } catch let error as OperatorIdentity.ValidationError {
            present(title: "Check your callsign", message: error.description)
            return
        } catch {
            present(title: "Check your callsign", message: "\(error)")
            return
        }

        // Written back so the field shows the uppercased, trimmed form used.
        identity = validatedIdentity
        settingsStore.saveIdentity(validatedIdentity)

        let validated: NodeSettings
        do {
            validated = try settings.validated()
        } catch let error as NodeSettings.ValidationError {
            present(title: "Check the connection details", message: error.description)
            return
        } catch {
            present(title: "Check the connection details", message: "\(error)")
            return
        }
        settings = validated

        // Checked here, not in `NodeSettings.validated()`, which holds no
        // credentials. Only emptiness is refused; the node judges the shape.
        let trimmedToken = webTransceiverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if validated.usesWebTransceiver && trimmedToken.isEmpty {
            present(
                title: "No Web Transceiver token",
                message:
                    "This channel connects as a Web Transceiver guest, which needs a token from "
                    + "your allstarlink.org portal account. Enter one, or switch the channel to a "
                    + "node secret.")
            return
        }

        // Connecting may add a channel; it never overwrites one (BU-9). An
        // edit to a stored channel stays a draft until `saveDraft()`.
        if !channels.channels.contains(where: { $0.id == validated.id }) {
            channels.add(validated)
            persistChannels()
        }

        stashDraft()

        // The legacy single-node key too, so a downgrade finds the last node.
        settingsStore.save(validated)

        do {
            if validated.usesWebTransceiver {
                webTransceiverToken = trimmedToken
                try secretStore.setSecret(
                    trimmedToken, for: validated.webTransceiverAccount(for: validatedIdentity))
            }

            // What is written depends on whose secret it is (APP-14).
            switch validated.secretOwnership(for: validatedIdentity) {
            case .channel(let account):
                // Never empty: `SecretStore` deletes on an empty value, and the
                // account may be shared with another channel.
                guard !secret.isEmpty else { break }
                try secretStore.setSecret(secret, for: account)

            case .appWide:
                // EchoLink: Settings owns it; connecting only reads it.
                break

            case .none:
                // M17, or Web Transceiver (token written above).
                break
            }
        } catch {
            // Not fatal: the connection proceeds with the credential held in
            // memory.
            present(
                title: "Could not save the secret",
                message: "\(error) The connection will continue, but the secret was not stored.")
        }

        connection = .connecting
        safetyNotice = nil
        lastDisconnectReason = nil
        mediaWarning = nil
        negotiatedCodec = nil
        receivingFrom = nil
        sentDTMF = ""
        receivedDTMF = ""

        // Before the session: this raises iOS's microphone prompt. Refusing to
        // connect without it is deliberate — a dead transmit path looks like a
        // working QSO until somebody needs to hear you.
        guard await audio.requestRecordPermission() else {
            connection = .disconnected
            present(
                title: "Microphone access is off",
                message:
                    micPermissionAdvice)
            return
        }

        do {
            try audio.configureSession()
        } catch {
            connection = .disconnected
            present(
                title: "Audio unavailable",
                message:
                    "The audio session could not be configured, so nothing could be transmitted or "
                    + "heard. \(error)")
            return
        }

        // BU-22: wake the input device now rather than on the first over (see
        // `AudioIO.warmUpInput()`), overlapped with placing the call.
        //
        // Every exit below awaits it before `connection` can be `.connected`,
        // so it cannot race a key-down, and a failed connect cannot leave the
        // microphone open.
        let warmUp = Task { @MainActor [audio] in await audio.warmUpInput() }

        // The library takes four octets. Resolved into a copy, so the channel
        // keeps the name rather than a stale address.
        let resolved: NodeSettings
        do {
            resolved = try await resolveDirectoryServer(in: validated)
        } catch {
            inputWarmUp = await warmUp.value
            connection = .disconnected
            present(title: "Could not reach the directory server", message: "\(error)")
            return
        }

        let newLink: RadioLink
        do {
            newLink = try makeLink(
                resolved, validatedIdentity,
                LinkCredentials(
                    secret: credentialSecret(for: validated, identity: validatedIdentity),
                    webTransceiverToken: trimmedToken),
                transmitTimeout, proxy)
        } catch {
            inputWarmUp = await warmUp.value
            connection = .disconnected
            present(title: "Could not connect", message: "\(error)")
            return
        }

        link = newLink
        startEventPump(for: newLink)
        startReceivePump(for: newLink)

        do {
            try await newLink.connect()
        } catch {
            inputWarmUp = await warmUp.value
            tearDownLink()
            connection = .disconnected
            present(title: "Could not connect", message: "\(error)")
            return
        }

        // Recorded, but does not gate the connect (see ``inputWarmUp``).
        inputWarmUp = await warmUp.value

        connection = .connected
        transmitState = newLink.transmitState()
        // Only now is the call known to have been answered.
        lastConnectedChannel = validated
    }

    /// Points the draft back at the last channel a call was placed to, so
    /// ``connect()`` reconnects there rather than to whatever is now selected.
    ///
    /// - Returns: whether the draft now points at that channel. `false` means
    ///   there is nowhere to go back to, or a link is already up.
    @discardableResult
    func restoreLastConnectedChannel() -> Bool {
        guard connection == .disconnected, let last = lastConnectedChannel else { return false }
        guard settings.id != last.id else { return true }

        // Through `select(_:)`, to keep the selection and the draft in step.
        if channels.channels.contains(where: { $0.id == last.id }) {
            select(last.id)
            return channels.selectedID == last.id
        }

        // Deleted since: point the draft at it anyway, stashing (not saving)
        // the draft being left.
        stashDraft()
        settings = last
        secret = storedSecret(for: last)
        return true
    }

    /// A copy of `settings` whose directory server is an address rather than a
    /// name. Unchanged outside EchoLink, or when the server is empty (no
    /// directory login).
    private func resolveDirectoryServer(in settings: NodeSettings) async throws -> NodeSettings {
        guard settings.mode.usesProxy, !settings.directoryServer.isEmpty else { return settings }

        var resolved = settings
        resolved.directoryServer = try await resolver.ipv4Address(for: settings.directoryServer)
        return resolved
    }

    /// Hangs up. **Stops transmitting first**, and waits for that to land
    /// before the client is torn down — a disconnect that raced the unkey
    /// could leave the far end's repeater keyed until its own timeout.
    func disconnect() async {
        guard connection == .connected || connection == .connecting else { return }
        connection = .disconnecting

        await endTransmitAndWait(reason: .disconnecting)

        if let link {
            await link.disconnect()
        }
        tearDownLink()
        connection = .disconnected
        transmitState = .idle
        routeResumeInFlight = false
        refreshActivity()
    }

    // MARK: - PTT (PT-1)

    /// Touch-down on the PTT button, or a press edge from any other input.
    /// `source` lets the UI say whether letting go will unkey (PT-4).
    ///
    /// Unconnected, only an on-screen press raises an alert: a fob pressed in
    /// a pocket must not stack up modal alerts.
    func beginTransmit(from source: PTTSource = .onScreen) {
        guard connection.isConnected else {
            if source == .onScreen {
                present(
                    title: "Not connected",
                    message: "Connect to a node before transmitting.")
            }
            return
        }

        // **APP-33** licence gate. After the connected guard, so it is not
        // shown to someone not connected; before everything below, so a
        // refused press does no hold bookkeeping and cannot perturb the
        // BU-15/BU-16 key-down ordering. Any source raises the sheet; the
        // radio stays unkeyed either way.
        guard hasAcknowledgedLicence else {
            needsLicenceAcknowledgement = true
            return
        }

        guard !transmitDesired else { return }

        safetyNotice = nil
        // An operator press, not an automatic resume, starts a fresh hold.
        if heldSource == nil {
            automaticResumes = 0
            keyDownsInCurrentHold = 0
            routeSignalsDuringPreparation = 0
            routeSignalsWhileTransmitting = 0
            holdTrace = []
        }
        // SF-4's clock times the hold, so a resume keeps the original stamp.
        if holdBegan == nil { holdBegan = now() }
        trace(heldSource == nil ? "press" : "resume")
        heldSource = source
        transmitDesired = true
        isKeyDown = true
        activeSource = source
        scheduleTransmitWork()
    }

    /// Every release path. Idempotent, safe when nothing is transmitting, and
    /// safe when there is no link at all.
    ///
    /// The microphone is closed **synchronously, first**, before the task
    /// chain is touched: an interruption or a watchdog must not wait behind a
    /// key-up that is still in flight to an actor.
    func endTransmit(reason: TransmitStopReason, explain: Bool = true) {
        audio.stopCapture()

        if transmitDesired || isTransmitting {
            // Only when something was up, not on defensive calls. Logs why,
            // so a watchdog or route-change drop is told from a release.
            Diagnostics.keying(
                "endTransmit reason=\(reason) wasTransmitting=\(isTransmitting) "
                    + "held=\(heldSource != nil)")
            lastStopReason = reason
            if reason.isUnexpected && explain { noteSafetyStop(reason) }
        }
        if !reason.leavesTheHoldAlive {
            heldSource = nil
            holdBegan = nil
        }
        transmitDesired = false
        isKeyDown = false
        activeSource = nil
        watchdogDeadline = nil
        // Only a route change may leave a resume pending. Any other reason
        // cancels one already in flight, so it cannot key back down — above
        // all after an SF-1 watchdog unkey.
        if reason != .routeChanged {
            routeResumeInFlight = false
            resumeWork?.cancel()
            resumeWork = nil
        }
        // Synchronously, not behind the task chain: the lock-screen indicator
        // must not lag an unkey (SF-4). `routeResumeInFlight` keeps it up for a
        // route-change recovery.
        refreshActivity()
        scheduleTransmitWork()
    }

    /// ``endTransmit(reason:)`` plus a wait for it to reach the client. A
    /// separate name, not an `async` overload, so no call site is ambiguous
    /// about which stop it got.
    func endTransmitAndWait(reason: TransmitStopReason) async {
        endTransmit(reason: reason)
        await settle()
    }

    /// Waits for all queued key-up/key-down work to be applied. Test support,
    /// and the one call `disconnect()` needs.
    func settle() async {
        var seen = -1
        while transmitWorkGeneration != seen {
            seen = transmitWorkGeneration
            await transmitWork?.value
        }
    }

    private func scheduleTransmitWork() {
        let previous = transmitWork
        transmitWorkGeneration += 1
        transmitWork = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyTransmit()
        }
    }

    private func applyTransmit() async {
        guard let link else {
            isTransmitting = false
            isKeyDown = false
            transmitDesired = false
            routeResumeInFlight = false
            routePreparationInFlight = false
            watchdogDeadline = nil
            refreshActivity()
            return
        }

        if transmitDesired {
            guard connection.isConnected, !isTransmitting else { return }
            do {
                // **BU-15: everything that moves the audio route happens
                // before anything is keyed.** Escalating the session policy and
                // opening the microphone both disturb the route; after keying,
                // SF-3 would drop the transmission they disturbed.
                //
                // BU-16: `settleRoute()` returns at once unless the route was
                // actually disturbed, so only the first over after a pause
                // pays the wait.
                routePreparationInFlight = true
                let preparationBegan = now()
                trace("prep")
                await audio.prepareForCapture()

                // Gain, then meter, then the wire, so the meter shows what
                // leaves. Audio thread, 50 times a second: bounded work only.
                //
                // **`onAir` is what makes opening the microphone early safe:**
                // nothing captured before the carrier reaches the wire.
                let gainBox = self.gainBox
                let meter = transmitMeter
                let onAir = OnAirGate()
                transmitMeter.reset()
                trace("mic")
                try audio.startCapture { frame in
                    guard onAir.isOpen else { return }
                    let amplified = gainBox.gain.apply(to: frame)
                    meter.note(amplified)
                    link.sendCapturedFrame(amplified)
                }

                await audio.settleRoute()
                routePreparationInFlight = false
                lastPreparationMilliseconds = Int(
                    now().timeIntervalSince(preparationBegan) * 1000)
                trace("prepped")

                // A release at either suspension above has already closed the
                // microphone and cleared the hold, and there is no carrier yet,
                // so a short tap never goes on air.
                guard transmitDesired, connection.isConnected else {
                    audio.stopCapture()
                    Diagnostics.keying(
                        "key-down abandoned: released while the audio route settled")
                    refreshActivity()
                    return
                }

                try await link.startTransmit()
                onAir.open()
                trace("carrier")
            } catch {
                // Fail closed: microphone shut, client unkeyed, button
                // released. The operator must make a fresh, deliberate press.
                routePreparationInFlight = false
                audio.stopCapture()
                await link.stopTransmit()
                transmitDesired = false
                isKeyDown = false
                isTransmitting = false
                // The hold ends here too, though this bypasses `endTransmit`:
                // a live hold could let an automatic resume re-key, and would
                // leave the lock-screen indicator with no way down.
                heldSource = nil
                holdBegan = nil
                routeResumeInFlight = false
                watchdogDeadline = nil
                lastStopReason = .transmitFailed
                transmitState = link.transmitState()
                refreshActivity()
                Diagnostics.keyingFailure("key-down FAILED: \(error)")
                present(title: "Could not transmit", message: "\(error)")
                return
            }
            isTransmitting = true
            keyDownsInCurrentHold += 1
            trace("onair")
            lastKeyDownRoute = Self.routeField(of: audio.audioStateDescription)
            lastCaptureStartMilliseconds = audio.lastCaptureStartMilliseconds
            Diagnostics.keying("key-down on air: \(audio.audioStateDescription)")
            // Each key-down, including a resume, starts its own watchdog.
            watchdogDeadline = now().addingTimeInterval(transmitTimeout.seconds)
            routeResumeInFlight = false
            transmitState = link.transmitState()
            refreshActivity()
        } else {
            // For the log only, so defensive applies do not log a key-up.
            let wasTransmitting = isTransmitting
            // Unconditional: a redundant stop costs nothing, a missed one is an
            // open microphone.
            audio.stopCapture()
            await link.stopTransmit()
            isTransmitting = false
            transmitState = link.transmitState()
            refreshActivity()
            // After the stop, to log the route with the engine down (BU-13).
            if wasTransmitting {
                Diagnostics.keying("key-up: \(audio.audioStateDescription)")
            }
        }
    }

    // MARK: - Scene phase and view lifetime

    /// The app left, or returned to, the foreground.
    ///
    /// Anything not fully active unkeys, `.inactive` included (control centre,
    /// a call banner, the app switcher). The connection survives (PD-2); only
    /// transmission stops, and it is never resumed without a fresh press.
    func setForeground(_ isForeground: Bool) {
        guard !isForeground else { return }
        endTransmit(reason: .appBackgrounded)
    }

    /// The view holding the PTT button went away.
    func viewDisappeared() {
        endTransmit(reason: .viewDisappeared)
    }

    // MARK: - SF-3

    private func handle(_ signal: AudioSessionSignal) {
        // Logged before the switch, so an ignored signal still leaves a trace
        // (BU-13).
        Diagnostics.route(
            "signal \(signal) isTransmitting=\(isTransmitting) "
                + "held=\(heldSource != nil) resumes=\(automaticResumes) "
                + "audio=\(audio.audioStateDescription)")
        switch signal {
        case .interruptionBegan:
            endTransmit(reason: .audioInterrupted)
        case .routeChanged:
            // BU-15: during preparation nothing is on air, so there is nothing
            // for SF-3 to drop; the key-down follows once the route settles.
            // See ``routePreparationInFlight``.
            if routePreparationInFlight, !isTransmitting {
                routeSignalsDuringPreparation += 1
                trace("sigPrep")
                Diagnostics.route(
                    "route change during preparation: nothing on air, key-down still pending")
                return
            }
            if isTransmitting { routeSignalsWhileTransmitting += 1 }
            trace(isTransmitting ? "sigTx" : "sigIdle")
            resumeAcrossRouteChange()
            // After `resumeAcrossRouteChange`, which decides whether a resume
            // is in flight.
            if isIdleForAccessoryRepair {
                onIdleAudioRouteChange?()
            }
        case .interruptionEnded:
            // Never resumes: `shouldResume` is about playback, and a radio must
            // not key itself because a call ended. The stop is repeated for
            // safety.
            endTransmit(reason: .audioInterrupted)
        }
    }

    /// SF-3 for a route change: transmission always stops. If the button is
    /// still held, this keys back down once the route settles; the safety
    /// banner is shown only when that cannot happen (no hold, no link, or a
    /// route that keeps changing).
    ///
    /// **Bounded:** after ``maximumAutomaticResumes`` in one hold it gives up
    /// and says so. Each resume starts its own SF-1 watchdog, and the watchdog
    /// ends the hold outright, so this cannot hold a transmitter open past the
    /// timeout.
    private func resumeAcrossRouteChange() {
        let resumable = heldSource.flatMap { source in
            connection.isConnected && automaticResumes < Self.maximumAutomaticResumes
                ? source : nil
        }

        // Set before the stop, since `endTransmit` refreshes the lock-screen
        // indicator (SF-4) and this tells it the hold is being repaired. If
        // unrecoverable, it stays false and the activity ends.
        routeResumeInFlight = resumable != nil
        endTransmit(reason: .routeChanged, explain: resumable == nil)
        guard let source = resumable else { return }

        automaticResumes += 1
        // Cancelled, not merely replaced: an earlier resume task must not key
        // back down after the budget has run out.
        resumeWork?.cancel()
        resumeWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.routeSettleNanoseconds)
            // `try?` swallows the cancellation, so a cancelled sleep returns
            // early and must be checked, or it would key back down. The
            // canceller has already cleared `routeResumeInFlight`.
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.heldSource == source, self.connection.isConnected else {
                // The hold or the link ended while settling: nothing will key
                // back down, so the indicator must stop saying so.
                self.routeResumeInFlight = false
                self.refreshActivity()
                return
            }
            self.beginTransmit(from: source)
        }
    }

    /// Where to turn the microphone back on, which differs by platform.
    private var micPermissionAdvice: String {
        #if os(iOS)
        return "Currawong cannot transmit without the microphone. Turn it on in Settings → "
            + "Currawong → Microphone, then connect again."
        #else
        return "Currawong cannot transmit without the microphone. Turn it on in System Settings "
            + "→ Privacy & Security → Microphone, then connect again."
        #endif
    }

    private func noteSafetyStop(_ reason: TransmitStopReason) {
        switch reason {
        case .watchdogExpired:
            break  // The event carries the timeout; handled where it arrives.
        case .audioInterrupted:
            safetyNotice = SafetyNotice(
                kind: .audioInterruption,
                message:
                    "Transmission stopped: the audio session was interrupted. Press and hold to "
                    + "transmit again.")
        case .routeChanged:
            safetyNotice = SafetyNotice(
                kind: .routeChange,
                message:
                    "Transmission stopped: the audio route changed. Press and hold to transmit "
                    + "again.")
        case .accessoryLinkLost:
            safetyNotice = SafetyNotice(
                kind: .accessoryLinkLost,
                message:
                    "Transmission stopped: the Bluetooth accessory disconnected, so its button "
                    + "could no longer be trusted to release. Currawong will reconnect to it.")
        default:
            break
        }
    }

    // MARK: - SF-4 (APP-3)

    /// What the lock screen should show right now, or `nil`. A pure function
    /// of session state, so no path has its own idea of how to take the banner
    /// down.
    ///
    /// **`isOnAir` follows ``isTransmitting`` only** — not ``isKeyDown`` or
    /// ``transmitDesired``, which lead the client — so it is neither red early
    /// nor red late.
    private var desiredActivity: TransmitActivityRequest? {
        guard connection.isConnected else { return nil }
        let channel = lastConnectedChannel ?? settings

        if isTransmitting, let source = activeSource {
            return TransmitActivityRequest(
                channel: channel.displayName,
                mode: channel.mode.displayName,
                state: TransmitActivityState(
                    isOnAir: true,
                    headline: "ON AIR",
                    detail: source.holdDescription,
                    holdBegan: holdBegan ?? now(),
                    watchdogDeadline: watchdogDeadline))
        }

        // A route-change recovery, mid-gap: not on air, but kept up rather
        // than blinking off under a held button.
        if routeResumeInFlight, let source = heldSource {
            return TransmitActivityRequest(
                channel: channel.displayName,
                mode: channel.mode.displayName,
                state: TransmitActivityState(
                    isOnAir: false,
                    headline: "NOT TRANSMITTING",
                    detail: source.isMomentary
                        ? "The audio route changed. Keying back down — keep holding."
                        : "The audio route changed. Keying back down.",
                    holdBegan: holdBegan ?? now(),
                    watchdogDeadline: nil))
        }

        // Nothing is keyed, so nothing is shown.
        //
        // **Open question (BU-10):** the activity is requested at key-down,
        // which for an accessory keying a backgrounded app is a background
        // request. `Activity.request` is documented as foreground-only; the app
        // is running (PD-2's `audio` mode), not suspended, which may or may not
        // count. If a device refuses, return a not-on-air state whenever
        // connected, so the activity is created at Connect in the foreground.
        return nil
    }

    /// Hands ``desiredActivity`` to the controller. Cheap and idempotent, so
    /// every transition calls it.
    private func refreshActivity() {
        activity.show(desiredActivity)
    }

    /// Waits for the lock-screen indicator to catch up. Test support only.
    func settleActivity() async {
        await activity.settle()
    }

    // MARK: - Link events

    private func startEventPump(for link: RadioLink) {
        let events = link.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event)
            }
            await self?.linkStreamEnded()
        }
    }

    private func handle(_ event: RadioLinkEvent) {
        switch event {
        case .connected(let codec):
            if connection == .connecting { connection = .connected }
            transmitState = link?.transmitState() ?? .receiving
            if let codec { negotiatedCodec = codec }

        case .transmitting, .receiving:
            transmitState = link?.transmitState() ?? transmitState

        case .dtmfReceived(let digit):
            receivedDTMF = Self.appending(digit, to: receivedDTMF)

        case .transmitWatchdogExpired(let timeout):
            // SF-1. The client has unkeyed itself; the app still has a
            // microphone open and a button that thinks it is held.
            endTransmit(reason: .watchdogExpired)
            // And possibly an accessory whose release will never arrive.
            onWatchdogUnkey?()
            safetyNotice = SafetyNotice(
                kind: .transmitWatchdog,
                message:
                    "Transmit watchdog: transmission was stopped automatically after "
                    + "\(Self.describe(timeout)). Release the button and press again to continue.")

        case .mediaRejected(let description):
            mediaWarning = description

        case .remoteStation(let callsign):
            receivingFrom = callsign

        case .disconnected(let reason):
            lastDisconnectReason = reason
            Task { @MainActor [weak self] in
                await self?.handleLinkLoss(reason: reason)
            }
        }
    }

    private func linkStreamEnded() async {
        await handleLinkLoss(reason: lastDisconnectReason)
    }

    /// The far end, or the transport, ended the call. Not reachable from a
    /// disconnect the operator asked for — that path has already set
    /// `.disconnecting` — so this is always news.
    private func handleLinkLoss(reason: String?) async {
        guard connection == .connected || connection == .connecting else { return }
        connection = .disconnecting
        await endTransmitAndWait(reason: .disconnecting)
        tearDownLink()
        connection = .disconnected
        transmitState = .idle
        routeResumeInFlight = false
        refreshActivity()
        lastDisconnectReason = reason
        present(
            title: "Disconnected",
            message: reason ?? "The connection to the node ended.")
    }

    // MARK: - Received audio

    private func startReceivePump(for link: RadioLink) {
        let stream = link.receivedAudio
        let audio = self.audio
        let window = Self.receiveActivityWindow
        let meter = self.receiveMeter
        let gainBox = self.receiveGainBox
        meter.reset()

        // Detached: playback locks and allocates 50 times a second, off the
        // main actor. Only the throttled activity note hops back.
        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            var lastNoted = Date.distantPast
            for await pcm in stream {
                // Gain read per frame, so a slider drag is heard at once; the
                // meter shows the amplified frame, as heard.
                let pcm = gainBox.gain.apply(to: pcm)
                audio.enqueuePlayback(pcm)
                meter.note(pcm)
                let arrival = Date()
                if arrival.timeIntervalSince(lastNoted) >= window / 2 {
                    lastNoted = arrival
                    // Bound first: capturing the weak `self` across the
                    // isolation boundary is an error under Swift 6.
                    guard let session = self else { return }
                    await MainActor.run { session.noteReceivedAudio(at: arrival) }
                }
            }
        }
    }

    /// Records inbound audio activity. Throttled by the caller, so the screen
    /// does not redraw 50 times a second.
    func noteReceivedAudio(at date: Date) {
        lastReceivedAudioAt = date
    }

    /// Whether audio is arriving as of `date`, which a `TimelineView` or a
    /// test supplies.
    func isReceivingAudio(asOf date: Date) -> Bool {
        guard let last = lastReceivedAudioAt else { return false }
        let age = date.timeIntervalSince(last)
        return age >= 0 && age < Self.receiveActivityWindow
    }

    /// For the view's `TimelineView`, which has no opinion about the clock.
    var isReceivingAudioNow: Bool { isReceivingAudio(asOf: now()) }

    // MARK: - DTMF (FR-1.5)

    /// Sends one DTMF digit to the node.
    ///
    /// **Does not key the radio:** DTMF travels as its own signalling frame,
    /// so a keypad press cannot put the operator on air. Refused, not queued,
    /// when unconnected.
    ///
    /// Upper-cases `a`–`d`: the library is strict about the alphabet and
    /// leaves normalising to the keypad's owner.
    func sendDTMF(_ digit: Character) async {
        guard let link, connection.isConnected else {
            present(
                title: "Not connected",
                message: "Connect to a node before sending DTMF.")
            return
        }

        // Not `Character(digit.uppercased())`, which traps when upper-casing
        // lengthens a character ("ß" → "SS").
        let uppercased = digit.uppercased()
        let normalised = uppercased.count == 1 ? Character(uppercased) : digit

        do {
            try await link.sendDTMF(normalised)
            sentDTMF = Self.appending(normalised, to: sentDTMF)
        } catch {
            present(title: "Could not send \(normalised)", message: "\(error)")
        }
    }

    /// Appends to a digit log, keeping the most recent ``dtmfLogLimit``.
    private static func appending(_ digit: Character, to log: String) -> String {
        let appended = log + String(digit)
        guard appended.count > dtmfLogLimit else { return appended }
        return String(appended.suffix(dtmfLogLimit))
    }

    // MARK: - Alerts

    /// The operator says they hold a licence (APP-33). Stored, so it is asked
    /// once per install.
    ///
    /// Does **not** begin transmitting: the press that raised the sheet is
    /// spent, and dismissing a dialogue must never key a radio. The next press
    /// transmits.
    func acknowledgeLicence() {
        acknowledgedLicenceVersion = LicenceAcknowledgement.currentVersion
        settingsStore.saveLicenceAcknowledgement(LicenceAcknowledgement.currentVersion)
        needsLicenceAcknowledgement = false
    }

    /// The operator declines (APP-33), keeping a receive-only radio. Nothing
    /// is stored, so the next press asks again.
    func declineLicence() {
        needsLicenceAcknowledgement = false
    }

    /// Dismisses the alert on screen and shows the next one waiting, if any.
    func dismissAlert() {
        alert = pendingAlerts.isEmpty ? nil : pendingAlerts.removeFirst()
    }

    func dismissSafetyNotice() {
        safetyNotice = nil
    }

    /// Says something to the operator, behind whatever is already being said.
    ///
    /// Queued, not assigned: SwiftUI does not re-present an alert whose value
    /// is replaced while showing, so a second message would be lost. Duplicates
    /// are dropped; `OperatorAlert` compares on its words for this.
    private func present(title: String, message: String) {
        let next = OperatorAlert(title: title, message: message)

        guard let showing = alert else {
            alert = next
            return
        }

        guard showing != next, !pendingAlerts.contains(next) else { return }
        pendingAlerts.append(next)
    }

    // MARK: - Teardown

    private func tearDownLink() {
        // Release the public proxy lease (APP-13). Here, not in `disconnect()`,
        // because both a hang-up and a dropped link end up here.
        releaseProxyLease()
        eventTask?.cancel()
        eventTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        link?.close()
        link = nil
        isTransmitting = false
        isKeyDown = false
        transmitDesired = false
        activeSource = nil
    }

    private static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return seconds == 1 ? "1 second" : "\(Int(seconds.rounded())) seconds"
    }
}

// MARK: - PTTSink

/// **The one consumer of every PTT input.** The accessory (PT-2/PT-3) and the
/// remote-command button (PT-4) reach the microphone only through here, so
/// every input shares ``RadioSession/endTransmit(reason:)``.
///
/// ## Releases are honoured unconditionally
///
/// No method checks that the input stopping is the one that started: an
/// unnecessary stop costs nothing, a swallowed one is an open microphone. An
/// accessory release while the on-screen button holds the key stops
/// transmission; the operator presses again.
extension RadioSession: PTTSink {

    func pttPressed(from source: PTTSource) {
        beginTransmit(from: source)
    }

    func pttReleased(from source: PTTSource, reason: TransmitStopReason) {
        endTransmit(reason: reason)
    }

    /// **PT-4.** A remote command with no release edge: press to key, press
    /// again to unkey.
    ///
    /// Tests `transmitDesired || isTransmitting`, not `isTransmitting` alone,
    /// so a second toggle before the client answers unkeys rather than
    /// latching.
    func pttToggled(from source: PTTSource) {
        if transmitDesired || isTransmitting {
            endTransmit(reason: .remoteCommandToggled)
        } else {
            beginTransmit(from: source)
        }
    }

    /// **SF-2.** The Bluetooth accessory's link dropped.
    ///
    /// Called by ``BLEPTTController`` on every disconnection, whether or not
    /// the accessory held the key; `endTransmit` is safe when nothing is
    /// transmitting and notes a reason only when it stopped something.
    func accessoryLinkLost() {
        endTransmit(reason: .accessoryLinkLost)
    }
}

/// A one-way latch the capture tap reads, and the key-down opens.
///
/// The microphone opens before the link is keyed (BU-15), so frames captured
/// while the route settles have no carrier; they are dropped here, before the
/// wire and the transmit meter.
///
/// Opened once from the main actor, read from the audio thread behind a lock,
/// as ``GainBox`` is. It cannot be closed again: the release path closes the
/// microphone, which is the stronger guarantee.
final class OnAirGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }
}
