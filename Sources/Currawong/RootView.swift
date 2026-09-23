// SPDX-License-Identifier: Apache-2.0

import RadioCore
import SwiftUI

/// The app's one root: the transmit banner, the pane container, and the four
/// session-lifetime handlers that must exist exactly once.
///
/// A shell around panes (``SessionPane``, ``ChannelListView``,
/// ``ConnectFormView``, ``DTMFKeypadView``, ``StationBrowserView``,
/// ``SettingsView``); what is left here is the part that cannot be moved into
/// any one of them:
///
/// * **``TransmitBanner``, outside the pane container and always present**
///   (SF-4). A sibling of the `TabView`/`NavigationSplitView`, not a child, so
///   that no tab, no column and no scroll offset can hide it.
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
/// **The tab layout releases the key when you leave the Session tab.**
/// ``PushToTalkButton`` carries `onDisappear { onRelease(.viewDisappeared) }`,
/// because its gesture is torn down with it and `@GestureState` would never
/// reset — so in a `TabView`, switching tabs while keyed unkeys. That is the
/// safe direction: a transmitter keyed by a button the operator can no longer
/// see is the SF-3 failure this app is built to avoid. The split layout does
/// not have the question — the PTT button is in the detail column's fixed
/// header and is never navigated away from.
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

    /// **APP-23.** Whether the Channels tab has the details form pushed. Tab
    /// layout only; the split layout shows the same form in its detail column,
    /// where it is never pushed and never dismissed.
    @State private var showsChannelDetails = false

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: session.transmitState)
    }

    var body: some View {
        VStack(spacing: 0) {
            // SF-4: above the pane container, never inside it, and **APP-23:
            // permanent** rather than inserted at key-down — inserting it
            // there moves every control below it, the PTT button under the
            // operator's finger included. Says which state it is in by colour
            // and wording.
            TransmitBanner(
                isTransmitting: status.isTransmitting,
                source: session.activeSource,
                keyDownsInHold: session.keyDownsInCurrentHold,
                routeTrace: "\(session.lastKeyDownRoute) "
                    + "prep=\(session.routeSignalsDuringPreparation) "
                    + "tx=\(session.routeSignalsWhileTransmitting) "
                    + "prepMs=\(session.lastPreparationMilliseconds) "
                    + "micMs=\(session.lastCaptureStartMilliseconds) "
                    // `BU-24`: a warm-up that could not open the input is why a
                    // first over is silent or a press fails, and this is the
                    // only place a device test can see it.
                    + (session.inputWarmUp.didWarm ? "" : "warmUp=failed ")
                    + "trace=\(session.holdTrace.joined(separator: ","))")

            panes
        }
        .task { session.start() }
        .onChange(of: scenePhase) { phase in
            session.setForeground(phase == .active)

            // **BU-9.** The app going away is the last chance to keep what the
            // operator typed. Stashing rather than saving is the point —
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
        // **APP-33.** Raised by the first press that would have gone on the air.
        // `isPresented` is one-way from the session's side: the session sets it,
        // and both buttons — and a swipe-down dismissal, which is a decline —
        // clear it through the session rather than behind its back.
        .sheet(
            isPresented: Binding(
                get: { session.needsLicenceAcknowledgement },
                set: { if !$0 { session.declineLicence() } })
        ) {
            LicenceAcknowledgementView(
                callsign: session.identity.callsign,
                onAccept: { session.acknowledgeLicence() },
                onDecline: { session.declineLicence() })
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
    /// The Keypad and directory tabs come and go with the mode, so a selection
    /// pointing at a departed tab would be a blank screen. ``effectiveTab``
    /// resolves the stored selection against the tabs the current mode
    /// actually has, on read, exactly as ``effectiveDetailPane`` does for the
    /// split layout — the worst case of changing mode is landing back on
    /// Channels.
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
    /// The form gets its own `ScrollView` so a keyboard covering half the
    /// screen cannot make the Connect button unreachable.
    ///
    /// **APP-18: no form once a link is up or on its way** —
    /// `isEditable: session.connection == .disconnected`, so while connected it
    /// is a read-only wall of fields, and the one thing in it worth reading —
    /// where the radio is pointed — is on the status panel instead (APP-16).
    /// The tab gets the whole screen for the channel list instead.
    private var channelsPane: some View {
        NavigationStack {
            ChannelListView(
                session: session,
                onChoose: { id in
                    // Choosing takes the operator to the radio, rather than
                    // landing back on the list with a link coming up
                    // off-screen — which is how an operator ends up talking to
                    // a node they cannot see the state of.
                    Task { await switchChannel(to: id) }
                    selectedTab = .session
                },
                onInspect: { _ in showsChannelDetails = true })
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationDestination(isPresented: $showsChannelDetails) {
                    channelDetails
                }
        }
    }

    /// The connect form, pushed. **APP-23.**
    ///
    /// A push is the iPhone idiom for list-then-detail, and it is what makes
    /// the list's and the form's sizes independent: the list gets the tab, the
    /// form gets a screen. The split layout does not need this and does not
    /// have it — its detail column *is* the pushed screen, permanently.
    private var channelDetails: some View {
        ScrollView {
            connectForm
                .padding(20)
                .paneColumn()
        }
        .navigationTitle(session.settings.displayName.isEmpty
            ? "New channel" : session.settings.displayName)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
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
            // sidebar's first element sits under the window's title bar area
            // and only this side knows that.
            //
            // Top-aligned (BU-12) so an empty list sits at the top of the
            // column, where a sidebar's contents belong, rather than centred
            // in it — see the `fixedSize` note in `ChannelListView` for why an
            // empty list needs that at all.
            // No `onInspect` here: the details are the Connect pane, on screen
            // beside this list already, so an ⓘ would push what is visible.
            ChannelListView(
                session: session,
                onChoose: { id in Task { await switchChannel(to: id) } })
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            detailColumn
        }
    }

    /// The session pane, with the chosen pane under it.
    ///
    /// The session pane is rigid (about 620 points), and a `VStack` that cannot
    /// fit a rigid child centres it, pushing the top of the column off-screen.
    /// So nothing that must stay reachable goes at the top, and the column
    /// sets no `minHeight`: it takes the height it is given, and the pane under
    /// the session pane is what compresses — a directory or settings list,
    /// both of which scroll. BU-12 is the mechanism; APP-15 and BU-19 are the
    /// fixes that settled this, and their commits have the history.
    ///
    /// - On macOS the pane picker is in the window toolbar, which the column's
    ///   overflow cannot push off-screen at any window height. iPad keeps it
    ///   inline: its windows are not short enough to overflow.
    /// - The column is not a scroll view, so the status panel and the button
    ///   that ends a transmission cannot be scrolled away mid-transmission.
    /// - The `.session` pane leaves nothing under the session pane, for the
    ///   displays where the height is tightest.
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

            // One branch below the session pane, not two around it: putting
            // ``SessionPane`` in both arms of an `if` gives it two identities,
            // so changing pane would rebuild it, fire ``PushToTalkButton``'s
            // `onDisappear`, and unkey the radio with the button still on
            // screen.
            if effectiveDetailPane != .session {
                Divider()

                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Overflow goes off the bottom rather than being shared between both
        // edges — a pane clipped symmetrically reads as a rendering fault, and
        // the edge it would be clipped at is the one the status panel is on.
        .frame(maxHeight: .infinity, alignment: .top)
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
            ForEach(detailPanes.panes) { pane in
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
        // Drawn by the column itself, expanded — see `detailColumn`. Reaching
        // here would mean the session pane was on screen twice.
        case .session:
            EmptyView()
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
        // **APP-20.** `paneColumn()` gives these the same padded, width-capped
        // column as the connect form, the keypad and the settings screen —
        // unbounded, the reflector rows' module chips push the list wider than
        // the column and clip the Refresh button off the right edge.
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

    /// The panes this mode and this connection state offer, and the picker's
    /// order for them. See ``DetailPaneSet``, which is where the decision — and
    /// the reason a connect lands on ``DetailPane/session`` rather than on
    /// whatever the mode's first optional pane happens to be — actually lives.
    private var detailPanes: DetailPaneSet {
        DetailPaneSet(connection: session.connection, mode: session.settings.mode)
    }

    /// The selection, resolved against what is actually on offer. Resolved on
    /// read rather than mutated from an `onChange`, because a mode change and a
    /// connect can both take the selected pane away and neither of them is
    /// state: see ``DetailPaneSet/resolving(_:)``.
    private var effectiveDetailPane: DetailPane {
        detailPanes.resolving(detailPane)
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
    /// Goes back through ``connectOrDisconnect()`` rather than calling
    /// `session.connect()`, so a channel needing a proxy gets one sourced the
    /// same way the form's button would.
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
            // ordinary connect, not a restore. See `SessionLinkControl`.
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
            // BU-9: the form's own Save, which is the only thing that writes an
            // edit over the channel it came from.
            hasUnsavedChanges: session.isDraftDirty,
            draftIsUnsavedChannel: session.isDraftAnUnsavedChannel,
            saveAction: { session.saveDraft() },
            proxyPicker: proxyPicker,
            privateProxy: session.echoLinkProxy,
            nodeLocator: nodeLocator)
    }

    /// **APP-23.** What a tap on a channel row does: go there.
    ///
    /// ``RadioSession/switchChannel(to:)`` hangs up and selects, and answers
    /// whether a call was up; the dialling is here because this is where a
    /// proxy gets sourced (see ``connectOrDisconnect()``), the same reason
    /// ``sessionLinkAction()`` goes back through it rather than calling
    /// `session.connect()`.
    ///
    /// The link state is preserved rather than forced: connected to one
    /// channel and tapping another leaves the operator connected to the new
    /// one; tapping one from a standing start only selects it. A single tap
    /// in a list must not place a call.
    private func switchChannel(to id: UUID) async {
        if await session.switchChannel(to: id) {
            await connectOrDisconnect()
        }
    }

    /// Finds a proxy first if this channel needs one, then places or drops the
    /// call. Only on the way *out* — hanging up does not need a proxy.
    ///
    /// A search that finds nothing stops here rather than falling through to
    /// `connect()`, which would otherwise fail validation with "enter the
    /// proxy's host name" — wrong (every public proxy was busy) and useless
    /// (it names a field the operator was never meant to fill in).
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

    /// **APP-12.** The settings screen — the operator, the two stored
    /// accounts, and the PTT accessory.
    ///
    /// Draws no "on air" strip of its own: the root's ``TransmitBanner`` is
    /// above this view and still on screen, so a second copy here would be two
    /// banners saying the same thing.
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
/// controls — keeps the panes the same width as each other, which is what
/// makes switching between them look like one app.
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
