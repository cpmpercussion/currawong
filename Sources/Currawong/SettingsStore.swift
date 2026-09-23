// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the app's non-secret settings are kept between launches. A protocol
/// so tests never write to the real defaults database.
///
/// ``load()``/``save(_:)`` are the pre-APP-4 single-node store, read only by
/// the migration to channels.
protocol SettingsStore: AnyObject, Sendable {
    func load() -> NodeSettings?
    func save(_ settings: NodeSettings)

    /// Every saved channel, in the operator's order. `nil` (never written)
    /// triggers the migration; `[]` means the operator deleted them all.
    func loadChannels() -> [NodeSettings]?
    func saveChannels(_ channels: [NodeSettings])

    /// Which channel was selected when the app last quit.
    func loadSelectedChannelID() -> UUID?
    func saveSelectedChannelID(_ id: UUID?)

    /// Unsaved edits (BU-9), each carrying the id of the channel it was edited
    /// from. Kept apart from ``loadChannels()`` because the two are meant to
    /// disagree until the operator saves.
    func loadDrafts() -> [NodeSettings]?
    func saveDrafts(_ drafts: [NodeSettings])

    /// The app-wide operator identity. `nil` means none is stored under its
    /// own key yet; older channels are searched for one first.
    func loadIdentity() -> OperatorIdentity?
    func saveIdentity(_ identity: OperatorIdentity)

    /// Transmit software gain, app-wide. `nil` if never set.
    func loadTransmitGain() -> TransmitGain?
    func saveTransmitGain(_ gain: TransmitGain)

    /// Receive software gain, app-wide. `nil` if never set.
    func loadReceiveGain() -> ReceiveGain?
    func saveReceiveGain(_ gain: ReceiveGain)

    /// **SF-1.** The transmit watchdog timeout, app-wide, migrated from older
    /// channels when absent.
    func loadTransmitTimeout() -> TransmitTimeout?
    func saveTransmitTimeout(_ timeout: TransmitTimeout)

    /// The operator's own EchoLink proxy (APP-13), app-wide, migrated from
    /// older channels when absent.
    func loadEchoLinkProxy() -> StoredEchoLinkProxy?
    func saveEchoLinkProxy(_ proxy: EchoLinkProxySettings)

    /// Which version of the licence acknowledgement was accepted (APP-33), or
    /// `nil` if none. No migration: there was nothing to accept before it.
    func loadLicenceAcknowledgement() -> Int?
    func saveLicenceAcknowledgement(_ version: Int)
}

/// What ``SettingsStore/loadEchoLinkProxy()`` found.
///
/// `harvestedPassword` is migration output: a password read from an old
/// channel blob, handed up for the caller to file in the Keychain.
struct StoredEchoLinkProxy: Equatable {
    var settings: EchoLinkProxySettings
    var harvestedPassword: String?
}

/// `UserDefaults`-backed settings, as JSON under one key per concern.
///
/// Never stores a secret. The channel list is one key, so it cannot be
/// partially written.
final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    /// The pre-APP-4 single-node key. Read by the migration, never written or
    /// deleted, so a downgrade still finds it.
    private static let key = "au.charlesmartin.currawong.nodeSettings"
    private static let channelsKey = "au.charlesmartin.currawong.channels"
    private static let draftsKey = "au.charlesmartin.currawong.channelDrafts"
    private static let selectedKey = "au.charlesmartin.currawong.selectedChannel"
    private static let identityKey = "au.charlesmartin.currawong.operatorIdentity"
    private static let transmitGainKey = "au.charlesmartin.currawong.transmitGainDB"
    private static let transmitTimeoutKey = "au.charlesmartin.currawong.transmitTimeoutSeconds"
    private static let receiveGainKey = "au.charlesmartin.currawong.receiveGainDB"
    private static let echoLinkProxyKey = "au.charlesmartin.currawong.echoLinkProxy"
    /// Internal so ``DefaultsSuite`` can pre-acknowledge for UI tests.
    static let licenceAcknowledgementKey =
        "au.charlesmartin.currawong.licenceAcknowledgement"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> NodeSettings? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(NodeSettings.self, from: data)
    }

    func save(_ settings: NodeSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func loadChannels() -> [NodeSettings]? {
        guard let data = defaults.data(forKey: Self.channelsKey) else { return nil }
        return try? JSONDecoder().decode([NodeSettings].self, from: data)
    }

    func saveChannels(_ channels: [NodeSettings]) {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        defaults.set(data, forKey: Self.channelsKey)
    }

    func loadDrafts() -> [NodeSettings]? {
        guard let data = defaults.data(forKey: Self.draftsKey) else { return nil }
        return try? JSONDecoder().decode([NodeSettings].self, from: data)
    }

    func saveDrafts(_ drafts: [NodeSettings]) {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        defaults.set(data, forKey: Self.draftsKey)
    }

    func loadSelectedChannelID() -> UUID? {
        guard let string = defaults.string(forKey: Self.selectedKey) else { return nil }
        return UUID(uuidString: string)
    }

    func saveSelectedChannelID(_ id: UUID?) {
        guard let id else {
            defaults.removeObject(forKey: Self.selectedKey)
            return
        }
        defaults.set(id.uuidString, forKey: Self.selectedKey)
    }

    /// The app-wide identity, or one harvested from older channel blobs.
    ///
    /// Reads raw JSON, since `NodeSettings` no longer decodes these fields.
    /// Writes nothing back; ``saveIdentity(_:)`` does, after validation.
    func loadIdentity() -> OperatorIdentity? {
        if let data = defaults.data(forKey: Self.identityKey),
            let identity = try? JSONDecoder().decode(OperatorIdentity.self, from: data)
        {
            return identity
        }

        let blobs =
            Self.storedChannelBlobs(defaults: defaults)
            + [Self.storedNodeBlob(defaults: defaults)].compactMap { $0 }

        let harvested = OperatorIdentity(
            callsign: Self.firstNonEmpty("callsign", in: blobs) ?? "",
            operatorName: Self.firstNonEmpty("operatorName", in: blobs) ?? "",
            location: Self.firstNonEmpty("location", in: blobs) ?? "")

        // No callsign, nothing worth migrating.
        return harvested.callsign.isEmpty ? nil : harvested
    }

    func saveIdentity(_ identity: OperatorIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Self.identityKey)
    }

    /// A bare number. `object(forKey:)` tells "never set" from a meaningful
    /// zero, which `double(forKey:)` alone cannot.
    func loadTransmitGain() -> TransmitGain? {
        guard defaults.object(forKey: Self.transmitGainKey) != nil else { return nil }
        return TransmitGain(decibels: defaults.double(forKey: Self.transmitGainKey))
    }

    func saveTransmitGain(_ gain: TransmitGain) {
        defaults.set(gain.decibels, forKey: Self.transmitGainKey)
    }

    /// As ``loadTransmitGain()``.
    func loadReceiveGain() -> ReceiveGain? {
        guard defaults.object(forKey: Self.receiveGainKey) != nil else { return nil }
        return ReceiveGain(decibels: defaults.double(forKey: Self.receiveGainKey))
    }

    func saveReceiveGain(_ gain: ReceiveGain) {
        defaults.set(gain.decibels, forKey: Self.receiveGainKey)
    }

    /// **SF-1.** The app-wide watchdog timeout, or one harvested from older
    /// channel blobs.
    ///
    /// **The shortest stored value wins**, not the newest: it is the only
    /// choice that cannot lengthen a limit the operator chose. Raising a safety
    /// ceiling is not a migration's decision.
    func loadTransmitTimeout() -> TransmitTimeout? {
        if defaults.object(forKey: Self.transmitTimeoutKey) != nil {
            return TransmitTimeout(seconds: defaults.double(forKey: Self.transmitTimeoutKey))
        }

        let blobs =
            Self.storedChannelBlobs(defaults: defaults)
            + [Self.storedNodeBlob(defaults: defaults)].compactMap { $0 }

        let stored = blobs.compactMap { ($0["transmitTimeout"] as? NSNumber)?.doubleValue }
            .filter { $0.isFinite }
        guard let shortest = stored.min() else { return nil }
        return TransmitTimeout(seconds: shortest)
    }

    /// A bare number, as ``loadTransmitGain()``.
    func saveTransmitTimeout(_ timeout: TransmitTimeout) {
        defaults.set(timeout.seconds, forKey: Self.transmitTimeoutKey)
    }

    /// `nil` when never written, which `integer(forKey:)` alone cannot say.
    func loadLicenceAcknowledgement() -> Int? {
        guard defaults.object(forKey: Self.licenceAcknowledgementKey) != nil else { return nil }
        return defaults.integer(forKey: Self.licenceAcknowledgementKey)
    }

    func saveLicenceAcknowledgement(_ version: Int) {
        defaults.set(version, forKey: Self.licenceAcknowledgementKey)
    }

    /// The app-wide private proxy, or one rescued from older EchoLink channel
    /// blobs (raw JSON, as ``loadIdentity()``).
    ///
    /// Only a password other than `PUBLIC` is rescued. Adopting a stranger's
    /// public proxy as the operator's own would be permanent and invisible;
    /// dropping a genuine private one costs one field retyped.
    ///
    /// Writes nothing back; the caller files the password, then saves.
    func loadEchoLinkProxy() -> StoredEchoLinkProxy? {
        if let data = defaults.data(forKey: Self.echoLinkProxyKey),
            let stored = try? JSONDecoder().decode(EchoLinkProxySettings.self, from: data)
        {
            return StoredEchoLinkProxy(settings: stored, harvestedPassword: nil)
        }

        let blobs =
            Self.storedChannelBlobs(defaults: defaults)
            + [Self.storedNodeBlob(defaults: defaults)].compactMap { $0 }

        for blob in blobs {
            guard (blob["mode"] as? String) == RadioMode.echoLink.rawValue else { continue }
            let host =
                (blob["host"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let password =
                (blob["proxyPassword"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !host.isEmpty, !password.isEmpty,
                password != EchoLinkProxySettings.publicPassword
            else { continue }

            let port = (blob["port"] as? NSNumber)?.uint16Value ?? EchoLinkProxySettings.defaultPort
            return StoredEchoLinkProxy(
                settings: EchoLinkProxySettings(host: host, port: port),
                harvestedPassword: password)
        }

        return nil
    }

    func saveEchoLinkProxy(_ proxy: EchoLinkProxySettings) {
        guard let data = try? JSONEncoder().encode(proxy) else { return }
        defaults.set(data, forKey: Self.echoLinkProxyKey)
    }

    /// The first non-empty, trimmed value of `key` across the stored blobs.
    /// Each field is harvested independently: all describe one person.
    private static func firstNonEmpty(_ key: String, in blobs: [[String: Any]]) -> String? {
        blobs.lazy
            .compactMap { ($0[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Callers put these before the single-node blob, so the newer answer wins.
    private static func storedChannelBlobs(defaults: UserDefaults) -> [[String: Any]] {
        guard let data = defaults.data(forKey: channelsKey),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array
    }

    private static func storedNodeBlob(defaults: UserDefaults) -> [String: Any]? {
        guard let data = defaults.data(forKey: key),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

/// The operator's channels and which one is selected, as one testable value.
/// ``RadioSession`` owns one and publishes its changes.
struct ChannelSet: Equatable {
    /// Every saved channel, in the order the operator sees them.
    private(set) var channels: [NodeSettings]

    /// The selected channel's id. Invariant: `nil` only when the list is
    /// empty, otherwise an id in ``channels``.
    private(set) var selectedID: UUID?

    init(channels: [NodeSettings] = [], selectedID: UUID? = nil) {
        self.channels = channels
        self.selectedID = channels.contains(where: { $0.id == selectedID })
            ? selectedID
            : channels.first?.id
    }

    /// Reads the store, migrating a pre-APP-4 single node only when no channel
    /// list was ever written, so a deleted last channel stays deleted.
    static func loaded(from store: SettingsStore) -> ChannelSet {
        if let stored = store.loadChannels() {
            return ChannelSet(channels: stored, selectedID: store.loadSelectedChannelID())
        }

        guard let legacy = store.load() else { return ChannelSet() }
        return ChannelSet(channels: [legacy], selectedID: legacy.id)
    }

    /// Writes the list and the selection back.
    func save(to store: SettingsStore) {
        store.saveChannels(channels)
        store.saveSelectedChannelID(selectedID)
    }

    /// The selected channel, or `nil` when there are none.
    var selected: NodeSettings? {
        guard let selectedID else { return nil }
        return channels.first { $0.id == selectedID }
    }

    /// Selects a channel by id. An unknown id is ignored, not a deselection.
    mutating func select(_ id: UUID) {
        guard channels.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Adds a channel and selects it.
    mutating func add(_ channel: NodeSettings) {
        channels.append(channel)
        selectedID = channel.id
    }

    /// Replaces a channel in place, matched by id; a no-op if absent.
    mutating func update(_ channel: NodeSettings) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[index] = channel
    }

    /// Removes a channel. A removed selection moves to the neighbour that took
    /// its place, or the new last one.
    mutating func remove(_ id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels.remove(at: index)

        guard selectedID == id else { return }
        if channels.isEmpty {
            selectedID = nil
        } else {
            selectedID = channels[min(index, channels.count - 1)].id
        }
    }

    /// Reorders, for a list the operator can drag.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
    }
}
