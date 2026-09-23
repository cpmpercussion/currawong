// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the non-secret half of ``NodeSettings`` is kept between launches.
///
/// A protocol so the view model can be tested without touching the real
/// defaults database — a unit test that writes to `UserDefaults.standard`
/// leaks into every later run on the same machine.
///
/// Three shapes, deliberately: ``load()``/``save(_:)`` are the pre-APP-4
/// single-node store, kept because the migration reads it forward as the
/// operator's first channel; ``loadChannels()``/``saveChannels(_:)`` are the
/// list everything above this file now uses; ``loadDrafts()``/``saveDrafts(_:)``
/// are the unsaved edits to it (BU-9) — a third thing, not a state the channel
/// list can be in.
protocol SettingsStore: AnyObject, Sendable {
    func load() -> NodeSettings?
    func save(_ settings: NodeSettings)

    /// Every saved channel, in the operator's order, or `nil` if none has ever
    /// been saved. `nil` and `[]` are different: `nil` means "no channel list
    /// has been written", which is what triggers the migration; `[]` means the
    /// operator deleted their last channel, which must not resurrect it.
    func loadChannels() -> [NodeSettings]?
    func saveChannels(_ channels: [NodeSettings])

    /// Which channel was selected when the app last quit. `nil` if none was, or
    /// if the one that was has since been deleted.
    func loadSelectedChannelID() -> UUID?
    func saveSelectedChannelID(_ id: UUID?)

    /// **BU-9.** The unsaved edits, one per channel they belong to, or `nil` if
    /// none has ever been written.
    ///
    /// A draft is a channel value — the same ``NodeSettings``, carrying the
    /// same ``NodeSettings/id`` as the stored channel it was edited from — so a
    /// draft whose id is in no channel is simply one never saved. Kept apart
    /// from ``loadChannels()`` because the two are meant to disagree: the
    /// channel list is what the operator saved, and this is what they were
    /// mid-typing when the app went away. Merging them is the overwrite BU-9
    /// exists to stop.
    func loadDrafts() -> [NodeSettings]?
    func saveDrafts(_ drafts: [NodeSettings])

    /// The operator — callsign, name and location — which is app-wide rather
    /// than per channel.
    ///
    /// `nil` means none has been saved under its own key, which is the signal
    /// to look for one in channels written before the callsign was hoisted out
    /// of them. See ``UserDefaultsSettingsStore/loadIdentity()``.
    func loadIdentity() -> OperatorIdentity?
    func saveIdentity(_ identity: OperatorIdentity)

    /// Software gain on the transmit path. App-wide: it compensates for this
    /// device and this voice, not for where the audio is going. `nil` if the
    /// operator has never set one.
    func loadTransmitGain() -> TransmitGain?
    func saveTransmitGain(_ gain: TransmitGain)

    /// Software gain on the receive path, app-wide for the same reason: it is
    /// about how loud this device is in this room. `nil` if never set.
    func loadReceiveGain() -> ReceiveGain?
    func saveReceiveGain(_ gain: ReceiveGain)

    /// **SF-1.** The transmit watchdog timeout, app-wide. `nil` means the same
    /// as ``loadIdentity()``'s `nil`: look for one hoisted out of older channels.
    func loadTransmitTimeout() -> TransmitTimeout?
    func saveTransmitTimeout(_ timeout: TransmitTimeout)

    /// **APP-13.** The operator's own EchoLink proxy, app-wide, with the same
    /// `nil`-means-look-in-older-channels rule as ``loadIdentity()``.
    func loadEchoLinkProxy() -> StoredEchoLinkProxy?
    func saveEchoLinkProxy(_ proxy: EchoLinkProxySettings)

    /// **APP-33.** Which version of the licence acknowledgement the operator has
    /// accepted, or `nil` if they never have. A version, not a flag — see
    /// ``LicenceAcknowledgement``. No migration behind this one: an operator
    /// updating into the version that introduced it has correctly acknowledged
    /// nothing, since there was no wording yet to agree to.
    func loadLicenceAcknowledgement() -> Int?
    func saveLicenceAcknowledgement(_ version: Int)
}

/// What ``SettingsStore/loadEchoLinkProxy()`` found, and where.
///
/// The password is separate and optional because it is migration output, not
/// stored state: it lives in the Keychain, which this type cannot reach, so a
/// password harvested from an old channel blob is handed up to whoever can
/// write it. Non-`nil` means "from a pre-APP-13 channel, not yet filed".
struct StoredEchoLinkProxy: Equatable {
    var settings: EchoLinkProxySettings
    var harvestedPassword: String?
}

/// `UserDefaults`-backed settings, stored as JSON under one key per concern.
///
/// No secret ever reaches this type: ``NodeSettings`` has no secret field, so
/// one cannot be persisted here by accident. The only proxy password this type
/// sees is one it reads out of a pre-APP-13 blob to file properly elsewhere.
///
/// One key for the whole channel list, not one per channel, for the same
/// reason the single node used one key for five fields: a partially-written
/// set of channels is then impossible.
final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    /// The pre-APP-4 single-node key. Read but never written — the migration in
    /// ``ChannelSet`` consumes it. Left in place, not deleted, so an operator
    /// who downgrades still finds their node where they left it.
    private static let key = "au.charlesmartin.currawong.nodeSettings"
    private static let channelsKey = "au.charlesmartin.currawong.channels"
    private static let draftsKey = "au.charlesmartin.currawong.channelDrafts"
    private static let selectedKey = "au.charlesmartin.currawong.selectedChannel"
    private static let identityKey = "au.charlesmartin.currawong.operatorIdentity"
    private static let transmitGainKey = "au.charlesmartin.currawong.transmitGainDB"
    private static let transmitTimeoutKey = "au.charlesmartin.currawong.transmitTimeoutSeconds"
    private static let receiveGainKey = "au.charlesmartin.currawong.receiveGainDB"
    private static let echoLinkProxyKey = "au.charlesmartin.currawong.echoLinkProxy"
    /// **APP-33.** Internal, not private — the only key here that is:
    /// ``DefaultsSuite`` writes it when a UI test asks to start already
    /// acknowledged.
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

    /// The app-wide callsign, harvesting one from older per-channel settings if
    /// this is the first launch since the callsign was hoisted out of them.
    ///
    /// Reads raw JSON rather than decoding through `NodeSettings`, which no
    /// longer has a `callsign` field and would silently drop the old value.
    /// Channels first, then the pre-APP-4 single node — the order they were
    /// written in. Nothing is written back here: saving is
    /// ``saveIdentity(_:)``'s job, once the value has been through
    /// `OperatorIdentity.validated()`.
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

        // A callsign is what makes it an identity worth having; an install
        // with neither is simply not migrated.
        return harvested.callsign.isEmpty ? nil : harvested
    }

    func saveIdentity(_ identity: OperatorIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Self.identityKey)
    }

    /// Stored as a bare number rather than as JSON: it is one scalar, and
    /// `object(forKey:)` distinguishes "never set" from "set to zero", which
    /// `double(forKey:)` alone would not — and zero is a meaningful setting.
    func loadTransmitGain() -> TransmitGain? {
        guard defaults.object(forKey: Self.transmitGainKey) != nil else { return nil }
        return TransmitGain(decibels: defaults.double(forKey: Self.transmitGainKey))
    }

    func saveTransmitGain(_ gain: TransmitGain) {
        defaults.set(gain.decibels, forKey: Self.transmitGainKey)
    }

    /// As ``loadTransmitGain()``: a bare number, and `object(forKey:)` so that
    /// "never set" is distinguishable from "set to zero" — and zero is the
    /// default, which makes the distinction worth keeping rather than academic.
    func loadReceiveGain() -> ReceiveGain? {
        guard defaults.object(forKey: Self.receiveGainKey) != nil else { return nil }
        return ReceiveGain(decibels: defaults.double(forKey: Self.receiveGainKey))
    }

    func saveReceiveGain(_ gain: ReceiveGain) {
        defaults.set(gain.decibels, forKey: Self.receiveGainKey)
    }

    /// **SF-1.** The app-wide watchdog timeout, harvesting one from older
    /// per-channel settings if this is the first launch since it was hoisted out
    /// of them. Raw JSON, as ``loadIdentity()``: an operator who deliberately
    /// set a short leash should not silently be given the default back.
    ///
    /// The shortest stored value wins, not the newest: with several channels'
    /// worth of candidates and no single right answer, this is the only choice
    /// that cannot lengthen a limit the operator chose. Raising a safety ceiling
    /// is not a migration's decision to make.
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

    /// Stored as a bare number, on the same reasoning as ``saveTransmitGain(_:)``.
    func saveTransmitTimeout(_ timeout: TransmitTimeout) {
        defaults.set(timeout.seconds, forKey: Self.transmitTimeoutKey)
    }

    /// **APP-33.** `nil` when the key has never been written — which
    /// `integer(forKey:)` alone cannot say, since it answers `0` for both
    /// "never acknowledged" and a stored `0`.
    func loadLicenceAcknowledgement() -> Int? {
        guard defaults.object(forKey: Self.licenceAcknowledgementKey) != nil else { return nil }
        return defaults.integer(forKey: Self.licenceAcknowledgementKey)
    }

    func saveLicenceAcknowledgement(_ version: Int) {
        defaults.set(version, forKey: Self.licenceAcknowledgementKey)
    }

    /// **APP-13.** The app-wide private proxy, rescuing one from older
    /// per-channel settings if this is the first launch since it was hoisted out
    /// of them. Raw JSON, as ``loadIdentity()``: `NodeSettings` no longer has a
    /// `proxyPassword` and blanks an EchoLink `host` at decode.
    ///
    /// A password other than `PUBLIC` is rescued as the operator's own proxy;
    /// `PUBLIC` itself is dropped, deliberately, even though it is the honest
    /// default and not proof of anything suspicious — because the alternative
    /// failure is worse. Adopting a stray public proxy as "your own" makes it
    /// permanent, invisible station infrastructure: a stranger's single-user
    /// machine, treated as the operator's own on every session after. Dropping
    /// a genuine private proxy costs one field retyped in Settings.
    ///
    /// Nothing is written back from here. The caller files the password in the
    /// Keychain and then saves, which stops the harvest running twice.
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

    /// The first non-empty value of `key` across the stored blobs.
    ///
    /// Each field is harvested independently, not all three from whichever
    /// channel had a callsign: they are three facts about one person, so mixing
    /// sources cannot produce a wrong person. Trimmed, since these blobs
    /// pre-date `validated()` and a callsign of three spaces is something they
    /// can genuinely contain.
    private static func firstNonEmpty(_ key: String, in blobs: [[String: Any]]) -> String? {
        blobs.lazy
            .compactMap { ($0[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Channels first, then the pre-APP-4 single node: the order they were
    /// written in, so the newer answer wins.
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

/// The operator's channels and which one is selected, as one value.
///
/// Pulled out of ``RadioSession`` so the list logic — migration, selection
/// following a deletion, keeping a selection valid — can be tested without a
/// view model, an audio device or a clock. The session owns one of these and
/// publishes changes; this type does the arithmetic.
struct ChannelSet: Equatable {
    /// Every saved channel, in the order the operator sees them.
    private(set) var channels: [NodeSettings]

    /// The selected channel's id, or `nil` when the list is empty.
    ///
    /// Invariant, maintained by every mutating member here: this is either `nil`
    /// or an id that exists in ``channels``. A selection pointing at a deleted
    /// channel is the bug this type exists to make unrepresentable.
    private(set) var selectedID: UUID?

    init(channels: [NodeSettings] = [], selectedID: UUID? = nil) {
        self.channels = channels
        self.selectedID = channels.contains(where: { $0.id == selectedID })
            ? selectedID
            : channels.first?.id
    }

    /// Reads the store, bringing a pre-APP-4 single node forward as one channel.
    ///
    /// The migration runs when no channel list has ever been written, not when
    /// the list is empty: an operator who deletes their last channel should not
    /// find it resurrected next launch.
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

    /// Selects a channel by id. A id that is not in the list is ignored rather
    /// than clearing the selection — the caller has a stale reference, and
    /// dropping the operator's current channel over it would be worse.
    mutating func select(_ id: UUID) {
        guard channels.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Adds a channel and selects it, because adding one is something an
    /// operator does in order to use it.
    mutating func add(_ channel: NodeSettings) {
        channels.append(channel)
        selectedID = channel.id
    }

    /// Replaces a channel in place, matched by id. Does nothing if it is not in
    /// the list — the selection and the order both stay put, which is what an
    /// edit should do.
    mutating func update(_ channel: NodeSettings) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[index] = channel
    }

    /// Removes a channel. If it was the selected one, the selection moves to the
    /// neighbour that took its place in the list — the one below, or the new
    /// last one if it was at the end — so there is still somewhere to be.
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
