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

    @State private var isShowingAccessorySheet = false

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
        }
        .onDisappear { session.viewDisappeared() }
        .sheet(isPresented: $isShowingAccessorySheet) {
            AccessoryView(
                accessory: accessory,
                remoteCommand: remoteCommand,
                isTransmitting: status.isTransmitting)
        }
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

            if session.settings.mode == .echoLink {
                StationBrowserView(
                    session: session, browser: browser, proxyPicker: proxyPicker,
                    onChosen: { selectedTab = .channels }
                )
                .tabItem { Label("Stations", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.directory)
            }

            if session.settings.mode == .m17 {
                ReflectorBrowserView(
                    session: session, browser: reflectorBrowser,
                    onChosen: { selectedTab = .channels }
                )
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

    /// The channel list with the connect form for whatever it has selected.
    ///
    /// The list takes the space and the form takes what it needs, because the
    /// list is what the operator is reading and the form is the handful of
    /// fields underneath it. The form gets its own `ScrollView` so that a
    /// keyboard covering half the screen cannot make the Connect button
    /// unreachable.
    private var channelsPane: some View {
        VStack(spacing: 0) {
            ChannelListView(session: session)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                // The list takes what it needs up to a third of the screen and
                // no more. Beyond that it scrolls internally, so a long channel
                // list never pushes the form — and the Connect button at the
                // bottom of it — off the bottom of the tab.
                .frame(maxHeight: 320, alignment: .top)

            Divider()

            // Not capped. An earlier `maxHeight` here left slack in the stack,
            // which a `VStack` centres, and the pane opened with a band of empty
            // space above the channel list. The form takes the remainder.
            ScrollView {
                connectForm
                    .padding(20)
                    .paneColumn()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
            ChannelListView(session: session)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            detailColumn
        }
    }

    /// The pane picker, the session pane, and whichever pane is chosen.
    ///
    /// **The picker is at the top, and that is load-bearing.** It used to sit
    /// between the session pane and the pane content, next to the thing it
    /// chooses, which reads better and is wrong. The session pane is a fixed
    /// column — status, meters, a PTT button with a `minHeight` — so it needs
    /// something like 620 points and cannot give any of them back. In a window
    /// shorter than the three regions together, a `VStack` does not shrink the
    /// rigid child; it overflows past the bottom edge. The picker was the first
    /// thing to go over that edge, which left an operator who had opened
    /// Stations on the Stations pane with nothing on screen that could take
    /// them off it — no back button, as reported.
    ///
    /// At the top it is laid out before anything can push it away — but being
    /// first is not on its own enough, and the first version of this fix was
    /// wrong in M17. **A `VStack` centres content it could not fit**, so a
    /// column that overflows spills in *both* directions, and the picker went
    /// off the top instead of the bottom. The Reflectors pane is taller than
    /// Stations — the same 200-point list, plus the attribution line under it —
    /// so M17 overflowed by enough to reach the top edge and EchoLink did not.
    ///
    /// `alignment: .top` is what actually pins it: the content's top edge is
    /// held against the frame's, and everything that does not fit goes off the
    /// bottom, where the pane's own list is already scrollable. Whatever a
    /// future pane's height turns out to be, the picker is still there.
    ///
    /// The `minHeight` is the other half: it stops the window shrinking to
    /// where the chosen pane has no room left to draw in, which the picker
    /// being visible would otherwise hide rather than fix.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            // Bound to the *resolved* selection, so that a mode change which
            // takes the selected pane away moves the picker and the content
            // below it together rather than leaving the picker showing nothing.
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
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .paneColumn()

            Divider()

            sessionPane(showsHeader: false)
                .padding(20)
                .paneColumn()

            Divider()

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // See the note above: `.top` is what keeps the picker on screen when
        // the column cannot fit, and it has to be here rather than on the
        // picker itself — it is the *stack's* overflow that needs a direction.
        .frame(maxHeight: .infinity, alignment: .top)
        // What the three regions actually need: the picker, a session pane that
        // cannot compress, and enough of the tallest pane to be worth showing.
        // A window may be made smaller than this on a small screen — a minimum
        // is a request, not a guarantee — which is exactly why the alignment
        // above matters more than the number does.
        .frame(minHeight: 620)
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
        case .stations:
            StationBrowserView(
                session: session, browser: browser, proxyPicker: proxyPicker,
                onChosen: { detailPane = .connect })
        case .reflectors:
            ReflectorBrowserView(
                session: session, browser: reflectorBrowser,
                onChosen: { detailPane = .connect })
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
            case .connect, .setup: return true
            }
        }
    }

    /// The selection, resolved against what the current mode actually offers.
    ///
    /// Changing mode can take the selected pane away — the selection is state
    /// and the mode is not — so it is corrected on read rather than mutated
    /// from an `onChange`. `.connect` is the fallback because it is the pane
    /// that can put the operator back on a working link.
    private var effectiveDetailPane: DetailPane {
        visibleDetailPanes.contains(detailPane) ? detailPane : .connect
    }

    // MARK: - Shared pieces

    private func sessionPane(showsHeader: Bool) -> some View {
        SessionPane(
            session: session,
            accessory: accessory,
            remoteCommand: remoteCommand,
            showsHeader: showsHeader,
            openAccessories: { isShowingAccessorySheet = true })
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
            proxyPicker: proxyPicker,
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
        if session.connection == .disconnected {
            guard
                await proxyPicker.sourceProxyIfNeeded(for: session.settings, apply: { candidate in
                    session.settings.host = candidate.host
                    session.settings.port = candidate.port
                })
            else { return }
        }

        await session.toggleConnection()
    }

    /// **APP-12.** The settings screen — the operator, the two stored accounts,
    /// and the PTT accessory, which used to be the whole of this destination.
    ///
    /// `isTransmitting: false` for the same reason the pane always passed it: the
    /// root's ``TransmitBanner`` is above this view and still on screen, so a
    /// second copy inside it would be two banners saying the same thing.
    private var settingsPane: some View {
        SettingsView(
            session: session,
            accessory: accessory,
            remoteCommand: remoteCommand,
            portalLogin: portalLogin,
            isTransmitting: false)
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
