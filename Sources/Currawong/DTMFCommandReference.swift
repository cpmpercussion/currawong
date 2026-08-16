// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **FR-1.5.** The AllStarLink node commands, as a sheet you can read while
/// connected.
///
/// The keypad sends digits; it has never said what any of them *mean*. Node
/// control is a small command language — `*3` plus a node number links you to
/// that node, `*1` unlinks — and it is exactly the kind of thing nobody
/// remembers between sessions. Everything here is reference text: no view in
/// this file sends anything.
///
/// ## Where these came from, and why they may still be wrong for your node
///
/// Transcribed from AllStarLink's own operator manual (the ASL3 "Standard
/// Commands" page), which documents the *suggested defaults*. The authority for
/// any particular node is that node's `[functions]` stanza in
/// `/etc/asterisk/rpt.conf`, which the owner is free to change. So this table is
/// a memory aid, not a contract, and the sheet says as much where the operator
/// will read it.
///
/// Clean-room note (LP-1, LP-2): operator documentation only. `app_rpt`'s
/// sources are off limits and were not consulted — which is also why the
/// optional list stops where the manual stops rather than being exhaustive.
enum DTMFCommandReference {

    /// Whether every conforming node has the command, or only some do.
    ///
    /// Worth showing, because it is the first thing to check when a code does
    /// nothing: a mandatory command that fails is a link or decoder problem,
    /// an optional one that fails may simply not be configured.
    enum Availability {
        case mandatory
        case optional
    }

    struct Command: Identifiable, Equatable {
        /// The literal digits, function start character included.
        let code: String
        /// The argument that follows the code, if any — rendered distinctly so
        /// `*3` and `<node>` do not read as one nine-character string.
        let argument: String?
        let summary: String
        let availability: Availability

        var id: String { code }

        /// `*3` is read by VoiceOver as punctuation and a number, or skipped.
        var spoken: String {
            let digits = code.map(DTMF.spoken).joined(separator: " ")
            guard let argument else { return digits }
            return "\(digits), followed by \(argument)"
        }
    }

    /// Suggested defaults, in the manual's own two groups.
    static let commands: [Command] = [
        // Linking — the reason the keypad exists.
        Command(
            code: "*3", argument: "node", summary: "Connect — transceive (two-way)",
            availability: .mandatory),
        Command(
            code: "*2", argument: "node", summary: "Connect — monitor only (you hear it, it does not hear you)",
            availability: .mandatory),
        Command(
            code: "*1", argument: "node", summary: "Disconnect",
            availability: .mandatory),
        Command(
            code: "*4", argument: "node", summary: "Enter command mode on a remote node",
            availability: .mandatory),
        Command(
            code: "*70", argument: nil, summary: "Say this node's connections",
            availability: .mandatory),
        Command(
            code: "*99", argument: nil, summary: "DTMF phone key — assert PTT from the phone portal",
            availability: .mandatory),

        Command(
            code: "*75", argument: "node", summary: "Connect — local monitor only",
            availability: .optional),
        Command(
            code: "*71", argument: nil, summary: "Disconnect all links",
            availability: .optional),
        Command(
            code: "*74", argument: nil, summary: "Reconnect all links",
            availability: .optional),
        Command(
            code: "*72", argument: nil, summary: "Say the last active node, system-wide",
            availability: .optional),
        Command(
            code: "*73", argument: nil, summary: "Say connections, system-wide",
            availability: .optional),
        Command(
            code: "*80", argument: nil, summary: "Force system ID",
            availability: .optional),
        Command(
            code: "*81", argument: nil, summary: "Say the system time",
            availability: .optional),
        Command(
            code: "*980", argument: nil, summary: "Say the node software version",
            availability: .optional),
    ]

    static func commands(_ availability: Availability) -> [Command] {
        commands.filter { $0.availability == availability }
    }

    /// Two things that bite an operator who has only ever seen the code list.
    static let notes: [String] = [
        "Send the digits without pausing. The node collects them after the \u{2A} and gives up if you stall between keys, so a half-typed node number is discarded rather than queued.",
        "Node 0 is shorthand for the node you last operated on \u{2014} \u{2A}10 disconnects it.",
    ]
}

/// The sheet itself. Presented from ``DTMFKeypadView``; holds no state and
/// sends nothing.
struct DTMFCommandReferenceView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DTMFCommandReference.commands(.mandatory)) { row($0) }
                } header: {
                    Text("Standard")
                } footer: {
                    Text("Every conforming node should have these.")
                }

                Section {
                    ForEach(DTMFCommandReference.commands(.optional)) { row($0) }
                } header: {
                    Text("Optional")
                } footer: {
                    Text("Common, but the node owner may not have configured them. A code that does nothing is more likely missing than broken.")
                }

                Section {
                    ForEach(DTMFCommandReference.notes, id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Suggested defaults from AllStarLink's manual. Your node's own commands live in its rpt.conf and may differ.")
                }
            }
            .navigationTitle("Node Commands")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ command: DTMFCommandReference.Command) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(command.code)
                    .font(.body.weight(.semibold))
                    .monospaced()
                if let argument = command.argument {
                    Text("<\(argument)>")
                        .font(.body)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
            Text(command.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(command.spoken). \(command.summary)")
    }
}

#Preview {
    DTMFCommandReferenceView()
}
