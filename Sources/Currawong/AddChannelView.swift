// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// `Add channel`: pick the network, then pick from that network's directory or
/// fill in its fields (APP-42). Choosing a station or a module adds the
/// channel; nothing reaches the list before that, so backing out leaves no
/// row behind.
///
/// The fields are ``ConnectFormView``'s, bound to a channel this view holds
/// until `Add`, so there is still one place a protocol's fields are edited.
/// EchoLink's account password is asked for here, on the way to the station
/// list, because the list is the first thing that needs it.
struct AddChannelView: View {
    @ObservedObject var session: RadioSession
    @ObservedObject var browser: StationBrowser
    @ObservedObject var reflectorBrowser: ReflectorBrowser
    @ObservedObject var proxyPicker: ProxyPicker
    @ObservedObject var nodeLocator: NodeLocator

    /// Ends the flow; `true` when a channel was added or chosen.
    let onFinish: (Bool) -> Void

    @State private var step: Step = .network

    /// The channel being typed in ``Step/fields(_:)``; in no list until `Add`.
    @State private var pending = NodeSettings()
    @State private var pendingSecret = ""

    /// The EchoLink account password as typed, committed by ``saveAccount()``.
    @State private var accountPassword = ""

    enum Step: Equatable {
        case network
        /// The network's directory. Only for a mode that has one.
        case directory(RadioMode)
        /// The connect form, for a network with no directory or an address
        /// its directory does not list.
        case fields(RadioMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch step {
            case .network:
                networkStep
            case .directory(let mode):
                directoryStep(for: mode)
            case .fields:
                fieldsStep
            }
        }
        .padding(20)
        #if os(macOS)
            // A macOS sheet takes its content's size, and a list has none.
            .frame(width: 520, height: 620)
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            if step != .network {
                Button {
                    step = .network
                } label: {
                    Label("Networks", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }

            Text("Add channel")
                .font(.headline)

            Spacer()

            Button("Cancel") { onFinish(false) }
                .accessibilityIdentifier("addChannel.cancel")
        }
    }

    // MARK: - Network

    private var networkStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which network is it on?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(RadioMode.allCases) { mode in
                Button {
                    start(mode)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.displayName)
                                .font(.body.weight(.medium))
                            Text(mode.addChannelSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addChannel.network.\(mode.rawValue)")
            }

            Spacer(minLength: 0)
        }
    }

    private func start(_ mode: RadioMode) {
        pending = .blank(for: mode)
        pendingSecret = ""
        // A lookup result from an earlier visit would describe another node.
        nodeLocator.clear()
        step = mode.hasDirectory ? .directory(mode) : .fields(mode)
    }

    // MARK: - Directory

    @ViewBuilder
    private func directoryStep(for mode: RadioMode) -> some View {
        switch mode {
        case .m17:
            ReflectorBrowserView(
                session: session, browser: reflectorBrowser,
                onChosen: { onFinish(true) })

            Button("Type an address instead") { step = .fields(mode) }
                .buttonStyle(.borderless)
                .font(.footnote)
                .accessibilityIdentifier("addChannel.typeInstead")

        case .echoLink:
            if session.echoLinkAccountPassword.isEmpty {
                accountStep
            } else {
                StationBrowserView(
                    session: session, browser: browser, proxyPicker: proxyPicker,
                    onChosen: { onFinish(true) })
            }

        case .allStarLink:
            // No directory; `start(_:)` never sends this mode here.
            EmptyView()
        }
    }

    /// The EchoLink account password, asked for on the way to the list that
    /// needs it. Stored by the session, where Settings also edits it.
    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your EchoLink password")
                .font(.headline)

            LabelledField(label: "Account password", systemImage: "key") {
                SecureField("", text: $accountPassword)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("addChannel.echoLinkPassword")
                    .onSubmit(saveAccount)
            }

            Text(
                "The password echolink.org issued for \(session.identity.callsign). Every "
                + "EchoLink channel uses it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Continue", action: saveAccount)
                .buttonStyle(.borderedProminent)
                .disabled(accountPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer(minLength: 0)
        }
    }

    private func saveAccount() {
        guard !accountPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        // Publishes the password, which swaps this step for the station list.
        session.setEchoLinkAccountPassword(accountPassword)
        accountPassword = ""
    }

    // MARK: - Fields

    private var fieldsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                ConnectFormView(
                    settings: $pending,
                    secret: $pendingSecret,
                    isEchoLinkAccountConfigured: !session.echoLinkAccountPassword.isEmpty,
                    webTransceiverToken: $session.webTransceiverToken,
                    isEditable: true,
                    proxyPicker: proxyPicker,
                    privateProxy: session.echoLinkProxy,
                    nodeLocator: nodeLocator)
            }

            Button("Add") {
                if session.addChannel(pending, secret: pendingSecret) != nil {
                    onFinish(true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // A channel that goes nowhere is a blank row, not a channel.
            .disabled(!pending.hasDestination)
            .accessibilityIdentifier("addChannel.add")
        }
    }
}

private extension RadioMode {
    /// What adding a channel on this network involves, under its name.
    var addChannelSummary: String {
        switch self {
        case .allStarLink: return "A node, by its number"
        case .m17: return "A reflector, from the published list"
        case .echoLink: return "A station, from the EchoLink directory"
        }
    }
}
