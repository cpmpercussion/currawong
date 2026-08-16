// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The EchoLink directory browser: which stations are on, and — the part that
/// matters — what their IP addresses are.
///
/// Nothing in the library resolves an EchoLink callsign to an address. The
/// proxy tunnels four literal octets, so `*ECHOTEST*` is not something the app
/// can dial; the directory listing is the only thing that turns a callsign into
/// an address, and this is the view over it. Tapping a station therefore does
/// not connect — it **fills in the connect screen** with the address, which is
/// the piece the operator could not have typed, and takes you there. Nothing is
/// saved until the connection succeeds; browsing six thousand entries should
/// not leave six thousand channels behind.
///
/// ## It does not fetch on appear, on purpose
///
/// A fetch is not a cheap read. It opens a real proxy session, and public
/// EchoLink proxies are single-user: while this app holds one, nobody else can,
/// and the operator's own connect attempt would find the proxy busy. A browser
/// that refreshed itself every time the pane came into view would be an
/// intermittent denial of service aimed at a stranger's proxy and at the
/// operator's own next call. So the operator asks, every time.
///
/// The listing also goes stale — stations come and go and addresses change — so
/// the fetch time is shown beside it rather than presenting an hour-old list as
/// the current state of the network.
struct StationBrowserView: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var browser: StationBrowser

    /// Called after a station is chosen, so the container can show the connect
    /// screen.
    var onChosen: () -> Void = {}

    /// Repointing the draft is refused while a link is up, by `RadioSession`.
    /// The browser itself stays usable — reading the directory mid-call is only
    /// a second proxy session, and looking up who is on is a reasonable thing
    /// to do — but the button that would choose one says why it cannot.
    private var canChoose: Bool { session.connection == .disconnected }

    /// Wall-clock time only. A directory listing that is a day old is a
    /// different kind of wrong from one that is ten minutes old, and the date
    /// makes that visible without a relative string that has to be recomputed.
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
                browser.load(
                    for: session.settings, identity: session.identity,
                    accountPassword: session.secret)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(browser.isLoading)
        }
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

    /// The spinner and the last failure. Both, rather than one or the other:
    /// a refresh that fails leaves the previous listing on screen, and the
    /// operator needs to know the rows they are looking at are the old ones.
    @ViewBuilder
    private var status: some View {
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

    /// What the operator needs before Refresh can work at all. Named as fields
    /// on the connect form rather than as protocol steps, because that is where
    /// the fix is; `StationBrowser` reports the same three as failures once a
    /// fetch is attempted, and this is the version that is shown first.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(browser.search.isEmpty ? "No listing yet" : "Nothing matches that")
                .font(.subheadline.weight(.medium))

            if browser.search.isEmpty {
                Text(
                    "Refresh reads the EchoLink directory using the current channel's proxy, "
                    + "directory server and account password. All three have to be filled in on "
                    + "the connect form first, and the channel has to be an EchoLink one.")
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
/// The button carries the label rather than the whole row, because tapping a
/// row in a list of six thousand entries reads as "open this" — and what
/// happens is that another pane changes. Naming the effect is cheaper than
/// explaining it afterwards.
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
                    // Worth saying once per test service rather than in a note
                    // somewhere: this is the station to try first, and knowing
                    // that saves an operator their first call to a stranger.
                    Text("Echoes your audio back — the right first contact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !station.hasDialableAddress {
                    // Said on the row rather than left to a disabled button,
                    // because a button that is merely grey reads as a bug in
                    // the app rather than a fact about the listing.
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

    /// Location, node number and address on one line. The address is the whole
    /// reason the browser exists, so it is always shown even when the listing
    /// gave nothing else.
    private var subtitle: String {
        var parts: [String] = []
        if !station.location.isEmpty { parts.append(station.location) }
        if let nodeNumber = station.nodeNumber { parts.append("node \(nodeNumber)") }
        parts.append(station.address.isEmpty ? "no address" : station.address)
        return parts.joined(separator: " · ")
    }
}
