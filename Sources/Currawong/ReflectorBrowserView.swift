// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The M17 reflector chooser: which reflectors exist, and which modules they
/// have.
///
/// The M17 equivalent of ``StationBrowserView``, for a milder version of the
/// same reason: an M17 reflector's host name is stable and dialable directly,
/// but a hundred and twenty-five reflectors across twenty countries is not
/// something to hold in your head.
///
/// Tapping a module fills in the connect screen and takes you to it — it does
/// not save a channel or go on the air. The channel is saved only when the
/// connection succeeds, so the list means "places I have been", not
/// "reflectors I once tapped".
struct ReflectorBrowserView: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var browser: ReflectorBrowser

    /// Called after a module is chosen, so the container can show the connect
    /// screen — otherwise choosing somewhere to go and being left in the list
    /// reads as nothing having happened.
    var onChosen: () -> Void = {}

    /// Repointing the draft is refused while a link is up, by `RadioSession`.
    private var canChoose: Bool { session.connection == .disconnected }

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

            if browser.visibleReflectors.isEmpty {
                emptyState
            } else {
                list
            }

            attribution
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Unlike the station browser, which must never fetch by itself. See
        // `ReflectorBrowser` — this is a static file, not somebody's proxy.
        .task { browser.loadIfNeeded() }
    }

    private var header: some View {
        HStack {
            Text("Reflectors")
                .font(.headline)

            Spacer()

            if let fetchedAt = browser.fetchedAt {
                Text("listed \(Self.listedFormatter.string(from: fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                browser.load()
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
            TextField("Reflector, country or sponsor", text: $browser.search)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var status: some View {
        if browser.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching the reflector list…")
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
            Text("Disconnect before choosing a different reflector.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(browser.search.isEmpty ? "No list yet" : "Nothing matches that")
                .font(.subheadline.weight(.medium))

            if browser.search.isEmpty && !browser.isLoading {
                Text(
                    "The list is published by the M17 Project and fetched over the internet. "
                    + "Refresh to try again, or type a reflector's host name on the connect "
                    + "form instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Required, not decorative: DVRef publishes this data under CC BY 4.0,
    /// conditioned on credit. Shown here, on the screen the data is actually
    /// on, as well as in the README.
    private var attribution: some View {
        Text("Reflector data provided by DVRef (dvref.com), CC BY 4.0, via the M17 Project.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        List(browser.visibleReflectors) { reflector in
            ReflectorRow(
                reflector: reflector,
                canChoose: canChoose,
                choose: { module in
                    guard
                        session.chooseChannel(
                            reflector.channel(module: module, basedOn: session.settings))
                    else { return }
                    onChosen()
                })
        }
        .listStyle(.plain)
        // A floor, not a size. Kept low: this pane is the tallest of them, and
        // every point of rigid minimum is a point the detail column can
        // overflow by in a short window; the list scrolls internally, so small
        // is cramped rather than broken.
        .frame(minHeight: 140)
    }
}

/// One reflector, and its modules as the things you actually pick.
///
/// The module is the choice, not the reflector: connecting to `M17-AUS` means
/// nothing until you say which module, and an operator who chose a reflector
/// and then had to go and find the module field has been made to do the work
/// twice. So each module is its own button.
private struct ReflectorRow: View {
    let reflector: M17Reflector
    let canChoose: Bool
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: reflector.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if reflector.isMultiprotocol {
                    // Not decoration: on a bridged module the far end may not
                    // be running M17, and the audio is transcoded on the way.
                    // An operator wondering why they sound rough should be able
                    // to see that from here.
                    Text("Bridged")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }

            Text(verbatim: reflector.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            dashboardLink

            if !reflector.hasDialableHost {
                Text("The list gives no address for this reflector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                modules
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// The reflector's own dashboard, opened in the browser.
    ///
    /// A link, not a scraped panel: every reflector publishes who was last
    /// heard on its own dashboard, in its own HTML, with no common feed to
    /// read, so a link hands the operator the real page instead of a copy
    /// that can go stale.
    ///
    /// Absent rather than disabled when the listing has no URL — a greyed
    /// link invites a tap that will not happen.
    @ViewBuilder
    private var dashboardLink: some View {
        if let dashboard = reflector.dashboard {
            Link(destination: dashboard) {
                Label("Dashboard — who is on, last heard", systemImage: "safari")
                    .font(.caption)
            }
            // Plain, so the whole row does not read as one big tappable thing
            // in a list where the modules are the buttons that matter.
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Open the \(reflector.designator) dashboard in the browser")
            .accessibilityHint("Shows who was last heard on this reflector")
        }
    }

    /// The modules, wrapped rather than in a row: a native M17 reflector can
    /// have all twenty-six, and a single `HStack` of those would run off the
    /// side of a phone.
    private var modules: some View {
        FlowLayout(spacing: 6) {
            ForEach(reflector.modules) { module in
                Button {
                    choose(module.letter)
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: module.letter)
                            .font(.caption.weight(.semibold))
                        if let note = module.note {
                            Text(verbatim: note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canChoose)
                .accessibilityLabel("Choose \(reflector.designator) module \(module.letter)")
                .accessibilityHint("Fills in the connect screen for this module")
            }
        }
    }
}

/// Lays subviews out left to right, wrapping onto a new line when the next one
/// will not fit.
///
/// Twenty-six module buttons need to wrap, and iOS 16 has no built-in flow
/// layout. `Layout` is iOS 16 and macOS 13, which is exactly this app's floor,
/// so this is a dozen lines rather than a dependency.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width

            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [], y: current.y + current.height + spacing)
                current.width = size.width
            } else {
                current.width = needed
            }

            current.indices.append(index)
            current.height = max(current.height, size.height)
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
