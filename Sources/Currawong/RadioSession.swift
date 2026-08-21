// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation
import RadioCore

/// Everything Currawong knows how to do, with no view attached.
///
/// Holds no client and names no protocol. It used to be generic over
/// `Client: NetworkClient`, which was the only way to keep `IAX2Kit` out of
/// the app while `NetworkClient` has an `associatedtype Destination` and
/// therefore no existential form.
///
/// That parameter had to be *chosen* somewhere, and it was chosen in
/// `CompositionRoot` — so the app could hold an AllStarLink session or an M17
/// session, but never one of either. Supporting both meant removing it, and
/// removing it cost nothing: this type only ever used five operations on the
/// client, and ``RadioLink`` now carries those as closures. The view model is
/// still testable against a fake that opens no socket; the fake supplies
/// closures instead of conforming to `NetworkClient`.
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
    /// The identity is its own type rather than a third `String` so that it
    /// cannot be swapped with the secret at a call site — see
    /// ``OperatorIdentity``.
    /// The watchdog timeout is passed separately rather than travelling in the
    /// settings, because it is no longer a field of them: it is the operator's
    /// one app-wide limit (SF-1), and the factory is where it meets the library.
    /// The proxy is passed separately for the same reason and is `nil` for every
    /// mode but EchoLink — it is the operator's station infrastructure, resolved
    /// per session (APP-13), and never a field of a channel.
    typealias LinkFactory =
        @MainActor (
            NodeSettings, OperatorIdentity, LinkCredentials, TransmitTimeout,
            EchoLinkProxyRoute?
        ) throws -> RadioLink

    /// What a link is built with, beyond the settings and the identity.
    ///
    /// One type rather than a growing list of `String` parameters, because the
    /// two credentials here are not interchangeable and a call site that swapped
    /// them would compile: a node secret authenticates us *as an account*, and a
    /// Web Transceiver token stands for our *callsign* on a guest call (APP-11).
    /// Which one is used is the channel's business — see
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

    /// The node being connected to, and the form's working copy of it.
    ///
    /// **This is a draft, not the stored channel.** The connect form binds
    /// straight to it, so it holds half-typed hostnames and an unvalidated port
    /// for as long as the operator is editing.
    ///
    /// **BU-9: only ``saveDraft()`` writes it back into ``channels``.** It
    /// carries the id of the channel it was edited from, so the two can differ
    /// for as long as the operator likes; while they do, the difference is kept
    /// in ``drafts`` and survives selecting another channel and quitting the
    /// app. ``connect()`` *adds* a draft that is in no channel yet, because
    /// connecting to somewhere new plainly says it is a place the operator goes,
    /// but it never overwrites a channel that is already there.
    @Published var settings: NodeSettings

    /// Every saved channel and which one is selected (APP-4).
    ///
    /// Selecting one loads it into ``settings`` and fetches its secret; see
    /// ``select(_:)``. The list is persisted on every change rather than at
    /// quit, because there is no reliable "at quit" on iOS.
    @Published private(set) var channels: ChannelSet

    /// **BU-9.** Unsaved edits, keyed by the id of the channel they belong to.
    ///
    /// The whole of the pending state, and the reason it is this cheap: a draft
    /// *is* a ``NodeSettings`` carrying the id of the channel it came from, so
    /// storing one is storing a channel value that has not been asked to
    /// replace anything. An entry whose id is in no channel is a channel that
    /// has never been saved — a directory browse, or ``newChannel(_:)`` on a
    /// channel the operator then abandoned — and needs no special case.
    ///
    /// Written by ``stashDraft()`` and cleared, per channel, by ``saveDraft()``.
    /// Persisted alongside the list, and loaded in preference to the stored
    /// channel when its channel is the selected one: that is what makes an edit
    /// survive a quit.
    @Published private(set) var drafts: [UUID: NodeSettings]

    /// The secret, in memory only. It reaches the Keychain in ``connect()``
    /// and `UserDefaults` never.
    @Published var secret: String

    /// The Web Transceiver token (APP-11), in memory only, on the same terms as
    /// ``secret``: it reaches the Keychain in ``connect()`` and `UserDefaults`
    /// never.
    ///
    /// **App-wide, not per channel.** The portal issues one token per operator
    /// and it stands for their callsign on every WT-enabled node, so it is filed
    /// under the callsign (``NodeSettings/webTransceiverAccount(for:)``) and is
    /// *not* reloaded when the operator selects a different channel — unlike
    /// ``secret``, which is per channel and is. Typed or pasted for now; APP-12's
    /// portal login is what will fill it in.
    @Published var webTransceiverToken: String

    /// **EchoLink.** The account password issued with the operator's callsign
    /// (APP-12), in memory only and app-wide.
    ///
    /// EchoLink has always filed this under `echolink:<callsign>`, shared by
    /// every EchoLink channel with that callsign — so it was never a per-channel
    /// credential, and the settings screen is where it is now edited rather than
    /// mid-connect.
    ///
    /// **APP-14: this is the only copy.** It used to be mirrored into ``secret``
    /// whenever an EchoLink channel happened to be selected, and `connect()`
    /// sent `secret` — so the password that was actually used depended on which
    /// channel had been selected when it was typed, connecting could write a
    /// node secret over it, and the station browser read `secret` and got the
    /// empty string. Nothing mirrors now: ``credentialSecret(for:identity:)``
    /// reads this for an EchoLink connection, and the station browser is handed
    /// this too.
    @Published private(set) var echoLinkAccountPassword: String

    /// **APP-13.** The operator's own EchoLink proxy, if they run one.
    ///
    /// App-wide, edited on the settings screen, and persisted on change like the
    /// watchdog — a proxy is a thing an operator sets up once for their whole
    /// station. Empty means "find a public one", which is what most sessions do.
    /// It reaches a connection through ``ProxyPicker/route(privateProxy:privatePassword:)``,
    /// which prefers it over any public proxy and never overwrites it.
    @Published private(set) var echoLinkProxy: EchoLinkProxySettings

    /// The private proxy's password, in memory only, from the Keychain.
    ///
    /// In the Keychain and not `UserDefaults`, unlike the `PUBLIC` literal it
    /// replaces: a private proxy's password is a real credential, and the field
    /// it used to live in said as much in its own documentation while storing it
    /// in the defaults database anyway. Empty when no private proxy is set.
    @Published private(set) var echoLinkProxyPassword: String

    /// What the microphone is putting on the air, **after** ``transmitGain``.
    /// Post-gain because that is the number the operator is trying to set, and
    /// a meter reading the input while the gain changes what leaves would be
    /// actively misleading.
    ///
    /// Not `@Published`: it is written fifty times a second from the audio
    /// thread, and the views poll it instead. See ``AudioLevelMeter``.
    let transmitMeter = AudioLevelMeter()

    /// What is arriving from the far end.
    let receiveMeter = AudioLevelMeter()

    /// Software gain on captured audio (0 to +30 dB).
    ///
    /// App-wide rather than per channel, like the operator's identity: it
    /// compensates for this device and this voice, not for where the audio is
    /// going. Persisted on change, because an operator who finds their level
    /// and then loses it on relaunch has not been helped.
    @Published var transmitGain: TransmitGain {
        didSet {
            guard transmitGain != oldValue else { return }
            // The box is what the audio thread reads, so this is what makes a
            // slider drag audible in the same breath rather than the next one.
            gainBox.gain = transmitGain
            settingsStore.saveTransmitGain(transmitGain)
        }
    }

    /// The gain as the capture tap sees it. See ``GainBox``.
    private let gainBox = GainBox<TransmitGain>(.unity)

    /// Software gain on received audio (0 to +20 dB).
    ///
    /// App-wide and persisted like ``transmitGain``, and for the same kind of
    /// reason: it compensates for how loud this device gets in the room the
    /// operator is standing in, not for where the audio came from. What it is
    /// making up for is documented on ``ReceiveGain``.
    @Published var receiveGain: ReceiveGain {
        didSet {
            guard receiveGain != oldValue else { return }
            // The box is what the receive pump reads, so this is what makes a
            // slider drag audible in the same breath rather than the next one.
            receiveGainBox.gain = receiveGain
            settingsStore.saveReceiveGain(receiveGain)
        }
    }

    /// The receive gain as the playback pump sees it. See ``GainBox``.
    private let receiveGainBox = GainBox<ReceiveGain>(.unity)

    /// **SF-1.** How long one transmission may last before the library unkeys.
    ///
    /// App-wide rather than per channel — see ``TransmitTimeout`` for why that
    /// changed — and persisted on change like the gain, because a safety limit
    /// that quietly reverts to three minutes on relaunch is worse than no setting
    /// at all. It reaches the library through `CompositionRoot` when a link is
    /// built, so changing it mid-connection applies to the *next* connection; the
    /// settings screen says so.
    @Published var transmitTimeout: TransmitTimeout {
        didSet {
            guard transmitTimeout != oldValue else { return }
            settingsStore.saveTransmitTimeout(transmitTimeout)
        }
    }

    /// Who is operating. **App-wide, not per channel** — one callsign is used on
    /// every network, so the connect form edits this rather than a field of the
    /// selected channel. Persisted by ``connect()``, ``saveDraft()`` and
    /// ``stashDraft()`` — it is not part of a channel, so there is no such thing
    /// as an unsaved draft of it and every one of those is simply a moment when
    /// it can be written.
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

    /// **PT-4's honesty requirement.** Which input keyed the radio, while it is
    /// keyed. `nil` when nothing is.
    ///
    /// This exists so the transmit banner can say whether letting go will
    /// unkey. The on-screen button and a Bluetooth accessory are momentary; a
    /// remote-command button latches, and an operator who has to remember which
    /// is which is an operator who will eventually leave a microphone open.
    @Published private(set) var activeSource: PTTSource?

    /// The codec the far end agreed to, as a name to display. `nil` until a
    /// connection reports one.
    @Published private(set) var negotiatedCodec: String?

    /// DTMF digits sent and received on this connection, oldest first.
    ///
    /// Kept because commanding an AllStar node means sending a digit string and
    /// watching for what comes back, and "did that go out?" is otherwise
    /// unanswerable from the app. Trimmed to ``dtmfLogLimit``: this is a recent
    /// history for the operator's eyes, not a record.
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

    /// The last reason transmission ended. Diagnostic, and what the tests
    /// assert against to prove each release path is wired up.
    @Published private(set) var lastStopReason: TransmitStopReason?

    /// When the last frame of received audio arrived.
    @Published private(set) var lastReceivedAudioAt: Date?

    /// Why the link went away, when it went away by itself.
    @Published private(set) var lastDisconnectReason: String?

    /// Inbound media the client is discarding, if any.
    @Published private(set) var mediaWarning: String?

    /// The channel the last call this run was actually placed to, or `nil`
    /// before the first one.
    ///
    /// What the session pane's Reconnect button goes back to
    /// (``SessionLinkControl``). Set on a **successful** connect only, so the
    /// button never offers to return to somewhere that refused us; the draft is
    /// not good enough for the purpose, because an operator may pick a different
    /// channel after hanging up and the button would then quietly mean somewhere
    /// else.
    ///
    /// It holds the channel as the operator typed it — the pre-resolution copy —
    /// so a name stays a name; see ``resolveDirectoryServer(in:)``.
    ///
    /// Deliberately in memory only. `SettingsStore` already remembers the last
    /// connected node across launches and the draft loads from it, so persisting
    /// this too would put a Reconnect button in front of an operator who has not
    /// connected to anything yet this run — offering to place a call they have
    /// not asked for, which is not a button an app that keys transmitters should
    /// grow on its own.
    @Published private(set) var lastConnectedChannel: NodeSettings?

    /// The station currently transmitting on a shared channel, when one is.
    ///
    /// **M17 only** — a reflector module is shared and an AllStarLink call is
    /// not, so this stays `nil` for the whole of an AllStar connection. `nil`
    /// while an M17 link is up means nobody is transmitting, which is the
    /// ordinary quiet state of a module.
    @Published private(set) var receivingFrom: String?

    // MARK: - Dependencies

    private let audio: AudioIO
    private let settingsStore: SettingsStore
    private let secretStore: SecretStore
    private let makeLink: LinkFactory

    /// **APP-13.** Gives up the leased public proxy when a link ends.
    ///
    /// A closure rather than a reference to ``ProxyPicker``, so this type keeps
    /// knowing nothing about probing strangers' machines — it knows only that
    /// something borrowed has to be returned when the session that borrowed it is
    /// over. `CompositionRoot` wires it; the tests can watch it.
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

    /// Where the *hold* came from, as distinct from ``activeSource``, which is
    /// where the current transmission came from.
    ///
    /// They differ for exactly as long as it takes to recover from a route
    /// change: transmission has stopped (SF-3) but the operator has not let go,
    /// so there is still a hold to key back down. Cleared by every stop reason
    /// but that one — see `TransmitStopReason.leavesTheHoldAlive`.
    private var heldSource: PTTSource?

    /// Automatic key-downs used by the current hold. Reset by a press the
    /// operator makes; never by one this class makes.
    private var automaticResumes = 0

    private var resumeWork: Task<Void, Never>?

    /// **SF-4.** The lock-screen half of the transmit indicator (APP-3).
    ///
    /// Driven from exactly one place — ``refreshActivity()``, called from every
    /// transition that could change whether the radio is keyed — rather than
    /// from each release path in turn. A per-path teardown is a teardown
    /// somebody eventually forgets to add, and the thing they would be
    /// forgetting is an activity that goes on claiming TX.
    private let activity: TransmitActivityController

    /// Whether a route-change recovery is between the stop and the key-down.
    ///
    /// The one state in which there is a live hold, nothing on air, and an
    /// activity that must *stay up* — ending and restarting it around a 300 ms
    /// gap would flicker the lock screen off and back on under a button the
    /// operator never released. Tracked explicitly rather than inferred from
    /// ``heldSource``, because a route change that cannot be recovered from also
    /// leaves the hold alive and must **not** keep the activity.
    private var routeResumeInFlight = false

    /// When the current hold began, for the activity's elapsed clock. Survives
    /// a route-change resume, so the clock measures the over rather than the
    /// key-down.
    private var holdBegan: Date?

    /// When the library's watchdog will unkey the current key-down (SF-1).
    /// Re-set on every key-down, including an automatic resume, because each one
    /// starts its own watchdog.
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
        // Not a default argument expression like the two above: the controller
        // is `@MainActor` and a default argument is evaluated in a nonisolated
        // context. `nil` means "no lock-screen indicator", which is what macOS,
        // a preview and most of the tests want; `CompositionRoot` passes a real
        // one on iOS.
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

        // **BU-9's other half.** The stash is loaded before the draft is chosen,
        // because the draft is chosen *from* it. Deduplicated by keeping the last
        // entry for an id rather than trapping: a stash is a convenience, and a
        // defaults blob that somehow holds two drafts for one channel must not be
        // a launch that crashes.
        let storedDrafts = settingsStore.loadDrafts() ?? []
        let allDrafts = Dictionary(
            storedDrafts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        // Drafts for channels that are not in the list are dropped **here, at
        // launch**, and this is the one place they are not kept.
        //
        // A draft is reached by selecting the channel it belongs to, and nothing
        // stored says which draft was the one on screen — so an orphan cannot be
        // reached again after a quit and would sit in the defaults for ever.
        // Within a run they work perfectly well (a directory browse is exactly
        // that: a draft that belongs to no channel yet), which is why they are
        // stashed rather than refused; it is only the launch that cannot find
        // them again.
        let liveDrafts = allDrafts.filter { id, _ in loaded.channels.contains { $0.id == id } }
        self.drafts = liveDrafts
        if liveDrafts.count != allDrafts.count {
            settingsStore.saveDrafts(Array(liveDrafts.values))
        }

        // An operator with no channels at all gets an empty draft to fill in,
        // which is the same thing the app did before it had a channel list.
        //
        // The stash wins over the stored channel where there is one: an edit that
        // was never saved is what the operator was last looking at, and BU-9 is
        // the report of it being thrown away on quit.
        let stored = loaded.selected ?? NodeSettings()
        let current = liveDrafts[stored.id] ?? stored
        self.settings = current

        // Before the secret is fetched: for two of the three modes the Keychain
        // account is derived from the callsign, so an identity loaded after this
        // would look the secret up under `echolink:` with nothing after the
        // colon and come back empty.
        let identity = settingsStore.loadIdentity() ?? .empty
        self.identity = identity
        let storedGain = settingsStore.loadTransmitGain() ?? .unity
        self.transmitGain = storedGain
        self.gainBox.gain = storedGain
        self.transmitTimeout = settingsStore.loadTransmitTimeout() ?? .default
        let storedReceiveGain = settingsStore.loadReceiveGain() ?? .unity
        self.receiveGain = storedReceiveGain
        self.receiveGainBox.gain = storedReceiveGain
        // Not `storedSecret(for:)`: an instance method cannot be called until
        // every property is initialised. The rule is the same one spelled out —
        // a channel's own secret is loaded, an app-wide one is not (APP-14),
        // because `echoLinkAccountPassword` below is where that one lives.
        if case .channel(let account) = current.secretOwnership(for: identity) {
            self.secret = (try? secretStore.secret(for: account)) ?? ""
        } else {
            self.secret = ""
        }
        // Loaded regardless of the selected channel's mode: the token belongs to
        // the operator rather than to a channel, so it is there for whichever
        // channel they switch to next.
        self.webTransceiverToken =
            (try? secretStore.secret(for: current.webTransceiverAccount(for: identity))) ?? ""
        self.echoLinkAccountPassword =
            (try? secretStore.secret(for: NodeSettings.echoLinkAccount(for: identity))) ?? ""

        // **APP-13's migration.** A channel written by an earlier build kept the
        // proxy in its own fields; `loadEchoLinkProxy()` is what rescues a
        // *private* one out of those blobs and discards a public one. When it
        // comes back with a harvested password, this is the launch that has to
        // file it — in the Keychain, where it now belongs — and save the settings
        // under their own key so the harvest does not run again.
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
    ///
    /// The settings screen is not a connect form: an operator who has just
    /// fetched a token and switched away expects it to still be there, and
    /// waiting for a connection to persist it would lose it. Trimmed, because a
    /// pasted token arrives with whatever the clipboard had around it.
    ///
    /// Failing to write is reported and not fatal, exactly as in ``connect()``:
    /// the token is still usable from memory for this run.
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

    /// Stores the EchoLink account password. The one place it is written.
    ///
    /// **APP-14 removed the mirror into ``secret``.** It was there because
    /// `connect()` sent `secret`, and it ran only `if settings.mode == .echoLink`
    /// — so which password a connection used depended on which channel was
    /// selected at the moment this was typed. Now `connect()` reads
    /// ``echoLinkAccountPassword`` for an EchoLink channel and there is nothing
    /// to keep in step.
    ///
    /// **Trimmed.** A password pasted with a trailing newline passed every
    /// emptiness check and every "Stored in the Keychain" indicator, and then
    /// failed the digest at the directory server — which presents as a password
    /// that is right but rejected. The Web Transceiver token is trimmed for the
    /// same reason; see ``saveWebTransceiverToken(_:)``.
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

    /// **APP-13.** Stores the operator's own EchoLink proxy: host and port in
    /// `UserDefaults`, password in the Keychain.
    ///
    /// One call for both halves, because they are one setting and a proxy stored
    /// without its password is a proxy that refuses every session. Validated
    /// here rather than at connect time, so a pasted URL is refused while the
    /// operator is looking at the field.
    ///
    /// Clearing the host clears the password with it — a stored password for a
    /// proxy that is no longer configured is a credential kept for nothing.
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
            // Not fatal, and said the way the other two credentials say it: the
            // proxy works for this run from memory, and the operator needs to
            // know it will not be there next time rather than to find out then.
            return
                "\(error) The proxy will work for this run, but its password was not stored — you "
                + "will have to type it again next time."
        }
        return nil
    }

    // MARK: - Channels (APP-4)

    /// Switches to a saved channel, loading its details and its secret.
    ///
    /// **Refused while a link is up.** Changing the destination under a live
    /// connection would leave the form describing one node and the audio coming
    /// from another, and the operator's next glance at the screen would be
    /// wrong. Disconnect first; the UI disables the list rather than relying on
    /// this, and this is the backstop.
    func select(_ id: UUID) {
        guard connection == .disconnected else { return }
        // Already selected *and* already in the form: nothing to do. The second
        // half is not redundant — ``chooseChannel(_:)`` points the draft at a
        // directory entry without moving the selection, so the highlighted row
        // and the form can be describing different places, and tapping the
        // highlighted row is then the operator asking to go back to it. Without
        // this it was the one tap in the list that did nothing.
        guard id != channels.selectedID || settings.id != id else { return }
        guard channels.channels.contains(where: { $0.id == id }) else { return }

        stashDraft()
        channels.select(id)
        loadSelectedIntoDraft()
        persistChannels()
    }

    /// Whether the draft differs from the channel it belongs to — the one
    /// question the Save action and the "unsaved changes" indicator are asking
    /// (BU-9).
    ///
    /// A draft whose id is in no channel is a channel that has never been saved,
    /// and counts as dirty because saving it is the only thing that would put it
    /// in the list. The exception is an **untouched blank form**: the app opens
    /// on one when there are no channels at all, and telling an operator who has
    /// done nothing that they have unsaved changes would make the indicator
    /// worthless everywhere else.
    var isDraftDirty: Bool {
        if let stored = channels.channels.first(where: { $0.id == settings.id }) {
            return stored != settings
        }
        return settings != NodeSettings(id: settings.id)
    }

    /// Whether a channel in the list has an edit waiting that it does not
    /// contain. What ``ChannelListView`` marks a row with, so the list is honest
    /// about showing the *stored* channel while the form shows something else.
    /// Whether the draft is somewhere that is **not in the channel list at all**
    /// — a directory browse, or an `Add channel` that has not been saved or
    /// connected yet.
    ///
    /// The distinction matters to what the form is allowed to say. Connecting
    /// *adds* a draft like this one, so telling the operator their channels are
    /// unchanged until they save would be false; connecting with edits to a
    /// channel that is already stored leaves it alone, so there the same sentence
    /// is the whole point. One rule, two honest descriptions of it.
    var isDraftAnUnsavedChannel: Bool {
        !channels.channels.contains { $0.id == settings.id }
    }

    func hasUnsavedEdits(for id: UUID) -> Bool {
        if id == settings.id { return isDraftDirty }
        guard let draft = drafts[id] else { return false }
        return channels.channels.first(where: { $0.id == id }) != draft
    }

    /// **Save. The only thing in the app that overwrites a stored channel**
    /// (BU-9), and it only ever runs because the operator asked it to.
    ///
    /// Writes the draft over the channel it came from and drops the pending
    /// edit, because there is no longer a difference to remember. A draft whose
    /// id is in no channel is *added* rather than silently discarded: Save is
    /// the operator saying "keep this", and a Save button that does nothing on a
    /// channel picked out of a directory would be the same class of fault BU-9
    /// reports.
    ///
    /// Unvalidated on purpose — an operator part-way through typing a host may
    /// still want to keep what they have, and refusing would lose it.
    /// ``connect()`` is where the validation gate is.
    func saveDraft() {
        if channels.channels.contains(where: { $0.id == settings.id }) {
            channels.update(settings)
        } else {
            channels.add(settings)
        }
        drafts[settings.id] = nil
        persistChannels()
        persistDrafts()

        // The identity travels with the draft rather than only with a
        // connection, so a callsign typed and then never connected with is
        // still there on the next launch. Stored as typed — validation, and
        // therefore uppercasing, happens at `connect()`.
        settingsStore.saveIdentity(identity)
    }

    /// Keeps the draft without saving it: the channel list is left exactly as it
    /// was, and the difference is remembered in ``drafts``.
    ///
    /// **This is what replaced the implicit save** BU-9 reported. Every path that
    /// moves the operator away from the draft — selecting another channel, adding
    /// one, pointing at a directory entry, going back to the last connected
    /// channel, and the app leaving the foreground — calls this. None of them
    /// touches the list, so none of them can overwrite a channel the operator
    /// did not ask to change, and none of them can lose what was typed either.
    ///
    /// Idempotent, and cheap enough to call on a state that is not dirty: a
    /// clean draft *clears* any stale stash for its channel, because there is
    /// then nothing to remember and a leftover entry would make the list mark a
    /// row that matches what the form shows.
    func stashDraft() {
        drafts[settings.id] = isDraftDirty ? settings : nil
        persistDrafts()

        // Saved here as well as in `saveDraft()`, and for the reason given
        // there: the callsign is app-wide rather than part of a channel, so it
        // is not a thing there could be an unsaved draft *of*. Stashing is
        // simply the moment we happen to be passing.
        settingsStore.saveIdentity(identity)
    }

    /// **`Add channel`.** Points the draft at a new, blank channel — and writes
    /// nothing to the list.
    ///
    /// ## APP-19
    ///
    /// This used to add the blank channel to the list, select it and persist it,
    /// on the reasoning that "adding is itself the operator asking". It is the
    /// only place in the app that could put an empty channel into storage, and it
    /// did: **one tap of `+` left a permanent "Unnamed channel" with no host,
    /// which nothing could connect to and only Delete could remove.** Nothing
    /// warned about it either — ``isDraftAnUnsavedChannel`` is false for a row
    /// that *is* in the list, so the form's own "Not saved" line stayed dark and
    /// Save stayed disabled, because a blank draft equal to a blank stored
    /// channel is not dirty.
    ///
    /// The rows the 2026-08-20 handoff called "leftovers of an older run" were
    /// exactly this: the on-air UI tests click `Add channel` against the real
    /// defaults, and a run that died between the click and the naming left one
    /// behind every time.
    ///
    /// So `+` now does what a directory browse does — see ``chooseChannel(_:)``,
    /// which this is otherwise identical to. **The channel reaches the list when
    /// it is saved or connected to**, which is BU-9's rule with nothing carved
    /// out of it: a channel is a working copy, Save is the only thing that
    /// overwrites one, and connecting adds where it went.
    ///
    /// The cost, stated plainly: a new channel that is typed into and neither
    /// saved nor connected **does not survive a quit**, exactly as a reflector
    /// picked out of the directory does not. That is the trade BU-9 already
    /// accepted for browsing, and the form says so on screen — "Not saved.
    /// Connecting will add this to your channels" — as soon as there is anything
    /// to lose.
    ///
    /// Still refused while connected, for the reason ``select(_:)`` is: it moves
    /// where the form is pointed, and doing that mid-call would leave the form
    /// describing one place and the audio coming from another.
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

    /// **APP-22.** Throws away a draft that is in no channel, and puts the form
    /// back on the selected channel.
    ///
    /// What the provisional row's Discard does. Not ``deleteChannel(_:)``, which
    /// takes an id out of the stored list — there is nothing stored here to take
    /// out, and calling it with this draft's id would be a no-op that left the
    /// row on screen.
    ///
    /// A no-op when the draft *is* a stored channel: there the row is the
    /// channel, and removing it is Delete's job.
    ///
    /// - Returns: whether anything was discarded.
    @discardableResult
    func discardDraftChannel() -> Bool {
        guard connection == .disconnected, isDraftAnUnsavedChannel else { return false }

        // Its pending edit goes with it. A draft is only ever reached by way of
        // the channel it belongs to, and this one belongs to none — so leaving it
        // in the stash would leave something unreachable in the defaults, which
        // is the reason BU-9 prunes those at launch anyway.
        drafts[settings.id] = nil
        persistDrafts()
        loadSelectedIntoDraft()
        return true
    }

    /// Points the draft at somewhere chosen from a directory, **without saving
    /// it**.
    ///
    /// This used to be the only path that did not write to the list, and the
    /// difference from `Add channel` was the whole reason it existed. Browsing a
    /// directory is looking around, and looking around should not leave anything
    /// behind: an operator who taps six reflectors to read their modules used to
    /// get six saved channels, and tapping the same one twice got two. What saves
    /// a channel is ``saveDraft()`` or ``connect()`` — the channel list then
    /// means "places I have actually been", which is the only definition that
    /// stays useful. **Since APP-19 ``newChannel(_:)`` works the same way**, and
    /// the only thing left here that is particular to a directory is the
    /// same-place check below.
    ///
    /// Nothing here writes to the list, and since BU-9 that is the ordinary
    /// state of the app rather than a special case this one call tolerates: an
    /// unsaved draft is kept in ``drafts``, survives a quit, and reaches the list
    /// only through ``saveDraft()`` or through connecting to somewhere that is
    /// not in it yet.
    ///
    /// - Returns: whether the draft now points at `channel`. `false` means a
    ///   link is up and nothing changed.
    @discardableResult
    func chooseChannel(_ channel: NodeSettings) -> Bool {
        // Same rule as `select(_:)` and `newChannel(_:)`: changing where we are
        // pointed mid-call would leave the form describing one place and the
        // audio coming from another.
        guard connection == .disconnected else { return false }

        // The draft being replaced may be a real channel with unsaved edits, and
        // they are kept without being applied to it.
        stashDraft()

        // Already in the list? Select it rather than making a second copy of
        // it. Two channels for one module are indistinguishable in the list and
        // an operator cannot tell which one they are editing.
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

    /// Deletes a channel.
    ///
    /// **The Keychain secret is left alone.** A deleted channel's secret is
    /// keyed by `secretAccount`, which other channels may share — every
    /// EchoLink channel for one callsign does, by construction — so deleting
    /// the item here would log the operator out of channels they did not touch.
    /// An orphaned Keychain item is invisible and harmless; a lost password is
    /// neither.
    ///
    /// **Its pending draft goes with it** (BU-9). The opposite of the Keychain
    /// rule, and for the opposite reason: a draft is only ever reached by
    /// selecting the channel it belongs to, so one for a channel that no longer
    /// exists is unreachable — it would sit in the defaults for ever, and the
    /// only way it could ever surface again is a new channel colliding with its
    /// UUID. Deleting a channel is also the clearest possible statement that the
    /// operator does not want it, unsaved edits included.
    func deleteChannel(_ id: UUID) {
        guard connection == .disconnected else { return }

        let wasSelected = channels.selectedID == id
        channels.remove(id)
        drafts[id] = nil
        persistDrafts()
        if wasSelected { loadSelectedIntoDraft() }
        persistChannels()
    }

    /// Reorders the channel list.
    ///
    /// The one channel operation with no "only while disconnected" guard, and
    /// deliberately: reordering changes nothing about which channel is selected
    /// or what it points at, so there is nothing here for a live connection to
    /// be inconsistent with.
    func moveChannels(fromOffsets source: IndexSet, toOffset destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
        persistChannels()
    }

    /// Replaces the draft and the in-memory secret from the selected channel —
    /// or from that channel's **pending draft**, where there is one (BU-9).
    ///
    /// The stash is preferred so that leaving a channel and coming back to it
    /// shows what was typed rather than what was stored. The secret is read for
    /// whichever of the two won, because a draft may have been re-pointed at a
    /// different account than the channel it came from.
    /// **APP-14.** What the station browser needs in order to ask the directory
    /// server for a listing.
    ///
    /// It exists so that *which* password goes to the directory server is
    /// decided here, next to the two fields, rather than in a view — which is
    /// where it was decided wrongly: `StationBrowserView` asked for
    /// `session.secret`, the channel's own secret, and got the empty string in
    /// the ordinary case. A view reaching for one of two similarly named
    /// properties is a mistake nothing could catch; a named request is testable.
    struct DirectoryRequest: Equatable {
        let settings: NodeSettings
        let identity: OperatorIdentity
        /// The **app-wide** EchoLink account password (APP-12), which is the only
        /// credential a directory login has ever used.
        let accountPassword: String
    }

    var directoryRequest: DirectoryRequest {
        DirectoryRequest(
            settings: settings, identity: identity, accountPassword: echoLinkAccountPassword)
    }

    /// **APP-14.** Which password a link is built with.
    ///
    /// For AllStarLink it is the channel's own, as typed into the form. For
    /// EchoLink it is the *app-wide* account password the settings screen owns —
    /// **not** the form's `secret`, which under the old code was whatever the
    /// previously selected channel had left there. Switching a draft from
    /// AllStarLink to EchoLink and connecting sent a node secret to the
    /// directory server as an account password, which fails to authenticate and
    /// reads to the operator as "my EchoLink password is wrong".
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
    /// own.
    ///
    /// **An app-wide password is not loaded here** (APP-14). It lives in
    /// ``echoLinkAccountPassword``, which is loaded once at launch and written
    /// only by the settings screen; copying it into `secret` as well is what let
    /// the two disagree, and what let a connect write one over the other.
    private func storedSecret(for settings: NodeSettings) -> String {
        switch settings.secretOwnership(for: identity) {
        case .channel(let account):
            return (try? secretStore.secret(for: account)) ?? ""
        case .appWide, .none:
            return ""
        }
    }

    private func loadSelectedIntoDraft() {
        let stored = channels.selected ?? NodeSettings()
        let current = drafts[stored.id] ?? stored
        settings = current
        secret = storedSecret(for: current)
    }

    private func persistChannels() {
        channels.save(to: settingsStore)
    }

    /// Writes the stash out. Persisted on every change rather than at quit, for
    /// the reason the channel list is: there is no reliable "at quit" on iOS, and
    /// the scene-phase hook is a second chance rather than the only one.
    private func persistDrafts() {
        settingsStore.saveDrafts(Array(drafts.values))
    }

    // MARK: - Lifecycle

    /// Starts observing SF-3 signals. Idempotent; called from the root view's
    /// `.task`, and directly by tests.
    ///
    /// This runs for the app's lifetime, not the connection's: an interruption
    /// that arrives while connecting must still be seen, and the pipeline's
    /// stream is created once.
    func start() {
        guard signalTask == nil else { return }
        // **SF-4, the app-termination path.** A Live Activity outlives the
        // process that requested it, so a Currawong killed mid-over leaves a
        // banner claiming TX with nothing behind it. This is the launch that
        // clears it, and it runs before anything can key up.
        activity.adopt()
        let signals = audio.signals
        signalTask = Task { @MainActor [weak self] in
            for await signal in signals {
                self?.handle(signal)
            }
        }
    }

    // MARK: - Connecting

    /// - Parameter proxy: the proxy an EchoLink session is to tunnel through,
    ///   already resolved by ``ProxyPicker`` — `nil` for the other two modes.
    ///   Passed in rather than read from the settings because a proxy is not part
    ///   of a channel (APP-13), and passed at the moment of connecting rather
    ///   than held on this object because that is the moment it is true: a public
    ///   proxy is leased for one sitting.
    func toggleConnection(proxy: EchoLinkProxyRoute? = nil) async {
        switch connection {
        case .disconnected: await connect(proxy: proxy)
        case .connected: await disconnect()
        case .connecting, .disconnecting: break
        }
    }

    /// Validates, persists, and places the call.
    ///
    /// The audio session is configured *before* the call goes out, and a
    /// failure there aborts the connection rather than being noted and
    /// ignored. A connection whose microphone will never open is a PTT button
    /// that lights up and transmits nothing, and the operator would have no
    /// way to tell that from a quiet channel.
    func connect(proxy: EchoLinkProxyRoute? = nil) async {
        guard connection == .disconnected else { return }

        // Two validations, because there are now two things being validated:
        // where we are going, and who we are. The identity goes first — it is
        // app-wide, so a missing callsign is wrong for every channel rather
        // than for this one, and reporting a channel problem first would send
        // the operator to the wrong field.
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

        // Written back so the field shows what was actually used — the
        // uppercased, trimmed form that went on the air.
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

        // A Web Transceiver call carries the token in place of a node secret
        // (APP-11), so an empty one is the same class of problem as an empty
        // host: nothing further can succeed. Checked here rather than in
        // `NodeSettings.validated()` because the token is a credential and this
        // type holds none — it is the same split as the secret.
        //
        // Only emptiness is refused. A token of an unfamiliar shape is passed on,
        // for the reason `isPlausibleWebTransceiverToken` documents: the node is
        // what decides, and the form has already said it looks wrong.
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

        // **Connecting may add a channel; it never overwrites one** (BU-9).
        //
        // The add is deliberate and worth keeping: an operator who typed a node
        // into an empty app, or picked a reflector out of the directory, and
        // pressed Connect has plainly said "this is a place I go", and making
        // them press Save as well would be a second step for a decision they
        // already made.
        //
        // What is gone is the other branch. Connecting used to write the draft
        // over the channel it came from, which is how this app repointed a
        // channel called `M17-432 H` at a different reflector while looking like
        // it had done nothing. An edit to a channel that is already in the list
        // now stays a pending draft until `saveDraft()` is asked for, and the
        // list goes on describing where it actually goes.
        if !channels.channels.contains(where: { $0.id == validated.id }) {
            channels.add(validated)
            persistChannels()
        }

        // Either way the draft is stashed, which does the right thing in both
        // cases: for a channel just added there is no difference left to
        // remember and the stash is cleared, and for an edited channel the
        // validated form of the edit is what is kept.
        stashDraft()

        // The single-node key too, so a downgrade — or a build of the app from
        // before APP-4 — still finds the node that was last connected to.
        settingsStore.save(validated)

        do {
            if validated.usesWebTransceiver {
                webTransceiverToken = trimmedToken
                try secretStore.setSecret(
                    trimmedToken, for: validated.webTransceiverAccount(for: validatedIdentity))
            }

            // **APP-14.** What gets written is decided by whose secret it is —
            // see ``NodeSettings/SecretOwnership``. The old branch asked only
                // "is this Web Transceiver?" and wrote the form's `secret` to
            // `secretAccount(for:)` for everything else, which wrote an empty
            // string for M17 and wrote over the settings screen's EchoLink
            // password for EchoLink.
            switch validated.secretOwnership(for: validatedIdentity) {
            case .channel(let account):
                // **Never empty.** `SecretStore` deletes on an empty value, and
                // the account string is shared by every channel with the same
                // username, host, port and node — so connecting with the field
                // blank would take another channel's password with it. That was
                // already the stated reason the Web Transceiver arm left this
                // slot alone; it is the same reason here.
                guard !secret.isEmpty else { break }
                try secretStore.setSecret(secret, for: account)

            case .appWide:
                // EchoLink. The settings screen owns this password (APP-12) and
                // connecting only *reads* it — see `credentialSecret` below.
                break

            case .none:
                // M17, and a Web Transceiver channel whose token is written
                // above. Nothing to store, so nothing is written and nothing can
                // fail: the "could not save the secret" alert stops appearing on
                // the happy path of a mode that has no secrets.
                break
            }
        } catch {
            // Not fatal: the connection can proceed with the credential held in
            // memory. Saying so is better than silently forgetting it.
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

        // Before the session, not after: this is the call that makes iOS show
        // the microphone prompt, and nothing downstream can ask on its own —
        // see `AudioIO.requestRecordPermission()` for why the capture path
        // cannot bootstrap it. Refusing to connect without the microphone is
        // deliberate. A connected node with a dead transmit path is the worst
        // of both: it looks like a working QSO right up until the moment
        // somebody needs to hear you.
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

        // The directory server may be a host name, and the library takes four
        // octets. Resolved here rather than in the link factory because that is
        // synchronous and a DNS lookup is not — and resolved into a *copy*, so
        // what gets saved as a channel stays the name the operator typed. An
        // address cached in a channel would go stale silently; the name will
        // not.
        let resolved: NodeSettings
        do {
            resolved = try await resolveDirectoryServer(in: validated)
        } catch {
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
            tearDownLink()
            connection = .disconnected
            present(title: "Could not connect", message: "\(error)")
            return
        }

        connection = .connected
        transmitState = newLink.transmitState()
        // Recorded here, not earlier: this is the first line at which a call is
        // known to have been answered, and Reconnect must mean "back to where I
        // just was" rather than "retry the thing that failed".
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

        // Still in the list — the normal case, since `connect()` puts it there.
        // Going through `select(_:)` keeps the channel list's selection and the
        // draft in step, which setting `settings` alone would not.
        if channels.channels.contains(where: { $0.id == last.id }) {
            select(last.id)
            return channels.selectedID == last.id
        }

        // Deleted since. The draft can still describe it — an unsaved draft is a
        // supported state (see `chooseChannel(_:)`) — and refusing to reconnect
        // because a list entry went away would be a worse answer than calling
        // the place the operator was just talking to.
        //
        // Stashed, not saved: going back to where the last call went is not the
        // operator asking for the channel they are leaving to be rewritten.
        stashDraft()
        settings = last
        secret = storedSecret(for: last)
        return true
    }

    /// A copy of `settings` whose directory server is an address rather than a
    /// name.
    ///
    /// Only EchoLink has a directory server, and an empty one means "do not log
    /// in to the directory" — a supported way to run — so both of those return
    /// unchanged rather than resolving nothing.
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
    ///
    /// `source` is recorded so the UI can tell the operator whether letting go
    /// will unkey (PT-4). It has a default because the on-screen button is the
    /// caller that has no choice about it.
    ///
    /// A press with no connection is only worth an alert when the operator is
    /// looking at the button they just pressed. A Bluetooth fob or a headset
    /// button pressed in a pocket must not stack up modal alerts — it gets the
    /// same refusal, silently.
    func beginTransmit(from source: PTTSource = .onScreen) {
        guard connection.isConnected else {
            if source == .onScreen {
                present(
                    title: "Not connected",
                    message: "Connect to a node before transmitting.")
            }
            return
        }
        guard !transmitDesired else { return }

        safetyNotice = nil
        // A press the operator made, rather than one this class made for them,
        // starts a fresh hold — and a fresh allowance of automatic resumes.
        if heldSource == nil { automaticResumes = 0 }
        // SF-4's elapsed clock measures the *hold*, so an automatic resume
        // under a button that was never released keeps the original stamp.
        if holdBegan == nil { holdBegan = now() }
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
        // Only a route change may leave a repair pending; every other reason
        // settles the question, so anything left over from an earlier route
        // change is stale and must not keep the indicator up.
        if reason != .routeChanged { routeResumeInFlight = false }
        // **Synchronously, with the microphone, and not behind the task
        // chain.** This is the call that takes the lock-screen banner down, and
        // it must not queue behind a key-down that is still in flight to the
        // client — an indicator that lags an unkey is the stale state SF-4
        // cannot afford. `routeResumeInFlight` is what keeps a route-change
        // recovery's banner up across this; every other reason ends it.
        refreshActivity()
        scheduleTransmitWork()
    }

    /// ``endTransmit(reason:)`` plus a wait for it to reach the client. Used
    /// by ``disconnect()`` and by the tests.
    ///
    /// A separate name rather than an `async` overload: an overload pair
    /// differing only in `async` resolves by context, and "which one did that
    /// call site get?" is not a question worth having about the code that
    /// stops transmission.
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
            watchdogDeadline = nil
            refreshActivity()
            return
        }

        if transmitDesired {
            guard connection.isConnected, !isTransmitting else { return }
            do {
                // Gain, then meter, then the wire. The order is the point: the
                // meter reports what actually leaves, so the operator is
                // setting the gain against the thing it changes.
                //
                // This closure runs on the audio thread fifty times a second.
                // Every step is bounded work on 160 samples with no awaits —
                // see `TransmitGainBox`, `TransmitGain.apply(to:)` and
                // `AudioLevelMeter.note(_:)`.
                let gainBox = self.gainBox
                let meter = transmitMeter
                transmitMeter.reset()
                try audio.startCapture { frame in
                    let amplified = gainBox.gain.apply(to: frame)
                    meter.note(amplified)
                    link.sendCapturedFrame(amplified)
                }
                try await link.startTransmit()
            } catch {
                // Fail closed: microphone shut, client unkeyed, button
                // released. The operator must make a fresh, deliberate press.
                audio.stopCapture()
                await link.stopTransmit()
                transmitDesired = false
                isKeyDown = false
                isTransmitting = false
                // **The hold ends here too**, which it did not before APP-3.
                // `.transmitFailed` says the operator "must make a fresh,
                // deliberate press", and `leavesTheHoldAlive` is false for it —
                // but this path does not go through `endTransmit`, so the hold
                // used to survive a failed key-down. That left an automatic
                // resume able to fire off a hold nobody had renewed, and a
                // lock-screen indicator with no way down.
                heldSource = nil
                holdBegan = nil
                routeResumeInFlight = false
                watchdogDeadline = nil
                lastStopReason = .transmitFailed
                transmitState = link.transmitState()
                refreshActivity()
                present(title: "Could not transmit", message: "\(error)")
                return
            }
            isTransmitting = true
            // Each key-down starts its own watchdog, including one this class
            // made after a route change.
            watchdogDeadline = now().addingTimeInterval(transmitTimeout.seconds)
            routeResumeInFlight = false
            transmitState = link.transmitState()
            refreshActivity()
        } else {
            // Unconditional rather than guarded by `isTransmitting`. Both
            // calls are documented as safe when nothing is running, and the
            // failure mode of a redundant stop is nothing at all, while the
            // failure mode of a missed one is an open microphone.
            audio.stopCapture()
            await link.stopTransmit()
            isTransmitting = false
            transmitState = link.transmitState()
            refreshActivity()
        }
    }

    // MARK: - Scene phase and view lifetime

    /// The app left, or returned to, the foreground.
    ///
    /// Anything that is not fully active unkeys. `.inactive` counts: the
    /// control centre being dragged down, a call banner, an app switcher
    /// preview — the operator is not looking at the PTT button in any of them.
    /// The *connection* survives (PD-2 gives the app the `audio` background
    /// mode); only transmission stops.
    ///
    /// Transmission is never resumed on returning to the foreground. A
    /// microphone that reopens without a fresh press is exactly the surprise
    /// this app exists to avoid.
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
        switch signal {
        case .interruptionBegan:
            endTransmit(reason: .audioInterrupted)
        case .routeChanged:
            resumeAcrossRouteChange()
        case .interruptionEnded:
            // Deliberately does not resume. `shouldResume` is a hint about
            // *playback*; keying a transmitter because a phone call ended is
            // not a thing a radio should do on its own. The stop is repeated
            // for safety and records no reason, because nothing new happened.
            endTransmit(reason: .audioInterrupted)
        }
    }

    /// SF-3 for a route change, with the recovery the operator would
    /// otherwise have to perform by hand.
    ///
    /// Transmission stops — that part is not negotiable, and the audio graph
    /// has just been rebuilt underneath us in any case. What changes is what
    /// happens next: if the button is still down, this keys back down once the
    /// route has settled instead of leaving a banner that says "press and hold
    /// to transmit again" to somebody who never stopped holding.
    ///
    /// The banner is kept for the cases that cannot be repaired — no hold, no
    /// link, or a route that will not stop changing. Then it is telling the
    /// operator something they can act on, which is the only reason to show it.
    ///
    /// **Bounded on purpose.** A flapping route must not become an unbounded
    /// series of key-downs: after ``maximumAutomaticResumes`` in one hold this
    /// gives up and says so. Each resume is a real key-down and starts its own
    /// SF-1 watchdog, and the watchdog firing ends the hold outright, so this
    /// cannot be used to hold a transmitter open past the timeout.
    private func resumeAcrossRouteChange() {
        let resumable = heldSource.flatMap { source in
            connection.isConnected && automaticResumes < Self.maximumAutomaticResumes
                ? source : nil
        }

        // Set **before** the stop, because `endTransmit` is what refreshes the
        // lock-screen indicator (SF-4) and this is the flag that tells it the
        // hold is being repaired rather than ended. A route change that cannot
        // be recovered from leaves this false and the activity ends with the
        // transmission, which is the honest answer: nothing is going to key
        // back down.
        routeResumeInFlight = resumable != nil
        endTransmit(reason: .routeChanged, explain: resumable == nil)
        guard let source = resumable else { return }

        automaticResumes += 1
        resumeWork = Task { @MainActor [weak self] in
            // Let the graph settle before asking for the microphone again:
            // the route change is the notification that it is *being* rebuilt,
            // not that it is finished.
            try? await Task.sleep(nanoseconds: Self.routeSettleNanoseconds)
            guard let self else { return }
            guard self.heldSource == source, self.connection.isConnected else {
                // The hold ended, or the link did, while the graph settled.
                // Nothing will key back down, so the indicator must not go on
                // saying otherwise.
                self.routeResumeInFlight = false
                self.refreshActivity()
                return
            }
            self.beginTransmit(from: source)
        }
    }

    /// Where to turn the microphone back on, which is not the same place on
    /// the two platforms — and telling a macOS operator to look in Settings →
    /// Currawong sends them somewhere that does not exist.
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

    /// What the lock screen should be showing right now, or `nil` for nothing.
    ///
    /// A pure function of the state above it, which is the point: there is one
    /// answer to "is the radio keyed?", every path that changes it calls
    /// ``refreshActivity()``, and no path has its own idea of how to take the
    /// banner down.
    ///
    /// **The `isOnAir` flag follows ``isTransmitting`` and nothing else.** Not
    /// ``isKeyDown``, which leads the client by a round trip, and not
    /// ``transmitDesired``. An indicator that goes red before the far end is
    /// keyed is a small lie, and it is the same kind of lie as one that stays red
    /// after the microphone shuts.
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

        // A route-change recovery, mid-gap. Nothing is on air and the activity
        // says so — but it stays up, because the operator has not let go and a
        // banner that blinks off and back on teaches them to disbelieve it.
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

        // Nothing is keyed, so nothing is shown. **This is also the one shape
        // decision in APP-3 with an open question behind it** (`BU-10`): the
        // activity is scoped to a *transmission*, which is what the plan asked
        // for — it must "end on every path that ends transmit" — and it means
        // the activity is requested at key-down, which for an accessory keying a
        // backgrounded app is a request made from the background. Apple
        // documents `Activity.request` as a foreground operation; Currawong is
        // *running* in that moment rather than suspended (PD-2's `audio` mode),
        // which is not the same thing, and no simulator will settle it.
        //
        // If a device says no, the fix is here and nowhere else: return a
        // not-on-air state whenever `connection.isConnected`, so the activity is
        // created by the operator tapping Connect — unambiguously foreground —
        // and merely goes red here. `TransmitActivityController` neither knows
        // nor cares which of the two it is being handed.
        return nil
    }

    /// Hands ``desiredActivity`` to the controller. Cheap and idempotent, so it
    /// is called from every transition rather than from the ones that were
    /// thought to matter.
    private func refreshActivity() {
        activity.show(desiredActivity)
    }

    /// Waits for the lock-screen indicator to catch up. Test support only —
    /// nothing in the app needs to know when a banner has been drawn.
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
            // SF-1. The client has already unkeyed itself; the app still has a
            // microphone open and a button that thinks it is held.
            endTransmit(reason: .watchdogExpired)
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

        // Detached: playback enqueue takes a lock and allocates, fifty times a
        // second, and none of that belongs on the main actor. Only the
        // throttled activity note hops back.
        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            var lastNoted = Date.distantPast
            for await pcm in stream {
                // Read per frame rather than snapshotted here, so dragging the
                // slider is audible on the next 20 ms of audio instead of on the
                // next connection. The meter reads the amplified frame, because
                // what the operator is judging is what they can hear.
                let pcm = gainBox.gain.apply(to: pcm)
                audio.enqueuePlayback(pcm)
                meter.note(pcm)
                let arrival = Date()
                if arrival.timeIntervalSince(lastNoted) >= window / 2 {
                    lastNoted = arrival
                    // Bound to a local first: `self?.…` inside the nested
                    // closure would capture the weak variable itself across an
                    // isolation boundary, which is a hard error under Swift 6.
                    guard let session = self else { return }
                    await MainActor.run { session.noteReceivedAudio(at: arrival) }
                }
            }
        }
    }

    /// Records inbound audio activity. Throttled by the caller — publishing
    /// fifty times a second would redraw the whole screen fifty times a
    /// second, for an indicator that only has two states.
    func noteReceivedAudio(at date: Date) {
        lastReceivedAudioAt = date
    }

    /// Whether audio is arriving right now, as of `date`.
    ///
    /// A function of a caller-supplied instant rather than a timer, so the
    /// view can drive it from a `TimelineView` and the tests can drive it from
    /// a fixed date.
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
    /// **Does not key the radio.** DTMF is signalling and travels as its own
    /// reliable frame, so there is no transmission to start and — importantly —
    /// pressing a keypad key cannot put the operator on air. It is refused when
    /// there is no connection rather than queued.
    ///
    /// Lower-case `a`–`d` are upper-cased on the way through: the library is
    /// deliberately strict about the RFC's alphabet and says the layer owning a
    /// keypad should normalise, and this is that layer.
    func sendDTMF(_ digit: Character) async {
        guard let link, connection.isConnected else {
            present(
                title: "Not connected",
                message: "Connect to a node before sending DTMF.")
            return
        }

        // `Character(digit.uppercased())` would be the obvious spelling and it
        // traps: upper-casing is not one-to-one — "ß" upper-cases to "SS" — and
        // `Character.init` refuses a multi-character string. Unreachable from
        // the keypad, which only offers `0`–`9`, `*` and `#`, but this method is
        // callable with anything and a trap is not an acceptable answer.
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

    /// Dismisses the alert on screen and shows the next one waiting, if any.
    func dismissAlert() {
        alert = pendingAlerts.isEmpty ? nil : pendingAlerts.removeFirst()
    }

    func dismissSafetyNotice() {
        safetyNotice = nil
    }

    /// Says something to the operator, behind whatever is already being said.
    ///
    /// **Queued rather than assigned, because one attempt can raise two.** The
    /// view presents a single alert bound to ``alert``, and SwiftUI does not
    /// re-present when the value behind a showing alert is replaced — so the
    /// second message was dropped, and dismissing the first cleared it.
    ///
    /// That was not theoretical. `connect()` warns when the secret could not be
    /// saved and then carries on, so a macOS build without the Keychain
    /// entitlement showed "the secret was not stored" and swallowed whatever
    /// the connection itself then failed with: the operator was told about the
    /// harmless problem and left to guess at the real one.
    ///
    /// Duplicates are dropped. Retrying a connection that fails the same way
    /// twice should not build a stack of identical alerts to dismiss one by
    /// one — `OperatorAlert` compares on its words, not its id, for this.
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
        // **APP-13.** The sitting is over, so the public proxy goes back. Here
        // rather than in `disconnect()` because both ways a link ends come
        // through this — the operator hanging up, and the link dropping by itself
        // — and a lease surviving one of them would send the next session back to
        // a machine somebody else has since taken. The library has already closed
        // the proxy connection itself by this point: `EchoLinkClient` sends the
        // RTCP farewell, then `CLOSE`, then closes the transport.
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

/// **The one consumer of every PTT input.**
///
/// The Bluetooth accessory (PT-2/PT-3) and the remote-command button (PT-4)
/// reach the microphone through here and nowhere else, which is the whole point
/// of ``PTTSink``: three inputs, one path to ``RadioSession/endTransmit(reason:)``,
/// so a release path that works for the on-screen button works for all of them.
///
/// ## Releases are honoured unconditionally
///
/// None of these methods checks whether the input asking to stop is the input
/// that started. That is deliberate, and it is the same reasoning
/// ``RadioSession/applyTransmit()`` uses about calling `stopTransmit` twice: the
/// cost of an unnecessary stop is nothing at all, and the cost of a swallowed
/// one is an open microphone. An accessory release that arrives while the
/// on-screen button holds the key stops transmission; the operator presses
/// again. The reverse arrangement — matching source before releasing — would
/// mean writing down the conditions under which the app ignores a release, and
/// there are no such conditions worth having.
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
    /// The "is it already keyed?" test is `transmitDesired || isTransmitting`,
    /// not `isTransmitting` alone. They differ for as long as it takes the
    /// client to answer a key-up, and a second toggle arriving inside that
    /// window must unkey rather than be read as a fresh press — otherwise a
    /// quick double-press latches instead of cancelling.
    func pttToggled(from source: PTTSource) {
        if transmitDesired || isTransmitting {
            endTransmit(reason: .remoteCommandToggled)
        } else {
            beginTransmit(from: source)
        }
    }

    /// **SF-2.** The Bluetooth accessory's link dropped.
    ///
    /// Called unconditionally by ``BLEPTTController`` on every disconnection,
    /// whether or not the accessory was the thing holding the key, so this
    /// method has to be safe when nothing is transmitting — which it is, because
    /// `endTransmit` is. It records a reason and raises a notice only when it
    /// actually stopped something.
    func accessoryLinkLost() {
        endTransmit(reason: .accessoryLinkLost)
    }
}
