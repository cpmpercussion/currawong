// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-4.** The saved channels, and the one that is current.
///
/// A channel is a place the operator can go back to — a node, a reflector
/// module, an EchoLink station — and the point of the list is that reaching one
/// again costs a tap rather than re-typing a host, a node number and a
/// watchdog timeout. `ConnectFormView` edits whichever of these is selected;
/// this decides which that is.
///
/// ## Everything here is refused while a link is up
///
/// `RadioSession.select(_:)`, `addChannel(_:)` and `deleteChannel(_:)` all
/// return early unless the connection is `.disconnected`, because changing the
/// destination under a live call would leave the screen describing one node
/// while the audio came from another. That is the backstop; this view is the
/// part the operator sees, and it **says so** rather than presenting live
/// controls that silently do nothing — a tap that produces no effect and no
/// explanation is the worst of the three possible behaviours.
///
/// ## One list, two platforms
///
/// Selection is a `Button` per row and a highlight, not `List(selection:)`:
/// that binding means "the row the operator clicked" on macOS and "the rows
/// ticked in edit mode" on iOS, and the behaviour wanted here — a tap switches
/// channel — is the same on both. Deletion is `onDelete`, which iOS renders as
/// the swipe every operator expects; macOS has no swipe, so each row also
/// carries the same action in a context menu.
struct ChannelListView: View {
    @ObservedObject var session: RadioSession

    /// Whether the session will accept a change to the list at all.
    private var isMutable: Bool { session.connection == .disconnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !isMutable {
                Label(
                    "Disconnect to switch, add or delete channels.",
                    systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.channels.channels.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("Channels")
                .font(.headline)

            Spacer()

            #if os(iOS)
                // The reorder handles and the delete buttons only appear in
                // edit mode on iOS, so without this the `onMove` below is
                // unreachable.
                EditButton()
                    .disabled(!isMutable)
            #endif

            Button {
                session.addChannel()
            } label: {
                Label("Add channel", systemImage: "plus")
            }
            .disabled(!isMutable)
        }
    }

    /// Shown before the operator has ever connected. Deliberately not a call to
    /// action: the way to get a first channel is to fill the form in and
    /// connect, and saying that is more useful than an empty list with a button.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No saved channels")
                .font(.subheadline.weight(.medium))
            Text(
                "Fill in the connect form and connect. The details are saved as a channel, and "
                + "coming back to it later is one tap.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var list: some View {
        List {
            ForEach(session.channels.channels) { channel in
                Button {
                    session.select(channel.id)
                } label: {
                    ChannelRow(
                        channel: channel,
                        isSelected: channel.id == session.channels.selectedID,
                        isConnected: channel.id == session.channels.selectedID
                            && session.connection != .disconnected,
                        connectionLabel: session.connection.label)
                }
                .buttonStyle(.plain)
                .disabled(!isMutable)
                .contextMenu {
                    // macOS has no swipe-to-delete; iOS gets this as a long
                    // press, which is harmless duplication.
                    Button(role: .destructive) {
                        session.deleteChannel(channel.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!isMutable)
                }
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
        // `.disabled` on the List itself would take the scrolling with it, so
        // the rows are disabled individually above and the list stays readable
        // while a call is up.
        .frame(minHeight: 120)
    }
}

/// One channel, as a name, a mode and a description of where it goes.
///
/// The subtitle is not decoration: two channels can easily share a name and a
/// mode — an operator with three EchoLink stations saved has three rows reading
/// "EchoLink" — and the destination is the only thing that tells them apart at
/// a glance.
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
                    Text(channel.displayName.isEmpty ? "Unnamed channel" : channel.displayName)
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
            "\(channel.displayName), \(channel.mode.displayName), \(destination)"
            + (isConnected ? ", \(connectionLabel)" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Where this channel goes, in the vocabulary of its own mode. EchoLink
    /// names the far end twice — callsign and address — and both belong here,
    /// because the address is what actually decides who answers.
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
