// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One characteristic, named by the pair of UUIDs that identify it.
///
/// Strings rather than `CBUUID` on purpose: this type is persisted, compared
/// and asserted against in tests, and none of those want CoreBluetooth linked
/// in. The strings are whatever `CBUUID.uuidString` produced — 16-bit UUIDs
/// come out short (`"FFE1"`), 128-bit ones come out long — which is stable for
/// a given device and is all the mapping needs.
struct BLECharacteristicPath: Hashable, Codable, Sendable {
    let service: String
    let characteristic: String

    init(service: String, characteristic: String) {
        self.service = service.uppercased()
        self.characteristic = characteristic.uppercased()
    }
}

/// One notification: where it came from and what it said.
///
/// **This is the whole vocabulary of PT-3.** A learned mapping is two of these
/// and nothing else — no vendor name, no service whitelist, no product ID. The
/// app never needs to know what the accessory *is*, only what it *sends*.
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

    /// For logs and the learn-mode UI, so an operator can see that *something*
    /// arrived even when it means nothing to them.
    var payloadDescription: String {
        payload.isEmpty ? "(empty)" : payload.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// A peripheral the central has seen. Not a device the app claims to support —
/// there is no such list (PT-3).
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

/// Whether Bluetooth can be used at all, in the app's own words.
///
/// `CBManagerState` collapsed to the five cases the UI has different sentences
/// for. The distinction that matters is *whose problem it is*: `.unauthorised`
/// and `.poweredOff` the operator can fix, `.unsupported` they cannot.
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

    /// The characteristics the central subscribed to on this peripheral. Every
    /// notifying characteristic it found, because PT-3 forbids guessing which
    /// one matters.
    case subscribed(id: UUID, paths: [BLECharacteristicPath])

    /// A notification arrived. The only event the runtime PTT path cares about.
    case notified(id: UUID, signal: BLESignal)
}

/// The seam that keeps CoreBluetooth out of the PTT state logic.
///
/// The same idea as `RadioCore.DatagramTransport` and this app's ``AudioIO``:
/// CoreBluetooth cannot run in a headless test — there is no radio, no
/// accessory and, in a test bundle, no authorisation prompt to answer — so
/// everything above this protocol deals in `BLECentralEvent` values instead.
/// Scanning, connecting, learn mode, the mapping, reconnection and the SF-2
/// drop are all tested against `FakeBLECentral` with no radio anywhere.
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

    /// Scans for anything advertising. Foreground only, by design: iOS refuses
    /// a service-less scan in the background, and the background mode is for
    /// keeping an *established* link alive (PT-2), not for finding new ones.
    func startScan()
    func stopScan()

    func connect(_ id: UUID)
    func disconnect(_ id: UUID)

    func subscribeToAllNotifyingCharacteristics(_ id: UUID)

    /// **Ask the link to prove it carries data**, by reading any readable
    /// characteristic.
    ///
    /// The result arrives as an ordinary ``BLECentralEvent/notified(id:signal:)``,
    /// because a read and a notification are the same callback in CoreBluetooth —
    /// the fact that once caused a false diagnosis of learn mode, put to work.
    ///
    /// This exists because **nothing else on this seam is evidence.**
    /// `.connected` is not: a link was observed reporting connected while
    /// delivering nothing. A successful subscribe is not either: five in a row
    /// reported success over a dead link. And waiting for a *notification* is not
    /// evidence of anything within a useful time, because a PTT button is
    /// legitimately silent for minutes — which is the flaw this call fixes.
    ///
    /// A no-op when the peripheral has nothing readable, or is not connected.
    /// Silence is then the answer, and the caller must not read anything into it.
    func probeForLiveness(_ id: UUID)
}
