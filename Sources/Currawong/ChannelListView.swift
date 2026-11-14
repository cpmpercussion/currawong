// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The saved channels, and which one is current (APP-4).
///
/// While a link is up, `RadioSession` refuses anything that changes the list —
/// adding, editing, deleting, reordering — so the screen cannot describe one
/// node while the audio comes from another; this view disables those controls
/// and says why. Tapping a row stays live: ``onChoose`` hangs up on the way.
///
/// Rows are buttons with a highlight, not `List(selection:)`, whose meaning
/// differs between macOS and iOS edit mode. macOS has no swipe-to-delete, so
/// each row also has a context menu.
struct ChannelListView: View {
    @ObservedObject var session: RadioSession

    /// What a tap on a row does: go to that channel. ``RootView`` owns the
    /// sequence, which may hang up and source a proxy.
    let onChoose: (UUID) -> Void

    /// Starts `Add channel`; ``RootView`` presents the flow.
    let onAdd: () -> Void

    /// Shows a channel's details (the ⓘ); `nil` where they are already beside
    /// the list. Disabled while a link is up, because it selects first and
    /// selecting is refused then.
    var onInspect: ((UUID) -> Void)?

    /// Whether the session will accept a change to the list. Choosing a row is
    /// not such a change.
    private var isMutable: Bool { session.connection == .disconnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, Self.inset)

            if !isMutable {
                // No `fixedSize` here or in the empty state; see `emptyState`.
                Label(
                    "Disconnect to add, edit or delete channels.",
                    systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.inset)
            }

            if session.channels.channels.isEmpty {
                emptyState
                    .padding(.horizontal, Self.inset)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The horizontal inset for everything that is not a `List` row, matching
    /// `List`'s own row inset. Not applied to the whole view, which would inset
    /// the rows twice.
    private static let inset: CGFloat = 20

    /// Select, then show: the form edits the selected channel.
    private func inspect(_ id: UUID) {
        session.select(id)
        onInspect?(id)
    }

    /// One stored channel's row: the row goes there, the ⓘ shows details. Two
    /// controls, because only the first is live during a call. A method, since
    /// inline the type-checker gave up.
    @ViewBuilder
    private func storedRow(_ channel: NodeSettings) -> some View {
        HStack(spacing: 8) {
            Button {
                onChoose(channel.id)
            } label: {
                row(for: channel)
            }
            .buttonStyle(.plain)
            // Not disabled during a call: this tap hangs up and redials.
            .contextMenu { menu(for: channel) }

            if onInspect != nil {
                Button {
                    inspect(channel.id)
                } label: {
                    Image(systemName: "info.circle").imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(!isMutable)
                .accessibilityLabel("Details for \(channel.listDisplayName)")
            }
        }
    }

    private func row(for channel: NodeSettings) -> ChannelRow {
        ChannelRow(
            channel: channel,
            // The highlight follows the form.
            isSelected: channel.id == session.settings.id,
            // The call was placed to the selected channel.
            isConnected: channel.id == session.channels.selectedID
                && session.connection != .disconnected,
            connectionLabel: session.connection.label)
    }

    @ViewBuilder
    private func menu(for channel: NodeSettings) -> some View {
        if onInspect != nil {
            Button {
                inspect(channel.id)
            } label: {
                Label("Channel details", systemImage: "info.circle")
            }
            .disabled(!isMutable)
        }
        // For macOS, which has no swipe-to-delete.
        Button(role: .destructive) {
            session.deleteChannel(channel.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!isMutable)
    }

    private var header: some View {
        HStack {
            Text("Channels")
                .font(.headline)

            Spacer()

            #if os(iOS)
                // Without edit mode on iOS, `onMove` is unreachable.
                EditButton()
                    .disabled(!isMutable)
            #endif

            Button(action: onAdd) {
                Label("Add channel", systemImage: "plus")
            }
            .disabled(!isMutable)
        }
    }

    /// Shown when there are no channels.
    ///
    /// **No `fixedSize` on wrapping text in this view (BU-12).** A split view
    /// measures its sidebar at an unspecified width, where wrapping text is one
    /// word per line, and `fixedSize` makes that height a minimum — macOS then
    /// centres the overflow and pushes the status panel off the top.
    /// `WindowSizingTests` has a canary. If one is ever wanted, measure the
    /// sidebar's height before and after.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No channels yet")
                .font(.subheadline.weight(.medium))
            Text("Add one to choose a reflector, a station or a node to talk through.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onAdd) {
                Label("Add channel", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
            .disabled(!isMutable)
        }
    }

    private var list: some View {
        List {
            ForEach(session.channels.channels) { channel in
                storedRow(channel)
            }
            .onDelete { offsets in
                // Offsets rather than ids, so map before deleting: each
                // `deleteChannel` shifts the ones after it.
                let doomed = offsets.map { session.channels.channels[$0].id }
                for id in doomed { session.deleteChannel(id) }
            }
            .onMove { source, destination in
                session.moveChannels(fromOffsets: source, toOffset: destination)
            }
            .deleteDisabled(!isMutable)
            .moveDisabled(!isMutable)
        }
        .listStyle(.plain)
        // Rows are disabled individually: disabling the List stops scrolling.
        .frame(minHeight: 120)
    }
}

/// One channel: a name, a mode, and where it goes — the subtitle is what tells
/// apart channels sharing a name and mode.
private struct ChannelRow: View {
    let channel: NodeSettings
    let isSelected: Bool
    let isConnected: Bool
    let connectionLabel: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isConnected ? Color.green : Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.listDisplayName)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Text(channel.mode.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.gray.opacity(0.2)))

                    if isConnected {
                        Text(connectionLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Text(destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(channel.listDisplayName), \(channel.mode.displayName), \(destination)"
            + (isConnected ? ", \(connectionLabel)" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Where this channel goes, in its mode's terms. EchoLink shows the address
    /// too, since that is what decides who answers.
    private var destination: String {
        switch channel.mode {
        case .allStarLink:
            let host = channel.host.isEmpty ? "no host" : channel.host
            return channel.node.isEmpty ? host : "node \(channel.node) at \(host)"
        case .m17:
            let host = channel.host.isEmpty ? "no reflector" : channel.host
            return channel.module.isEmpty ? host : "\(host) module \(channel.module)"
        case .echoLink:
            let address = channel.peer.isEmpty ? "no address" : channel.peer
            return channel.node.isEmpty ? address : "\(channel.node) at \(address)"
        }
    }
}
