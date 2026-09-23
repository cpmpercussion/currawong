// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One station from an EchoLink directory listing.
///
/// The app's own vocabulary again: `EchoLinkStationList` and `EchoLinkStation`
/// are library types, and only `CompositionRoot` is allowed to see them. This
/// is what the browser displays and what a channel is built from.
struct DirectoryStation: Identifiable, Equatable, Sendable {
    /// The callsign, which is also the identity — the directory is keyed by it.
    var callsign: String

    /// Free text from the listing: a town, a repeater's frequency, a note.
    var location: String

    /// The node number, when the listing carries one.
    var nodeNumber: Int?

    /// The station's IPv4 address — the field the whole browser exists to
    /// obtain. See ``RadioMode``.
    var address: String

    /// Whether the station said it was on and free, as opposed to busy or off.
    var isConnectable: Bool

    /// The raw status word from the listing (`ON`, `BUSY`), for display.
    var status: String?

    var id: String { callsign }

    /// Whether this station is one of the network's own test services.
    ///
    /// `*ECHOTEST*` echoes audio back, letting one operator prove the path
    /// end to end alone. Worth surfacing first in a browser of six thousand
    /// entries.
    var isTestService: Bool {
        callsign.hasPrefix("*") && callsign.uppercased().contains("TEST")
    }

    /// Whether ``address`` is something the proxy could actually be asked to
    /// open — four octets, and not one of the two that mean "nowhere".
    ///
    /// Deliberately not the library's `isConnectable`, which also requires a
    /// node number: a conference or `*ECHOTEST*` is often listed without one,
    /// and a channel only needs the address.
    ///
    /// `0.0.0.0` and `127.0.0.1` appear in real listings for registered but
    /// unreachable stations. Both pass ``NodeSettings/isDottedQuad(_:)`` and so
    /// survive `validated()`, which is why they are caught here instead —
    /// otherwise the channel saves cleanly and fails later, inside the proxy,
    /// with an error naming neither the station nor the reason.
    var hasDialableAddress: Bool {
        NodeSettings.isDottedQuad(address) && address != "0.0.0.0" && address != "127.0.0.1"
    }

    /// A channel pointed at this station, filled in from an existing channel's
    /// directory server.
    ///
    /// Takes a template rather than building from nothing: which directory
    /// server listed the station is not something a station can supply, and
    /// the operator has already configured it once. The proxy is app-wide
    /// (APP-13) and so is not part of the template.
    func channel(basedOn template: NodeSettings) -> NodeSettings {
        var channel = template
        channel.id = UUID()
        channel.name = callsign
        channel.mode = .echoLink
        channel.node = callsign
        channel.peer = address
        return channel
    }
}

/// Fetches an EchoLink directory listing.
///
/// A protocol so the browser can be tested, and the app built and run,
/// without a proxy, a directory server or a network. The real implementation
/// is `CompositionRoot.EchoLinkStationDirectory`; a listing arrives through a
/// tunnelled TCP session, not an HTTP request.
protocol StationDirectory: Sendable {
    /// Every station the directory server lists.
    ///
    /// - Parameters:
    ///   - settings: supplies the directory server; the node fields are ignored,
    ///     since this opens a directory-only session and never contacts a node.
    ///   - accountPassword: the operator's EchoLink account password.
    ///   - identity: the operator's callsign, which the directory server is
    ///     asked to log in as.
    ///   - proxy: the proxy to tunnel the directory session through, resolved
    ///     by ``ProxyPicker`` (APP-13).
    func stations(
        for settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute
    ) async throws -> [DirectoryStation]
}

/// What can go wrong before the library is even asked.
enum StationDirectoryError: Error, Equatable, CustomStringConvertible {
    case notEchoLink

    /// The directory server logs us in as a callsign; there is no anonymous
    /// browse. Reported first: the callsign is app-wide, so a missing one is
    /// wrong for every channel.
    case missingCallsign

    case missingProxy
    case missingDirectoryServer
    case missingAccountPassword

    var description: String {
        switch self {
        case .notEchoLink:
            return "The station directory is an EchoLink thing; this channel is not an EchoLink channel."
        case .missingCallsign:
            return "Enter your callsign. The directory server logs you in as a station, not anonymously."
        case .missingProxy:
            return """
                No proxy could be found. The directory is reached through one, and every public \
                proxy appears to be busy — try again, or set your own proxy in Settings.
                """
        case .missingDirectoryServer:
            return """
                Enter the directory server's IP address. Without it there is nothing to ask \
                for the list.
                """
        case .missingAccountPassword:
            return """
                Enter your EchoLink account password. The directory server will not list \
                stations for an account it has not authenticated.
                """
        }
    }
}

/// The station browser's state, kept out of the view so it can be tested.
///
/// Fetching a listing means opening a proxy session, logging in to a directory
/// server and reading six thousand entries, which is slow enough that the
/// operator needs to see it happening and be able to give up on it.
@MainActor
final class StationBrowser: ObservableObject {
    /// What the operator typed to narrow the list.
    @Published var search: String = ""

    @Published private(set) var stations: [DirectoryStation] = []
    @Published private(set) var isLoading = false

    /// Why the last fetch failed, in words the operator can act on.
    @Published private(set) var failure: String?

    /// When the listing was fetched, so the browser can say how old it is
    /// rather than presenting yesterday's list as fact.
    @Published private(set) var fetchedAt: Date?

    private let directory: StationDirectory
    private let now: @MainActor () -> Date
    private var fetchTask: Task<Void, Never>?

    /// Bumped by every ``load(for:identity:accountPassword:proxy:)``, so a
    /// superseded fetch can tell that it is.
    private var generation = 0

    init(directory: StationDirectory, now: @escaping @MainActor () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// The listing, filtered by ``search`` and ordered with the test services
    /// first — see ``DirectoryStation/isTestService``.
    var visibleStations: [DirectoryStation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let matching =
            query.isEmpty
            ? stations
            : stations.filter {
                $0.callsign.uppercased().contains(query)
                    || $0.location.uppercased().contains(query)
                    || $0.nodeNumber.map { String($0).contains(query) } == true
            }

        // A stable partition, not a sort: re-ordering six thousand rows on
        // every keystroke is felt, so only the test services move.
        return matching.filter(\.isTestService) + matching.filter { !$0.isTestService }
    }

    /// Fetches the listing, from the session's own ``RadioSession/DirectoryRequest``
    /// (APP-14): taking the request whole leaves no call site free to pick the
    /// wrong password out of `NodeSettings`. A second call while one is in
    /// flight replaces it.
    func load(_ request: RadioSession.DirectoryRequest, proxy: EchoLinkProxyRoute?) {
        load(
            for: request.settings, identity: request.identity,
            accountPassword: request.accountPassword, proxy: proxy)
    }

    func load(
        for settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute?
    ) {
        fetchTask?.cancel()

        if let complaint = Self.whatIsMissing(
            in: settings, identity: identity, accountPassword: accountPassword, proxy: proxy)
        {
            stations = []
            failure = complaint.description
            isLoading = false
            return
        }

        // `whatIsMissing` already answers `.missingProxy` for a nil proxy, so
        // this cannot fail — `guard`, not `!`, so a future edit to that check
        // degrades to "no fetch" rather than a crash.
        guard let proxy else { return }

        isLoading = true
        failure = nil
        generation += 1
        let generation = generation

        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // `defer`, not a line at the end: several paths out of this task
            // are early returns on cancellation, and an unguarded spinner would
            // be stuck on. The generation check guards it because a cancelled
            // task observes its cancellation later than the `load` that
            // cancelled it — after that `load` has already set `isLoading`
            // back to true — so without the check this `defer` would clear the
            // spinner belonging to the fetch that replaced this one.
            defer { if self.generation == generation { self.isLoading = false } }

            do {
                let fetched = try await self.directory.stations(
                    for: settings, identity: identity, accountPassword: accountPassword,
                    proxy: proxy)
                guard !Task.isCancelled else { return }
                self.stations = fetched
                self.fetchedAt = self.now()
                self.failure = fetched.isEmpty ? "The directory server listed no stations." : nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.failure = "\(error)"
            }
        }
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        isLoading = false
    }

    /// The complaint to show instead of attempting a fetch that cannot work.
    ///
    /// Checked here rather than left to the library, so the operator is told
    /// which field is empty rather than watching a spinner end in a protocol
    /// error that names none of them. `nonisolated` because the directory
    /// implementation checks it too, off the main actor.
    nonisolated static func whatIsMissing(
        in settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute?
    ) -> StationDirectoryError? {
        guard settings.mode == .echoLink else { return .notEchoLink }
        if identity.callsign.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingCallsign
        }
        // `nil` here is not an empty field: it means the app tried to source a
        // proxy and could not (APP-13). Checked last because it's the one
        // thing nobody typed.
        guard let proxy, !proxy.host.isEmpty else { return .missingProxy }
        if settings.directoryServer.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingDirectoryServer
        }
        if accountPassword.isEmpty { return .missingAccountPassword }
        return nil
    }
}
