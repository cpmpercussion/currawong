// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The app-wide settings screen (APP-12): identity, the SF-1 watchdog, the
/// operator's own accounts and proxy. Nothing here is per channel, and after
/// first run it is the only place the callsign is edited.
///
/// "EchoLink" is nominative use only (OQ-1b): no logo, nothing implying the
/// app is an EchoLink product.
struct SettingsView: View {
    @ObservedObject var session: RadioSession
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
            }

            Text("Used on every channel.")
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
                "The longest one transmission may last before the app stops it for you, on "
                + "every channel. Between \(Int(TransmitTimeout.range.lowerBound)) and "
                + "\(Int(TransmitTimeout.range.upperBound)) seconds; it cannot be turned off.")
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
                "A token lets you reach any node that allows Web Transceiver. Keep it like a "
                + "password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if portalLogin.isAvailable {
                loginControls
            } else {
                // Only in previews or builds without a login.
                Label(
                    "Logging in is not available. Paste a token below instead.",
                    systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabelledField(label: "Token", systemImage: "key") {
                // Not a SecureField, so a truncated paste is visible.
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

        Text("Used once to fetch the token, and not kept.")
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
            Label("No token saved.", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !NodeSettings.isPlausibleWebTransceiverToken(session.webTransceiverToken) {
            // A warning, never a refusal: only the node decides whether a token
            // works, and the issuing endpoint is expected to change.
            Label(
                "Saved, but it does not look like a token. They are "
                    + "\(NodeSettings.webTransceiverTokenLength) characters, like 1b59df18107e.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label(
                portalLogin.didSucceed ? "Fetched and saved." : "Saved.",
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
                SecureField("", text: $echoLinkPasswordText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.setEchoLinkAccountPassword(echoLinkPasswordText) }
            }

            Button("Save password") {
                session.setEchoLinkAccountPassword(echoLinkPasswordText)
            }
            .buttonStyle(.bordered)
            .disabled(echoLinkPasswordText == session.echoLinkAccountPassword)

            Text("The password echolink.org issued for your callsign. Every EchoLink channel uses it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if session.echoLinkAccountPassword.isEmpty {
                Label("No password saved.", systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Saved.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabelledField(label: "Operator name", systemImage: "person") {
                TextField("optional", text: $session.identity.operatorName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabelledField(label: "Location", systemImage: "mappin.and.ellipse") {
                TextField("Canberra", text: $session.identity.location)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Text("Shown to the station you call and in the EchoLink directory. Both are optional.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - EchoLink proxy (APP-13)

    /// The operator's own proxy, if they run one (APP-13). Optional; empty is
    /// the ordinary case.
    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own proxy")
                .font(.title3.weight(.semibold))

            Text("Optional. Left empty, a public proxy is found each time you connect.")
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
                SecureField("", text: $proxyPasswordText)
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
                        + "\(session.echoLinkProxy.host):\(session.echoLinkProxy.port).",
                    systemImage: "checkmark.circle")
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
}
