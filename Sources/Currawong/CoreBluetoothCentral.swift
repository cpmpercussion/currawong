// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(CoreBluetooth)

import CoreBluetooth

/// **PT-2.** The real ``BLECentral``: one `CBCentralManager` and its delegates,
/// turned into a stream of values.
///
/// This file is the only one in the app that imports CoreBluetooth, for the
/// same reason `CompositionRoot` is the only one that imports `IAX2Kit`.
/// Everything it does is translation; there is no PTT logic here at all, which
/// is what lets the logic be tested (see ``BLEPTTController``).
///
/// ## Deliberate choices
///
/// - **No service filter anywhere.** `discoverServices(nil)`,
///   `discoverCharacteristics(nil)`, and a subscription to every characteristic
///   whose properties include `.notify` or `.indicate`. PT-3 says the operator
///   teaches the app what their accessory does; a filter here would quietly
///   reintroduce the whitelist that requirement exists to delete.
/// - **The manager is built in `init`,** so nothing constructs one of these
///   until the app actually needs Bluetooth. Constructing a `CBCentralManager`
///   is what triggers the authorisation prompt, and an operator who never uses
///   an accessory should never see it.
/// - **`CBCentralManagerOptionShowPowerAlertKey: false`.** If Bluetooth is off,
///   the accessory screen says so in its own words; a system alert thrown at an
///   operator who was doing something else is worse.
/// - **State restoration on iOS only.** `CBCentralManagerOptionRestoreIdentifierKey`
///   is what lets a `bluetooth-central` app be relaunched into an existing
///   connection; macOS has no equivalent and rejects the option, so it is
///   conditional. This is the one real platform difference in the file.
final class CoreBluetoothCentral: NSObject, BLECentral, @unchecked Sendable {

    let events: AsyncStream<BLECentralEvent>
    private let continuation: AsyncStream<BLECentralEvent>.Continuation

    /// Every peripheral we have a reference to. CoreBluetooth does not retain
    /// peripherals for you: drop the reference and the connection goes with it.
    private var peripherals: [UUID: CBPeripheral] = [:]

    /// Peripherals the app wants connected, so a restore or a power cycle can
    /// re-establish them without the layer above having to notice.
    private var wanted: Set<UUID> = []

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
            // `withServices: nil` — no whitelist (PT-3). Foreground only; iOS
            // ignores a service-less scan once the app is backgrounded, which
            // is fine, because scanning is a pairing-time activity.
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
        guard let peripheral = peripherals[id], peripheral.state == .connected else {
            return
        }
        // Any readable characteristic will do: the question is whether the link
        // carries bytes, not what the bytes say. The first one found keeps this
        // cheap — a probe is issued after every rebuild.
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] {
                guard characteristic.properties.contains(.read) else { continue }
                peripheral.readValue(for: characteristic)
                return
            }
        }
        // **Nothing readable *yet*, and that is not a failure.**
        //
        // Characteristic discovery arrives service by service, and the caller
        // probes as each one is subscribed — so the first probe of a rebuild runs
        // before the readable characteristic has been discovered at all. Treating
        // that as "the link is dead" made this method the cause of the fault it
        // was written to detect: measured 2026-08-22, a probe 24 ms too early
        // reported failure, the controller rebuilt a link that was about to be
        // fine, and the whole thing looped.
        //
        // So: say nothing. A later subscription will probe again, and the
        // controller's backstop covers the pathological case of a device with
        // nothing readable at all. Only a *read that was attempted and failed* is
        // evidence about the link.
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

    /// A peripheral we have seen, or one the system remembers. The second half
    /// is what makes reconnecting to a learned accessory work after a relaunch,
    /// when nothing has been scanned yet.
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

        // A power cycle drops every connection. Re-place the ones the app still
        // wants; the layer above already knows the link is down, because a
        // disconnect event preceded this.
        if central.state == .poweredOn {
            for id in wanted {
                guard let peripheral = peripheral(for: id) else { continue }
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
            }
        }
    }

    #if os(iOS)
    /// The app was relaunched into an existing connection. Take the peripherals
    /// back before anything else happens, or they are released and the link the
    /// `bluetooth-central` background mode was granted for goes with them.
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
        // Unconditionally, and with no filter: there is nothing to connect for
        // except the notifications.
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
        // **SF-2 starts here.** Everything above this line is CoreBluetooth's;
        // everything below is the app's, and the first thing it does with this
        // event is stop transmitting. See `BLEPTTController.handle(_:)`.
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
        // A failed read is information, not noise: it is the only *positive*
        // evidence this seam can produce that a link has stopped carrying data.
        // Dropping it silently is what left the controller guessing from
        // timeouts.
        if let error {
            continuation.yield(
                .probeFailed(id: peripheral.identifier, reason: error.localizedDescription))
            return
        }
        guard let service = characteristic.service else {
            continuation.yield(.probeFailed(id: peripheral.identifier, reason: nil))
            return
        }
        // A notification with no value is still an edge on some devices, so an
        // empty payload is passed through rather than dropped.
        let signal = BLESignal(
            service: service.uuid.uuidString,
            characteristic: characteristic.uuid.uuidString,
            payload: characteristic.value ?? Data())
        continuation.yield(.notified(id: peripheral.identifier, signal: signal))
    }
}

#else

/// A platform with no CoreBluetooth. Not reachable on iOS or macOS; present so
/// the rest of the app compiles anywhere the library does.
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
