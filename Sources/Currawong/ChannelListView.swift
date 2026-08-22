// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-4.** The saved channels, and the one that is current.
///
/// A channel is a place the operator can go back to — a node, a reflector
/// module, an EchoLink station — and the point of the list is that reaching one
/// again costs a tap rather than re-typing a host and a node number.
/// `ConnectFormView` edits whichever of these is selected;
/// this decides which that is.
///
/// ## What a live link refuses, and what it no longer does
///
/// `RadioSession.select(_:)`, `newChannel(_:)` and `deleteChannel(_:)` all
/// return early unless the connection is `.disconnected`, because changing the
/// destination under a live call would leave the screen describing one node
/// while the audio came from another. That is the backstop; this view is the
/// part the operator sees, and it **says so** rather than presenting live
/// controls that silently do nothing — a tap that produces no effect and no
/// explanation is the worst of the three possible behaviours.
///
/// **APP-23: choosing a channel is no longer one of the refused things.** The
/// whole list used to grey out mid-call, which made the ordinary radio gesture —
/// tap another channel to go there — into disconnect, choose, connect. A tap now
/// calls ``onChoose``, which hangs up on the way, so the selection still only
/// moves while disconnected and the invariant above is untouched. What stays
/// locked is everything that changes what the list *contains*: adding, editing,
/// deleting, reordering. None of those is "take me there now".
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

    /// **APP-23.** What a tap on a row means: *go to this channel*.
    ///
    /// Not `session.select(_:)` any more, and the difference is the whole of
    /// the change. Selecting is refused while a link is up — rightly, see the
    /// note above — so the list used to grey itself out and tell the operator
    /// to disconnect first. Going somewhere is a sequence that includes hanging
    /// up, and only ``RootView`` knows the whole of it, because dialling an
    /// EchoLink channel needs a proxy sourced first.
    let onChoose: (UUID) -> Void

    /// **APP-23.** Show this channel's details — the ⓘ, and where `Add channel`
    /// lands. `nil` where the details are already on screen beside the list,
    /// which is the split layout on iPad and Mac.
    ///
    /// The channel is selected before this is called, so the form (which edits
    /// the *draft*, and the draft follows the selection) is describing the row
    /// that was tapped. That is also why the button is disabled while a link is
    /// up: selecting is refused there, so an enabled ⓘ would open the form on
    /// somewhere other than the row that was tapped.
    var onInspect: ((UUID) -> Void)?

    /// Whether the session will accept a change to the *list* — adding,
    /// deleting, reordering, editing.
    ///
    /// **Choosing a channel is no longer one of these (APP-23).** A tap on a row
    /// goes there, hanging up on the way if it has to, so the rows themselves
    /// stay live while a call is up. What is still refused is everything that
    /// changes what the list contains, because none of those is "take me there
    /// now" and all of them would edit the channel under a live call.
    private var isMutable: Bool { session.connection == .disconnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, Self.inset)

            if !isMutable {
                // No `.fixedSize(horizontal: false, vertical: true)` here or in
                // the empty state, and that is BU-12's fix — see the note below.
                //
                // **APP-23: switching is no longer in this list.** Tapping a row
                // now hangs up and dials the new channel, so the label names
                // only what is still refused — the operations that change what
                // the list contains.
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

    /// **APP-20.** The horizontal inset for everything that is not a `List` row.
    ///
    /// The rows get theirs from the `List`, which is why this is not applied to
    /// the whole view: padding the container would inset the rows *again* and
    /// leave the header hanging left of the channel names it labels. It was the
    /// other way round before — the two call sites padded the whole view, so on
    /// macOS, where the sidebar padded nothing, "Channels" and `Add channel` sat
    /// flush against both edges of the column.
    ///
    /// 20 to match `List`'s own row inset on both platforms, so the header lines
    /// up with the row text under it rather than nearly lining up with it.
    private static let inset: CGFloat = 20

    /// Select, then show. The order matters: the details form edits the draft
    /// and the draft follows the selection, so a form opened before the
    /// selection moved would describe the previous channel.
    private func inspect(_ id: UUID) {
        session.select(id)
        onInspect?(id)
    }

    /// One stored channel's row.
    ///
    /// **APP-23: two controls side by side**, the way a Wi-Fi list is — the row
    /// means "go there", the ⓘ means "show me what this is". They cannot be one
    /// control, because the first is live while a call is up and the second is
    /// not.
    ///
    /// A method rather than more `List` body: with both controls inline the
    /// builder became one expression the type-checker gave up on.
    @ViewBuilder
    private func storedRow(_ channel: NodeSettings) -> some View {
        HStack(spacing: 8) {
            Button {
                onChoose(channel.id)
            } label: {
                row(for: channel)
            }
            .buttonStyle(.plain)
            // **No `.disabled(!isMutable)` (APP-23).** This is the tap that now
            // hangs up and redials, so a live call is the state it is most for,
            // not the state it is refused in.
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
            // **APP-19: the highlight follows the form, not the stored
            // selection.** The two can differ — a directory browse and
            // `Add channel` both point the form at a channel that is not in this
            // list — and when they do, no row is highlighted, which is the
            // honest answer: what the form is describing is not one of these
            // yet. Highlighting the channel the operator has just left made
            // `Add channel` look like it had done nothing.
            isSelected: channel.id == session.settings.id,
            // BU-9: the row shows the *stored* channel, and an edit no longer
            // reaches it on its own — so where the two disagree the list has to
            // say so, or the operator is reading a description of somewhere
            // they are not about to call.
            hasUnsavedEdits: session.hasUnsavedEdits(for: channel.id),
            // The *connected* row is still the selected one, which is the
            // channel the call was placed to — a connection cannot be to a
            // draft that is in no list.
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
        // macOS has no swipe-to-delete; iOS gets this as a long press, which is
        // harmless duplication.
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
                // The reorder handles and the delete buttons only appear in
                // edit mode on iOS, so without this the `onMove` below is
                // unreachable.
                EditButton()
                    .disabled(!isMutable)
            #endif

            Button {
                // **APP-23.** The provisional row is still what `+` produces
                // (APP-22); what is new is that where the details live behind
                // navigation, the button also opens them. A button that adds a
                // blank row and leaves the operator on the list has put them
                // one undiscoverable tap away from the fields it exists to let
                // them fill in.
                let id = session.newChannel()
                if let id { onInspect?(id) }
            } label: {
                Label("Add channel", systemImage: "plus")
            }
            .disabled(!isMutable)
        }
    }

    /// Shown before the operator has ever connected. Deliberately not a call to
    /// action: the way to get a first channel is to fill the form in and
    /// connect, and saying that is more useful than an empty list with a button.
    ///
    /// ## **BU-12.** Why neither text carries `fixedSize`
    ///
    /// It used to, on the caption here and on the lock label above — the usual
    /// spelling of "wrap, do not truncate". In a `NavigationSplitView` sidebar
    /// that made the **whole app taller than its window**: the split view
    /// measures its sidebar's height against an **unspecified width**, wrapping
    /// text asked for its height at no width answers with one word per line, and
    /// `fixedSize` turns that answer into a *minimum* the layout must satisfy.
    /// This view is 67 points tall on its own and demanded **1237.5** in the
    /// sidebar; the app was laid out at 1249.5 points in an 866-point window and
    /// macOS centred the overflow, which put the status panel above the top edge
    /// of the window on a first launch. `WindowSizingTests` is the regression,
    /// and it carries a canary for the platform behaviour.
    ///
    /// Nothing is truncated by their absence: a sidebar proposes a real width
    /// and hundreds of points of height, so both texts wrap exactly as before —
    /// the difference is only in what they *demand* when asked to measure
    /// themselves at no width at all. **If a `fixedSize` is ever wanted in this
    /// view, measure the sidebar's height before and after.**
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No saved channels")
                .font(.subheadline.weight(.medium))
            // APP-23: `Add channel` is named because it is now the way in on a
            // phone, where the form is behind it rather than under this list.
            Text(
                "Add a channel and fill in where it goes. Connecting saves it, and "
                + "coming back to it later is one tap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// ## BU-9 item 3: the menu this builds is not the defect
    ///
    /// The bring-up report has right-click → Delete greyed out for ever on any
    /// channel a launch has connected to, **after** the link is fully down. That
    /// was measured through an XCUITest, and the menu it measured was the wrong
    /// one.
    ///
    /// `ChannelListContextMenuTests` looks at the `NSMenu` the platform actually
    /// displays for a row, driving a real connect and disconnect through the
    /// session. What it finds:
    ///
    /// - SwiftUI **rebuilds** this menu on every read of the row's `view.menu`.
    ///   A menu read while the list was locked carries `isEnabled == false` and a
    ///   `nil` action, and keeps them for ever — but the row hands out a fresh,
    ///   live one the moment `isMutable` is true again.
    /// - After a connect/disconnect cycle, Delete is enabled on the connected
    ///   channel *and* on a row that merely sat in the list while it was locked,
    ///   and sending its action deletes the channel. So the `.disabled` below
    ///   does not leave `isEnabled = false` behind in the row's subtree, which is
    ///   what the four earlier attempts were all trying to fix.
    ///
    /// So nothing here changed. What did change is the test's query:
    /// `app.menuItems["Delete"]` is not scoped to the context menu, and every
    /// SwiftUI app on macOS has an always-greyed `Edit ▸ Delete` in the menu bar.
    /// An unscoped query finds *that* — existing, disabled, and clicking
    /// nothing — whether or not the row's menu ever opened. A modal alert left
    /// standing after the session (`handleLinkLoss` presents one, and so does a
    /// failed connect) is enough to stop the menu opening while leaving every
    /// other symptom the report lists intact: "Not connected", no lock label, the
    /// row enabled.
    ///
    /// **Unconfirmed end to end.** The scoped-query UI tests
    /// (`ChannelDeleteAfterConnectUITests`) that would settle it have not been
    /// run: this machine's UI-test automation grant has lapsed. Until somebody
    /// runs them, item 3's cause is the best-supported explanation rather than a
    /// closed one, and the ⚠️ belongs on the *report*, not on this view.
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

            // **APP-22: the row for a channel that is not in the list yet.**
            //
            // `Add channel` points the form at a new channel and writes nothing
            // (APP-19) — which was right about storage and left the operator with
            // no sign that anything had happened, since the row it used to create
            // was the only feedback the button had. So the draft appears here, at
            // the bottom, marked "Not saved", and **Save or Connect is still what
            // puts it in storage**. Quit without either and it is gone, exactly
            // as a reflector picked out of the directory is: nothing can leave a
            // permanent hostless row behind. The maintainer's call, 2026-08-21.
            //
            // Outside the `ForEach` on purpose: `onDelete` and `onMove` above
            // work in offsets into the *stored* array, and a row inside that
            // loop would shift every index by one.
            if session.isDraftAnUnsavedChannel {
                Button {
                    // Already selected, so there is nothing to choose — but
                    // where the details live behind navigation (APP-23) this is
                    // the only way back to the half-filled form, and on a phone
                    // that is the whole point of the row.
                    onInspect?(session.settings.id)
                } label: {
                    ChannelRow(
                        channel: session.settings,
                        isSelected: true,
                        hasUnsavedEdits: false,
                        isUnsavedChannel: true,
                        isConnected: false,
                        connectionLabel: session.connection.label)
                }
                .buttonStyle(.plain)
                .disabled(!isMutable)
                .contextMenu {
                    // Not `deleteChannel(_:)`: there is nothing stored to
                    // delete. Discarding puts the form back on the selected
                    // channel, which is what leaving this row means.
                    Button(role: .destructive) {
                        session.discardDraftChannel()
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .disabled(!isMutable)
                }
            }
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

    /// **BU-9.** Whether there is an edit to this channel that it does not yet
    /// contain. Shown, because the alternative is a row that quietly describes
    /// something other than what pressing Connect would call.
    let hasUnsavedEdits: Bool

    /// **APP-22.** Whether this row is the *provisional* one — a channel the
    /// operator has started and not yet saved, which is in the list but not in
    /// storage. Says "Not saved" rather than "Edited", because there is nothing
    /// stored for it to differ from.
    var isUnsavedChannel = false

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

                    if isUnsavedChannel {
                        Text("Not saved")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if hasUnsavedEdits {
                        Text("Edited")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
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
            + (isConnected ? ", \(connectionLabel)" : "")
            + (isUnsavedChannel ? ", not saved" : hasUnsavedEdits ? ", unsaved changes" : ""))
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
