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
/// * **``TransmitBanner``, outside the pane container and always present.**
///   SF-4. It is a sibling
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

    /// **APP-23.** Whether the Channels tab has the details form pushed. Tab
    /// layout only; the split layout shows the same form in its detail column,
    /// where it is never pushed and never dismissed.
    @State private var showsChannelDetails = false

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: session.transmitState)
    }

    var body: some View {
        VStack(spacing: 0) {
            // SF-4: above the pane container, never inside it — and **APP-23:
            // always in it**. Inserting the banner at key-down moved every
            // control below it down the screen, the PTT button under the
            // operator's finger included. The strip is permanent now and says
            // which state it is in by colour and wording.
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
        NavigationStack {
            ChannelListView(
                session: session,
                onChoose: { id in
                    // Choosing takes the operator to the radio. It is what they
                    // came to the list to do, and the alternative — landing back
                    // on the list with a link coming up somewhere off-screen —
                    // is how an operator ends up talking to a node they cannot
                    // see the state of.
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
    /// It used to be the bottom half of the Channels tab, with the list capped
    /// at 320 points above it — which gave the list a third of the screen when
    /// it is the thing the operator is reading, and gave the form two thirds of
    /// one when it is a form they need all of. Neither half was the size it
    /// wanted, in either state.
    ///
    /// A push is the iPhone idiom for list-then-detail, and it is what makes the
    /// two sizes independent: the list gets the tab, the form gets a screen.
    /// The split layout does not need this and does not have it — its detail
    /// column *is* the pushed screen, permanently.
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
            // sidebar's first element sits under the window's title bar area and
            // only this side knows that.
            //
            // **BU-12: the top alignment.** Written while the app was still
            // taller than its window, and held back for it — under that overflow
            // it moved the "Channels" header off the top edge instead of merely
            // down the column, which was worse. With the cause gone (a
            // `fixedSize` in `ChannelListView`; the note there says why) an empty
            // list sits at the top of the column, where a sidebar's contents
            // belong, rather than centred in it.
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
    /// scrollable away while one is running.
    ///
    /// ## Why there is no `minHeight` any more
    ///
    /// There was one — 620 points, "what the session pane and a usable amount
    /// of the tallest pane need" — and it was the BU-12 shape all over again on
    /// an **iPad mini in landscape**, where the column has around 650 points to
    /// work with and connecting adds the meters, the PTT button and the link
    /// button at once. A `minHeight` larger than the window does not scroll and
    /// does not clip at the bottom: the parent **centres** what it could not
    /// fit, so the overflow is split between both edges and the status panel —
    /// the LCD, the first thing in the pane — goes off the top. The operator
    /// loses the display exactly when a link comes up, which is when they are
    /// looking at it.
    ///
    /// A number cannot be right here, because the column has to hold two panes
    /// on a Mac window and one on an iPad mini. So the column now takes what it
    /// is given and lets the stack distribute it: the session pane is rigid and
    /// keeps its size (the PTT button's own `minHeight` is the floor that
    /// matters, and it is 190), and what compresses is whichever pane is under
    /// it — which is a directory or a settings list, both of which scroll.
    /// Nothing load-bearing is in the part that gives.
    ///
    /// The `.session` pane is the other half of the same fix: connected, there
    /// *is* no pane under the session pane, so on the display where the height
    /// was tightest the column is holding one thing.
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

            // `.session` is the radio with the column to itself: no divider and
            // no pane under it, so the meters and the PTT button get the height
            // a directory would otherwise have taken.
            //
            // **Written as one branch below the session pane, not two branches
            // around it.** The obvious shape — `if .session { pane } else {
            // pane; Divider(); content }` — puts ``SessionPane`` in two arms of
            // a conditional, which is two view identities to SwiftUI, so moving
            // the picker between Radio and anything else would tear the pane
            // down and build it again. ``PushToTalkButton``'s
            // `onDisappear { onRelease(.viewDisappeared) }` would fire on the
            // way past: **changing pane while keyed would unkey the radio**,
            // with the button still on screen the whole time. Safe, and wrong —
            // the tab layout unkeys on a tab change because the button really
            // does leave, and here it does not. One position in the stack keeps
            // one identity.
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
    /// **APP-23.** What a tap on a channel row does: go there.
    ///
    /// ``RadioSession/switchChannel(to:)`` does the hanging up and the
    /// selecting, and answers whether a call was up. The dialling is here
    /// because it is here that a proxy gets sourced — the same reason
    /// ``sessionLinkAction()`` goes back through ``connectOrDisconnect()``
    /// rather than calling `session.connect()`.
    ///
    /// The link state is preserved rather than forced: connected to one channel
    /// and tapping another leaves the operator connected to the new one, while
    /// tapping one from a standing start only selects it. A single tap in a
    /// list must not place a call.
    private func switchChannel(to id: UUID) async {
        if await session.switchChannel(to: id) {
            await connectOrDisconnect()
        }
    }

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
