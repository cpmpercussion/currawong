// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One module on a reflector — a channel, in the reflector's own vocabulary.
///
/// A letter, and sometimes a word about what it carries. Modelled rather than
/// left as a bare `String` because a multiprotocol reflector's modules are not
/// interchangeable: some are D-Star or DMR and cannot be used from here at all,
/// and the ones that can are worth labelling as such.
struct ReflectorModule: Equatable, Sendable, Identifiable {
    /// The module letter, `A`–`Z`. This is what goes on the wire.
    var letter: String

    /// What the listing said this module carries, when it is worth repeating —
    /// `"All modes"` on a transcoding module, for instance. `nil` on a plain
    /// M17 reflector, where every module is an M17 module and saying so on each
    /// of twenty-six rows would be noise.
    var note: String?

    var id: String { letter }
}

/// One M17 reflector, in the app's own vocabulary.
///
/// The published listing carries rather more than this — a slug, a dashboard
/// URL, IPv6, DNS cache timestamps, the hosting network's type. What an
/// operator choosing somewhere to talk needs is who it is, where it is, who
/// runs it, and which modules it has.
struct M17Reflector: Equatable, Sendable, Identifiable {
    /// `M17-AUS`, `URF018`. The name everybody uses for the reflector, and the
    /// identity: the listing is keyed by it.
    var designator: String

    /// A longer name, when the listing gives one. Most entries do not.
    var name: String?

    /// What to connect to — a host name where the listing has one, an address
    /// otherwise. Empty when the listing has neither, which happens.
    ///
    /// A name is preferred over an address because reflectors move and the
    /// listing's own DNS cache is a snapshot; the resolver on the device is
    /// more current than a field regenerated once a day.
    var host: String

    var port: UInt16

    /// The callsign or organisation running it.
    var sponsor: String?

    /// Two-letter country code, as the listing gives it. Not localised into a
    /// country name: `AU` is what an operator will have seen the reflector
    /// called elsewhere.
    var country: String?

    /// The modules that can be linked from here, in the listing's order.
    var modules: [ReflectorModule]

    /// Whether this is a multiprotocol reflector — a URF bridging M17 to D-Star,
    /// DMR and others — rather than a native M17 one.
    ///
    /// Worth showing. On a bridged module the far end may not be running M17 at
    /// all, and audio is transcoded on the way, so an operator debugging how
    /// they sound should know which kind of reflector they are on.
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

    /// A channel pointed at this reflector's `module`, filled in from an
    /// existing channel's callsign and watchdog.
    ///
    /// Takes a template for the same reason `DirectoryStation` does: who *we*
    /// are and how long we may transmit are things the operator has already
    /// configured, and a chooser that dropped them would be handing back a
    /// channel that cannot connect.
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
/// A protocol so the chooser can be tested — and the app run — without a
/// network. The real one is ``HostFileReflectorDirectory``.
///
/// Unlike ``StationDirectory``, nothing here touches the library or a radio
/// protocol: this is an HTTPS GET of a JSON file that the M17 Project publishes
/// for exactly this purpose. So it does not live in `CompositionRoot` — there is
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

    /// It parsed, and there was nothing in it. Distinct from `malformed`
    /// because it means the list is being served but is empty, which is a
    /// problem at the other end rather than in our reading of it.
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
/// Mirrors ``StationBrowser``, and deliberately: two panes that do the same job
/// for two networks should not have two different shapes. The differences are
/// all in what the fetch costs.
///
/// ## This one may fetch on appear, and the station browser may not
///
/// The EchoLink browser refuses to fetch by itself because a listing there
/// means seizing a public proxy that serves one user at a time. This is a
/// static JSON file on a CDN. Refreshing it costs a hundred kilobytes and
/// inconveniences nobody, so the operator does not have to ask.
@MainActor
final class ReflectorBrowser: ObservableObject {
    /// What the operator typed to narrow the list.
    @Published var search: String = ""

    @Published private(set) var reflectors: [M17Reflector] = []
    @Published private(set) var isLoading = false

    /// Why the last fetch failed, in words the operator can act on.
    @Published private(set) var failure: String?

    /// When the list was fetched. Reflectors come and go and addresses change,
    /// so the age is shown rather than presenting an old list as current.
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

    /// The list, filtered by ``search``.
    ///
    /// No re-ordering: the listing arrives grouped by designator, which is the
    /// order an operator scanning for `M17-AUS` expects. Matching is on
    /// everything visible on the row, so searching `AU` finds the Australian
    /// reflectors and searching a sponsor's callsign finds theirs.
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
            // unguarded `defer` would clear the spinner belonging to the fetch
            // that replaced this one.
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

    /// Fetches only if nothing has been fetched yet. What the pane calls when it
    /// appears, so the list is there the first time it is looked at without
    /// re-downloading on every switch between panes.
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
