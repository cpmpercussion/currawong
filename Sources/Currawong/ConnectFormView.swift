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

    let isEditable: Bool
    let connectTitle: String
    let isBusy: Bool
    let connectAction: () -> Void

    /// The public-proxy finder's state. Only read when the mode uses a proxy,
    /// which is EchoLink alone.
    @ObservedObject var proxyPicker: ProxyPicker

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

            // Not decoration. Two of these modes have carried a real
            // conversation and one has never been transmitted at all, and the
            // two that work are not equally proven — the mode itself owns that
            // distinction, so the form just displays whatever it says. An
            // operator deserves to know which is which before they key up
            // rather than after.
            if let warning = settings.mode.unvalidatedWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            modePicker

            // The channel's own name. Optional, and the placeholder shows what
            // the list will call it if it stays empty — so an operator can see
            // the fallback is reasonable and skip the field, rather than
            // wondering what an unnamed channel looks like.
            LabelledField(label: "Channel name", systemImage: "tag") {
                TextField(
                    settings.displayName.isEmpty ? "New channel" : settings.displayName,
                    text: $settings.name
                )
                .textFieldStyle(.roundedBorder)
            }

            Text(destinationHeading)
                .font(.headline)

            // Same two fields, three meanings. In EchoLink these address the
            // *proxy* — the node is reached only through the tunnel and is
            // named further down — and mislabelling them is the fastest way to
            // have someone type a node's address here and wait for a
            // connection that was never going to arrive.
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

            if settings.mode.usesProxy {
                proxyFinderRow
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

            if settings.mode.usesProxy {
                LabelledField(label: "Proxy password", systemImage: "lock.open") {
                    // A plain TextField on purpose. `PUBLIC` is the literal a
                    // public proxy expects and is not a secret; hiding it
                    // behind dots would imply it is one, and would stop the
                    // operator seeing that it is still set correctly.
                    TextField(NodeSettings.defaultProxyPassword, text: $settings.proxyPassword)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                Text(
                    "Public proxies all use \(NodeSettings.defaultProxyPassword), which is not a "
                    + "secret and is stored with the channel. A private proxy's password would be "
                    + "stored the same way — less carefully than your account password below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The three modes reach the far end differently: AllStarLink dials
            // a node number, M17 links a module on a reflector, EchoLink names
            // a station twice — once for the operator and once for the wire.
            // Showing all of them would mean fields that quietly do nothing.
            if settings.mode.usesNodeNumber {
                LabelledField(
                    label: "Node number", systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    TextField("55553", text: $settings.node)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
            }

            if settings.mode.usesModule {
                LabelledField(label: "Module", systemImage: "square.grid.2x2") {
                    TextField("C", text: $settings.module)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                }
            }

            if settings.mode.usesProxy {
                echoLinkNodeFields
            }

            Divider()

            Text("You")
                .font(.headline)

            LabelledField(label: "Callsign", systemImage: "person.wave.2") {
                TextField("VK1XYZ", text: $settings.callsign)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .textInputAutocapitalization(.characters)
                    #endif
                    .autocorrectionDisabled()
            }

            identityFields

            Divider()

            Text("Safety")
                .font(.headline)

            LabelledField(label: "Transmit watchdog (seconds)", systemImage: "timer") {
                TextField(String(Int(NodeSettings.defaultTransmitTimeout)), text: $timeoutText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }

            // SF-1 is enforced in the library, not here, and it is not
            // optional — the field sets the number, it cannot switch the
            // watchdog off. Worth saying, so nobody goes looking for the switch.
            Text(
                "The longest a single transmission may last before Currawong unkeys for you. "
                + "Between \(Int(NodeSettings.transmitTimeoutRange.lowerBound)) and "
                + "\(Int(NodeSettings.transmitTimeoutRange.upperBound)) seconds; it cannot be "
                + "turned off. A short value is the quickest way to prove the watchdog works.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            + "EchoLink addresses change as stations come and go, so use the station browser "
            + "rather than typing one from memory.")
            .font(.caption)
            .foregroundStyle(.secondary)

        LabelledField(label: "Directory server", systemImage: "list.bullet.rectangle") {
            TextField(NodeSettings.defaultDirectoryServer, text: $settings.directoryServer)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        }

        // The node address above says "a host name will not work here", which
        // is true of *that* field and would otherwise read as true of this one.
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
    @ViewBuilder
    private var identityFields: some View {
        switch settings.mode {
        case .allStarLink:
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
            LabelledField(label: "Account password", systemImage: "key") {
                SecureField("stored in the Keychain", text: $secret)
                    .textFieldStyle(.roundedBorder)
            }

            // Two passwords on one screen is a trap, so it is named rather than
            // left to position: this is the one EchoLink issued with the
            // callsign, and it is the one the directory server checks.
            //
            // The consequence is spelled out because it is the failure where
            // every step reports success and no call ever arrives: registering
            // is what makes the station reachable at all. That sentence used to
            // sit further up the form, orphaned from any field it described.
            Text(
                "This is your EchoLink account password — the one issued with your callsign — "
                + "and not the proxy password above. Without it the directory server will not "
                + "list stations or register you, and nobody can call you.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabelledField(label: "Operator name", systemImage: "person") {
                TextField("optional", text: $settings.operatorName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabelledField(label: "Location", systemImage: "mappin.and.ellipse") {
                TextField("Canberra", text: $settings.location)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Text("Both are shown to the far end and in the directory listing. Both may be empty.")
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

    /// A label above its field. A `Form` would give this for free on iOS and
    /// something quite different on macOS; laying it out by hand is the
    /// cheapest way to have one screen rather than two.
    private struct LabelledField<Content: View>: View {
        let label: String
        let systemImage: String
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Label(label, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content
            }
        }
    }
}
