// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation
import RadioCore

/// Everything Currawong knows how to do, with no view attached.
///
/// Generic over `Client: NetworkClient` for the reason `CompositionRoot`
/// documents: `NetworkClient` has an `associatedtype Destination`, so there is
/// no `any NetworkClient` to hold, and a concrete client here would drag
/// `IAX2Kit` into the whole app. The generic parameter keeps the view model
/// testable against a fake client that opens no socket, which is what the test
/// suite does.
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
final class RadioSession<Client: NetworkClient>: ObservableObject {

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

    /// How the composition root turns settings plus a secret into a link.
    /// Throws, because building a destination can reject what was typed.
    typealias LinkFactory = @MainActor (NodeSettings, String) throws -> RadioLink<Client>

    /// How long after the last inbound frame the receive indicator stays lit.
    /// Two and a half frames — long enough not to flicker on the 20 ms grid,
    /// short enough to go out promptly when the far end unkeys.
    static var receiveActivityWindow: TimeInterval { 0.5 }

    /// How many DTMF digits of history to keep in each direction. Enough for a
    /// long node command and its reply, short enough to read at a glance.
    /// A computed property rather than a `let`, because a generic type cannot
    /// have static stored properties — the same reason
    /// ``receiveActivityWindow`` is written this way.
    static var dtmfLogLimit: Int { 24 }

    // MARK: - Published state

    /// The node being connected to. Bound directly by the connect form.
    @Published var settings: NodeSettings

    /// The secret, in memory only. It reaches the Keychain in ``connect()``
    /// and `UserDefaults` never.
    @Published var secret: String

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

    // MARK: - Dependencies

    private let audio: AudioIO
    private let settingsStore: SettingsStore
    private let secretStore: SecretStore
    private let makeLink: LinkFactory
    private let now: @MainActor () -> Date

    // MARK: - Private state

    private var link: RadioLink<Client>?

    /// The desired key state. `isTransmitting` is the applied one; these
    /// differ for as long as it takes the client to answer.
    private var transmitDesired = false

    /// Serialises key-up and key-down so they cannot be applied out of order.
    private var transmitWork: Task<Void, Never>?
    private var transmitWorkGeneration = 0

    private var signalTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    // MARK: - Init

    init(
        audio: AudioIO,
        settingsStore: SettingsStore,
        secretStore: SecretStore,
        makeLink: @escaping LinkFactory,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.audio = audio
        self.settingsStore = settingsStore
        self.secretStore = secretStore
        self.makeLink = makeLink
        self.now = now

        let loaded = settingsStore.load() ?? NodeSettings()
        self.settings = loaded
        self.secret = (try? secretStore.secret(for: loaded.secretAccount)) ?? ""
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
        let signals = audio.signals
        signalTask = Task { @MainActor [weak self] in
            for await signal in signals {
                self?.handle(signal)
            }
        }
    }

    // MARK: - Connecting

    func toggleConnection() async {
        switch connection {
        case .disconnected: await connect()
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
    func connect() async {
        guard connection == .disconnected else { return }

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
        settingsStore.save(validated)

        do {
            try secretStore.setSecret(secret, for: validated.secretAccount)
        } catch {
            // Not fatal: the connection can proceed with the secret held in
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
                    "Currawong cannot transmit without the microphone. Turn it on in Settings → "
                    + "Currawong → Microphone, then connect again.")
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

        let newLink: RadioLink<Client>
        do {
            newLink = try makeLink(validated, secret)
        } catch {
            connection = .disconnected
            present(title: "Could not connect", message: "\(error)")
            return
        }

        link = newLink
        startEventPump(for: newLink)
        startReceivePump(for: newLink)

        do {
            try await newLink.client.connect(to: newLink.destination)
        } catch {
            tearDownLink()
            connection = .disconnected
            present(title: "Could not connect", message: "\(error)")
            return
        }

        connection = .connected
        transmitState = newLink.client.state
    }

    /// Hangs up. **Stops transmitting first**, and waits for that to land
    /// before the client is torn down — a disconnect that raced the unkey
    /// could leave the far end's repeater keyed until its own timeout.
    func disconnect() async {
        guard connection == .connected || connection == .connecting else { return }
        connection = .disconnecting

        await endTransmitAndWait(reason: .disconnecting)

        if let link {
            await link.client.disconnect()
        }
        tearDownLink()
        connection = .disconnected
        transmitState = .idle
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
    func endTransmit(reason: TransmitStopReason) {
        audio.stopCapture()

        if transmitDesired || isTransmitting {
            lastStopReason = reason
            if reason.isUnexpected { noteSafetyStop(reason) }
        }
        transmitDesired = false
        isKeyDown = false
        activeSource = nil
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
            return
        }

        if transmitDesired {
            guard connection.isConnected, !isTransmitting else { return }
            do {
                try audio.startCapture(onFrame: link.sendCapturedFrame)
                try await link.client.startTransmit()
            } catch {
                // Fail closed: microphone shut, client unkeyed, button
                // released. The operator must make a fresh, deliberate press.
                audio.stopCapture()
                await link.client.stopTransmit()
                transmitDesired = false
                isKeyDown = false
                isTransmitting = false
                lastStopReason = .transmitFailed
                transmitState = link.client.state
                present(title: "Could not transmit", message: "\(error)")
                return
            }
            isTransmitting = true
            transmitState = link.client.state
        } else {
            // Unconditional rather than guarded by `isTransmitting`. Both
            // calls are documented as safe when nothing is running, and the
            // failure mode of a redundant stop is nothing at all, while the
            // failure mode of a missed one is an open microphone.
            audio.stopCapture()
            await link.client.stopTransmit()
            isTransmitting = false
            transmitState = link.client.state
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
            endTransmit(reason: .routeChanged)
        case .interruptionEnded:
            // Deliberately does not resume. `shouldResume` is a hint about
            // *playback*; keying a transmitter because a phone call ended is
            // not a thing a radio should do on its own. The stop is repeated
            // for safety and records no reason, because nothing new happened.
            endTransmit(reason: .audioInterrupted)
        }
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

    // MARK: - Link events

    private func startEventPump(for link: RadioLink<Client>) {
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
            transmitState = link?.client.state ?? .receiving
            if let codec { negotiatedCodec = codec }

        case .transmitting, .receiving:
            transmitState = link?.client.state ?? transmitState

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
        lastDisconnectReason = reason
        present(
            title: "Disconnected",
            message: reason ?? "The connection to the node ended.")
    }

    // MARK: - Received audio

    private func startReceivePump(for link: RadioLink<Client>) {
        let stream = link.receivedAudio
        let audio = self.audio
        let window = Self.receiveActivityWindow

        // Detached: playback enqueue takes a lock and allocates, fifty times a
        // second, and none of that belongs on the main actor. Only the
        // throttled activity note hops back.
        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            var lastNoted = Date.distantPast
            for await pcm in stream {
                audio.enqueuePlayback(pcm)
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

    func dismissAlert() {
        alert = nil
    }

    func dismissSafetyNotice() {
        safetyNotice = nil
    }

    private func present(title: String, message: String) {
        alert = OperatorAlert(title: title, message: message)
    }

    // MARK: - Teardown

    private func tearDownLink() {
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
