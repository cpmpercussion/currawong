// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The connect screen: where the node lives, who we are, and the one control
/// that opens and closes the connection.
///
/// Deliberately one node, not a list. Full settings CRUD — several stored
/// nodes, editing, deleting, reordering — is APP-4; this is what a first
/// connection needs and no more. The one thing that would have been painful to
/// change later, and so is not deferred, is *where the secret goes*: it is in
/// the Keychain from the first commit, so there is never a migration out of
/// `UserDefaults` to write.
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

    @State private var portText = ""

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
        .onAppear { portText = String(settings.port) }
        .onChange(of: portText) { newValue in
            if let port = NodeSettings.parsePort(newValue) {
                settings.port = port
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Node")
                .font(.headline)

            LabelledField(label: "Host", systemImage: "network") {
                TextField("node.example.org", text: $settings.host)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
            }

            LabelledField(label: "Port", systemImage: "number") {
                TextField("4569", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }

            LabelledField(label: "Node number", systemImage: "antenna.radiowaves.left.and.right") {
                TextField("55553", text: $settings.node)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
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

            Text("The secret is kept in the Keychain, not in the app's settings file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
