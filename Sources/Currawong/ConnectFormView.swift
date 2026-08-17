// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The connect screen: where the node lives, who we are, and the one control
/// that opens and closes the connection.
///
/// This edits *one channel* — the draft `RadioSession` holds — and the list of
/// them is `ChannelListView`'s job. The one thing that would have been painful
/// to change later, and so was never deferred, is *where the secret goes*: it
/// is in the Keychain from the first commit, so there is never a migration out
/// of `UserDefaults` to write.
///
/// ## Three modes, three sets of live fields
///
/// The form shows the third of `NodeSettings` the mode actually uses, per
/// `RadioMode.usesNodeNumber` / `usesModule` / `usesProxy`. A field that is
/// visible but does nothing is worse than an absent one: the operator fills it
/// in, the connection fails somewhere else, and the field they typed into is
/// the first place they will go looking.
///
/// EchoLink is where that matters most, because two of the fields it shares
/// with the other modes *mean something different*: `host` and `port` are the
/// **proxy's**, not the node's, and the node is named separately by callsign
/// and by literal address. The labels say so rather than leaving the operator
/// to infer it from a failed connection.
///
/// Fields lock while a connection is up. Editing the host under a live call
/// would either do nothing (confusing) or silently apply to the next call
/// (worse).
struct ConnectFormView: View {
    @Binding var settings: NodeSettings
    @Binding var secret: String

    /// Whether an EchoLink account password is stored (APP-12). The form no
    /// longer edits it — the settings screen does — but it still says whether one
    /// is set, because an EchoLink connection without it succeeds at every step
    /// and is then unreachable.
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
    let connectTitle: String
    let isBusy: Bool
    let connectAction: () -> Void

    /// The public-proxy finder's state. Only read when the mode uses a proxy,
    /// which is EchoLink alone.
    @ObservedObject var proxyPicker: ProxyPicker

    /// The node lookup's state. Only read in AllStarLink mode, which is the
    /// only one with node numbers.
    @ObservedObject var nodeLocator: NodeLocator

    @State private var portText = ""
    @State private var timeoutText = ""

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

            Button(action: connectAction) {
                HStack {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(connectTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
        }
        .onAppear {
            portText = String(settings.port)
            timeoutText = String(Int(settings.transmitTimeout))
        }
        .onChange(of: portText) { newValue in
            // The mode matters: a cleared field means "this mode's own port",
            // and the three modes do not share one.
            if let port = NodeSettings.parsePort(newValue, for: settings.mode) {
                settings.port = port
            }
        }
        .onChange(of: timeoutText) { newValue in
            if let timeout = NodeSettings.parseTransmitTimeout(newValue) {
                settings.transmitTimeout = timeout
            }
        }
        // The port can now change without this form touching it: Connect and
        // the Stations pane both source a proxy when the channel has none, and
        // that writes a port. `portText` is only seeded in `onAppear`, so
        // without this the field would go on showing the old number while the
        // connection used the new one — and the *next* keystroke in it would
        // write the stale value back over the proxy's.
        //
        // The guard is what stops the loop: `portText`'s own `onChange` writes
        // `settings.port`, which lands back here.
        .onChange(of: settings.port) { newPort in
            if portText != String(newPort) { portText = String(newPort) }
        }
    }

    /// What the Connect button is doing before it connects.
    ///
    /// The same two lines live in ``proxyFinderRow``, which is inside a
    /// disclosure group that is collapsed on the common path — so on the path
    /// that matters, pressing Connect with no proxy set, neither of them would
    /// be seen. This is the copy that is always visible, and it is only drawn
    /// while there is something to say.
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

            Divider()

            safetyFields
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
            .textFieldStyle(.roundedBorder)
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
    /// The other two modes ask for a destination and a callsign. EchoLink asks
    /// for a proxy host, a proxy port, a proxy password, a node callsign, a node
    /// address, a directory server, an account password, a name and a location —
    /// and an operator meeting that form has no way to tell that six of the nine
    /// are the same every time and two of them are filled in by pressing a
    /// button.
    ///
    /// So it is ordered by *how often it changes* rather than by protocol layer:
    ///
    /// 1. **Your account.** Callsign and password. These are the operator, not
    ///    the channel — the Keychain has always known that, filing an EchoLink
    ///    secret under `echolink:<callsign>` and sharing it across every channel
    ///    with that callsign — but the form used to present them last, below the
    ///    plumbing, as though they were per-destination settings.
    /// 2. **Where to.** The station, which is the only part that really varies,
    ///    and which the Stations pane fills in.
    /// 3. **How to get there.** The proxy and the directory server, folded away.
    ///    A public proxy is found by pressing a button and the directory server
    ///    has one sensible value, so this is a drawer to open when something is
    ///    wrong rather than a form to fill in.
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
                proxyFinderRow
                hostAndPortFields
                proxyPasswordField
                directoryServerField
            }
            .padding(.top, 10)
        }
        .font(.headline)
    }

    /// SF-1. Its own section in every mode, because the watchdog is the one
    /// setting on this screen that exists to stop something bad rather than to
    /// make something work.
    @ViewBuilder
    private var safetyFields: some View {
        Text("Safety")
            .font(.headline)

        watchdogField
    }

    @ViewBuilder
    private var hostAndPortFields: some View {
        LabelledField(
            label: settings.mode.usesProxy ? "Proxy host" : "Host", systemImage: "network"
        ) {
            TextField(
                settings.mode.usesProxy ? "proxy.example.org" : "node.example.org",
                text: $settings.host
            )
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
        }

        LabelledField(
            label: settings.mode.usesProxy ? "Proxy port" : "Port", systemImage: "number"
        ) {
            TextField(String(settings.mode.defaultPort), text: $portText)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
        }
    }

    @ViewBuilder
    private var proxyPasswordField: some View {
        LabelledField(label: "Proxy password", systemImage: "lock.open") {
            // A plain TextField on purpose. `PUBLIC` is the literal a public
            // proxy expects and is not a secret; hiding it behind dots would
            // imply it is one, and would stop the operator seeing that it is
            // still set correctly.
            TextField(NodeSettings.defaultProxyPassword, text: $settings.proxyPassword)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        }

        Text(
            "Public proxies all use \(NodeSettings.defaultProxyPassword), which is not a secret "
            + "and is stored with the channel. A private proxy's password would be stored the "
            + "same way — less carefully than your account password.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
    /// knowing it.
    ///
    /// A node number is what everybody quotes on the air; the address behind it
    /// is not something an operator carries around, and for a node that
    /// re-registers on a dynamic address it is not something they can carry
    /// around. AllStarLink publishes the mapping, so the app asks.
    ///
    /// **The field stays editable.** A private node is not in the directory at
    /// all and its owner gives you the address directly, so the lookup is an
    /// offer rather than a gate.
    @ViewBuilder
    private var nodeLookupRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    nodeLocator.find(node: settings.node) { registration in
                        settings.host = registration.host
                        // Through `portText`, not `settings.port`: the port
                        // field is bound to the text and its `onChange` writes
                        // the number back, so setting the number directly would
                        // be overwritten by the stale text. Same trap the proxy
                        // finder documents.
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

                // The counterpart to the reflector list's dashboard link, and
                // shown for the same reason: the lookup answers where to dial,
                // and the node's own page answers everything else — what it is
                // linked to, who keyed it last. Only after a successful lookup,
                // so it never offers a page for a number that is not a node.
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
                + "filled in from the number. A private node is not listed — type its address by "
                + "hand.")
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
            // A plain TextField, unlike the node secret's SecureField, and it is
            // a considered difference rather than an oversight: 12 characters of
            // hex cannot be typed blind, the mistakes people make with it are
            // *visible* ones (a truncated paste, an upper-cased autocorrection),
            // and it is still stored in the Keychain exactly as the secret is.
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
            // A warning, not a refusal. The endpoint that issues these is named
            // `legacy` and a successor is expected, so the app must not be the
            // thing that decides a token is invalid — the node decides.
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

    @ViewBuilder
    private var watchdogField: some View {
        LabelledField(label: "Transmit watchdog (seconds)", systemImage: "timer") {
            TextField(String(Int(NodeSettings.defaultTransmitTimeout)), text: $timeoutText)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
        }

        // SF-1 is enforced in the library, not here, and it is not optional —
        // the field sets the number, it cannot switch the watchdog off. Worth
        // saying, so nobody goes looking for the switch.
        Text(
            "The longest a single transmission may last before Currawong unkeys for you. "
            + "Between \(Int(NodeSettings.transmitTimeoutRange.lowerBound)) and "
            + "\(Int(NodeSettings.transmitTimeoutRange.upperBound)) seconds; it cannot be "
            + "turned off. A short value is the quickest way to prove the watchdog works.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What the first block of fields is addressing. Three words for three
    /// different things, because in EchoLink it is genuinely not the node.
    private var destinationHeading: String {
        switch settings.mode {
        case .allStarLink: return "Node"
        case .m17: return "Reflector"
        case .echoLink: return "Proxy"
        }
    }

    /// **EchoLink.** Fill in the proxy host and port by measurement rather than
    /// by typing (EL-12).
    ///
    /// A phone cannot reach an EchoLink node directly, so a proxy is mandatory,
    /// and the public ones are a list of strangers' machines that each carry one
    /// user at a time. Choosing well means knowing which are near and which are
    /// free right now — neither of which an operator can tell by looking at a
    /// list, and both of which a probe answers in a second or two.
    ///
    /// **Finding nothing is an ordinary outcome, not an error.** Every public
    /// proxy being taken is a normal state of the world, so the failure is
    /// phrased as contention and the button stays right there to be pressed
    /// again, rather than raising an alert that has to be dismissed first.
    @ViewBuilder
    private var proxyFinderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    proxyPicker.find { candidate in
                        settings.host = candidate.host
                        // Through `portText`, not `settings.port`: the port
                        // field is bound to the text and its `onChange` is what
                        // writes the number back. Setting the number directly
                        // would be overwritten by the stale text.
                        portText = String(candidate.port)
                    }
                } label: {
                    Label(
                        proxyPicker.isSearching ? "Finding a proxy…" : "Find a public proxy",
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

            if let chosen = proxyPicker.chosen, !proxyPicker.isSearching {
                Label(chosen.summary, systemImage: "checkmark.circle")
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

            // Carried across from the CLI, which prints the same thing, because
            // it is an obligation rather than a nicety: a public proxy is
            // somebody else's machine, it serves one user at a time, and
            // echolink.org asks that they be used briefly. An operator who does
            // not know that cannot honour it.
            Text(
                "Public proxies are other operators' machines, one user at a time. Use them "
                + "briefly — a private proxy is the answer for sustained operating.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    // SecureField, and the value is written to the Keychain on
                    // connect — never to UserDefaults, and never to a log.
                    SecureField("stored in the Keychain", text: $secret)
                        .textFieldStyle(.roundedBorder)
                }

                keychainNote
            }

        case .m17:
            // M17 reflectors do not authenticate — the callsign in every frame
            // is the whole of the identity — so there is no account and nothing
            // to put in the Keychain. Offering an empty secret field in that
            // mode would imply a security property M17 does not have.
            Label(
                "M17 reflectors are unauthenticated. Your callsign identifies you.",
                systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .echoLink:
            // The password moved to the settings screen (APP-12). It was never a
            // property of a channel — the Keychain has always filed it under
            // `echolink:<callsign>`, shared by every EchoLink channel with that
            // callsign — and a form that asked for it per channel implied
            // otherwise. What is left here is whether it is set, because that is
            // the thing an operator needs to know from *this* screen: an
            // EchoLink connection with no account password succeeds at every
            // step and is then unreachable.
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

            // App-wide like the callsign, and for the same reason — they are
            // facts about the operator. Only EchoLink transmits them, so only
            // this form offers them, but what they edit is the one stored value
            // rather than a field of this channel.
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
