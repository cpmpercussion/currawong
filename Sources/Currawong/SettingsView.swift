// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The app-wide settings screen (APP-12): identity, the SF-1 watchdog, the
/// operator's own accounts and proxy, and the PTT accessory. Nothing here is
/// per channel. The connect form edits the same callsign.
///
/// "EchoLink" is nominative use only (OQ-1b): no logo, nothing implying the
/// app is an EchoLink product.
struct SettingsView: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var accessory: BLEPTTController
    @ObservedObject var remoteCommand: RemoteCommandPTTController
    @ObservedObject var portalLogin: PortalLoginController

    /// The token, as typed or pasted. Committed on submit or loss of focus, so
    /// a half-pasted token is never stored.
    @State private var tokenText = ""

    /// Likewise the EchoLink password.
    @State private var echoLinkPasswordText = ""

    /// The private proxy, as typed. Host and password are committed together
    /// by ``RadioSession/setEchoLinkProxy(_:password:)``.
    @State private var proxyHostText = ""
    @State private var proxyPortText = ""
    @State private var proxyPasswordText = ""

    /// What went wrong saving the proxy, shown beside the fields.
    @State private var proxyComplaint: String?

    /// The watchdog timeout as typed. Committed on every keystroke that parses:
    /// a safety limit must not wait for a button press.
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
            // Unparseable is left alone, not reset, so clearing the field to
            // retype it does not flick back to the default mid-edit.
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
                    // BU-9: `stashDraft()`, not `saveDraft()` — this screen must
                    // not overwrite whichever channel happens to be selected.
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

    /// **SF-1.** The transmit watchdog, app-wide so "how long will it let me
    /// talk?" never depends on the channel. See ``TransmitTimeout``.
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

            // SF-1 is enforced in the library, not here, and is not optional:
            // this field sets the number, it cannot switch the watchdog off.
            Text(
                "The longest a single transmission may last before Currawong unkeys for you, on "
                + "every channel. Between \(Int(TransmitTimeout.range.lowerBound)) and "
                + "\(Int(TransmitTimeout.range.upperBound)) seconds; it cannot be turned off. A "
                + "short value is the quickest way to prove the watchdog works.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The number is read when a link is built.
            Text("A change applies to the next connection, not the one that is up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - AllStarLink portal

    /// Portal login → token. The paste field is always present: it still works
    /// if allstarlink.org replaces its login service (OQ-10).
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
                // Only in previews or builds without a login.
                Label(
                    "Logging in is not available in this build. Paste a token below instead — "
                    + "`hamvoip-cli wt-token` prints one.",
                    systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabelledField(label: "Token", systemImage: "key") {
                // Not a SecureField, so a truncated paste is visible. Stored in
                // the Keychain either way.
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

    /// The callsign is not repeated here; it is at the top of the screen.
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

    /// The operator's own proxy, if they run one (APP-13). Optional; empty is
    /// the ordinary case.
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
                    // Its own button, not "empty the field and save": emptying
                    // a field is not obviously an instruction.
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

    /// Whether the fields, password included, differ from what is stored.
    private var proxyHasChanges: Bool {
        proxyHostText != session.echoLinkProxy.host
            || proxyPortText != String(session.echoLinkProxy.port)
            || proxyPasswordText != session.echoLinkProxyPassword
    }

    /// Commits the fields, then re-reads what was actually stored.
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

    /// The accessory screen, embedded rather than reimplemented.
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
}
