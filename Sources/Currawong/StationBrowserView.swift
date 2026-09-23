// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The EchoLink directory browser: which stations are on, and — the part that
/// matters — what their IP addresses are.
///
/// The proxy tunnels four literal octets, and nothing in the library resolves
/// a callsign to one; the directory listing is the only thing that does, and
/// this is the view over it. Tapping a station does not connect — it fills in
/// the connect screen with the address and takes you there. Nothing is saved
/// until the connection succeeds.
///
/// Does not fetch on appear: a fetch opens a real proxy session, and public
/// EchoLink proxies are single-user, so refreshing on every appearance would
/// be an intermittent denial of service against a stranger's proxy and the
/// operator's own next call. The listing also goes stale, so the fetch time
/// is shown beside it rather than presenting an old list as current.
struct StationBrowserView: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var browser: StationBrowser

    /// The public-proxy finder. Refresh is one of the two moments a proxy is
    /// needed — see ``ProxyPicker/route(privateProxy:privatePassword:)`` — and
    /// its state is shown in ``status`` too, since from this pane the search is
    /// a step of the refresh rather than a separate screen.
    @ObservedObject var proxyPicker: ProxyPicker

    /// Called after a station is chosen, so the container can show the connect
    /// screen.
    var onChosen: () -> Void = {}

    /// Repointing the draft is refused while a link is up, by `RadioSession`.
    /// The browser itself stays usable — reading the directory mid-call is only
    /// a second proxy session — but the button that would choose a station
    /// says why it cannot.
    private var canChoose: Bool { session.connection == .disconnected }

    /// Wall-clock time only, so a day-old listing reads differently from a
    /// ten-minute-old one without a relative string that must be recomputed.
    private static let listedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField
            status

            if browser.visibleStations.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("Stations")
                .font(.headline)

            Spacer()

            if let fetchedAt = browser.fetchedAt {
                Text("listed \(Self.listedFormatter.string(from: fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(browser.isLoading || proxyPicker.isSearching)
        }
    }

    /// Resolve a proxy, then read the directory through it.
    ///
    /// One button for both steps because they are one intention: a listing
    /// travels through a proxy, so an operator who has just added an EchoLink
    /// channel needs one, and sending them to another pane first is a detour
    /// through information they cannot act on.
    ///
    /// The proxy this returns is handed straight to the fetch and stored
    /// nowhere (APP-13). It is also the one the Connect button will use — a
    /// public proxy is leased for the sitting, not probed for again.
    private func refresh() async {
        guard
            let proxy = await proxyPicker.route(
                privateProxy: session.echoLinkProxy,
                privatePassword: session.echoLinkProxyPassword)
        else { return }

        // The session says what to send (APP-14), not this view.
        browser.load(session.directoryRequest, proxy: proxy)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Callsign, location or node number", text: $browser.search)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
        }
    }

    /// The spinner and the last failure, both rather than one or the other: a
    /// refresh that fails leaves the previous listing on screen, and the
    /// operator needs to know those rows are the old ones.
    @ViewBuilder
    private var status: some View {
        // Ahead of the fetch's own spinner, since it happens first and the two
        // are steps of one press.
        if proxyPicker.isSearching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    proxyPicker.probedCount > 0
                        ? "Finding a public proxy — probed \(proxyPicker.probedCount)…"
                        : "Finding a public proxy…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel") { proxyPicker.cancel() }
                    .buttonStyle(.bordered)
            }
        }

        // The picker's failure, not the browser's: when no proxy was found
        // there was never a fetch to fail.
        if let failure = proxyPicker.failure, !proxyPicker.isSearching {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if browser.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the directory…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel") { browser.cancel() }
                    .buttonStyle(.bordered)
            }
        }

        if let failure = browser.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !canChoose {
            Text("Disconnect before choosing a different station.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What the operator needs before Refresh can work at all. Named as the
    /// places those things are set, on the Settings screen, rather than as
    /// protocol steps; `StationBrowser` reports the same three as failures
    /// once a fetch is attempted, and this is the version shown first.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(browser.search.isEmpty ? "No listing yet" : "Nothing matches that")
                .font(.subheadline.weight(.medium))

            if browser.search.isEmpty {
                Text(
                    "Refresh reads the EchoLink directory. It needs your callsign and EchoLink "
                    + "account password, both on the Settings screen, and the channel has to be "
                    + "an EchoLink one; if the channel has no proxy yet, Refresh finds a public "
                    + "one first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "It is not fetched automatically: a listing opens a real proxy session, and "
                    + "a public proxy serves one user at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var list: some View {
        List(browser.visibleStations) { station in
            StationRow(
                station: station,
                canChoose: canChoose,
                choose: {
                    guard session.chooseChannel(station.channel(basedOn: session.settings))
                    else { return }
                    onChosen()
                })
        }
        .listStyle(.plain)
        // A floor, not a size; see the same frame in `ReflectorBrowserView`.
        .frame(minHeight: 140)
    }
}

/// One station, and the button that turns it into somewhere to go.
///
/// The button carries the label rather than the whole row: tapping a row in a
/// list of six thousand entries reads as "open this", but what happens is that
/// another pane changes.
private struct StationRow: View {
    let station: DirectoryStation
    let canChoose: Bool
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Non-localised on purpose: a callsign such as `*ECHOTEST*`
                    // is markdown emphasis to a `LocalizedStringKey`, which
                    // would render it italic with the asterisks eaten.
                    Text(verbatim: station.callsign)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if station.isTestService {
                        Text("Test service")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }

                    if let status = station.status {
                        Text(verbatim: status)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(station.isConnectable ? Color.green : Color.secondary)
                    }
                }

                if station.isTestService {
                    Text("Echoes your audio back — the right first contact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !station.hasDialableAddress {
                    // On the row, not left to a disabled button: a merely grey
                    // button reads as a bug rather than a fact about the listing.
                    Text("The directory lists no reachable address for this station.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button(action: choose) {
                Label("Use this station", systemImage: "arrow.right.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(!canChoose || !station.hasDialableAddress)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    /// Location, node number and address on one line. The address is always
    /// shown, even when the listing gave nothing else — it's the whole reason
    /// the browser exists.
    private var subtitle: String {
        var parts: [String] = []
        if !station.location.isEmpty { parts.append(station.location) }
        if let nodeNumber = station.nodeNumber { parts.append("node \(nodeNumber)") }
        parts.append(station.address.isEmpty ? "no address" : station.address)
        return parts.joined(separator: " · ")
    }
}
