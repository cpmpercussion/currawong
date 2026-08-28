// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-12.** The app-level settings screen: who you are, how long you may
/// transmit, the two accounts that are yours rather than a channel's, and the PTT
/// accessory.
///
/// ## Why these things are together
///
/// Everything here is app-wide. Each of the three was previously somewhere that
/// implied otherwise:
///
/// * **The callsign** was on every connect form, where it looks like a field of
///   the channel in front of you. It is not, and never was.
/// * **The EchoLink account password** was typed on the connect form too, while
///   the Keychain had always filed it under `echolink:<callsign>` — one password
///   shared by every EchoLink channel with that callsign. The form was the wrong
///   shape for the thing it was editing.
/// * **The Web Transceiver token** is issued by allstarlink.org to an operator
///   and works on every WT-enabled node, so it belongs beside the callsign it
///   stands for and not with any one node.
/// * **The transmit watchdog** (SF-1) was a field of every connect form, so the
///   answer to "how long will it let me talk?" depended on which channel was
///   selected — for the one setting in the app whose whole job is to stop a stuck
///   microphone. See ``TransmitTimeout``.
/// * **The PTT accessory** was reachable only from a row on the session pane,
///   which meant accessory setup was something found mid-session — a poor moment
///   to be pairing a fob.
/// * **A private EchoLink proxy** (APP-13) was three fields of every channel,
///   inside a collapsed drawer on the connect screen. A proxy is the machine an
///   operator's traffic leaves through — one for the whole station, set up once —
///   so asking for it per destination put the most durable setting in the app in
///   its least durable place. It is also tricky enough to set up that it deserves
///   a screen where an operator is *expecting* to configure something, rather
///   than one they are on because they want to talk to somebody.
///
/// The connect form keeps the callsign field, because it is the field an operator
/// filling in their first channel must not have to go looking for. Both edit the
/// same app-wide value; there is one source of truth and two doors to it.
///
/// ## EchoLink's wording
///
/// OQ-1b: "EchoLink" is nominative use only. The pane says what the account is
/// for and no more — no logo, no styling, nothing that suggests the app is an
/// EchoLink product.
struct SettingsView: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var accessory: BLEPTTController
    @ObservedObject var remoteCommand: RemoteCommandPTTController
    @ObservedObject var portalLogin: PortalLoginController

    /// The token, as typed or pasted. Committed to the Keychain on `onSubmit`
    /// and when the field loses focus rather than on every keystroke, so a
    /// half-pasted token is never what gets stored.
    @State private var tokenText = ""

    /// Likewise the EchoLink password.
    @State private var echoLinkPasswordText = ""

    /// The private proxy, as typed. Committed together, on the button, for the
    /// reason ``RadioSession/setEchoLinkProxy(_:password:)`` takes both: a host
    /// stored without its password is a proxy that refuses every session.
    @State private var proxyHostText = ""
    @State private var proxyPortText = ""
    @State private var proxyPasswordText = ""

    /// What went wrong saving the proxy, if anything. Shown beside the fields
    /// rather than as an alert: it is a complaint about something on screen.
    @State private var proxyComplaint: String?

    /// The watchdog timeout as typed. Committed on every keystroke that parses,
    /// unlike the two credentials above: it is one number rather than a pasted
    /// string, there is nothing to half-type, and a safety limit that only takes
    /// effect if you remember to press something is not one.
    @State private var timeoutText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                operatorSection
                Divider()
                safetySection
                Divider()
                portalSection
                Divider()
                echoLinkSection
                Divider()
                proxySection
                Divider()
                accessorySection
                Divider()
                aboutSection
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            tokenText = session.webTransceiverToken
            echoLinkPasswordText = session.echoLinkAccountPassword
            timeoutText = String(session.transmitTimeout.wholeSeconds)
            proxyHostText = session.echoLinkProxy.host
            proxyPortText = String(session.echoLinkProxy.port)
            proxyPasswordText = session.echoLinkProxyPassword
        }
        .onChange(of: timeoutText) { newValue in
            // An unparseable value is left alone rather than reset, so a field
            // being cleared to retype it does not flick back to 180 under the
            // operator's fingers. `TransmitTimeout.parse` clamps what it accepts.
            if let timeout = TransmitTimeout.parse(newValue) {
                session.transmitTimeout = timeout
            }
        }
        // The portal login writes the token through the session, so the field
        // has to follow it rather than only being read once.
        .onChange(of: session.webTransceiverToken) { newValue in
            if tokenText != newValue { tokenText = newValue }
        }
    }

    // MARK: - You

    private var operatorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Operator")
                .font(.title3.weight(.semibold))

            LabelledField(label: "Callsign", systemImage: "person.wave.2") {
                TextField("VK1XYZ", text: $session.identity.callsign)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .textInputAutocapitalization(.characters)
                    #endif
                    .autocorrectionDisabled()
                    // BU-9: `stashDraft()`, not `saveDraft()`. The callsign is
                    // app-wide and this persists it, and the settings screen has
                    // no business overwriting whichever channel happens to be
                    // selected — which is exactly what the old call did.
                    .onSubmit { session.stashDraft() }
            }

            Text(
                "Used on every channel and in every mode, and it is what both accounts below are "
                + "filed under.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Safety

    /// **SF-1.** The transmit watchdog, which used to be a field of every connect
    /// form.
    ///
    /// It is here for the same reason the callsign is: it was on a per-channel
    /// screen while being the operator's own setting. The watchdog is the one
    /// control in the app that exists to stop something bad rather than to make
    /// something work, and an operator who cannot answer "how long will it let me
    /// talk?" without opening a particular channel does not really have the
    /// setting at all. See ``TransmitTimeout``.
    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Safety")
                .font(.title3.weight(.semibold))

            LabelledField(label: "Transmit watchdog (seconds)", systemImage: "timer") {
                TextField(String(TransmitTimeout.default.wholeSeconds), text: $timeoutText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }

            // SF-1 is enforced in the library, not here, and it is not optional —
            // the field sets the number, it cannot switch the watchdog off. Worth
            // saying, so nobody goes looking for the switch.
            Text(
                "The longest a single transmission may last before Currawong unkeys for you, on "
                + "every channel. Between \(Int(TransmitTimeout.range.lowerBound)) and "
                + "\(Int(TransmitTimeout.range.upperBound)) seconds; it cannot be turned off. A "
                + "short value is the quickest way to prove the watchdog works.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The number is read when a link is built, so this is the honest
            // description of a change made mid-call rather than a hedge.
            Text("A change applies to the next connection, not the one that is up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - AllStarLink portal

    /// Pane 1: portal login → token.
    ///
    /// The paste field is present whether or not logging in is available, and it
    /// is not a fallback — it is how a token got here before this screen existed,
    /// and it is what still works if allstarlink.org replaces its login service
    /// (OQ-10). The button is what may be missing; see
    /// ``PortalLoginController/isAvailable``.
    private var portalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AllStarLink portal")
                .font(.title3.weight(.semibold))

            Text(
                "A Web Transceiver token lets you reach any node whose owner has switched Web "
                + "Transceiver on, with no arrangement of your own on that node. It stands for "
                + "your callsign — the node asks allstarlink.org whose token it is — so keep it "
                + "like a password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if portalLogin.isAvailable {
                loginControls
            } else {
                // Not the shipping wiring — `CompositionRoot` supplies a live
                // login. This is what a preview or a build with the login
                // deliberately withheld shows, and it says what still works
                // rather than promising anything.
                Label(
                    "Logging in is not available in this build. Paste a token below instead — "
                    + "`hamvoip-cli wt-token` prints one.",
                    systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabelledField(label: "Token", systemImage: "key") {
                // Not a SecureField, for the reason the connect form gives: the
                // mistakes people make with 12 characters of hex are visible
                // ones, and hiding them would make a truncated paste
                // undiagnosable. Stored in the Keychain either way.
                TextField("1b59df18107e", text: $tokenText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onSubmit { session.saveWebTransceiverToken(tokenText) }
            }

            HStack(spacing: 10) {
                Button("Save token") { session.saveWebTransceiverToken(tokenText) }
                    .buttonStyle(.bordered)
                    .disabled(tokenText == session.webTransceiverToken)

                if !session.webTransceiverToken.isEmpty {
                    Button("Forget token") {
                        tokenText = ""
                        session.saveWebTransceiverToken("")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            tokenStatus
        }
    }

    /// The callsign is not repeated here: it is the field at the top of this same
    /// screen, and a second copy would be two controls for one value on one page.
    @ViewBuilder
    private var loginControls: some View {
        LabelledField(label: "Portal password", systemImage: "lock") {
            SecureField("your allstarlink.org password", text: $portalLogin.password)
                .textFieldStyle(.roundedBorder)
                .onChange(of: portalLogin.password) { _ in portalLogin.clearFailure() }
        }

        HStack(spacing: 10) {
            Button {
                portalLogin.logIn(callsign: session.identity.callsign) { token in
                    session.saveWebTransceiverToken(token)
                }
            } label: {
                Label(
                    portalLogin.isWorking ? "Logging in…" : "Log in and fetch token",
                    systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(portalLogin.isWorking)

            if portalLogin.isWorking {
                ProgressView().controlSize(.small)
                Button("Stop") { portalLogin.cancel() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }

        Text(
            "This is your allstarlink.org portal password, not a node secret. It is used once to "
            + "fetch the token and then discarded — only the token is stored.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let failure = portalLogin.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tokenStatus: some View {
        if session.webTransceiverToken.isEmpty {
            Label("No token stored.", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !NodeSettings.isPlausibleWebTransceiverToken(session.webTransceiverToken) {
            // A warning, never a refusal: only the node decides whether a token
            // works, and the issuing endpoint is expected to change.
            Label(
                "Stored, but it does not look like a token — they are "
                    + "\(NodeSettings.webTransceiverTokenLength) lowercase hex characters.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label(
                portalLogin.didSucceed
                    ? "Fetched and stored in the Keychain."
                    : "Stored in the Keychain.",
                systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - EchoLink account

    /// Pane 2. Nominative use only (OQ-1b): what the account is for, and no more.
    private var echoLinkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EchoLink account")
                .font(.title3.weight(.semibold))

            LabelledField(label: "Account password", systemImage: "key") {
                SecureField("stored in the Keychain", text: $echoLinkPasswordText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.setEchoLinkAccountPassword(echoLinkPasswordText) }
            }

            Button("Save password") {
                session.setEchoLinkAccountPassword(echoLinkPasswordText)
            }
            .buttonStyle(.bordered)
            .disabled(echoLinkPasswordText == session.echoLinkAccountPassword)

            Text(
                "The password issued with your callsign by echolink.org — not a proxy password, "
                + "which is the section below. "
                + "Without it the directory server will not list stations or register you, and "
                + "nobody can call you. One password per callsign, so every EchoLink channel uses "
                + "this one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if session.echoLinkAccountPassword.isEmpty {
                Label("No password stored.", systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Stored in the Keychain.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - EchoLink proxy (APP-13)

    /// **APP-13.** The operator's own proxy, if they run one.
    ///
    /// Its own section rather than part of the account above, because they are
    /// two unrelated things that happen to share a network: one is who you are to
    /// echolink.org, the other is which machine your packets leave through. An
    /// operator with an account and no proxy is the ordinary case.
    ///
    /// **Empty is a working configuration and the copy has to say so**, or this
    /// reads as three more fields to fill in before EchoLink works — which is
    /// precisely the impression the connect form used to give and the reason this
    /// moved. Nothing here is required.
    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own proxy")
                .font(.title3.weight(.semibold))

            Text(
                "Optional. Leave this empty and a public proxy is found for you each time you "
                + "connect — that is the normal way to use the app. Fill it in if you run your "
                + "own proxy: public ones carry one user at a time and are meant for brief use, "
                + "so a private one is the answer for sustained operating.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabelledField(label: "Proxy host", systemImage: "network") {
                TextField("shackpi or proxy.example.org", text: $proxyHostText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
            }

            LabelledField(label: "Proxy port", systemImage: "number") {
                TextField(String(EchoLinkProxySettings.defaultPort), text: $proxyPortText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }

            LabelledField(label: "Proxy password", systemImage: "lock") {
                SecureField("stored in the Keychain", text: $proxyPasswordText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveProxy() }
            }

            HStack(spacing: 10) {
                Button("Save proxy") { saveProxy() }
                    .buttonStyle(.bordered)
                    .disabled(!proxyHasChanges)

                if session.echoLinkProxy.isConfigured {
                    // Clearing is a button rather than "empty the field and
                    // save", because emptying a field is not obviously an
                    // instruction, and going back to public proxies is a thing an
                    // operator does deliberately.
                    Button("Use public proxies") {
                        proxyHostText = ""
                        proxyPasswordText = ""
                        saveProxy()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if let proxyComplaint {
                Label(proxyComplaint, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.echoLinkProxy.isConfigured {
                Label(
                    "Every EchoLink channel goes through "
                        + "\(session.echoLinkProxy.host):\(session.echoLinkProxy.port). Its "
                        + "password is in the Keychain.",
                    systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(
                    "No private proxy — a public one is found when you connect.",
                    systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Whether the fields differ from what is stored, which is what makes the
    /// Save button live. The password counts: changing only that is a real edit.
    private var proxyHasChanges: Bool {
        proxyHostText != session.echoLinkProxy.host
            || proxyPortText != String(session.echoLinkProxy.port)
            || proxyPasswordText != session.echoLinkProxyPassword
    }

    /// Commits the three fields, and re-reads them from the session afterwards so
    /// the screen shows what was actually stored — trimmed, and with an empty
    /// port turned into 8100 — rather than what was typed.
    private func saveProxy() {
        let port =
            UInt16(proxyPortText.trimmingCharacters(in: .whitespaces))
            ?? EchoLinkProxySettings.defaultPort
        proxyComplaint = session.setEchoLinkProxy(
            EchoLinkProxySettings(host: proxyHostText, port: port),
            password: proxyPasswordText)
        proxyHostText = session.echoLinkProxy.host
        proxyPortText = String(session.echoLinkProxy.port)
        proxyPasswordText = session.echoLinkProxyPassword
    }

    // MARK: - PTT accessory

    /// Pane 3. The existing screen, embedded rather than reimplemented — it is a
    /// learn-mode state machine and a second copy of it would drift.
    private var accessorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PTT accessories")
                .font(.title3.weight(.semibold))

            AccessoryPane(
                accessory: accessory,
                remoteCommand: remoteCommand,
                isEmbedded: true)
        }
    }

    // MARK: - About

    /// **APP-26.** The version, and what the app ships that is not ours.
    ///
    /// Last, because it is the only section nothing is configured in — and on
    /// the settings screen rather than anywhere else because two of the four
    /// licences require a notice be shown to whoever runs the application, and
    /// this is the one screen an operator opens to read about the app rather
    /// than to talk to somebody. See ``AboutPane``.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(.title3.weight(.semibold))

            AboutPane()
        }
    }
}
