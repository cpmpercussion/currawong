// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(CoreBluetooth)

import CoreBluetooth

/// The real ``BLECentral`` (PT-2): a `CBCentralManager` and its delegates as a
/// stream of values. The only file that imports CoreBluetooth, and translation
/// only — no PTT logic.
///
/// - No service filter anywhere: everything that notifies or indicates is
///   subscribed (PT-3).
/// - The manager is built in `init`, which shows the permission prompt, so
///   construct one only when Bluetooth is wanted.
/// - No system power alert; the accessory screen says Bluetooth is off.
/// - State restoration on iOS only; macOS rejects the option.
final class CoreBluetoothCentral: NSObject, BLECentral, @unchecked Sendable {

    let events: AsyncStream<BLECentralEvent>
    private let continuation: AsyncStream<BLECentralEvent>.Continuation

    /// Every peripheral referenced. CoreBluetooth does not retain them, and a
    /// dropped reference drops the connection.
    private var peripherals: [UUID: CBPeripheral] = [:]

    /// Peripherals to reconnect after a restore or power cycle.
    private var wanted: Set<UUID> = []

    /// The characteristic each outstanding liveness probe read — the only way
    /// to tell a read's answer from a notification, which share a callback.
    /// Only touched on ``queue``; cleared on disconnection.
    private var pendingProbes: [UUID: CBUUID] = [:]

    private var manager: CBCentralManager!
    private let queue = DispatchQueue(label: "au.charlesmartin.currawong.ble")
    private let lock = NSLock()
    private var storedAvailability: BLECentralAvailability = .unknown

    override init() {
        var escaped: AsyncStream<BLECentralEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
        super.init()

        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
        #if os(iOS)
        options[CBCentralManagerOptionRestoreIdentifierKey] =
            "au.charlesmartin.currawong.ble.central"
        #endif
        self.manager = CBCentralManager(delegate: self, queue: queue, options: options)
    }

    deinit {
        continuation.finish()
    }

    var availability: BLECentralAvailability {
        lock.lock()
        defer { lock.unlock() }
        return storedAvailability
    }

    // MARK: - BLECentral

    func startScan() {
        queue.async { [weak self] in
            guard let self, self.manager.state == .poweredOn else { return }
            // No service filter (PT-3). Foreground only, which suits pairing.
            self.manager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func stopScan() {
        queue.async { [weak self] in
            guard let self, self.manager.state == .poweredOn else { return }
            self.manager.stopScan()
        }
    }

    func connect(_ id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wanted.insert(id)
            guard let peripheral = self.peripheral(for: id) else {
                self.continuation.yield(
                    .connectionFailed(id: id, reason: "The accessory is not in range."))
                return
            }
            peripheral.delegate = self
            guard self.manager.state == .poweredOn else { return }
            self.manager.connect(peripheral, options: nil)
        }
    }

    func disconnect(_ id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wanted.remove(id)
            guard let peripheral = self.peripherals[id] else { return }
            self.manager.cancelPeripheralConnection(peripheral)
        }
    }

    func probeForLiveness(_ id: UUID) {
        // On the queue: the delegate callbacks mutate this state.
        queue.async { [weak self] in
            guard let self, let peripheral = self.peripherals[id],
                peripheral.state == .connected
            else { return }
            // Any readable characteristic proves the link carries bytes.
            for service in peripheral.services ?? [] {
                for characteristic in service.characteristics ?? [] {
                    guard characteristic.properties.contains(.read) else { continue }
                    self.pendingProbes[id] = characteristic.uuid
                    peripheral.readValue(for: characteristic)
                    self.continuation.yield(.probeIssued(id: id))
                    return
                }
            }
        }
        // Nothing readable yet is not a failure: discovery arrives service by
        // service, and a later subscription probes again.
    }

    func subscribeToAllNotifyingCharacteristics(_ id: UUID) {
        queue.async { [weak self] in
            guard let self, let peripheral = self.peripherals[id] else { return }
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices(nil)
            }
        }
    }

    // MARK: - Helpers

    /// A peripheral we have seen, or one the system remembers — which is how a
    /// learned accessory reconnects after relaunch without a scan.
    private func peripheral(for id: UUID) -> CBPeripheral? {
        if let known = peripherals[id] { return known }
        guard let retrieved = manager.retrievePeripherals(withIdentifiers: [id]).first else {
            return nil
        }
        peripherals[id] = retrieved
        return retrieved
    }

    private func note(_ availability: BLECentralAvailability) {
        lock.lock()
        storedAvailability = availability
        lock.unlock()
        continuation.yield(.availabilityChanged(availability))
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let availability: BLECentralAvailability
        switch central.state {
        case .poweredOn: availability = .poweredOn
        case .poweredOff: availability = .poweredOff
        case .unauthorized: availability = .unauthorised
        case .unsupported: availability = .unsupported
        case .resetting, .unknown: availability = .unknown
        @unknown default: availability = .unknown
        }
        note(availability)

        // A power cycle drops every connection; reconnect the wanted ones. A
        // disconnect event has already told the layer above.
        if central.state == .poweredOn {
            for id in wanted {
                guard let peripheral = peripheral(for: id) else { continue }
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
            }
        }
    }

    #if os(iOS)
    /// Relaunched into an existing connection: take the peripherals back first,
    /// or they are released and the link with them.
    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        let restored = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            wanted.insert(peripheral.identifier)
            peripheral.delegate = self
            if peripheral.state == .connected {
                continuation.yield(.connected(id: peripheral.identifier))
                peripheral.discoverServices(nil)
            }
        }
    }
    #endif

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        continuation.yield(
            .discovered(
                BLEAccessory(
                    id: peripheral.identifier,
                    name: peripheral.name ?? advertised,
                    rssi: RSSI.intValue)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        continuation.yield(.connected(id: peripheral.identifier))
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        continuation.yield(
            .connectionFailed(id: peripheral.identifier, reason: error.map { "\($0)" }))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // A probe the dead link never answered must not be matched against the
        // rebuilt link's first notification.
        pendingProbes[peripheral.identifier] = nil
        // SF-2 starts here: the first thing done with this event is to stop
        // transmitting. See `BLEPTTController.handle(_:)`.
        continuation.yield(
            .disconnected(id: peripheral.identifier, reason: error.map { "\($0)" }))
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothCentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        var subscribed: [BLECharacteristicPath] = []
        for characteristic in service.characteristics ?? [] {
            guard characteristic.properties.contains(.notify)
                || characteristic.properties.contains(.indicate)
            else { continue }
            peripheral.setNotifyValue(true, for: characteristic)
            subscribed.append(
                BLECharacteristicPath(
                    service: service.uuid.uuidString,
                    characteristic: characteristic.uuid.uuidString))
        }
        guard !subscribed.isEmpty else { return }
        continuation.yield(.subscribed(id: peripheral.identifier, paths: subscribed))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Reads and notifications arrive identically; `pendingProbes` tells
        // them apart. A read reported as `.notified` could key the radio; a
        // notification taken for a read would swallow a press.
        let id = peripheral.identifier
        let answersProbe = pendingProbes[id] == characteristic.uuid
        if answersProbe { pendingProbes[id] = nil }

        // A failed probe read is evidence of a dead link. Any other error is
        // not, and must not force a rebuild.
        if let error {
            if answersProbe {
                continuation.yield(
                    .probeFailed(id: id, reason: error.localizedDescription))
            }
            return
        }
        guard let service = characteristic.service else {
            if answersProbe { continuation.yield(.probeFailed(id: id, reason: nil)) }
            return
        }
        // An empty notification is still an edge on some devices.
        let signal = BLESignal(
            service: service.uuid.uuidString,
            characteristic: characteristic.uuid.uuidString,
            payload: characteristic.value ?? Data())
        continuation.yield(
            answersProbe
                ? .probeAnswered(id: id, signal: signal)
                : .notified(id: id, signal: signal))
    }
}

#else

/// Stand-in for platforms without CoreBluetooth, so the app compiles.
final class CoreBluetoothCentral: BLECentral, @unchecked Sendable {
    let events: AsyncStream<BLECentralEvent>

    init() {
        self.events = AsyncStream { $0.finish() }
    }

    var availability: BLECentralAvailability { .unsupported }
    func startScan() {}
    func stopScan() {}
    func connect(_ id: UUID) {}
    func disconnect(_ id: UUID) {}
    func subscribeToAllNotifyingCharacteristics(_ id: UUID) {}
    func probeForLiveness(_ id: UUID) {}
}

#endif
