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

    /// A channel pointed at this station, filled in from an existing channel's
    /// proxy, directory server and callsign.
    ///
    /// Takes a template rather than building from nothing because the parts a
    /// station cannot supply — which proxy to tunnel through, which directory
    /// server, who *we* are — are exactly the parts the operator has already
    /// configured once and should never type twice.
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
    ///   - settings: supplies the proxy, the directory server and our callsign.
    ///     The node fields are ignored: this opens a directory-only session and
    ///     never contacts a node.
    ///   - accountPassword: the operator's EchoLink account password.
    func stations(for settings: NodeSettings, accountPassword: String) async throws
        -> [DirectoryStation]
}

/// What can go wrong before the library is even asked.
enum StationDirectoryError: Error, Equatable, CustomStringConvertible {
    case notEchoLink
    case missingProxy
    case missingDirectoryServer
    case missingAccountPassword

    var description: String {
        switch self {
        case .notEchoLink:
            return "The station directory is an EchoLink thing; this channel is not an EchoLink channel."
        case .missingProxy:
            return "Enter the proxy's host name or address. The directory is reached through it."
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

    /// Bumped by every ``load(for:accountPassword:)``, so a fetch that has been
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
    func load(for settings: NodeSettings, accountPassword: String) {
        fetchTask?.cancel()

        if let complaint = Self.whatIsMissing(in: settings, accountPassword: accountPassword) {
            stations = []
            failure = complaint.description
            isLoading = false
            return
        }

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
                    for: settings, accountPassword: accountPassword)
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
    nonisolated static func whatIsMissing(in settings: NodeSettings, accountPassword: String)
        -> StationDirectoryError?
    {
        guard settings.mode == .echoLink else { return .notEchoLink }
        if settings.host.trimmingCharacters(in: .whitespaces).isEmpty { return .missingProxy }
        if settings.directoryServer.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingDirectoryServer
        }
        if accountPassword.isEmpty { return .missingAccountPassword }
        return nil
    }
}
