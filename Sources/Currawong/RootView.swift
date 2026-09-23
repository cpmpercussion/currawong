// SPDX-License-Identifier: Apache-2.0

import RadioCore
import SwiftUI

/// The app's root: the transmit banner, the panes, and the session-lifetime
/// handlers that must exist exactly once.
///
/// - ``TransmitBanner`` is a sibling of the `TabView`/`NavigationSplitView`, not
///   a child, so no tab, column or scroll can hide it (SF-4).
/// - It owns two release paths: `scenePhase` leaving `.active` (backgrounded or
///   merely covered — both unkey) and `onDisappear`. `onDisappear` means "the
///   operator has left" and must not be copied into a pane, which would fire it
///   on every tab switch.
/// - It is the one alert presenter; two bound to `session.alert` would race.
///
/// Tabs on a compact iPhone, a split view otherwise; macOS always splits. In
/// the tab layout, leaving the Session tab while keyed unkeys, through
/// ``PushToTalkButton``'s `onDisappear`. That is the safe direction: a
/// transmitter keyed by a button the operator cannot see is the SF-3 failure.
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

    /// Whether the Channels tab has the details form pushed. Tab layout only.
    @State private var showsChannelDetails = false

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: session.transmitState)
    }

    var body: some View {
        VStack(spacing: 0) {
            // SF-4: outside the pane container, and always present; see
            // ``TransmitBanner``.
            TransmitBanner(
                isTransmitting: status.isTransmitting,
                source: session.activeSource,
                keyDownsInHold: session.keyDownsInCurrentHold,
                routeTrace: "\(session.lastKeyDownRoute) "
                    + "prep=\(session.routeSignalsDuringPreparation) "
                    + "tx=\(session.routeSignalsWhileTransmitting) "
                    + "prepMs=\(session.lastPreparationMilliseconds) "
                    + "micMs=\(session.lastCaptureStartMilliseconds) "
                    // BU-24: the only place a device test can see a failed warm-up.
                    + (session.inputWarmUp.didWarm ? "" : "warmUp=failed ")
                    + "trace=\(session.holdTrace.joined(separator: ","))")

            panes
        }
        .task { session.start() }
        .onChange(of: scenePhase) { phase in
            session.setForeground(phase == .active)

            // BU-9: keep unsaved edits as a draft; quitting is not a Save.
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
        // APP-33: raised by the first press that would go on air. Every way
        // out, including a swipe-down (a decline), goes through the session.
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

    /// iPhone: five tabs, of which Keypad and the directory depend on the mode.
    private var tabLayout: some View {
        TabView(selection: tabSelection) {
            channelsPane
                .tabItem { Label("Channels", systemImage: "list.bullet") }
                .tag(Tab.channels)

            // Leaving this tab while keyed unkeys; see the type's doc comment.
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

    /// The tab layout's destinations. The two directories share `directory`:
    /// only one is ever present.
    private enum Tab: Hashable {
        case channels, session, keypad, directory, setup
    }

    /// The stored selection, resolved on read against the tabs this mode has,
    /// so it never points at a missing tab (as ``DetailPaneSet`` does).
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

    /// The channel list; a channel's details are pushed from it.
    private var channelsPane: some View {
        NavigationStack {
            ChannelListView(
                session: session,
                onChoose: { id in
                    // Go to the radio, so a link never comes up off-screen.
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

    /// The connect form, pushed from the channel list (APP-23).
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

    /// Mac and iPad: channels on the left, the radio on the right.
    private var splitLayout: some View {
        NavigationSplitView {
            // Top-aligned so an empty list is not centred (BU-12). No
            // `onInspect`: the details are already on screen beside the list.
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
        // Overflow goes off the bottom, never the top where the status panel is.
        .frame(maxHeight: .infinity, alignment: .top)
        #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    panePicker
                }
            }
        #endif
    }

    /// The pane switcher, bound to the resolved selection so the picker and the
    /// content move together.
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
        // Drawn by `detailColumn` itself.
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
        // Width-capped: unbounded, the reflector rows push Refresh off-screen.
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

    /// The panes on offer, in picker order; see ``DetailPaneSet``.
    private var detailPanes: DetailPaneSet {
        DetailPaneSet(connection: session.connection, mode: session.settings.mode)
    }

    /// The selection, resolved on read; see ``DetailPaneSet/resolving(_:)``.
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

    /// What the session pane's link button does. Connects through
    /// ``connectOrDisconnect()`` so a proxy is sourced as for the form's button.
    private func sessionLinkAction() async {
        switch session.connection {
        case .connected, .connecting:
            // Not `toggleConnection()`, which ignores `.connecting`: this
            // button must be able to cancel a connect.
            await session.disconnect()
        case .disconnecting:
            break
        case .disconnected:
            // The selected channel, as the button names it.
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
            // BU-9: Save is the only thing that overwrites a stored channel.
            hasUnsavedChanges: session.isDraftDirty,
            draftIsUnsavedChannel: session.isDraftAnUnsavedChannel,
            saveAction: { session.saveDraft() },
            proxyPicker: proxyPicker,
            privateProxy: session.echoLinkProxy,
            nodeLocator: nodeLocator)
    }

    /// What a tap on a channel row does (APP-23): select it, and reconnect
    /// there only if a call was up. A tap from disconnected never places a
    /// call.
    private func switchChannel(to id: UUID) async {
        if await session.switchChannel(to: id) {
            await connectOrDisconnect()
        }
    }

    /// Finds a proxy first if connecting a channel that needs one, then places
    /// or drops the call. A search that finds nothing stops here rather than
    /// failing `connect()`'s validation with a misleading message.
    private func connectOrDisconnect() async {
        var proxy: EchoLinkProxyRoute?
        if session.connection == .disconnected, session.settings.mode.usesProxy {
            // Handed to the connect, not stored in the channel (APP-13).
            guard
                let resolved = await proxyPicker.route(
                    privateProxy: session.echoLinkProxy,
                    privatePassword: session.echoLinkProxyPassword)
            else { return }
            proxy = resolved
        }

        await session.toggleConnection(proxy: proxy)
    }

    /// The settings screen: the operator, the stored accounts, the PTT
    /// accessory.
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
}

/// One centred reading width, shared by every pane in this file.
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
