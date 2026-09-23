// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The channel form: where the channel goes, who the operator is, and Save.
///
/// Edits the draft `RadioSession` holds, which is a working copy (BU-9): Save
/// is the only thing that writes it over its channel. Shows only the fields the
/// current `RadioMode` uses, and locks them while a link is up.
struct ConnectFormView: View {
    @Binding var settings: NodeSettings
    @Binding var secret: String

    /// Whether an EchoLink account password is stored. Edited in Settings;
    /// shown because without one a connection succeeds but is unreachable.
    let isEchoLinkAccountConfigured: Bool

    /// The Web Transceiver token: one per operator, not per channel, so an edit
    /// here changes it everywhere.
    @Binding var webTransceiverToken: String

    /// The operator's identity: app-wide, not part of ``settings``.
    @Binding var identity: OperatorIdentity

    let isEditable: Bool

    /// Whether the draft differs from its stored channel (BU-9). Drives Save
    /// and the notice.
    let hasUnsavedChanges: Bool

    /// Whether the draft is a channel not in the list yet, which changes what
    /// ``unsavedChangesNotice`` says.
    let draftIsUnsavedChannel: Bool

    /// Saves the draft over its channel.
    let saveAction: () -> Void

    /// The public-proxy finder's state (EchoLink only).
    @ObservedObject var proxyPicker: ProxyPicker

    /// The operator's own proxy, if any; read only, to say which proxy will be
    /// used (APP-13).
    let privateProxy: EchoLinkProxySettings

    /// The node lookup's state (AllStarLink only).
    @ObservedObject var nodeLocator: NodeLocator

    @State private var portText = ""

    /// EchoLink's echo-test service, the placeholder because it proves the
    /// path end to end without troubling another operator.
    private static let echoTestCallsign = "*ECHOTEST*"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            fields
                .disabled(!isEditable)

            proxySourcingStatus

            unsavedChangesNotice

            // Save only; connecting is ``SessionLinkButton``'s (APP-23).
            Button("Save", action: saveAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasUnsavedChanges || !isEditable)
        }
        .onAppear {
            portText = String(settings.port)
        }
        .onChange(of: portText) { newValue in
            // A cleared field means this mode's default port.
            if let port = NodeSettings.parsePort(newValue, for: settings.mode) {
                settings.port = port
            }
        }
    }

    /// Says the form and the channel list disagree (BU-9).
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

    /// The proxy search before a connect, outside the collapsed group that
    /// holds ``proxyStatusRow`` so it stays visible.
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

    /// Which network to use. Changing it moves the port to the new mode's
    /// default only if it was still another mode's default.
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

                // Only when empty: blank means "no directory login", which
                // leaves a station unreachable while reporting success.
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

            if settings.mode.usesProxy {
                echoLinkFields
            } else {
                directFields
            }
        }
    }

    /// The channel's name. Optional; the placeholder shows the fallback.
    private var channelNameField: some View {
        LabelledField(label: "Channel name", systemImage: "tag") {
            TextField(
                settings.displayName.isEmpty ? "New channel" : settings.displayName,
                text: $settings.name
            )
            .accessibilityIdentifier("connect.channelName")
            .textFieldStyle(.roundedBorder)
            // Names are callsigns and reflectors. (Not related to the AutoFill
            // panel under this field on macOS; see BU-11.)
            .autocorrectionDisabled()
        }
    }

    /// AllStarLink and M17: destination first, then the operator.
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

    /// EchoLink: the operator's account, then the station, then the proxy and
    /// directory server folded away — ordered by how often each changes.
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

        // Collapsed, not hidden: a failing proxy is diagnosed in here.
        DisclosureGroup("Proxy and directory server") {
            VStack(alignment: .leading, spacing: 14) {
                proxyStatusRow
                directoryServerField
            }
            .padding(.top, 10)
        }
        .font(.headline)
    }

    /// AllStarLink and M17 only; EchoLink's node is an address.
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
                // A lookup result for a different number would mislead.
                .onChange(of: settings.node) { _ in nodeLocator.clear() }
        }
    }

    /// **AllStarLink.** Fills in the host from where the node last registered,
    /// and the name from its callsign if unnamed. An offer, not a gate: a
    /// private node is not listed, so the fields stay editable.
    @ViewBuilder
    private var nodeLookupRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    nodeLocator.find(node: settings.node) { registration in
                        // See `NodeRegistration.applied(to:)`.
                        settings = registration.applied(to: settings)
                        // Or the port field's `onChange` would write stale
                        // text back over the assignment above.
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

                // Only after a successful lookup, so never for a non-node.
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

        Text(
            "A single letter — reflectors put different conversations on different modules. "
            + "The Reflectors pane lists what is out there and fills both fields in for you.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **AllStarLink.** Which route to the node this channel takes: chosen, not
    /// inferred from the filled fields, since the routes need different
    /// credentials. In "You", because it decides credentials, not destination.
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

    /// **AllStarLink, Web Transceiver.** Only the token: the username, secret
    /// and extension are fixed for a WT call and live in `CompositionRoot`.
    @ViewBuilder
    private var webTransceiverFields: some View {
        LabelledField(label: "Portal token", systemImage: "key") {
            // Not a SecureField, so a bad paste is visible. Still Keychain-stored.
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
            // A warning, not a refusal: the node decides what is valid.
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

        // Said plainly: this field is app-wide, unlike the rest of the form.
        Text("Your callsign, used on every channel and in every mode.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The destination heading for ``directFields``; EchoLink has its own.
    private var destinationHeading: String {
        switch settings.mode {
        case .allStarLink: return "Node"
        case .m17: return "Reflector"
        case .echoLink: return "Node"
        }
    }

    /// **EchoLink.** Which proxy this session goes through: status, not a form,
    /// since one is picked automatically (APP-13). Shown so the operator knows
    /// whose machine carries their traffic and can swap a dead one. Finding
    /// none is contention, not an error, so it is no alert.
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

    /// The leased public proxy, and a way to swap it.
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
            // A moving count tells working from hung.
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

        // echolink.org asks that public proxies be used briefly.
        Text(
            "Public proxies are other operators' machines, one user at a time, and this app lets "
            + "one go as soon as you disconnect. Use them briefly — for sustained operating, set "
            + "your own proxy in Settings.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **EchoLink.** The far station: a callsign for the operator and an
    /// address for the wire, since the proxy tunnels literal octets. If they
    /// disagree the address wins; the Stations pane fills in both.
    @ViewBuilder
    private var echoLinkNodeFields: some View {
        LabelledField(label: "Node callsign", systemImage: "antenna.radiowaves.left.and.right") {
            // Not a literal: as a `LocalizedStringKey`, `*ECHOTEST*` renders as
            // markdown italics and loses its asterisks.
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

    /// **EchoLink.** The directory server; filled in when the mode is chosen,
    /// since blank means "no directory login".
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

        // Unlike the node address, this takes a host name.
        Text(
            "A host name or an address. \(NodeSettings.defaultDirectoryServer) answers with the "
            + "whole pool and is the one to use unless you have a reason not to.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Who the operator is to the far end, per mode. The callsign leads in
    /// every mode; in EchoLink it is also the account name.
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
                    // Written to the Keychain on connect; never to defaults or logs.
                    SecureField("stored in the Keychain", text: $secret)
                        .textFieldStyle(.roundedBorder)
                }

                keychainNote
            }

        case .m17:
            // No secret field: it would imply security M17 does not have.
            Label(
                "M17 reflectors are unauthenticated. Your callsign identifies you.",
                systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .echoLink:
            // Edited in Settings (APP-12); shown only as set or not.
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

            // App-wide, like the callsign; only EchoLink sends them.
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
