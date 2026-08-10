// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import XCTest

@testable import Currawong

// MARK: - Network client

/// A `NetworkClient` that opens nothing.
///
/// This is the whole reason ``RadioSession`` is generic: the view model can be
/// driven through every connection and PTT path against this, on a machine
/// with no network, no node and no radio licence. It records the calls it
/// received *in order*, which is how the "stops transmitting before it hangs
/// up" test is written.
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

    func disconnect() async {
        lock.lock()
        storedCalls.append(.disconnect)
        storedState = .idle
        lock.unlock()
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

    // MARK: Test surface

    /// Stands in for `IAX2Client.send(pcm:)`, which `NetworkClient` does not
    /// have — see the note in `CompositionRoot`.
    func send(pcm: [Int16]) {
        lock.lock()
        storedSentFrames.append(pcm)
        storedCalls.append(.send(frameCount: pcm.count))
        lock.unlock()
    }

    /// Stands in for `IAX2Client.send(dtmf:)`, likewise absent from the
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

    var configureSessionError: Error?
    var startCaptureError: Error?

    init() {
        var escaped: AsyncStream<AudioSessionSignal>.Continuation!
        self.signals = AsyncStream { escaped = $0 }
        self.signalContinuation = escaped
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

    var playedFrames: [[Int16]] {
        lock.lock()
        defer { lock.unlock() }
        return storedPlayed
    }
}

// MARK: - Stores

final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NodeSettings?
    private var storedSaveCount = 0

    init(initial: NodeSettings? = nil) {
        self.stored = initial
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

    var saved: NodeSettings? { load() }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSaveCount
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

    private(set) var session: RadioSession<FakeNetworkClient>!

    /// Yields ``RadioLinkEvent``s at the session, as the composition root's
    /// translated event pump would.
    private(set) var eventContinuation: AsyncStream<RadioLinkEvent>.Continuation!

    /// Yields received PCM at the session, as the client's `receivedAudio`
    /// would.
    private(set) var audioContinuation: AsyncStream<[Int16]>.Continuation!

    private(set) var linksMade = 0

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
    static let goodSettings = NodeSettings(
        host: "node.example.org",
        port: 4569,
        node: "55553",
        username: "vk1xyz",
        callsign: "VK1XYZ")

    init(
        settings: NodeSettings? = SessionHarness.goodSettings,
        secrets: [String: String] = [:]
    ) {
        self.settingsStore = InMemorySettingsStore(initial: settings)
        self.secretStore = InMemorySecretStore(initial: secrets)

        let closedLinks = self.closedLinks
        self.session = RadioSession(
            audio: audio,
            settingsStore: settingsStore,
            secretStore: secretStore,
            makeLink: { [unowned self] settings, secret in
                if let error = self.makeLinkError { throw error }
                self.linksMade += 1

                var eventEscape: AsyncStream<RadioLinkEvent>.Continuation!
                let events = AsyncStream<RadioLinkEvent> { eventEscape = $0 }
                self.eventContinuation = eventEscape

                var audioEscape: AsyncStream<[Int16]>.Continuation!
                let received = AsyncStream<[Int16]> { audioEscape = $0 }
                self.audioContinuation = audioEscape

                let client = self.client
                return RadioLink(
                    client: client,
                    destination: FakeNetworkClient.Destination(
                        host: settings.host,
                        port: settings.port,
                        node: settings.node,
                        username: settings.username,
                        callsign: settings.callsign,
                        secret: secret),
                    events: events,
                    receivedAudio: received,
                    sendCapturedFrame: { client.send(pcm: $0) },
                    sendDTMF: { try client.send(dtmf: $0) },
                    close: { closedLinks.bump() })
            })
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
