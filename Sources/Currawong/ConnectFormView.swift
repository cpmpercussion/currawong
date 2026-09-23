// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The connect screen: where the node lives, who we are, and the one control
/// that opens and closes the connection.
///
/// Edits *one channel* — the draft `RadioSession` holds. **The draft is a
/// working copy** (BU-9): Save writes it to the channel list, and otherwise it
/// waits, including across a quit. Connecting calls whatever the form says and
/// adds it to the list if it is not there yet, without rewriting a channel that
/// is.
///
/// Shows only the fields the current `RadioMode` uses (`usesNodeNumber` /
/// `usesModule` / `usesProxy`) — a visible field that does nothing sends the
/// operator looking in the wrong place when the connection fails. In EchoLink,
/// `host` and `port` are the **proxy's**, not the node's; the labels say so.
///
/// Fields lock while a connection is up, so an edit cannot apply silently to
/// the call already in progress.
struct ConnectFormView: View {
    @Binding var settings: NodeSettings
    @Binding var secret: String

    /// Whether an EchoLink account password is stored (APP-12). Edited on the
    /// settings screen, not here; shown because an EchoLink connection without
    /// one succeeds at every step and is then unreachable.
    let isEchoLinkAccountConfigured: Bool

    /// The Web Transceiver token (APP-11). **Not part of ``settings``** and not
    /// per channel: the portal issues one per operator, and it works on every
    /// WT-enabled node — so, like the callsign, editing it here changes it
    /// everywhere. Only read in AllStarLink mode with that route chosen.
    @Binding var webTransceiverToken: String

    /// The operator's callsign. **Not part of ``settings``** — it is app-wide,
    /// so editing it here changes it for every channel, which is the intent.
    /// See ``OperatorIdentity``.
    @Binding var identity: OperatorIdentity

    let isEditable: Bool

    /// **BU-9.** Whether this channel differs from what is stored under it.
    ///
    /// Drives the Save button and the notice above it: the app never writes an
    /// edit back on its own, so the notice is the only way an operator can see
    /// that what they are looking at is not what the channel list holds.
    let hasUnsavedChanges: Bool

    /// Whether the draft is somewhere not in the channel list yet, which changes
    /// what ``unsavedChangesNotice`` can honestly say — connecting *adds* one of
    /// these, and leaves a stored channel alone.
    let draftIsUnsavedChannel: Bool

    /// Saves the draft over its channel — the one action in the app that
    /// overwrites one.
    let saveAction: () -> Void

    /// The public-proxy finder's state. Only read when the mode uses a proxy,
    /// which is EchoLink alone.
    @ObservedObject var proxyPicker: ProxyPicker

    /// **APP-13.** The operator's own proxy, if they run one — app-wide, edited
    /// on the settings screen, and read here only to say which proxy this session
    /// will use. Not a binding: this form does not own it and must not change it.
    let privateProxy: EchoLinkProxySettings

    /// The node lookup's state. Only read in AllStarLink mode, which is the
    /// only one with node numbers.
    @ObservedObject var nodeLocator: NodeLocator

    @State private var portText = ""

    /// EchoLink's own echo-test service, offered as the node-callsign
    /// placeholder because it is the right first contact: it plays your audio
    /// back at you, so the path can be proved end to end without troubling
    /// another operator.
    private static let echoTestCallsign = "*ECHOTEST*"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Only the fields lock while a call is up; the button must stay
            // live, because it is the one that hangs up.
            fields
                .disabled(!isEditable)

            proxySourcingStatus

            unsavedChangesNotice

            // **APP-23.** Save only — connecting is ``SessionLinkButton``'s job,
            // on the session pane where the operator is watching while talking
            // (see `SessionLinkControl`). This is the only place that answers
            // "keep this", kept separate from "go there" because BU-9 is what
            // happens when one quietly answers the other.
            Button("Save", action: saveAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasUnsavedChanges || !isEditable)
        }
        .onAppear {
            portText = String(settings.port)
        }
        .onChange(of: portText) { newValue in
            // The mode matters: a cleared field means "this mode's own port",
            // and the three modes do not share one.
            if let port = NodeSettings.parsePort(newValue, for: settings.mode) {
                settings.port = port
            }
        }
        // The only writer of `settings.port` is the field above: the proxy is
        // not a channel field (APP-13), so nothing else can move it out from
        // under this.
    }

    /// **BU-9.** Says that the form and the channel list disagree, and which way
    /// round — visible because the edit waits rather than applying itself, and
    /// that is only safe if the operator can see it has not yet.
    @ViewBuilder
    private var unsavedChangesNotice: some View {
        if hasUnsavedChanges {
            Label(
                draftIsUnsavedChannel
                    ? "Not saved. Connecting will add this to your channels."
                    : "Unsaved changes. Connecting will call this, but the saved channel is "
                        + "unchanged until you save.",
                systemImage: "pencil.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the Connect button is doing before it connects.
    ///
    /// ``proxyStatusRow`` says the same thing but sits inside a collapsed
    /// disclosure group, so this is the copy that stays visible on the path
    /// that matters — pressing Connect with no proxy set. Drawn only while
    /// there is something to say.
    @ViewBuilder
    private var proxySourcingStatus: some View {
        if settings.mode.usesProxy {
            if proxyPicker.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        proxyPicker.probedCount > 0
                            ? "Finding a public proxy — probed \(proxyPicker.probedCount)…"
                            : "Finding a public proxy…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop") { proxyPicker.cancel() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else if let failure = proxyPicker.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Which network to use.
    ///
    /// A segmented control rather than a menu: there are three, all are always
    /// available, and an operator should be able to see which one they are on
    /// without opening anything. Changing it moves the port to that mode's
    /// default, but only when the port is still *another* mode's default —
    /// a port the operator typed themselves is theirs to keep.
    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: $settings.mode) {
                ForEach(RadioMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.mode) { newMode in
                for other in RadioMode.allCases where other != newMode {
                    if settings.port == other.defaultPort {
                        settings.port = newMode.defaultPort
                        portText = String(newMode.defaultPort)
                    }
                }

                // Only when the field is empty, so switching modes never
                // overwrites a server the operator chose. Filled in rather than
                // left blank because blank is a *legitimate* setting meaning
                // "no directory login" — an operator who has not decided is not
                // asking for that, and a station that skips the directory login
                // is unreachable while every step still reports success.
                if newMode.usesProxy && settings.directoryServer.isEmpty {
                    settings.directoryServer = NodeSettings.defaultDirectoryServer
                }
            }

        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            modePicker
            channelNameField

            // EchoLink asks for two or three times as much as the other modes,
            // and most of it is infrastructure rather than a destination — so
            // it gets an order of its own. See ``echoLinkFields``.
            if settings.mode.usesProxy {
                echoLinkFields
            } else {
                directFields
            }
        }
    }

    /// The channel's own name. Optional, and the placeholder shows what the
    /// list will call it if it stays empty — so an operator can see the
    /// fallback is reasonable and skip the field, rather than wondering what an
    /// unnamed channel looks like.
    private var channelNameField: some View {
        LabelledField(label: "Channel name", systemImage: "tag") {
            TextField(
                settings.displayName.isEmpty ? "New channel" : settings.displayName,
                text: $settings.name
            )
            .accessibilityIdentifier("connect.channelName")
            .textFieldStyle(.roundedBorder)
            // A channel name is usually a callsign, a reflector or a node —
            // `M17-CBR A`, `VK1RGI` — and autocorrect on any of those is wrong.
            //
            // **Not** the fix for the panel that hangs under this field on
            // launch: that is AppKit's own one-time-code AutoFill panel,
            // unaffected by this modifier. See BU-11 in `docs/BRINGUP.md`.
            .autocorrectionDisabled()
        }
    }

    /// **AllStarLink and M17.** Where to, then who we are. Both modes dial the
    /// thing the operator is thinking of, so the destination comes first.
    @ViewBuilder
    private var directFields: some View {
        Text(destinationHeading)
            .font(.headline)

        hostAndPortFields

        if settings.mode.usesNodeNumber {
            nodeNumberField
            nodeLookupRow
        }

        if settings.mode.usesModule {
            moduleField
        }

        Divider()

        Text("You")
            .font(.headline)

        identityFields
    }

    /// **EchoLink.** Sign in, choose a station, and leave the plumbing alone.
    ///
    /// Ordered by how often it changes rather than by protocol layer:
    ///
    /// 1. **Your account.** Callsign and password — the operator, not the
    ///    channel. The Keychain files the secret under `echolink:<callsign>`,
    ///    shared by every channel with that callsign.
    /// 2. **Where to.** The station, the only part that really varies; the
    ///    Stations pane fills it in.
    /// 3. **How to get there.** The proxy and the directory server, folded
    ///    away — the proxy is app-wide and sourced automatically (APP-13), the
    ///    directory server has one sensible value — so this is a drawer to
    ///    check when something is wrong, not a form to fill in.
    @ViewBuilder
    private var echoLinkFields: some View {
        Text("Your EchoLink account")
            .font(.headline)

        identityFields

        Divider()

        Text("Where to")
            .font(.headline)

        echoLinkNodeFields

        Divider()

        // Collapsed by default: on the common path the operator opens this
        // never, and on the uncommon one they open it once. It is *not* hidden
        // — a proxy that has gone away is diagnosed in here, and a drawer that
        // cannot be found is the same as a missing field.
        DisclosureGroup("Proxy and directory server") {
            VStack(alignment: .leading, spacing: 14) {
                proxyStatusRow
                directoryServerField
            }
            .padding(.top, 10)
        }
        .font(.headline)
    }

    /// **AllStarLink and M17 only.** EchoLink names no host: the node is an
    /// address and the proxy is app-wide (APP-13).
    @ViewBuilder
    private var hostAndPortFields: some View {
        LabelledField(label: "Host", systemImage: "network") {
            TextField("node.example.org", text: $settings.host)
                .accessibilityIdentifier("connect.host")
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
        }

        LabelledField(label: "Port", systemImage: "number") {
            TextField(String(settings.mode.defaultPort), text: $portText)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
        }
    }

    /// **AllStarLink.** The node to dial.
    private var nodeNumberField: some View {
        LabelledField(label: "Node number", systemImage: "antenna.radiowaves.left.and.right") {
            TextField("55553", text: $settings.node)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                // A summary describing a node the operator has since typed over
                // would sit there looking authoritative.
                .onChange(of: settings.node) { _ in nodeLocator.clear() }
        }
    }

    /// **AllStarLink.** Fill in the host by asking the directory rather than by
    /// knowing it — a node's address can be dynamic, so AllStarLink publishes
    /// where it last registered and the app asks rather than requiring the
    /// operator to carry it around.
    ///
    /// **The field stays editable**: a private node is not in the directory at
    /// all, so the lookup is an offer rather than a gate. Also fills in the
    /// channel name from the node's callsign, when the operator has not named
    /// it themselves.
    @ViewBuilder
    private var nodeLookupRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    nodeLocator.find(node: settings.node) { registration in
                        // Host, port and — if unnamed — the channel name; the
                        // rules are the registration's, see
                        // `NodeRegistration.applied(to:)`.
                        settings = registration.applied(to: settings)
                        // Also updates `portText` directly: it is bound to the
                        // field, whose `onChange` would otherwise overwrite the
                        // assignment above with stale text.
                        portText = String(registration.port)
                    }
                } label: {
                    Label(
                        nodeLocator.isSearching ? "Looking up…" : "Look up this node",
                        systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(
                    nodeLocator.isSearching
                        || settings.node.trimmingCharacters(in: .whitespaces).isEmpty)

                if nodeLocator.isSearching {
                    ProgressView().controlSize(.small)
                }
            }

            if let found = nodeLocator.found {
                Label(
                    found.isActive
                        ? found.summary
                        : "\(found.summary) — the directory does not call it active",
                    systemImage: found.isActive ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(found.isActive ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                // Shown only after a successful lookup, so it never offers a
                // page for a number that is not a node. The lookup answers
                // where to dial; the node's own page answers everything else —
                // what it is linked to, who keyed it last.
                if let dashboard = found.dashboard {
                    Link(destination: dashboard) {
                        Label("Node page — connections, last heard", systemImage: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(
                        "Open the page for node \(found.node) in the browser")
                    .accessibilityHint("Shows what this node is connected to and who was last heard")
                }
            }

            if let failure = nodeLocator.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "AllStarLink publishes where each node last registered, so the host above can be "
                + "filled in from the number — and the node's callsign becomes the channel name if "
                + "you have not named it yourself. A private node is not listed — type its address "
                + "by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// **M17.** The module to link on the reflector.
    @ViewBuilder
    private var moduleField: some View {
        LabelledField(label: "Module", systemImage: "square.grid.2x2") {
            TextField("C", text: $settings.module)
                .accessibilityIdentifier("connect.module")
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
        }

        // The host and module can both be typed, and an operator who knows a
        // reflector should not be made to go somewhere else to enter it. But
        // knowing one means having read a list on a website, so the pane that
        // holds that list is named here rather than left to be discovered.
        Text(
            "A single letter — reflectors put different conversations on different modules. "
            + "The Reflectors pane lists what is out there and fills both fields in for you.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **AllStarLink.** Which of the two routes to the node this channel takes.
    ///
    /// A picker rather than something inferred from which fields are filled in:
    /// the two need different credentials, and an app that guessed would tell an
    /// operator with an empty secret field that they had made a typo when in fact
    /// they had chosen the wrong route.
    ///
    /// It sits in the "You" section rather than beside the node, because that is
    /// what it decides — the destination is the same node either way.
    @ViewBuilder
    private var accessPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("How to connect", selection: $settings.allStarAccess) {
                ForEach(AllStarLinkAccess.allCases) { access in
                    Text(access.displayName).tag(access)
                }
            }
            .pickerStyle(.segmented)

            Text(
                settings.usesWebTransceiver
                    ? "Web Transceiver: reach any node whose owner has switched it on, using your "
                        + "allstarlink.org portal account. No arrangement with the node's owner."
                    : "Node secret: the username and secret the node's owner set up for you in "
                        + "its configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// **AllStarLink, Web Transceiver.** The token, and nothing else.
    ///
    /// The username, the node's secret and the extension dialled are all fixed
    /// values for a WT call — a shared guest account, a static secret that ships
    /// in every node's `iax.conf`, and Asterisk's start extension — so the app
    /// fills them in rather than showing three fields whose only correct value is
    /// the one already in them. `CompositionRoot` is where they live, with the
    /// evidence for each.
    @ViewBuilder
    private var webTransceiverFields: some View {
        LabelledField(label: "Portal token", systemImage: "key") {
            // A plain TextField, not a SecureField: 12 hex characters cannot be
            // typed blind, mistakes here are visible (a truncated paste, an
            // upper-cased autocorrection), and it is stored in the Keychain
            // exactly as the secret is.
            TextField("1b59df18107e", text: $webTransceiverToken)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .font(.body.monospaced())
        }

        if !webTransceiverToken.isEmpty
            && !NodeSettings.isPlausibleWebTransceiverToken(webTransceiverToken)
        {
            // A warning, not a refusal: the issuing endpoint is named `legacy`
            // and a successor is expected, so the app must not be the thing
            // that decides a token is invalid — the node decides.
            Label(
                "That does not look like a token: they are \(NodeSettings.webTransceiverTokenLength)"
                    + " lowercase hex characters, like 1b59df18107e. Connecting anyway is fine if "
                    + "you are sure.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text(
            "Get this from your allstarlink.org account. It stands for your callsign — the node "
            + "asks allstarlink.org who the token belongs to — so treat it like a password. Stored "
            + "in the Keychain, under your callsign rather than this channel, because one token "
            + "works on every node.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var callsignField: some View {
        LabelledField(label: "Callsign", systemImage: "person.wave.2") {
            TextField("VK1XYZ", text: $identity.callsign)
                .accessibilityIdentifier("connect.callsign")
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
        }

        // The one field on this form that is not about the channel. Said
        // plainly, because an operator who changed it expecting to affect only
        // the channel in front of them would be wrong in a way that matters:
        // this is what identifies them on the air, everywhere.
        Text("Your callsign, used on every channel and in every mode.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// What the first block of fields is addressing, in the two modes that dial
    /// a host. EchoLink does not use this — its fields have headings of their
    /// own, and the thing it dials is not reached at a host name at all.
    private var destinationHeading: String {
        switch settings.mode {
        case .allStarLink: return "Node"
        case .m17: return "Reflector"
        case .echoLink: return "Node"
        }
    }

    /// **EchoLink.** Which proxy this session goes through — status, not a form
    /// (EL-12, APP-13).
    ///
    /// A phone cannot reach an EchoLink node directly, and public proxies each
    /// carry one user at a time, so the app probes and picks one automatically
    /// — nothing here to fill in. Shown anyway: an operator is entitled to know
    /// whose machine is carrying their traffic, and a proxy that has gone away
    /// mid-sitting is diagnosed here and replaced with one button.
    ///
    /// **Finding nothing is ordinary, not an error.** Every public proxy being
    /// taken is a normal state of the world, so the failure reads as contention
    /// and the button stays pressable, rather than raising a dismissable alert.
    @ViewBuilder
    private var proxyStatusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if privateProxy.isConfigured {
                Label(
                    "Your own proxy: \(privateProxy.host):\(privateProxy.port)",
                    systemImage: "house")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Every EchoLink channel uses it. Change it in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                publicProxyStatus
            }
        }
    }

    /// The public-proxy half of ``proxyStatusRow``: which one is leased, and a way
    /// to swap it.
    @ViewBuilder
    private var publicProxyStatus: some View {
        HStack(spacing: 8) {
            Button {
                proxyPicker.findAnother()
            } label: {
                Label(
                    proxyPicker.isSearching
                        ? "Finding a proxy…"
                        : (proxyPicker.lease == nil ? "Find a public proxy" : "Find another"),
                    systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .disabled(!isEditable || proxyPicker.isSearching)

            if proxyPicker.isSearching {
                ProgressView().controlSize(.small)
                Button("Stop") { proxyPicker.cancel() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Spacer(minLength: 0)
        }

        if proxyPicker.isSearching && proxyPicker.probedCount > 0 {
            // The count moving is what distinguishes "working" from "hung"
            // during the second or two of probing.
            Text("Probed \(proxyPicker.probedCount)…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let lease = proxyPicker.lease, !proxyPicker.isSearching {
            Label(lease.summary, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !proxyPicker.isSearching, proxyPicker.failure == nil {
            // Pressing Connect is the whole step — nothing here needs filling
            // in.
            Text("None yet — one is found when you connect or refresh the directory.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let failure = proxyPicker.failure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        // An obligation, not a nicety: a public proxy is somebody else's
        // machine, one user at a time, and echolink.org asks that they be used
        // briefly. Names the Settings screen that answers it.
        Text(
            "Public proxies are other operators' machines, one user at a time, and this app lets "
            + "one go as soon as you disconnect. Use them briefly — for sustained operating, set "
            + "your own proxy in Settings.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **EchoLink.** The far station, named twice.
    ///
    /// Twice because nothing in the library resolves a callsign to an address —
    /// the proxy tunnels four literal octets — so the callsign is for the
    /// operator and the address is for the wire. They can disagree, and when
    /// they do it is the address that decides who answers, which is exactly why
    /// the browser is the way to fill them both in at once.
    @ViewBuilder
    private var echoLinkNodeFields: some View {
        LabelledField(label: "Node callsign", systemImage: "antenna.radiowaves.left.and.right") {
            // `Self.echoTestCallsign` rather than the literal: a string literal
            // here is a `LocalizedStringKey`, which reads `*ECHOTEST*` as
            // markdown emphasis and renders it as italic ECHOTEST with the
            // asterisks eaten — and the asterisks are part of the callsign.
            TextField(Self.echoTestCallsign, text: $settings.node)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
        }

        LabelledField(label: "Node address", systemImage: "personalhotspot") {
            TextField("13.57.14.183", text: $settings.peer)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        }

        Text(
            "Four numbers separated by dots — a callsign or a host name will not work here. "
            + "EchoLink addresses change as stations come and go, so use the Stations pane "
            + "rather than typing one from memory.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **EchoLink.** Which directory server to log in to.
    ///
    /// In the drawer with the proxy, because it is infrastructure and has one
    /// right answer. It is filled in with that answer when the mode is chosen —
    /// blank is a *legitimate* setting meaning "no directory login", and an
    /// operator who has not decided is not asking for that.
    @ViewBuilder
    private var directoryServerField: some View {
        LabelledField(label: "Directory server", systemImage: "list.bullet.rectangle") {
            TextField(NodeSettings.defaultDirectoryServer, text: $settings.directoryServer)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        }

        // The node address says "a host name will not work here", which is true
        // of *that* field and would otherwise read as true of this one.
        Text(
            "A host name or an address. \(NodeSettings.defaultDirectoryServer) answers with the "
            + "whole pool and is the one to use unless you have a reason not to.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Who we are to the far end — which is a different question in each mode,
    /// and in two of the three involves a password that must not be confused
    /// with the other one on this screen.
    ///
    /// The callsign leads, in every mode. It is the one field on this form that
    /// is about the operator rather than about the destination, and in EchoLink
    /// it is also the account name.
    @ViewBuilder
    private var identityFields: some View {
        callsignField

        switch settings.mode {
        case .allStarLink:
            accessPicker

            if settings.usesWebTransceiver {
                webTransceiverFields
            } else {
                LabelledField(label: "Username", systemImage: "person") {
                    TextField("optional", text: $settings.username)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                LabelledField(label: "Secret", systemImage: "key") {
                    // SecureField; written to the Keychain on connect, never to
                    // UserDefaults or a log.
                    SecureField("stored in the Keychain", text: $secret)
                        .textFieldStyle(.roundedBorder)
                }

                keychainNote
            }

        case .m17:
            // M17 reflectors are unauthenticated — the callsign in every frame
            // is the whole identity — so there is no account and nothing to put
            // in the Keychain. An empty secret field here would imply a
            // security property M17 does not have.
            Label(
                "M17 reflectors are unauthenticated. Your callsign identifies you.",
                systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .echoLink:
            // Edited on the settings screen (APP-12), not per channel: the
            // Keychain files it under `echolink:<callsign>`, shared by every
            // channel with that callsign. Shown here only as whether it is
            // set — a connection with none succeeds at every step and is then
            // unreachable.
            Label(
                isEchoLinkAccountConfigured
                    ? "Account password stored. Change it in Settings."
                    : "No account password yet — set one in Settings, or the directory server "
                        + "will not register you.",
                systemImage: isEchoLinkAccountConfigured
                    ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(isEchoLinkAccountConfigured ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            LabelledField(label: "Operator name", systemImage: "person") {
                TextField("optional", text: $identity.operatorName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabelledField(label: "Location", systemImage: "mappin.and.ellipse") {
                TextField("Canberra", text: $identity.location)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            // App-wide like the callsign — facts about the operator, not the
            // channel. Only EchoLink transmits them, so only this form offers
            // them.
            Text(
                "Both are shown to the far end and in the directory listing, and both may be "
                + "empty. Like your callsign, they are yours rather than this channel's.")
                .font(.caption)
                .foregroundStyle(.secondary)

            keychainNote
        }
    }

    private var keychainNote: some View {
        Text("The password is kept in the Keychain, not in the app's settings file.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

}
