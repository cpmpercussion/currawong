// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import XCTest

@testable import Currawong

// MARK: - Network client

/// A `NetworkClient` that opens nothing.
///
/// The view model can be driven through every connection and PTT path against
/// this, on a machine with no network, no node and no radio licence. It records
/// the calls it received *in order*, which is how the "stops transmitting
/// before it hangs up" test is written.
///
/// **Conforming to the whole protocol is the point.** `NetworkClient` grew
/// ``radioEvents``, ``receivedAudio`` and ``send(pcm:)`` in library v0.3.0
/// (RC-10) precisely so an app could be written against the seam rather than
/// against a concrete client. If this fake stops conforming, the app has lost
/// the only compile-time proof that the seam is wide enough.
final class FakeNetworkClient: NetworkClient, @unchecked Sendable {
    struct Destination: Equatable, Sendable {
        var host: String
        var port: UInt16
        var node: String
        var username: String
        var callsign: String
        var secret: String
    }

    enum Call: Equatable {
        case connect(Destination)
        case disconnect
        case startTransmit
        case stopTransmit
        case send(frameCount: Int)
        case sendDTMF(Character)
    }

    private let lock = NSLock()
    private var storedState: TransmitState = .idle
    private var storedCalls: [Call] = []
    private var storedConnectError: Error?
    private var storedStartTransmitError: Error?
    private var storedSentFrames: [[Int16]] = []
    private var storedSentDigits: [Character] = []
    private var storedDTMFError: Error?
    private var storedDuringStartTransmit: (@Sendable () async -> Void)?

    // MARK: NetworkClient

    /// The protocol's two client → app streams. Both are live and drivable —
    /// ``emit(_:)`` and ``deliver(pcm:)`` are what a test pushes through them —
    /// rather than empty stubs, so the conformance is honest about being a
    /// working client rather than a compile-time shim.
    let radioEvents: AsyncStream<RadioEvent>
    let receivedAudio: AsyncStream<[Int16]>

    private let radioEventContinuation: AsyncStream<RadioEvent>.Continuation
    private let receivedAudioContinuation: AsyncStream<[Int16]>.Continuation

    init() {
        var eventEscape: AsyncStream<RadioEvent>.Continuation!
        self.radioEvents = AsyncStream { eventEscape = $0 }
        self.radioEventContinuation = eventEscape

        var audioEscape: AsyncStream<[Int16]>.Continuation!
        self.receivedAudio = AsyncStream { audioEscape = $0 }
        self.receivedAudioContinuation = audioEscape
    }

    var state: TransmitState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    func connect(to destination: Destination) async throws {
        lock.lock()
        storedCalls.append(.connect(destination))
        let error = storedConnectError
        lock.unlock()

        if let error { throw error }

        lock.lock()
        storedState = .receiving
        lock.unlock()
    }

    /// Terminal and idempotent, and it finishes both streams — that is part of
    /// the protocol's lifecycle contract, not an implementation detail, and a
    /// fake that skipped it would let a `for await` loop survive a disconnect
    /// here in a way it never could against a real client.
    func disconnect() async {
        lock.lock()
        storedCalls.append(.disconnect)
        storedState = .idle
        lock.unlock()
        radioEventContinuation.finish()
        receivedAudioContinuation.finish()
    }

    func startTransmit() async throws {
        lock.lock()
        storedCalls.append(.startTransmit)
        let error = storedStartTransmitError
        let during = storedDuringStartTransmit
        lock.unlock()

        // Whatever a test wants to happen *while* the link is keying — which
        // since BU-16 is where the key-down suspends, and so where a release
        // can land. Run before the error check so a test can combine the two.
        await during?()

        if let error { throw error }

        lock.lock()
        storedState = .transmitting(since: Date())
        lock.unlock()
    }

    func stopTransmit() async {
        lock.lock()
        storedCalls.append(.stopTransmit)
        if case .transmitting = storedState { storedState = .receiving }
        lock.unlock()
    }

    /// The protocol's transmit-audio seam. Records the frame and returns; a
    /// real client discards audio offered while unkeyed and calls that success,
    /// so there is nothing here to refuse either.
    func send(pcm: [Int16]) async throws {
        record(pcm: pcm)
    }

    // MARK: Test surface

    /// The synchronous spelling, for the composition root's
    /// `sendCapturedFrame` — which is called from the audio thread and must not
    /// `await`. Named after the concrete clients' own frame-returning
    /// `transmit(pcm:)` so it cannot be confused with the protocol's
    /// `send(pcm:)` above.
    func transmit(pcm: [Int16]) {
        record(pcm: pcm)
    }

    private func record(pcm: [Int16]) {
        lock.lock()
        storedSentFrames.append(pcm)
        storedCalls.append(.send(frameCount: pcm.count))
        lock.unlock()
    }

    /// Pushes a ``RadioEvent`` at whoever is iterating ``radioEvents``.
    func emit(_ event: RadioEvent) {
        radioEventContinuation.yield(event)
    }

    /// Pushes a frame of decoded PCM at whoever is iterating ``receivedAudio``.
    func deliver(pcm: [Int16]) {
        receivedAudioContinuation.yield(pcm)
    }

    /// Stands in for `IAX2Client.send(dtmf:)`, which is absent from the
    /// protocol. Throws `dtmfError` when a test has set one.
    func send(dtmf digit: Character) throws {
        lock.lock()
        storedCalls.append(.sendDTMF(digit))
        storedSentDigits.append(digit)
        let error = storedDTMFError
        lock.unlock()
        if let error { throw error }
    }

    var sentDigits: String {
        lock.lock()
        defer { lock.unlock() }
        return String(storedSentDigits)
    }

    var dtmfError: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedDTMFError
        }
        set {
            lock.lock()
            storedDTMFError = newValue
            lock.unlock()
        }
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    var sentFrames: [[Int16]] {
        lock.lock()
        defer { lock.unlock() }
        return storedSentFrames
    }

    var connectError: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedConnectError
        }
        set {
            lock.lock()
            storedConnectError = newValue
            lock.unlock()
        }
    }

    /// Runs inside ``startTransmit()``, before it returns.
    ///
    /// The reentrancy hazard the workspace `CLAUDE.md` names: a release that
    /// arrives at the key-down's own suspension point is the case a
    /// common-ordering test cannot reach, and it is exactly BU-16's tap. Setting
    /// this is how a test delivers the release from inside the awaited call.
    var duringStartTransmit: (@Sendable () async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedDuringStartTransmit
        }
        set {
            lock.lock()
            storedDuringStartTransmit = newValue
            lock.unlock()
        }
    }

    var startTransmitError: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedStartTransmitError
        }
        set {
            lock.lock()
            storedStartTransmitError = newValue
            lock.unlock()
        }
    }

    var isTransmitting: Bool {
        if case .transmitting = state { return true }
        return false
    }
}

// MARK: - Audio

/// An ``AudioIO`` with no `AVAudioEngine` behind it.
///
/// Records what was asked of it and lets a test push SF-3 signals in, which is
/// the only way to exercise the interruption and route-change release paths
/// without an incoming phone call.
final class FakeAudioIO: AudioIO, @unchecked Sendable {
    let signals: AsyncStream<AudioSessionSignal>
    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation

    private let lock = NSLock()
    private var storedIsCapturing = false
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var storedPlayed: [[Int16]] = []
    private var storedOnFrame: (@Sendable ([Int16]) -> Void)?
    private var storedConfigureCount = 0

    private var storedPermissionRequestCount = 0
    private var storedPrepareCount = 0
    private var storedSettleCount = 0

    /// Called from inside ``settleRoute()``.
    ///
    /// This is what lets a test stand where iOS's cascade stands: the closure
    /// runs *inside* the session's `await`, after the microphone has opened and
    /// before the link is keyed, so emitting `.routeChanged` from it delivers a
    /// route change in exactly the window the fix is about. That is the
    /// reentrancy discipline the workspace `CLAUDE.md` asks for — deliver the
    /// event from inside the awaited call, not before or after it.
    var onSettleRoute: (@Sendable () async -> Void)?

    var configureSessionError: Error?
    var startCaptureError: Error?

    /// Diagnostic only — the key/unkey log reads this and nothing branches on
    /// it, so a fixed string is the whole of what a fake owes the protocol.
    var audioStateDescription: String { "fake audio, no session" }

    /// Settable, so a test can say "this capture was slow" without one.
    var lastCaptureStartMilliseconds = 0

    /// What the operating system will "decide" about the microphone. Granted by
    /// default so every test that does not care about permission is unaffected.
    var recordPermissionGranted = true

    init() {
        var escaped: AsyncStream<AudioSessionSignal>.Continuation!
        self.signals = AsyncStream { escaped = $0 }
        self.signalContinuation = escaped
    }

    func requestRecordPermission() async -> Bool {
        lock.lock()
        storedPermissionRequestCount += 1
        let granted = recordPermissionGranted
        lock.unlock()
        return granted
    }

    func configureSession() throws {
        lock.lock()
        storedConfigureCount += 1
        lock.unlock()
        if let configureSessionError { throw configureSessionError }
    }

    /// **`BU-15`.** Counts the call. The cascade goes in ``onSettleRoute``,
    /// which is where the session actually waits.
    func prepareForCapture() async {
        lock.lock()
        storedPrepareCount += 1
        lock.unlock()
    }

    /// **`BU-15`.** Runs whatever the test installed in ``onSettleRoute``.
    func settleRoute() async {
        lock.lock()
        storedSettleCount += 1
        let hook = onSettleRoute
        lock.unlock()
        await hook?()
    }

    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws {
        if let startCaptureError { throw startCaptureError }
        lock.lock()
        storedIsCapturing = true
        storedStartCount += 1
        storedOnFrame = onFrame
        lock.unlock()
    }

    func stopCapture() {
        lock.lock()
        if storedIsCapturing { storedIsCapturing = false }
        storedStopCount += 1
        storedOnFrame = nil
        lock.unlock()
    }

    func enqueuePlayback(_ pcm: [Int16]) {
        lock.lock()
        storedPlayed.append(pcm)
        lock.unlock()
    }

    // MARK: Test surface

    /// Pretends the microphone produced a frame.
    func produceFrame(_ pcm: [Int16]) {
        lock.lock()
        let sink = storedOnFrame
        lock.unlock()
        sink?(pcm)
    }

    /// Pushes an SF-3 signal at whoever is observing ``signals``.
    func emit(_ signal: AudioSessionSignal) {
        signalContinuation.yield(signal)
    }

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsCapturing
    }

    var prepareForCaptureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPrepareCount
    }

    var settleRouteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSettleCount
    }

    var startCaptureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }

    var stopCaptureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }

    var configureSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedConfigureCount
    }

    var recordPermissionRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPermissionRequestCount
    }

    var playedFrames: [[Int16]] {
        lock.lock()
        defer { lock.unlock() }
        return storedPlayed
    }
}

// MARK: - Stores

/// A ``SettingsStore`` that keeps a real list and a real selection.
///
/// Deliberately not a stub returning constants: the migration in ``ChannelSet``
/// turns on the difference between a channel list that has never been written
/// (`nil`) and one the operator emptied (`[]`), so a fake that could not tell
/// those apart could not test the thing most worth testing.
///
/// `initial:` seeds the **legacy single-node key**, which is what a pre-APP-4
/// install looks like on disk: one node, no channel list. Seeding channels
/// instead is what `channels:` is for.
final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NodeSettings?
    private var storedChannels: [NodeSettings]?
    private var storedDrafts: [NodeSettings]?
    private var storedSelectedID: UUID?
    private var storedIdentity: OperatorIdentity?
    private var storedGain: TransmitGain?
    private var storedReceiveGain: ReceiveGain?
    private var storedTimeout: TransmitTimeout?
    private var storedProxy: StoredEchoLinkProxy?
    private var storedSaveCount = 0
    private var storedChannelSaveCount = 0

    init(
        initial: NodeSettings? = nil,
        channels: [NodeSettings]? = nil,
        selectedID: UUID? = nil,
        identity: OperatorIdentity? = nil,
        gain: TransmitGain? = nil,
        timeout: TransmitTimeout? = nil,
        receiveGain: ReceiveGain? = nil,
        echoLinkProxy: StoredEchoLinkProxy? = nil
    ) {
        self.stored = initial
        self.storedChannels = channels
        self.storedSelectedID = selectedID
        self.storedIdentity = identity
        self.storedGain = gain
        self.storedTimeout = timeout
        self.storedReceiveGain = receiveGain
        self.storedProxy = echoLinkProxy
    }

    func loadEchoLinkProxy() -> StoredEchoLinkProxy? {
        lock.lock()
        defer { lock.unlock() }
        return storedProxy
    }

    /// Stores what a save stores: the settings, and never a harvested password —
    /// the harvest is a one-off read, and a store that echoed it back would let a
    /// test pass while the real migration ran on every launch.
    func saveEchoLinkProxy(_ proxy: EchoLinkProxySettings) {
        lock.lock()
        storedProxy = StoredEchoLinkProxy(settings: proxy, harvestedPassword: nil)
        lock.unlock()
    }

    /// What ``saveEchoLinkProxy(_:)`` last wrote.
    var savedEchoLinkProxy: EchoLinkProxySettings? {
        lock.lock()
        defer { lock.unlock() }
        return storedProxy?.settings
    }

    func loadIdentity() -> OperatorIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return storedIdentity
    }

    func saveIdentity(_ identity: OperatorIdentity) {
        lock.lock()
        storedIdentity = identity
        lock.unlock()
    }

    func loadTransmitGain() -> TransmitGain? {
        lock.lock()
        defer { lock.unlock() }
        return storedGain
    }

    func saveTransmitGain(_ gain: TransmitGain) {
        lock.lock()
        storedGain = gain
        lock.unlock()
    }

    /// What ``saveTransmitGain(_:)`` last wrote.
    var savedTransmitGain: TransmitGain? {
        lock.lock()
        defer { lock.unlock() }
        return storedGain
    }

    func loadReceiveGain() -> ReceiveGain? {
        lock.lock()
        defer { lock.unlock() }
        return storedReceiveGain
    }

    func saveReceiveGain(_ gain: ReceiveGain) {
        lock.lock()
        storedReceiveGain = gain
        lock.unlock()
    }

    /// What ``saveReceiveGain(_:)`` last wrote.
    var savedReceiveGain: ReceiveGain? {
        lock.lock()
        defer { lock.unlock() }
        return storedReceiveGain
    }

    func loadTransmitTimeout() -> TransmitTimeout? {
        lock.lock()
        defer { lock.unlock() }
        return storedTimeout
    }

    func saveTransmitTimeout(_ timeout: TransmitTimeout) {
        lock.lock()
        storedTimeout = timeout
        lock.unlock()
    }

    /// What ``saveTransmitTimeout(_:)`` last wrote.
    var savedTransmitTimeout: TransmitTimeout? {
        lock.lock()
        defer { lock.unlock() }
        return storedTimeout
    }

    /// What ``saveIdentity(_:)`` last wrote, for the tests about when the
    /// callsign is persisted.
    var savedIdentity: OperatorIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return storedIdentity
    }

    func load() -> NodeSettings? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ settings: NodeSettings) {
        lock.lock()
        stored = settings
        storedSaveCount += 1
        lock.unlock()
    }

    func loadChannels() -> [NodeSettings]? {
        lock.lock()
        defer { lock.unlock() }
        return storedChannels
    }

    func saveChannels(_ channels: [NodeSettings]) {
        lock.lock()
        storedChannels = channels
        storedChannelSaveCount += 1
        lock.unlock()
    }

    /// **BU-9.** The unsaved edits. `nil` until something writes them, the same
    /// way the channel list is, so a test can tell "never stashed" from
    /// "stashed and then cleared".
    func loadDrafts() -> [NodeSettings]? {
        lock.lock()
        defer { lock.unlock() }
        return storedDrafts
    }

    func saveDrafts(_ drafts: [NodeSettings]) {
        lock.lock()
        storedDrafts = drafts
        lock.unlock()
    }

    func loadSelectedChannelID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedSelectedID
    }

    func saveSelectedChannelID(_ id: UUID?) {
        lock.lock()
        storedSelectedID = id
        lock.unlock()
    }

    var saved: NodeSettings? { load() }

    var savedChannels: [NodeSettings]? { loadChannels() }

    /// What the last stash wrote, as a dictionary keyed the way the session
    /// holds it — the order the values come out in is not meaningful.
    var savedDrafts: [UUID: NodeSettings] {
        Dictionary((loadDrafts() ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in
            latest
        })
    }

    var savedSelectedID: UUID? { loadSelectedChannelID() }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSaveCount
    }

    var channelSaveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedChannelSaveCount
    }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    struct WriteFailed: Error, Equatable {}

    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var writeLog: [(account: String, secret: String?)] = []

    var failWrites = false

    init(initial: [String: String] = [:]) {
        self.secrets = initial
    }

    /// Every write attempted, in order — **including the ones that store
    /// nothing** (APP-14). `setSecret(_:for:)` treats an empty value as a
    /// removal, exactly as the Keychain store does, so a write of `""` to an
    /// account with nothing in it leaves `all` unchanged and is invisible to a
    /// test that only reads the contents. That is the shape of the M17 fault: a
    /// write that exists only to fail.
    var writes: [(account: String, secret: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return writeLog
    }

    func secret(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func setSecret(_ secret: String?, for account: String) throws {
        lock.lock()
        writeLog.append((account: account, secret: secret))
        lock.unlock()
        if failWrites { throw WriteFailed() }
        lock.lock()
        if let secret, !secret.isEmpty {
            secrets[account] = secret
        } else {
            secrets.removeValue(forKey: account)
        }
        lock.unlock()
    }

    var all: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return secrets
    }
}

// MARK: - Harness

/// **SF-4.** A ``TransmitActivityPresenting`` that records instead of touching
/// ActivityKit.
///
/// ``calls`` is what the six end-path tests assert on. `isShowing` is derived
/// from the calls rather than tracked separately, so a presenter that was ended
/// twice, or started without being ended, shows up as the sequence it really was
/// rather than as a tidy boolean.
///
/// **`endOrphans` ends things, and this fake has to agree.** It reads as a
/// launch-time housekeeping call, but the contract is "end every activity this
/// app has left running" — and the real presenter nils its own handle too, so it
/// ends *ours* along with any leftover. A fake that treated it as a no-op would
/// report `isShowing == true` after a sequence that had really taken the banner
/// down, which is exactly the kind of ordering bug these tests exist to catch.
/// Caught in review of the APP-3 PR.
@MainActor
final class RecordingActivityPresenter: TransmitActivityPresenting {
    enum Call: Equatable {
        case start(TransmitActivityRequest)
        case update(TransmitActivityState)
        case end
        case endOrphans
    }

    private(set) var calls: [Call] = []

    /// Whether an activity is on screen as far as this presenter is concerned.
    var isShowing: Bool {
        for call in calls.reversed() {
            switch call {
            case .start: return true
            case .end, .endOrphans: return false
            case .update: continue
            }
        }
        return false
    }

    /// The state most recently shown, whether by a start or an update. `nil`
    /// when nothing has been shown at all.
    var shownState: TransmitActivityState? {
        for call in calls.reversed() {
            switch call {
            case .start(let request): return request.state
            case .update(let state): return state
            case .end, .endOrphans: continue  // the state shown, not whether it still is
            }
        }
        return nil
    }

    /// The state on screen *now* — `nil` once the activity has ended.
    ///
    /// Distinct from ``shownState``, which is the last state ever shown and goes
    /// on reporting a red banner after the banner has been taken down. An
    /// assertion about what the operator can see wants this one.
    var visibleState: TransmitActivityState? { isShowing ? shownState : nil }

    /// The states shown, in order — the sequence a flicker would appear in.
    var shownStates: [TransmitActivityState] {
        calls.compactMap { call in
            switch call {
            case .start(let request): return request.state
            case .update(let state): return state
            case .end, .endOrphans: return nil
            }
        }
    }

    /// How many times an activity was started. A route change that took the
    /// banner down and put it back up would make this 2.
    var startCount: Int {
        calls.filter { if case .start = $0 { return true } else { return false } }.count
    }

    var endCount: Int { calls.filter { $0 == .end }.count }

    /// Ends of either kind. `endCount` counts only the ordinary one, because the
    /// route-change tests are asserting that *no* teardown happened and an
    /// `adopt()` at launch would otherwise count against them.
    var anyEndCount: Int { calls.filter { $0 == .end || $0 == .endOrphans }.count }

    func start(_ request: TransmitActivityRequest) async { calls.append(.start(request)) }
    func update(_ state: TransmitActivityState) async { calls.append(.update(state)) }
    func end() async { calls.append(.end) }
    func endOrphans() async { calls.append(.endOrphans) }
}

/// A ``RadioSession`` wired to fakes, plus the handles a test needs to drive
/// the streams the composition root would otherwise own.
@MainActor
final class SessionHarness {
    let client = FakeNetworkClient()
    let audio = FakeAudioIO()

    /// **SF-4.** What the app asked the lock screen for. Installed on every
    /// harness, not just the SF-4 tests, so an activity left behind by some
    /// other path shows up wherever that path is tested.
    let activityPresenter = RecordingActivityPresenter()
    let settingsStore: InMemorySettingsStore
    let secretStore: InMemorySecretStore

    private(set) var session: RadioSession!

    /// Yields ``RadioLinkEvent``s at the session, as the composition root's
    /// translated event pump would.
    private(set) var eventContinuation: AsyncStream<RadioLinkEvent>.Continuation!

    /// Yields received PCM at the session, as the client's `receivedAudio`
    /// would.
    private(set) var audioContinuation: AsyncStream<[Int16]>.Continuation!

    private(set) var linksMade = 0

    /// The settings each link was built from, so a test can assert what the
    /// factory was handed — the directory server having been resolved from a
    /// name to an address on the way, for one.
    private(set) var settingsSeen: [NodeSettings] = []

    /// The identity each link was built with, so a test can prove the app-wide
    /// callsign — and not a stale per-channel one — is what reached the library.
    private(set) var identitiesSeen: [OperatorIdentity] = []

    /// The credentials each link was built with. The fake bypasses
    /// `CompositionRoot`, so this is where a test sees whether the Web
    /// Transceiver token reached the factory at all (APP-11).
    private(set) var credentialsSeen: [RadioSession.LinkCredentials] = []

    /// The watchdog timeout each link was built with (SF-1). App-wide, so this is
    /// where a test proves the operator's one number reached the factory rather
    /// than a per-channel value that no longer exists.
    private(set) var timeoutsSeen: [TransmitTimeout] = []

    /// The proxy each link was built with (APP-13). `nil` for the two modes that
    /// need none — and, for EchoLink, the evidence that the route came from the
    /// caller rather than out of the channel.
    private(set) var proxiesSeen: [EchoLinkProxyRoute?] = []

    /// How many times the session gave up its leased public proxy. The session
    /// does this on every teardown, however the link ended, so a test can prove a
    /// dropped link releases the machine as surely as hanging up does.
    private(set) var proxyLeaseReleases = 0

    /// Bumped by the link's `close` callback, which is `@Sendable` and may run
    /// off the main actor, so it counts through a lock rather than a property.
    let closedLinks = Counter()

    /// Set to make the link factory itself fail.
    var makeLinkError: Error?

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    struct LinkFailed: Error, Equatable {}
    struct ConnectFailed: Error, Equatable, CustomStringConvertible {
        var description: String { "the node rejected the call" }
    }
    struct AudioFailed: Error, Equatable, CustomStringConvertible {
        var description: String { "no input device" }
    }

    /// Settings that pass validation, so a test that is not about validation
    /// does not have to care.
    ///
    /// A `static let` rather than a factory, so its ``NodeSettings/id`` is
    /// stable across the whole run: a channel is identified by that id, and a
    /// fresh one per access would make every "is this the same channel?"
    /// assertion meaningless.
    static let goodSettings = NodeSettings(
        host: "node.example.org",
        port: 4569,
        node: "55553",
        username: "vk1xyz")

    /// A second channel that also validates, for the tests about switching
    /// between them.
    static let otherSettings = NodeSettings(
        name: "Repeater",
        host: "other.example.org",
        port: 4569,
        node: "12345",
        username: "vk1abc")

    /// An EchoLink channel that validates, for the tests about a mode whose
    /// secret account is shared between channels. **No host** — the proxy is
    /// app-wide (APP-13) and the node is `peer`.
    static let echoLinkSettings = NodeSettings(
        name: "Echo test",
        mode: .echoLink,
        port: 8100,
        node: "*ECHOTEST*",
        peer: "13.57.14.183",
        directoryServer: "192.0.2.1")

    init(
        settings: NodeSettings? = SessionHarness.goodSettings,
        channels: [NodeSettings]? = nil,
        selectedID: UUID? = nil,
        secrets: [String: String] = [:],
        resolver: any HostResolver = FakeHostResolver(),
        identity: OperatorIdentity? = OperatorIdentity(callsign: "VK1XYZ"),
        gain: TransmitGain? = nil,
        timeout: TransmitTimeout? = nil,
        receiveGain: ReceiveGain? = nil,
        echoLinkProxy: StoredEchoLinkProxy? = nil,
        reusing previous: SessionHarness? = nil
    ) {
        // `reusing:` is how a test quits and relaunches the app: a second
        // session over the store and the Keychain the first one left behind,
        // with every other argument ignored because the stores already hold
        // whatever the first session put there. Anything less than a whole new
        // `RadioSession` would not test the launch path (BU-9).
        self.settingsStore =
            previous?.settingsStore
            ?? InMemorySettingsStore(
                initial: settings, channels: channels, selectedID: selectedID, identity: identity,
                gain: gain, timeout: timeout, receiveGain: receiveGain,
                echoLinkProxy: echoLinkProxy)
        self.secretStore = previous?.secretStore ?? InMemorySecretStore(initial: secrets)

        let closedLinks = self.closedLinks
        self.session = RadioSession(
            audio: audio,
            settingsStore: settingsStore,
            secretStore: secretStore,
            makeLink: { [unowned self] settings, identity, credentials, timeout, proxy in
                if let error = self.makeLinkError { throw error }
                self.proxiesSeen.append(proxy)
                self.linksMade += 1
                self.settingsSeen.append(settings)
                self.identitiesSeen.append(identity)
                self.credentialsSeen.append(credentials)
                self.timeoutsSeen.append(timeout)

                var eventEscape: AsyncStream<RadioLinkEvent>.Continuation!
                let events = AsyncStream<RadioLinkEvent> { eventEscape = $0 }
                self.eventContinuation = eventEscape

                var audioEscape: AsyncStream<[Int16]>.Continuation!
                let received = AsyncStream<[Int16]> { audioEscape = $0 }
                self.audioContinuation = audioEscape

                let client = self.client
                // `RadioLink` stopped being generic when a second mode
                // arrived, so the fake supplies the five client operations as
                // closures over `FakeNetworkClient` rather than handing the
                // client over. The fake still conforms to `NetworkClient` —
                // it is what the closures call, and the recording it does is
                // what the assertions read.
                let destination = FakeNetworkClient.Destination(
                    host: settings.host,
                    port: settings.port,
                    node: settings.node,
                    username: settings.username,
                    callsign: identity.callsign,
                    secret: credentials.secret)
                return RadioLink(
                    // Reflects what was asked for, so a test can assert the
                    // mode reached the factory at all.
                    mode: settings.mode,
                    connect: { try await client.connect(to: destination) },
                    disconnect: { await client.disconnect() },
                    startTransmit: { try await client.startTransmit() },
                    stopTransmit: { await client.stopTransmit() },
                    transmitState: { client.state },
                    events: events,
                    receivedAudio: received,
                    sendCapturedFrame: { client.transmit(pcm: $0) },
                    sendDTMF: { try client.send(dtmf: $0) },
                    close: { closedLinks.bump() })
            },
            // `weak`, not `unowned` like the factory above: this runs from
            // `tearDownLink()`, which the session reaches while the harness is
            // being torn down at the end of a test.
            releaseProxyLease: { [weak self] in self?.proxyLeaseReleases += 1 },
            resolver: resolver,
            activity: TransmitActivityController(presenter: activityPresenter))
    }

    /// Connects with settings that validate, so PTT tests can start from a
    /// live connection in one line.
    func connect() async {
        session.settings = Self.goodSettings
        session.secret = "hunter2"
        await session.connect()
    }

    /// Keys up and waits for it to land.
    func keyDown() async {
        session.beginTransmit()
        await session.settle()
        await session.settleActivity()
    }

    /// Waits for the transmit chain **and** the lock-screen indicator. The two
    /// are separate queues, and an SF-4 assertion made after only the first one
    /// reads a banner that has not been drawn yet.
    func settleAll() async {
        await session.settle()
        await session.settleActivity()
    }
}

// MARK: - Waiting

/// Polls until a condition holds, so a test never has to guess how many
/// `Task.yield()`s an `AsyncStream` hand-off takes. Fails the test on timeout
/// rather than hanging the suite.
///
/// ## Why the default is 20 seconds and not 5
///
/// Because a CI runner can stop scheduling detached work for **fourteen
/// seconds**, and did. Measured on `main`, run 32959937776, in
/// `testReplyAudioArrivingDuringTheLingerDefersTheHandback`: the test's own
/// escalation logged at t=17.812, and the hand-back that follows one linger —
/// with the linger injected, so the wait was for a `Task.detached` to be
/// scheduled at all, not for a timer — logged at t=32.060. The test had given
/// up 9 seconds earlier. The work was not stuck; it was not run.
///
/// The host is an app whose launch alone took 7 seconds on that runner, so the
/// process is doing real audio-session work on a machine with few cores, and
/// blocking calls on the cooperative pool starve everything scheduled on it.
/// See `BU-20`.
///
/// **A longer timeout costs a passing test nothing** — every predicate here is
/// polled, so a wait returns as soon as it holds — and costs a failing test
/// fifteen more seconds before it says so. That is the right way round: a
/// five-second budget was reporting a scheduling stall as a product fault, and
/// the diagnosis of a red `main` is worth more than the seconds.
@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 20,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for: \(description)", file: file, line: line)
}
