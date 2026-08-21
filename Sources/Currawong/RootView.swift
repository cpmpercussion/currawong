// SPDX-License-Identifier: Apache-2.0

import RadioCore
import SwiftUI

/// The app's one root: the transmit banner, the pane container, and the four
/// session-lifetime handlers that must exist exactly once.
///
/// ## What this view is for now
///
/// It used to *be* the app — one scrolling column with everything in it. It is
/// now a shell around panes (``SessionPane``, ``ChannelListView``,
/// ``ConnectFormView``, ``DTMFKeypadView``, ``StationBrowserView``,
/// ``SettingsView``), and what is left here is the part that cannot be moved
/// into any one of them:
///
/// * **``TransmitBanner``, outside the pane container.** SF-4. It is a sibling
///   of the `TabView`/`NavigationSplitView`, not a child, so that no tab, no
///   column and no scroll offset can hide it. This is the single most important
///   structural fact about this file.
/// * **The release paths this view owns.** `scenePhase` leaving `.active`
///   (backgrounded, or merely covered by the control centre — both unkey) and
///   `onDisappear` (the view leaving the hierarchy). The PTT button's own
///   gesture handles touch-up, drag-off and cancellation; audio interruption
///   and the SF-1 watchdog live in the view model, because they arrive from
///   streams rather than from SwiftUI.
/// * **The alert.** One presenter, because two views bound to the same
///   `session.alert` would race to present and one of them would lose the
///   message.
///
/// **`onDisappear` must not be duplicated into a pane.** It means "the operator
/// has left"; a pane that carried it would fire it on every tab switch, and the
/// session cannot tell the two apart.
///
/// ## Compact and regular
///
/// Two layouts, one set of panes. macOS always takes the split layout —
/// `horizontalSizeClass` is answerable there but a Mac window is never the
/// phone case, and `#if os(macOS)` says so honestly rather than relying on what
/// AppKit reports.
///
/// ### The tab layout releases the key when you leave the Session tab
///
/// ``PushToTalkButton`` carries `onDisappear { onRelease(.viewDisappeared) }`,
/// because its gesture is torn down with it and `@GestureState` would never
/// reset. In a `TabView` that means: **switch tabs while keyed and you unkey.**
/// That is deliberate, and it is the safe direction — a transmitter keyed by a
/// button the operator can no longer see is the SF-3 failure this app is built
/// to avoid. The split layout does not have the question, because the PTT
/// button is in the detail column's fixed header and is never navigated away
/// from.
struct RootView: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var accessory: BLEPTTController
    @ObservedObject var remoteCommand: RemoteCommandPTTController
    @ObservedObject var browser: StationBrowser
    @ObservedObject var reflectorBrowser: ReflectorBrowser
    @ObservedObject var proxyPicker: ProxyPicker
    @ObservedObject var nodeLocator: NodeLocator
    @ObservedObject var portalLogin: PortalLoginController

    @Environment(\.scenePhase) private var scenePhase

    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Which of the detail column's secondary panes is showing. Split layout
    /// only; the tab layout uses tabs for the same choice.
    @State private var detailPane: DetailPane = .connect

    /// Which tab is showing. Compact layout only; the split layout uses
    /// ``detailPane`` for the same choice.
    @State private var selectedTab: Tab = .channels

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: session.transmitState)
    }

    var body: some View {
        VStack(spacing: 0) {
            // SF-4: above the pane container, never inside it.
            if status.isTransmitting {
                TransmitBanner(source: session.activeSource)
            }

            panes
        }
        .task { session.start() }
        .onChange(of: scenePhase) { phase in
            session.setForeground(phase == .active)

            // **BU-9.** The app going away is the last chance to keep what the
            // operator typed, and it used to be a chance nobody took: this hook
            // called `setForeground(_:)` and nothing else, so a corrected host
            // went with the process. Stashing rather than saving is the point —
            // quitting is not the operator asking for the channel to be
            // rewritten, so the edit comes back next launch with the stored
            // channel still describing where it actually goes.
            if phase != .active { session.stashDraft() }
        }
        .onDisappear { session.viewDisappeared() }
        .alert(
            session.alert?.title ?? "",
            isPresented: Binding(
                get: { session.alert != nil },
                set: { if !$0 { session.dismissAlert() } }),
            presenting: session.alert
        ) { _ in
            Button("OK", role: .cancel) { session.dismissAlert() }
        } message: { alert in
            Text(alert.message)
        }
    }

    @ViewBuilder
    private var panes: some View {
        #if os(macOS)
        splitLayout
        #else
        if horizontalSizeClass == .compact {
            tabLayout
        } else {
            splitLayout
        }
        #endif
    }

    // MARK: - Compact: tabs

    /// iPhone. Five tabs, two of which are mode-dependent.
    ///
    /// **There is a `selection` binding, and it needs a guard.** This used to
    /// have none, on the grounds that the Keypad and directory tabs come and go
    /// with the mode and a selection pointing at a departed tab is a blank
    /// screen. That reasoning still holds — what changed is that choosing a
    /// station or reflector now has to *take* the operator to the connect
    /// screen, and a tab layout cannot be driven without a binding.
    ///
    /// So the hazard is handled rather than avoided: ``effectiveTab`` resolves
    /// the stored selection against the tabs the current mode actually has, on
    /// read, exactly as ``effectiveDetailPane`` does for the split layout. The
    /// worst case of changing mode is still landing back on Channels.
    private var tabLayout: some View {
        TabView(selection: tabSelection) {
            channelsPane
                .tabItem { Label("Channels", systemImage: "list.bullet") }
                .tag(Tab.channels)

            // Leaving this tab while keyed releases the key — see the note on
            // the type. Documented rather than worked around.
            ScrollView {
                sessionPane(showsHeader: true)
                    .padding(20)
                    .paneColumn()
            }
            .tabItem { Label("Session", systemImage: "dot.radiowaves.left.and.right") }
            .tag(Tab.session)

            if session.settings.mode.sendsDTMF {
                ScrollView {
                    keypadPane
                        .padding(20)
                        .paneColumn()
                }
                .tabItem { Label("Keypad", systemImage: "square.grid.3x3") }
                .tag(Tab.keypad)
            }

            // APP-20: padded here for the reason the split layout's are — a
            // directory ran flush into both edges of the screen while every
            // other tab sat in a padded column.
            if session.settings.mode == .echoLink {
                StationBrowserView(
                    session: session, browser: browser, proxyPicker: proxyPicker,
                    onChosen: { selectedTab = .channels }
                )
                .padding(20)
                .paneColumn()
                .tabItem { Label("Stations", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.directory)
            }

            if session.settings.mode == .m17 {
                ReflectorBrowserView(
                    session: session, browser: reflectorBrowser,
                    onChosen: { selectedTab = .channels }
                )
                .padding(20)
                .paneColumn()
                .tabItem {
                    Label("Reflectors", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(Tab.directory)
            }

            settingsPane
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.setup)
        }
    }

    /// The tab layout's five destinations. The two directories share `directory`
    /// because only one of them is ever present: they are the same slot filled
    /// by whichever network the mode names.
    private enum Tab: Hashable {
        case channels, session, keypad, directory, setup
    }

    /// The stored selection, corrected against the tabs this mode has.
    ///
    /// Reading resolves; writing stores whatever was asked for. A mode change
    /// can take the selected tab away, and correcting on read rather than in an
    /// `onChange` means there is no frame in which the selection points at a
    /// tab that is not there.
    private var tabSelection: Binding<Tab> {
        Binding(get: { effectiveTab }, set: { selectedTab = $0 })
    }

    private var effectiveTab: Tab {
        switch selectedTab {
        case .keypad where !session.settings.mode.sendsDTMF: return .channels
        case .directory where !session.settings.mode.hasDirectory: return .channels
        default: return selectedTab
        }
    }

    /// The channel list, with the connect form under it while there is no link.
    ///
    /// The list takes the space and the form takes what it needs, because the
    /// list is what the operator is reading and the form is the handful of
    /// fields underneath it. The form gets its own `ScrollView` so that a
    /// keyboard covering half the screen cannot make the Connect button
    /// unreachable.
    ///
    /// **APP-18: no form once a link is up or on its way.** It is
    /// `isEditable: session.connection == .disconnected`, so while connected it
    /// is a read-only wall of fields, and the one thing in it worth reading —
    /// where the radio is pointed — is on the status panel (APP-16). What the
    /// tab gets instead is the whole screen for the channel list, which is what
    /// this tab is for.
    private var channelsPane: some View {
        VStack(spacing: 0) {
            ChannelListView(session: session)
                .padding(.top, 12)
                // The list takes what it needs up to a third of the screen and
                // no more, *while the form is under it*: beyond that it scrolls
                // internally, so a long channel list never pushes the form — and
                // the Connect button at the bottom of it — off the bottom of the
                // tab. With no form, the cap has nothing to protect and the list
                // takes the tab.
                .frame(maxHeight: showsConnectForm ? 320 : .infinity, alignment: .top)

            if showsConnectForm {
                Divider()

                // Not capped. An earlier `maxHeight` here left slack in the
                // stack, which a `VStack` centres, and the pane opened with a
                // band of empty space above the channel list. The form takes the
                // remainder.
                ScrollView {
                    connectForm
                        .padding(20)
                        .paneColumn()
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.default, value: showsConnectForm)
    }

    /// **APP-18.** Whether the connect form is on screen at all.
    ///
    /// The other half of the switch ``SessionPane`` makes for the meters and the
    /// PTT button, and exactly its complement — which is why both come from
    /// ``SessionPaneLayout`` rather than from a comparison written out twice.
    private var showsConnectForm: Bool {
        SessionPaneLayout(connection: session.connection).showsConnectForm
    }

    // MARK: - Regular: split view

    /// Mac and iPad. Channels on the left, the radio on the right.
    ///
    /// The detail column is not a scroll view. Its top half — status, safety
    /// notices, PTT — is fixed, and only the pane below the picker scrolls, so
    /// the button that stops a transmission cannot be scrolled off the screen
    /// while a transmission is running.
    private var splitLayout: some View {
        NavigationSplitView {
            // **APP-20.** The list brings its own insets for everything that is
            // not a `List` row; the top padding is the column's, because a
            // sidebar's first element sits under the window's title bar area and
            // only this side knows that.
            ChannelListView(session: session)
                .padding(.top, 12)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            detailColumn
        }
    }

    /// The session pane and whichever pane is chosen. **On macOS the picker
    /// that chooses is in the window toolbar, not in this column** — see below.
    ///
    /// ## Why the picker left the column
    ///
    /// The session pane is rigid — status, meters, a PTT button with a
    /// `minHeight`, and since APP-3's sibling work a link button too — so it
    /// needs something like 620 points and cannot give any of them back. In a
    /// window shorter than the column, a `VStack` does not shrink the rigid
    /// child: it **centres** what it could not fit, so the column spills off
    /// *both* edges. Whatever is first in the stack goes off the top.
    ///
    /// That cost an operator the only way out of a pane. The picker sat first,
    /// went over the top edge, and someone on Reflectors had nothing on screen
    /// that could take them off it — no back button, twice reported.
    ///
    /// It was fixed twice inside the column and regressed both times, because
    /// the fix was always a number or an alignment holding a rigid column
    /// against a window that can be any height:
    ///
    /// 1. Moving the picker to the top of the stack (it then went off the top
    ///    instead of the bottom, in M17 only, because the Reflectors pane is
    ///    taller than Stations).
    /// 2. `alignment: .top` on the stack's frame, plus `minHeight: 620` — which
    ///    held until `SessionLinkControl` added a button row to the session
    ///    pane and nobody re-measured the 620. The button only renders once
    ///    there is a `lastConnectedName`, so a fresh launch fit and a launch
    ///    that had connected to anything did not. That is the worst shape a
    ///    layout bug can take: invisible until the app has been used.
    ///
    /// **The toolbar is not a third number.** A toolbar item cannot be laid out
    /// off-screen by the column's overflow, at any window height, with any
    /// future session-pane content — so the class of bug is gone rather than
    /// this instance of it. It is also where macOS puts a view switcher.
    ///
    /// iPad keeps the inline picker: it uses this same split layout, but its
    /// windows do not get short enough to overflow, and `.principal` in a
    /// toolbar there competes with the navigation title.
    ///
    /// ## What is left in the column
    ///
    /// The column is still not a scroll view, and that is deliberate: the
    /// status panel and the button that ends a transmission must not be
    /// scrollable away while one is running. `minHeight` is still a request —
    /// a window may be made smaller than it — but with the picker out of the
    /// stack, overflow can no longer cost the operator their way out.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            #if !os(macOS)
                panePicker
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .paneColumn()

                Divider()
            #endif

            sessionPane(showsHeader: false)
                .padding(20)
                .paneColumn()

            Divider()

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Overflow still goes off the bottom rather than being shared between
        // both edges. Nothing load-bearing is down there any more, but a pane
        // clipped symmetrically reads as a rendering fault.
        .frame(maxHeight: .infinity, alignment: .top)
        // What the session pane and a usable amount of the tallest pane need.
        .frame(minHeight: 620)
        #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    panePicker
                }
            }
        #endif
    }

    /// The Connect / Reflectors / Settings switcher.
    ///
    /// Bound to the *resolved* selection, so that a mode change which takes the
    /// selected pane away moves the picker and the content below it together
    /// rather than leaving the picker showing nothing.
    private var panePicker: some View {
        Picker(
            "Pane",
            selection: Binding(
                get: { effectiveDetailPane },
                set: { detailPane = $0 })
        ) {
            ForEach(visibleDetailPanes) { pane in
                Text(pane.title).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("detail.panePicker")
    }

    @ViewBuilder
    private var detailContent: some View {
        switch effectiveDetailPane {
        case .connect:
            ScrollView {
                connectForm
                    .padding(20)
                    .paneColumn()
            }
        case .keypad:
            ScrollView {
                keypadPane
                    .padding(20)
                    .paneColumn()
            }
        // **APP-20: the same column as every other pane.** These two were
        // inserted raw, so they ran flush into both edges of the detail column
        // while the connect form, the keypad and the settings screen sat in a
        // padded, width-capped column — and unbounded, the reflector rows' module
        // chips pushed the list wider than the column, which clipped the Refresh
        // button off the right-hand side. `paneColumn()` is what the other three
        // already use, so this is one column width for the whole app rather than
        // a number chosen here.
        case .stations:
            StationBrowserView(
                session: session, browser: browser, proxyPicker: proxyPicker,
                onChosen: { detailPane = .connect })
                .padding(20)
                .paneColumn()
        case .reflectors:
            ReflectorBrowserView(
                session: session, browser: reflectorBrowser,
                onChosen: { detailPane = .connect })
                .padding(20)
                .paneColumn()
        case .setup:
            settingsPane
        }
    }

    /// The detail column's secondary panes.
    private enum DetailPane: String, CaseIterable, Identifiable, Hashable {
        case connect
        case keypad
        case stations
        case reflectors
        case setup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connect: return "Connect"
            case .keypad: return "Keypad"
            case .stations: return "Stations"
            case .reflectors: return "Reflectors"
            case .setup: return "Settings"
            }
        }
    }

    /// Which panes the current mode has. Same conditions as the tabs: no keypad
    /// without a DTMF path (``RadioMode/sendsDTMF``), and each of the two
    /// directories only in the mode it belongs to. They are separate panes
    /// rather than one that changes contents because they are separate
    /// networks — nothing in an EchoLink listing means anything to M17 — and a
    /// pane whose title stayed put while everything under it changed would
    /// suggest otherwise.
    private var visibleDetailPanes: [DetailPane] {
        DetailPane.allCases.filter { pane in
            switch pane {
            case .keypad: return session.settings.mode.sendsDTMF
            case .stations: return session.settings.mode == .echoLink
            case .reflectors: return session.settings.mode == .m17
            // **APP-18.** The form is the disconnected state's pane, and only
            // that state's: see ``showsConnectForm``. It leaves the picker
            // rather than staying in it showing nothing, because a pane that is
            // offered and then turns out to be a wall of greyed fields is worse
            // than one that is not offered.
            case .connect: return showsConnectForm
            case .setup: return true
            }
        }
    }

    /// The selection, resolved against what this mode and this connection state
    /// actually offer.
    ///
    /// Changing mode can take the selected pane away, and since APP-18 so can
    /// connecting — the selection is state and neither of those is — so it is
    /// corrected on read rather than mutated from an `onChange`. There is then
    /// no frame in which the picker points at a pane that is not there, and the
    /// stored choice comes back when its pane does: connect while the form is
    /// showing and the picker moves on; disconnect and it is showing again.
    ///
    /// The fallback is the first pane there is, which is `.connect` whenever
    /// that exists — the pane that can put the operator back on a working link —
    /// and otherwise the leftmost of what a live link has: the keypad for a mode
    /// that sends DTMF, then the directory, then Settings, which is always
    /// there. So the list is never empty and the picker never has nothing to
    /// select.
    private var effectiveDetailPane: DetailPane {
        guard !visibleDetailPanes.contains(detailPane) else { return detailPane }
        return visibleDetailPanes.first ?? .setup
    }

    // MARK: - Shared pieces

    private func sessionPane(showsHeader: Bool) -> some View {
        SessionPane(
            session: session,
            accessory: accessory,
            remoteCommand: remoteCommand,
            showsHeader: showsHeader,
            linkAction: { Task { await sessionLinkAction() } })
    }

    /// What the session pane's link button does, per state.
    ///
    /// The reconnect path goes back through ``connectOrDisconnect()`` rather
    /// than calling `session.connect()`, so that a channel needing a proxy gets
    /// one sourced the same way the form's button would. What it adds is the
    /// line before it: the draft is pointed back at the channel the last call
    /// was placed to, because the operator may have selected a different one
    /// while disconnected and "Reconnect to VK1RGI" must call VK1RGI.
    private func sessionLinkAction() async {
        switch session.connection {
        case .connected, .connecting:
            // Not `toggleConnection()`: that treats `.connecting` as "busy, do
            // nothing", and cancelling a connect that is going nowhere is half
            // of why this button exists.
            await session.disconnect()
        case .disconnecting:
            break
        case .disconnected:
            // The channel the button names is the selected one, which is also
            // the one the status panel above it is showing — so this is the
            // ordinary connect, not a restore. It used to call
            // `restoreLastConnectedChannel()` first, which silently changed the
            // selection out from under the operator. See `SessionLinkControl`.
            await connectOrDisconnect()
        }
    }

    private var connectForm: some View {
        ConnectFormView(
            settings: $session.settings,
            secret: $session.secret,
            isEchoLinkAccountConfigured: !session.echoLinkAccountPassword.isEmpty,
            webTransceiverToken: $session.webTransceiverToken,
            identity: $session.identity,
            isEditable: session.connection == .disconnected,
            connectTitle: connectTitle,
            isBusy: session.connection.isBusy || proxyPicker.isSearching,
            connectAction: { Task { await connectOrDisconnect() } },
            // BU-9: the form's own Save, which is the only thing that writes an
            // edit over the channel it came from.
            hasUnsavedChanges: session.isDraftDirty,
            draftIsUnsavedChannel: session.isDraftAnUnsavedChannel,
            saveAction: { session.saveDraft() },
            proxyPicker: proxyPicker,
            privateProxy: session.echoLinkProxy,
            nodeLocator: nodeLocator)
    }

    /// The Connect button's action: find a proxy first if this channel needs
    /// one, then place or drop the call.
    ///
    /// Only on the way *out*. `toggleConnection` is one button for two verbs,
    /// and hanging up does not need a proxy — sourcing one there would be a
    /// second or two of probing strangers' machines in front of the one action
    /// an operator may be in a hurry to complete.
    ///
    /// A search that finds nothing stops here rather than falling through to
    /// `connect()`. Without the guard the call would go on to fail validation
    /// with "enter the proxy's host name", which is both wrong — the app was
    /// looking for one and every public proxy was busy — and the opposite of
    /// useful, since it names a field the operator was never meant to fill in.
    private func connectOrDisconnect() async {
        var proxy: EchoLinkProxyRoute?
        if session.connection == .disconnected, session.settings.mode.usesProxy {
            // Handed to the connect rather than written into the channel
            // (APP-13): a proxy is not part of a destination, and a public one is
            // borrowed for this sitting only.
            guard
                let resolved = await proxyPicker.route(
                    privateProxy: session.echoLinkProxy,
                    privatePassword: session.echoLinkProxyPassword)
            else { return }
            proxy = resolved
        }

        await session.toggleConnection(proxy: proxy)
    }

    /// **APP-12.** The settings screen — the operator, the two stored accounts,
    /// and the PTT accessory, which used to be the whole of this destination.
    ///
    /// It used to be handed an `isTransmitting` to draw its own "on air" strip,
    /// which was always `false`: the root's ``TransmitBanner`` is above this view
    /// and still on screen, so a second copy inside it would be two banners
    /// saying the same thing. The parameter existed for the accessory *sheet*,
    /// which covered the banner and which APP-18 removed, so it went with it.
    private var settingsPane: some View {
        SettingsView(
            session: session,
            accessory: accessory,
            remoteCommand: remoteCommand,
            portalLogin: portalLogin)
    }

    private var keypadPane: some View {
        DTMFKeypadView(
            isEnabled: session.connection.isConnected,
            sent: session.sentDTMF,
            received: session.receivedDTMF,
            send: { digit in Task { await session.sendDTMF(digit) } })
    }

    private var connectTitle: String {
        switch session.connection {
        case .disconnected: return "Connect"
        case .connecting: return "Connecting…"
        case .connected: return "Disconnect"
        case .disconnecting: return "Disconnecting…"
        }
    }
}

/// One reading measure, centred, in every pane that is a column of text and
/// controls. Was two `frame` calls repeated at each site before the split;
/// naming it keeps the panes the same width as each other, which is what makes
/// switching between them look like one app.
///
/// Deliberately `private` — file scope, not the app's vocabulary. A shared
/// helper on `View` is the kind of thing two files independently invent under
/// the same name.
private extension View {
    func paneColumn() -> some View {
        self
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
    }
}

#Preview {
    let root = CompositionRoot()
    RootView(
        session: root.session,
        accessory: root.accessory,
        remoteCommand: root.remoteCommand,
        browser: root.stationBrowser,
        reflectorBrowser: root.reflectorBrowser,
        proxyPicker: root.proxyPicker,
        nodeLocator: root.nodeLocator,
        portalLogin: root.portalLogin)
}
