// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One module on a reflector. Modelled, not a bare letter, because a
/// multiprotocol reflector's modules are not interchangeable.
struct ReflectorModule: Equatable, Sendable, Identifiable {
    /// The module letter, `A`–`Z`, as sent on the wire.
    var letter: String

    /// What the module carries, e.g. `"All modes"`. `nil` on a native M17
    /// reflector.
    var note: String?

    var id: String { letter }
}

/// One M17 reflector, in the app's own vocabulary: who it is, where it is, who
/// runs it, and which modules it has.
struct M17Reflector: Equatable, Sendable, Identifiable {
    /// `M17-AUS`, `URF018`: the name everybody uses.
    var designator: String

    /// A longer name, when the listing gives one.
    var name: String?

    /// What to connect to: a host name if listed, since reflectors move and
    /// the device's resolver is current; else an address; else empty.
    var host: String

    var port: UInt16

    /// The callsign or organisation running it.
    var sponsor: String?

    /// Two-letter country code, as listed.
    var country: String?

    /// The modules that can be linked from here, in the listing's order.
    var modules: [ReflectorModule]

    /// The reflector's own dashboard, as a link out. `nil` unless the listing
    /// gives a web address (``M17HostFile/dashboard(from:)``).
    var dashboard: URL? = nil

    /// Whether this is a multiprotocol (URF) reflector, where the far end may
    /// not be on M17 and audio may be transcoded.
    var isMultiprotocol: Bool

    var id: String { designator }

    /// Whether there is anything here to connect to.
    var hasDialableHost: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `"M17-AUS · Australia-wide"`, or just the designator.
    var title: String {
        guard let name, !name.isEmpty, name != designator else { return designator }
        return "\(designator) · \(name)"
    }

    /// Country, sponsor and host on one line, skipping whatever is missing.
    var subtitle: String {
        var parts: [String] = []
        if let country, !country.isEmpty { parts.append(country) }
        if let sponsor, !sponsor.isEmpty { parts.append(sponsor) }
        parts.append(hasDialableHost ? host : "no address listed")
        return parts.joined(separator: " · ")
    }

    /// A channel pointed at this reflector's `module`, keeping the template's
    /// other fields.
    func channel(module: String, basedOn template: NodeSettings) -> NodeSettings {
        var channel = template
        channel.id = UUID()
        channel.name = "\(designator) \(module)"
        channel.mode = .m17
        channel.host = host
        channel.port = port
        channel.module = module
        return channel
    }
}

/// Fetches the published list of M17 reflectors. The real implementation is
/// ``HostFileReflectorDirectory``: a plain HTTPS fetch, with no library type
/// involved, so it lives outside `CompositionRoot`.
protocol ReflectorDirectory: Sendable {
    /// Every reflector the published listing carries.
    func reflectors() async throws -> [M17Reflector]
}

/// Why the reflector list could not be had.
enum ReflectorDirectoryError: Error, Equatable, CustomStringConvertible {
    /// The request failed or was not answered with success.
    case unreachable(detail: String)

    /// The file arrived but was not the shape we expect.
    case malformed(detail: String)

    /// It parsed, and was empty.
    case empty

    var description: String {
        switch self {
        case .unreachable(let detail):
            return """
                Could not fetch the reflector list: \(detail). It is downloaded over the \
                internet, so this device needs a connection.
                """
        case .malformed(let detail):
            return """
                The reflector list was not in the expected format: \(detail). Enter a \
                reflector's host name on the connect form instead.
                """
        case .empty:
            return "The reflector list was empty."
        }
    }
}

/// The reflector chooser's state, shaped like ``StationBrowser``. Unlike that
/// one, it may fetch on appear: the list is a static file, where an EchoLink
/// fetch would seize a public proxy.
@MainActor
final class ReflectorBrowser: ObservableObject {
    /// What the operator typed to narrow the list.
    @Published var search: String = ""

    @Published private(set) var reflectors: [M17Reflector] = []
    @Published private(set) var isLoading = false

    /// Why the last fetch failed, in words the operator can act on.
    @Published private(set) var failure: String?

    /// When the list was fetched, so the browser can show its age.
    @Published private(set) var fetchedAt: Date?

    private let directory: ReflectorDirectory
    private let now: @MainActor () -> Date
    private var fetchTask: Task<Void, Never>?

    /// Bumped by every ``load()``, so a superseded fetch can tell.
    private var generation = 0

    init(directory: ReflectorDirectory, now: @escaping @MainActor () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Whether a fetch has ever succeeded.
    var hasList: Bool { fetchedAt != nil }

    /// The list in listed order, filtered by ``search`` against everything
    /// visible on a row.
    var visibleReflectors: [M17Reflector] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else { return reflectors }
        return reflectors.filter { reflector in
            reflector.designator.uppercased().contains(query)
                || reflector.name?.uppercased().contains(query) == true
                || reflector.country?.uppercased().contains(query) == true
                || reflector.sponsor?.uppercased().contains(query) == true
                || reflector.host.uppercased().contains(query)
        }
    }

    /// Fetches the list. A second call while one is in flight replaces it.
    func load() {
        fetchTask?.cancel()

        isLoading = true
        failure = nil
        generation += 1
        let generation = generation

        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Generation-guarded, as in `StationBrowser`.
            defer { if self.generation == generation { self.isLoading = false } }

            do {
                let fetched = try await self.directory.reflectors()
                guard !Task.isCancelled, self.generation == generation else { return }
                self.reflectors = fetched
                self.fetchedAt = self.now()
                self.failure = fetched.isEmpty ? ReflectorDirectoryError.empty.description : nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.failure = "\(error)"
            }
        }
    }

    /// Fetches only if nothing has been fetched yet; called on appear.
    func loadIfNeeded() {
        guard !hasList, !isLoading else { return }
        load()
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        isLoading = false
    }
}
