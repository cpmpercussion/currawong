// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One module on a reflector — a channel, in the reflector's own vocabulary.
///
/// Modelled rather than left as a bare `String`: a multiprotocol reflector's
/// modules are not interchangeable, and the ones that are D-Star or DMR
/// cannot be used from here at all.
struct ReflectorModule: Equatable, Sendable, Identifiable {
    /// The module letter, `A`–`Z`. This is what goes on the wire.
    var letter: String

    /// What the listing said this module carries, e.g. `"All modes"` on a
    /// transcoding module. `nil` on a plain M17 reflector, where saying so on
    /// each of twenty-six rows would be noise.
    var note: String?

    var id: String { letter }
}

/// One M17 reflector, in the app's own vocabulary: who it is, where it is, who
/// runs it, and which modules it has. The published listing carries more than
/// this (a slug, IPv6, DNS cache timestamps) that an operator does not need.
struct M17Reflector: Equatable, Sendable, Identifiable {
    /// `M17-AUS`, `URF018`. The name everybody uses; the listing is keyed by it.
    var designator: String

    /// A longer name, when the listing gives one. Most entries do not.
    var name: String?

    /// What to connect to — a host name where the listing has one, an address
    /// otherwise, empty if neither. A name is preferred over an address:
    /// reflectors move, and the listing's own DNS cache is a snapshot, while
    /// the resolver on the device is current.
    var host: String

    var port: UInt16

    /// The callsign or organisation running it.
    var sponsor: String?

    /// Two-letter country code, as the listing gives it. Not localised: `AU`
    /// is what an operator will have seen elsewhere.
    var country: String?

    /// The modules that can be linked from here, in the listing's order.
    var modules: [ReflectorModule]

    /// The reflector's own dashboard, where the listing gives one.
    ///
    /// Answers what the host file cannot — who was last heard, which modules
    /// are active, what the reflector is bridging — but every reflector runs
    /// its own dashboard in its own dialect of HTML, so this is a link out
    /// rather than something scraped and parsed.
    ///
    /// `nil` when the listing has no URL, or what it has is not a web address
    /// — see ``M17HostFile``, which makes that judgement.
    var dashboard: URL? = nil

    /// Whether this is a multiprotocol reflector (a URF bridging M17 to
    /// D-Star, DMR and others) rather than a native M17 one. Worth showing: on
    /// a bridged module the far end may not be running M17, and audio is
    /// transcoded on the way.
    var isMultiprotocol: Bool

    var id: String { designator }

    /// Whether there is anything here to connect to.
    var hasDialableHost: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `"M17-AUS · Australia-wide"`, or just the designator when there is no
    /// second name — which is the common case.
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

    /// A channel pointed at this reflector's `module`, based on an existing one.
    ///
    /// Takes a template for the same reason `DirectoryStation` does: the fields
    /// this does not set are things the operator has already configured, and a
    /// chooser that dropped them would hand back a channel that cannot connect.
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

/// Fetches the published list of M17 reflectors.
///
/// A protocol so the chooser can be tested, and the app run, without a
/// network. The real implementation is ``HostFileReflectorDirectory``.
///
/// Unlike ``StationDirectory``, nothing here touches the library or a radio
/// protocol: this is an HTTPS GET of a JSON file the M17 Project publishes for
/// exactly this purpose, so it does not live in `CompositionRoot` — there is
/// no library type for that file to hide.
protocol ReflectorDirectory: Sendable {
    /// Every reflector the published listing carries.
    func reflectors() async throws -> [M17Reflector]
}

/// Why the reflector list could not be had.
enum ReflectorDirectoryError: Error, Equatable, CustomStringConvertible {
    /// The request failed, or the server answered with something other than
    /// success.
    case unreachable(detail: String)

    /// The file arrived but was not the shape we expect.
    case malformed(detail: String)

    /// It parsed and there was nothing in it — distinct from `malformed`
    /// because the list is being served, just empty.
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

/// The reflector chooser's state, kept out of the view so it can be tested.
///
/// Mirrors ``StationBrowser`` deliberately: two panes doing the same job for
/// two networks should not have two different shapes. The difference is what
/// the fetch costs — this is a static JSON file on a CDN, so unlike the
/// EchoLink browser (which would be seizing a public proxy), this one may
/// fetch on appear without asking the operator.
@MainActor
final class ReflectorBrowser: ObservableObject {
    /// What the operator typed to narrow the list.
    @Published var search: String = ""

    @Published private(set) var reflectors: [M17Reflector] = []
    @Published private(set) var isLoading = false

    /// Why the last fetch failed, in words the operator can act on.
    @Published private(set) var failure: String?

    /// When the list was fetched, shown so an old list isn't presented as
    /// current.
    @Published private(set) var fetchedAt: Date?

    private let directory: ReflectorDirectory
    private let now: @MainActor () -> Date
    private var fetchTask: Task<Void, Never>?

    /// Bumped by every ``load()``, so a superseded fetch can tell that it is
    /// one. Same hazard and same guard as `StationBrowser` and `ProxyPicker`.
    private var generation = 0

    init(directory: ReflectorDirectory, now: @escaping @MainActor () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Whether a fetch has ever succeeded. Drives "load it the first time the
    /// pane is looked at, and not on every appearance after that".
    var hasList: Bool { fetchedAt != nil }

    /// The list, filtered by ``search``. No re-ordering: the listing arrives
    /// grouped by designator, the order an operator scanning for `M17-AUS`
    /// expects. Matches everything visible on the row.
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

            // Guarded by generation for the same reason `StationBrowser`'s is:
            // a cancelled task observes its cancellation after the `load` that
            // cancelled it has already set `isLoading` back to true, so an
            // unguarded `defer` clears the wrong fetch's spinner.
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

    /// Fetches only if nothing has been fetched yet. Called when the pane
    /// appears, so it isn't re-downloaded on every switch between panes.
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
