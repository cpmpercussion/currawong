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
        lock.unlock()

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

    var configureSessionError: Error?
    var startCaptureError: Error?

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

    var failWrites = false

    init(initial: [String: String] = [:]) {
        self.secrets = initial
    }

    func secret(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func setSecret(_ secret: String?, for account: String) throws {
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

/// A ``RadioSession`` wired to fakes, plus the handles a test needs to drive
/// the streams the composition root would otherwise own.
@MainActor
final class SessionHarness {
    let client = FakeNetworkClient()
    let audio = FakeAudioIO()
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
        echoLinkProxy: StoredEchoLinkProxy? = nil
    ) {
        self.settingsStore = InMemorySettingsStore(
            initial: settings, channels: channels, selectedID: selectedID, identity: identity,
            gain: gain, timeout: timeout, receiveGain: receiveGain,
            echoLinkProxy: echoLinkProxy)
        self.secretStore = InMemorySecretStore(initial: secrets)

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
            resolver: resolver)
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
    }
}

// MARK: - Waiting

/// Polls until a condition holds, so a test never has to guess how many
/// `Task.yield()`s an `AsyncStream` hand-off takes. Fails the test on timeout
/// rather than hanging the suite.
@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
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
