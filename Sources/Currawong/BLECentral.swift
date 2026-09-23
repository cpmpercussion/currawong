// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One characteristic, by service and characteristic UUID.
///
/// Strings rather than `CBUUID`, so it can be persisted and tested without
/// CoreBluetooth. They are `CBUUID.uuidString` as produced — short for 16-bit
/// UUIDs, long for 128-bit — which is stable per device.
struct BLECharacteristicPath: Hashable, Codable, Sendable {
    let service: String
    let characteristic: String

    init(service: String, characteristic: String) {
        self.service = service.uppercased()
        self.characteristic = characteristic.uppercased()
    }
}

/// One notification: where it came from and what it said. A learned mapping
/// is two of these and nothing else — no vendor or product knowledge (PT-3).
struct BLESignal: Hashable, Codable, Sendable {
    let path: BLECharacteristicPath
    let payload: Data

    init(path: BLECharacteristicPath, payload: Data) {
        self.path = path
        self.payload = payload
    }

    init(service: String, characteristic: String, payload: Data) {
        self.init(
            path: BLECharacteristicPath(service: service, characteristic: characteristic),
            payload: payload)
    }

    /// Hex bytes, for logs and the learn-mode UI.
    var payloadDescription: String {
        payload.isEmpty ? "(empty)" : payload.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// A peripheral the central has seen. There is no list of supported devices
/// (PT-3).
struct BLEAccessory: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String?
    let rssi: Int?

    init(id: UUID, name: String? = nil, rssi: Int? = nil) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }

    var displayName: String { name ?? "Unnamed accessory" }
}

/// Whether Bluetooth can be used: `CBManagerState` reduced to the cases the UI
/// words differently.
enum BLECentralAvailability: Equatable, Sendable {
    case unknown
    case unsupported
    case unauthorised
    case poweredOff
    case poweredOn

    var isUsable: Bool { self == .poweredOn }

    /// What to tell the operator, or `nil` when there is nothing wrong.
    var problem: String? {
        switch self {
        case .poweredOn: return nil
        case .unknown: return "Waiting for Bluetooth…"
        case .unsupported: return "This device has no Bluetooth LE radio."
        case .unauthorised: return "Currawong is not allowed to use Bluetooth. Grant access in Settings."
        case .poweredOff: return "Bluetooth is switched off."
        }
    }
}

/// Everything that can happen to a central, as values.
enum BLECentralEvent: Sendable, Equatable {
    case availabilityChanged(BLECentralAvailability)
    case discovered(BLEAccessory)
    case connected(id: UUID)
    case connectionFailed(id: UUID, reason: String?)
    case disconnected(id: UUID, reason: String?)

    /// Every notifying characteristic found and subscribed to (PT-3: no
    /// guessing which one matters).
    case subscribed(id: UUID, paths: [BLECharacteristicPath])

    /// A notification arrived — the only event that may key the radio.
    ///
    /// **Never a probe's read answer**, which the central alone can tell apart
    /// (CoreBluetooth delivers both through one callback). A readable press
    /// characteristic would otherwise key the radio on every probe, with no
    /// release to follow.
    case notified(id: UUID, signal: BLESignal)

    /// A liveness probe's read went out. Not emitted when nothing readable has
    /// been discovered, so the caller times the answer, not discovery.
    case probeIssued(id: UUID)

    /// A liveness probe's read answered: the link carries data. The payload is
    /// for the log only.
    case probeAnswered(id: UUID, signal: BLESignal)

    /// A liveness probe's read was refused or errored, so a dead link is an
    /// event rather than an absence. Emitted only for a read a probe issued.
    case probeFailed(id: UUID, reason: String?)
}

/// The seam that keeps CoreBluetooth out of the PTT logic, so it can be tested
/// against `FakeBLECentral`.
///
/// Rules for conformers:
///
/// - `events` yields in order and is a **single-consumer** stream, iterated
///   once by ``BLEPTTController``.
/// - Every method is safe to call at any time, including before Bluetooth is
///   powered on and for a peripheral that was never discovered. A conformer
///   that cannot do what was asked says so with an event; nothing throws,
///   because there is no useful `catch` at a press edge.
/// - `subscribeToAllNotifyingCharacteristics(_:)` subscribes to *everything*
///   that notifies or indicates. It must not filter by service (PT-3).
protocol BLECentral: AnyObject, Sendable {
    var events: AsyncStream<BLECentralEvent> { get }

    /// The last known availability, for a caller that starts observing late.
    var availability: BLECentralAvailability { get }

    /// Scans for anything advertising. Foreground only: iOS refuses a
    /// service-less background scan, and the background mode keeps an
    /// established link alive (PT-2).
    func startScan()
    func stopScan()

    func connect(_ id: UUID)
    func disconnect(_ id: UUID)

    func subscribeToAllNotifyingCharacteristics(_ id: UUID)

    /// Asks the link to prove it carries data, by reading any readable
    /// characteristic — the only evidence on this seam, since `.connected` and a
    /// subscribe can succeed over a dead link and a PTT button is silent for
    /// minutes.
    ///
    /// Announced as ``BLECentralEvent/probeIssued(id:)``; answered as
    /// ``BLECentralEvent/probeAnswered(id:signal:)`` or
    /// ``BLECentralEvent/probeFailed(id:reason:)``, **never** as
    /// ``BLECentralEvent/notified(id:signal:)``, or a probe could key the radio.
    /// A no-op with nothing readable yet or no connection; that silence is not
    /// failure.
    func probeForLiveness(_ id: UUID)
}
