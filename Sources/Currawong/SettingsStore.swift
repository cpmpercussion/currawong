// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the non-secret half of ``NodeSettings`` is kept between launches.
///
/// A protocol so the view model can be tested without touching the real
/// defaults database — a unit test that writes to `UserDefaults.standard`
/// leaks into every later run on the same machine.
protocol SettingsStore: AnyObject, Sendable {
    func load() -> NodeSettings?
    func save(_ settings: NodeSettings)
}

/// `UserDefaults`-backed settings, stored as JSON under one key.
///
/// **No secret ever reaches this type.** ``NodeSettings`` does not have a
/// secret field, which is the point: the password cannot be persisted here by
/// accident, only deliberately, and nobody is going to do that deliberately.
/// One key rather than five keeps a partially-written settings set impossible.
final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private static let key = "au.charlesmartin.currawong.nodeSettings"

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
}
