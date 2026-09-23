// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One station from an EchoLink directory listing, in the app's own
/// vocabulary (the library's types stay in `CompositionRoot`).
struct DirectoryStation: Identifiable, Equatable, Sendable {
    /// The callsign, which is also the identity.
    var callsign: String

    /// Free text from the listing: a town, a repeater's frequency, a note.
    var location: String

    /// The node number, when the listing carries one.
    var nodeNumber: Int?

    /// The station's IPv4 address.
    var address: String

    /// Whether the station said it was on and free, as opposed to busy or off.
    var isConnectable: Bool

    /// The raw status word from the listing (`ON`, `BUSY`), for display.
    var status: String?

    var id: String { callsign }

    /// Whether this is one of the network's test services, such as
    /// `*ECHOTEST*`, which echoes audio back. Listed first.
    var isTestService: Bool {
        callsign.hasPrefix("*") && callsign.uppercased().contains("TEST")
    }

    /// Whether ``address`` is four octets and not `0.0.0.0` or `127.0.0.1`,
    /// which listings use for unreachable stations and which would otherwise
    /// pass `validated()` and fail later inside the proxy.
    ///
    /// Not the library's `isConnectable`, which also requires a node number
    /// that conferences and test services often lack.
    var hasDialableAddress: Bool {
        NodeSettings.isDottedQuad(address) && address != "0.0.0.0" && address != "127.0.0.1"
    }

    /// A channel pointed at this station, keeping the template's directory
    /// server, which a listing cannot supply.
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

/// Fetches an EchoLink directory listing, through a proxied TCP session. The
/// real implementation is `EchoLinkStationDirectory` in `CompositionRoot`.
protocol StationDirectory: Sendable {
    /// Every station the directory server lists.
    ///
    /// - Parameters:
    ///   - settings: supplies the directory server; node fields are ignored.
    ///   - accountPassword: the operator's EchoLink account password.
    ///   - identity: the callsign the directory session logs in as.
    ///   - proxy: the proxy to tunnel through, from ``ProxyPicker``.
    func stations(
        for settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute
    ) async throws -> [DirectoryStation]
}

/// What can go wrong before the library is even asked.
enum StationDirectoryError: Error, Equatable, CustomStringConvertible {
    case notEchoLink

    /// There is no anonymous browse.
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
/// A fetch is slow, so it shows progress and can be cancelled.
@MainActor
final class StationBrowser: ObservableObject {
    /// What the operator typed to narrow the list.
    @Published var search: String = ""

    @Published private(set) var stations: [DirectoryStation] = []
    @Published private(set) var isLoading = false

    /// Why the last fetch failed, in words the operator can act on.
    @Published private(set) var failure: String?

    /// When the listing was fetched, so the browser can show its age.
    @Published private(set) var fetchedAt: Date?

    private let directory: StationDirectory
    private let now: @MainActor () -> Date
    private var fetchTask: Task<Void, Never>?

    /// Bumped by every load, so a superseded fetch can tell.
    private var generation = 0

    init(directory: StationDirectory, now: @escaping @MainActor () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// The listing, filtered by ``search``, test services first.
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

        // A stable partition, not a sort, which would be slow per keystroke.
        return matching.filter(\.isTestService) + matching.filter { !$0.isTestService }
    }

    /// Fetches the listing for a ``RadioSession/DirectoryRequest`` (APP-14),
    /// taken whole so no call site can pick the wrong password. Replaces a
    /// fetch in flight.
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

        // Cannot fail after `whatIsMissing`; `guard` rather than `!` anyway.
        guard let proxy else { return }

        isLoading = true
        failure = nil
        generation += 1
        let generation = generation

        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // `defer` covers the early returns. The generation check stops a
            // cancelled task, which notices late, from clearing the spinner of
            // the fetch that replaced it.
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

    /// The complaint to show instead of a fetch that cannot work, naming the
    /// empty field. `nonisolated` because the directory calls it too.
    nonisolated static func whatIsMissing(
        in settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute?
    ) -> StationDirectoryError? {
        guard settings.mode == .echoLink else { return .notEchoLink }
        if identity.callsign.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingCallsign
        }
        // `nil` means the app could not source a proxy, not an empty field.
        guard let proxy, !proxy.host.isEmpty else { return .missingProxy }
        if settings.directoryServer.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingDirectoryServer
        }
        if accountPassword.isEmpty { return .missingAccountPassword }
        return nil
    }
}
