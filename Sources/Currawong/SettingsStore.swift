// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the non-secret half of ``NodeSettings`` is kept between launches.
///
/// A protocol so the view model can be tested without touching the real
/// defaults database — a unit test that writes to `UserDefaults.standard`
/// leaks into every later run on the same machine.
///
/// **Two shapes, deliberately.** ``load()``/``save(_:)`` are the single-node
/// store this app had before APP-4, and they are still here because they are
/// what the migration reads: an operator updating the app has exactly one node
/// in that key, and it must come forward as their first channel rather than
/// vanish. ``loadChannels()``/``saveChannels(_:)`` are the list everything
/// above this file now uses.
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

    /// The operator — callsign, name and location — which is app-wide rather
    /// than per channel.
    ///
    /// `nil` means none has ever been saved *under its own key* — which is the
    /// signal to go looking for one in the channels written before the callsign
    /// was hoisted out of them. See
    /// ``UserDefaultsSettingsStore/loadIdentity()``.
    func loadIdentity() -> OperatorIdentity?
    func saveIdentity(_ identity: OperatorIdentity)
}

/// `UserDefaults`-backed settings, stored as JSON under one key per concern.
///
/// **No secret ever reaches this type.** ``NodeSettings`` does not have a
/// secret field, which is the point: the password cannot be persisted here by
/// accident, only deliberately, and nobody is going to do that deliberately.
/// The EchoLink *proxy* password is the one exception, and it is in
/// `NodeSettings` on purpose — see ``NodeSettings/proxyPassword``.
///
/// One key for the whole list rather than one per channel, for the same reason
/// the single node used one key for five fields: a partially-written set of
/// channels is then impossible.
final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    /// The pre-APP-4 single-node key. **Read but never written** — the
    /// migration in ``ChannelSet`` consumes it, and after that the channel list
    /// is the only thing that matters. Left in place rather than deleted so an
    /// operator who downgrades still finds their node where they left it.
    private static let key = "au.charlesmartin.currawong.nodeSettings"
    private static let channelsKey = "au.charlesmartin.currawong.channels"
    private static let selectedKey = "au.charlesmartin.currawong.selectedChannel"
    private static let identityKey = "au.charlesmartin.currawong.operatorIdentity"

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
    /// **Why this reads raw JSON.** `NodeSettings` no longer has a `callsign`
    /// property, so decoding a stored channel throws the old value away — which
    /// is the correct behaviour for that type and the wrong behaviour exactly
    /// once, on the launch after the update. Rather than keep a vestigial field
    /// on `NodeSettings` for the benefit of a one-off, the migration reads the
    /// stored blobs as dictionaries and takes the first non-empty callsign it
    /// finds. The alternative is an operator who has to work out why the app
    /// suddenly will not let them transmit.
    ///
    /// Channels first, then the pre-APP-4 single node, which is the order they
    /// were written in. Nothing is written back here: saving is
    /// ``saveIdentity(_:)``'s job and the session does it once the value has
    /// been through `OperatorIdentity.validated()`.
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

        // A callsign is what makes it an identity worth having. Name and
        // location are optional everywhere else and are optional here too, so
        // an install that had neither is simply not migrated.
        return harvested.callsign.isEmpty ? nil : harvested
    }

    func saveIdentity(_ identity: OperatorIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Self.identityKey)
    }

    /// The first non-empty value of `key` across the stored blobs.
    ///
    /// Each field is harvested independently rather than all three being taken
    /// from whichever channel had a callsign. They are three facts about one
    /// person, so mixing their sources cannot produce a wrong person — whereas
    /// insisting they come from one channel would silently drop a name the
    /// operator had only ever filled in on their second channel.
    private static func firstNonEmpty(_ key: String, in blobs: [[String: Any]]) -> String? {
        blobs.lazy.compactMap { $0[key] as? String }.first { !$0.isEmpty }
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
    /// The migration runs when no channel list has ever been written — not when
    /// the list is empty. An operator who deletes their last channel has said
    /// something, and resurrecting the node they deleted on the next launch
    /// would be the app arguing with them.
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
