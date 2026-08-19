// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One station from an EchoLink directory listing.
///
/// The app's own vocabulary again: `EchoLinkStationList` and `EchoLinkStation`
/// are library types, and only `CompositionRoot` is allowed to see them. This
/// is what the browser displays and what a channel is built from.
struct DirectoryStation: Identifiable, Equatable, Sendable {
    /// The callsign, which is also the identity — the directory is keyed by it,
    /// and two entries with one callsign would be the same station listed twice.
    var callsign: String

    /// Free text from the listing: a town, a repeater's frequency, a note.
    var location: String

    /// The node number, when the listing carries one.
    var nodeNumber: Int?

    /// The station's IPv4 address. This is the field the whole browser exists
    /// to obtain — see ``RadioMode``.
    var address: String

    /// Whether the station said it was on and free, as opposed to busy or off.
    var isConnectable: Bool

    /// The raw status word from the listing (`ON`, `BUSY`), for display.
    var status: String?

    var id: String { callsign }

    /// Whether this station is one of the network's own test services.
    ///
    /// `*ECHOTEST*` echoes audio back, so one operator alone can prove the path
    /// end to end without troubling anybody. It is worth surfacing first in a
    /// browser of six thousand entries, and worth a nudge for a first
    /// connection, which is why the app knows this rather than leaving the
    /// operator to find it by scrolling.
    var isTestService: Bool {
        callsign.hasPrefix("*") && callsign.uppercased().contains("TEST")
    }

    /// Whether ``address`` is something the proxy could actually be asked to
    /// open — four octets, and not one of the two that mean "nowhere".
    ///
    /// Deliberately *not* the library's `isConnectable`, which also requires a
    /// node number. A conference is listed without one often enough, and
    /// `*ECHOTEST*` is exactly the entry an operator reaches for first, so
    /// refusing to save it for want of a number it was never going to have
    /// would block the one station this browser most needs to hand over. The
    /// only thing a channel needs from a listing is the address; that is what
    /// is checked.
    ///
    /// `0.0.0.0` and `127.0.0.1` appear in real listings for stations that are
    /// registered but not reachable. Both pass ``NodeSettings/isDottedQuad(_:)``
    /// and so survive `validated()`, which is why they are caught here instead:
    /// otherwise the channel saves cleanly and fails much later, inside the
    /// proxy, with an error that names neither the station nor the reason.
    var hasDialableAddress: Bool {
        NodeSettings.isDottedQuad(address) && address != "0.0.0.0" && address != "127.0.0.1"
    }

    /// A channel pointed at this station, filled in from an existing channel's
    /// directory server.
    ///
    /// Takes a template rather than building from nothing because the part a
    /// station cannot supply — which directory server listed it — is one the
    /// operator has already configured once and should never type twice. The
    /// proxy is not among them any more: it is app-wide (APP-13), so a new
    /// channel inherits it by not naming it.
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
/// A protocol so the browser can be tested — and so the app can be built and
/// run — without a proxy, a directory server or a network. The real one is
/// `CompositionRoot.EchoLinkStationDirectory`, and it is the only thing that
/// knows a listing arrives through a tunnelled TCP session rather than, say,
/// an HTTP request.
protocol StationDirectory: Sendable {
    /// Every station the directory server lists.
    ///
    /// - Parameters:
    ///   - settings: supplies the directory server. The node fields are ignored:
    ///     this opens a directory-only session and never contacts a node.
    ///   - accountPassword: the operator's EchoLink account password.
    ///   - identity: the operator's callsign, which is who the directory server
    ///     is asked to log in as.
    ///   - proxy: the proxy to tunnel the directory session through, resolved by
    ///     ``ProxyPicker`` (APP-13). The listing does not arrive over HTTP; it
    ///     comes down a proxy connection like a QSO does.
    func stations(
        for settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute
    ) async throws -> [DirectoryStation]
}

/// What can go wrong before the library is even asked.
enum StationDirectoryError: Error, Equatable, CustomStringConvertible {
    case notEchoLink

    /// The directory server logs us in *as* a callsign, so an anonymous browse
    /// is not a thing that exists. Reported first, because the callsign is
    /// app-wide and a missing one is wrong for every channel.
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

    /// When the listing was fetched. A directory listing goes stale — stations
    /// come and go, and addresses change — so the browser says how old it is
    /// rather than presenting yesterday's list as fact.
    @Published private(set) var fetchedAt: Date?

    private let directory: StationDirectory
    private let now: @MainActor () -> Date
    private var fetchTask: Task<Void, Never>?

    /// Bumped by every ``load(for:identity:accountPassword:proxy:)``, so a fetch that has been
    /// superseded can tell that it has.
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

        // A stable partition rather than a sort: the directory's own order is
        // meaningful to nobody, but re-ordering six thousand rows on every
        // keystroke is felt. Only the test services move.
        return matching.filter(\.isTestService) + matching.filter { !$0.isTestService }
    }

    /// Fetches the listing. A second call while one is in flight replaces it —
    /// the operator has changed something and wants the new answer.
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

        // `whatIsMissing` answers `.missingProxy` for a nil proxy, so this cannot
        // fail — unwrapped with `guard` rather than `!` so that an edit to that
        // check degrades into "no fetch" instead of a crash on a screen the
        // operator opened to look for a station.
        guard let proxy else { return }

        isLoading = true
        failure = nil
        generation += 1
        let generation = generation

        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // `defer`, not a line at the end: three of the paths out of this
            // task are early returns on cancellation, and a spinner left
            // turning because the enclosing task was torn down is a screen the
            // operator can only fix by leaving it.
            //
            // The generation check is what makes that safe. A cancelled task
            // observes its cancellation *later* than the `load` that cancelled
            // it — after that `load` has already set `isLoading` back to true —
            // so an unguarded `defer` here would clear the spinner belonging to
            // the fetch that replaced this one.
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
    /// Checked here rather than left to the library so the operator is told
    /// which field is empty, instead of watching a spinner end in a protocol
    /// error that names none of them.
    /// `nonisolated` because the directory implementation checks it too, off the
    /// main actor, and one copy of the rule is the point.
    nonisolated static func whatIsMissing(
        in settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute?
    ) -> StationDirectoryError? {
        guard settings.mode == .echoLink else { return .notEchoLink }
        if identity.callsign.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingCallsign
        }
        // `nil` here is not an empty field the operator can go and fill in: it
        // means the app tried to source a proxy and could not (APP-13). The
        // wording says so, and it is the last thing checked before the fetch
        // because it is the one thing nobody typed.
        guard let proxy, !proxy.host.isEmpty else { return .missingProxy }
        if settings.directoryServer.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingDirectoryServer
        }
        if accountPassword.isEmpty { return .missingAccountPassword }
        return nil
    }
}
