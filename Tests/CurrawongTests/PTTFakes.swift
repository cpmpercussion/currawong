// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import Currawong

// MARK: - Bluetooth

/// A ``BLECentral`` with no CoreBluetooth behind it.
///
/// This is what makes BLE-1, BLE-2 and BLE-3 testable at all: a real central
/// needs a radio, an accessory, an authorisation prompt and a human thumb, and a
/// test bundle has none of those. Every event a real central can produce is
/// pushed in from a test method instead.
final class FakeBLECentral: BLECentral, @unchecked Sendable {
    enum Call: Equatable {
        case startScan
        case stopScan
        case connect(UUID)
        case disconnect(UUID)
        case subscribe(UUID)
    }

    let events: AsyncStream<BLECentralEvent>
    private let continuation: AsyncStream<BLECentralEvent>.Continuation

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    private var storedAvailability: BLECentralAvailability

    init(availability: BLECentralAvailability = .poweredOn) {
        self.storedAvailability = availability
        var escaped: AsyncStream<BLECentralEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
    }

    deinit {
        continuation.finish()
    }

    var availability: BLECentralAvailability {
        lock.lock()
        defer { lock.unlock() }
        return storedAvailability
    }

    func startScan() { record(.startScan) }
    func stopScan() { record(.stopScan) }
    func connect(_ id: UUID) { record(.connect(id)) }
    func disconnect(_ id: UUID) { record(.disconnect(id)) }
    func subscribeToAllNotifyingCharacteristics(_ id: UUID) { record(.subscribe(id)) }

    // MARK: Test surface

    /// Pushes an event at the controller, as the radio would.
    func emit(_ event: BLECentralEvent) {
        if case .availabilityChanged(let availability) = event {
            lock.lock()
            storedAvailability = availability
            lock.unlock()
        }
        continuation.yield(event)
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func clearCalls() {
        lock.lock()
        storedCalls = []
        lock.unlock()
    }

    private func record(_ call: Call) {
        lock.lock()
        storedCalls.append(call)
        lock.unlock()
    }
}

// MARK: - Remote command

final class FakeRemoteCommandSource: RemoteCommandSource, @unchecked Sendable {
    let commands: AsyncStream<RemoteCommandEvent>
    private let continuation: AsyncStream<RemoteCommandEvent>.Continuation

    private let lock = NSLock()
    private var storedEnableCount = 0
    private var storedDisableCount = 0

    init() {
        var escaped: AsyncStream<RemoteCommandEvent>.Continuation!
        self.commands = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
    }

    deinit {
        continuation.finish()
    }

    func enable() {
        lock.lock()
        storedEnableCount += 1
        lock.unlock()
    }

    func disable() {
        lock.lock()
        storedDisableCount += 1
        lock.unlock()
    }

    func emit(_ command: RemoteCommandEvent) {
        continuation.yield(command)
    }

    var enableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedEnableCount
    }

    var disableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDisableCount
    }
}

// MARK: - Stores

final class InMemoryPTTSettingsStore: PTTSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedMapping: BLEPTTMapping?
    private var storedRemoteEnabled: Bool

    init(mapping: BLEPTTMapping? = nil, remoteCommandEnabled: Bool = false) {
        self.storedMapping = mapping
        self.storedRemoteEnabled = remoteCommandEnabled
    }

    func loadMapping() -> BLEPTTMapping? {
        lock.lock()
        defer { lock.unlock() }
        // Mirrors `UserDefaultsPTTSettingsStore`: an unusable mapping on disk is
        // never handed to the runtime matcher.
        return storedMapping.flatMap { $0.isUsable ? $0 : nil }
    }

    func saveMapping(_ mapping: BLEPTTMapping?) {
        lock.lock()
        storedMapping = mapping
        lock.unlock()
    }

    func loadRemoteCommandEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedRemoteEnabled
    }

    func saveRemoteCommandEnabled(_ enabled: Bool) {
        lock.lock()
        storedRemoteEnabled = enabled
        lock.unlock()
    }

    var savedMapping: BLEPTTMapping? {
        lock.lock()
        defer { lock.unlock() }
        return storedMapping
    }
}

// MARK: - Sink

/// A ``PTTSink`` that records rather than transmits.
///
/// Lets the input controllers be tested for the edges they produce without a
/// network client anywhere near them — which is the whole reason `PTTSink` is a
/// protocol.
@MainActor
final class RecordingPTTSink: PTTSink {
    enum Call: Equatable {
        case pressed(PTTSource)
        case released(PTTSource, TransmitStopReason)
        case toggled(PTTSource)
        case accessoryLinkLost
    }

    private(set) var calls: [Call] = []

    func pttPressed(from source: PTTSource) {
        calls.append(.pressed(source))
    }

    func pttReleased(from source: PTTSource, reason: TransmitStopReason) {
        calls.append(.released(source, reason))
    }

    func pttToggled(from source: PTTSource) {
        calls.append(.toggled(source))
    }

    func accessoryLinkLost() {
        calls.append(.accessoryLinkLost)
    }

    func clear() {
        calls = []
    }
}

// MARK: - Signals

/// Signals for the common accessory shape: one characteristic, `01` down and
/// `00` up.
enum TestSignals {
    static let service = "FFE0"
    static let characteristic = "FFE1"

    static func signal(_ bytes: UInt8...) -> BLESignal {
        BLESignal(service: service, characteristic: characteristic, payload: Data(bytes))
    }

    static var press: BLESignal { signal(0x01) }
    static var release: BLESignal { signal(0x00) }

    /// A signal on a different characteristic — a battery level, a heartbeat,
    /// the other button on the fob.
    static var unrelated: BLESignal {
        BLESignal(service: "180F", characteristic: "2A19", payload: Data([0x63]))
    }

    static func mapping(id: UUID = UUID(), name: String? = "Test fob") -> BLEPTTMapping {
        // Force-unwrapped deliberately: `press != release` here by construction,
        // and a `nil` would mean this helper is broken rather than the test.
        BLEPTTMapping(accessoryID: id, accessoryName: name, press: press, release: release)!
    }
}
