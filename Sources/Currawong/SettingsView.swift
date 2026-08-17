// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **APP-12.** The app-level settings screen: who you are, the two accounts that
/// are yours rather than a channel's, and the PTT accessory.
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
/// * **The PTT accessory** was reachable only from a row on the session pane,
///   which meant accessory setup was something found mid-session — a poor moment
///   to be pairing a fob.
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

    /// Whether to draw the local "on air" strip in the accessory pane. See
    /// ``AccessoryPane/isTransmitting``.
    let isTransmitting: Bool

    /// The token, as typed or pasted. Committed to the Keychain on `onSubmit`
    /// and when the field loses focus rather than on every keystroke, so a
    /// half-pasted token is never what gets stored.
    @State private var tokenText = ""

    /// Likewise the EchoLink password.
    @State private var echoLinkPasswordText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                operatorSection
                Divider()
                portalSection
                Divider()
                echoLinkSection
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
                    .onSubmit { session.saveDraft() }
            }

            Text(
                "Used on every channel and in every mode, and it is what both accounts below are "
                + "filed under.")
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
                Label(
                    "Logging in from the app arrives with the next library release. Until then, "
                    + "paste a token below — `hamvoip-cli wt-token` prints one.",
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
                "The password issued with your callsign by echolink.org — not a proxy password. "
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
                isTransmitting: isTransmitting,
                isEmbedded: true)
        }
    }
}
