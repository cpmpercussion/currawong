// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The channel form: a channel's name, where it goes, and what it needs to get
/// in. The one place a network's fields are edited.
///
/// Edits whatever ``settings`` is bound to as it is typed, with no Save: the
/// selected channel, which `RadioSession` writes back on every change, or the
/// channel ``AddChannelView`` is holding. Shows only the fields the channel's
/// `RadioMode` uses, and locks them while a link is up. The network is fixed
/// when a channel is added, so there is no picker for it.
struct ConnectFormView: View {
    @Binding var settings: NodeSettings
    @Binding var secret: String

    /// Whether an EchoLink account password is stored. Its absence is shown,
    /// because without one a connection succeeds but is unreachable.
    let isEchoLinkAccountConfigured: Bool

    /// The Web Transceiver token: one per operator, not per channel, so an edit
    /// here changes it everywhere.
    @Binding var webTransceiverToken: String

    let isEditable: Bool

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
        }
        .onAppear {
            portText = String(settings.port)
        }
        // The form outlives a change of channel, and the port field is text.
        .onChange(of: settings.id) { _ in
            portText = String(settings.port)
        }
        .onChange(of: portText) { newValue in
            // A cleared field means this mode's default port.
            if let port = NodeSettings.parsePort(newValue, for: settings.mode) {
                settings.port = port
            }
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
                            ? "Finding a public proxy, tried \(proxyPicker.probedCount)…"
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

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
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

    /// AllStarLink and M17: the destination, then what it takes to get in.
    /// AllStarLink leads with the node number, because the lookup under it
    /// fills in the host.
    @ViewBuilder
    private var directFields: some View {
        Text(destinationHeading)
            .font(.headline)

        if settings.mode.usesNodeNumber {
            nodeNumberField
            nodeLookupRow
        }

        hostAndPortFields

        if settings.mode.usesModule {
            moduleField
        }

        accessFields
    }

    /// EchoLink: the station, then the proxy and directory server folded
    /// away — ordered by how often each changes.
    @ViewBuilder
    private var echoLinkFields: some View {
        if !isEchoLinkAccountConfigured {
            Label(
                "No EchoLink password yet. Add it in Settings, or stations will not answer.",
                systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("Station")
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
                .numberPadWithDone()
        }
    }

    /// **AllStarLink.** The node to dial.
    private var nodeNumberField: some View {
        LabelledField(label: "Node number", systemImage: "antenna.radiowaves.left.and.right") {
            TextField("55553", text: $settings.node)
                .accessibilityIdentifier("connect.node")
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
                        : "\(found.summary), not listed as active",
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

            Text("Fills in the host from the number. A private node is not listed.")
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

        Text("A single letter. Reflectors put different conversations on different modules.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **AllStarLink.** Which route to the node this channel takes: chosen, not
    /// inferred from the filled fields, since the routes need different
    /// credentials. Under "Access", because it decides credentials, not
    /// destination.
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
                    ? "Reach any node that allows Web Transceiver, with your allstarlink.org account."
                    : "Use the username and secret the node's owner gave you.")
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
            // Not a SecureField, so a bad paste is visible.
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
                "This does not look like a token. They are "
                    + "\(NodeSettings.webTransceiverTokenLength) characters, like 1b59df18107e.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("From your allstarlink.org account. Used for every AllStarLink channel.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
            Text("Tried \(proxyPicker.probedCount) so far…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let lease = proxyPicker.lease, !proxyPicker.isSearching {
            Label(lease.summary, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !proxyPicker.isSearching, proxyPicker.failure == nil {
            Text("None yet. One is found when you connect.")
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
        Text("Public proxies are shared. Use them briefly, or set your own in Settings.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **EchoLink.** The far station: a callsign for the operator and an
    /// address for the wire, since the proxy tunnels literal octets. If they
    /// disagree the address wins; the station list fills in both.
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

        Text("Four numbers separated by dots. Add the station again to bring it up to date.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **EchoLink.** The directory server. A new channel starts with the
    /// default (``NodeSettings/blank(for:)``), since blank means "no directory
    /// login".
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
        Text("Leave this as \(NodeSettings.defaultDirectoryServer) unless you know otherwise.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What the channel needs to get in, per mode. The callsign is not here: it
    /// is the operator's, asked for once and kept in Settings.
    @ViewBuilder
    private var accessFields: some View {
        switch settings.mode {
        case .allStarLink:
            Divider()

            Text("Access")
                .font(.headline)

            accessPicker

            if settings.usesWebTransceiver {
                webTransceiverFields
            } else {
                LabelledField(label: "Username", systemImage: "person") {
                    TextField("optional", text: $settings.username)
                        .accessibilityIdentifier("connect.username")
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                LabelledField(label: "Secret", systemImage: "key") {
                    // Kept in the Keychain; never in defaults or logs.
                    SecureField("", text: $secret)
                        .accessibilityIdentifier("connect.secret")
                        .textFieldStyle(.roundedBorder)
                }
            }

        case .m17:
            // No secret field: it would imply security M17 does not have.
            Label(
                "M17 needs no password. Your callsign identifies you.",
                systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .echoLink:
            // The account is the operator's, not the channel's.
            EmptyView()
        }
    }

}
