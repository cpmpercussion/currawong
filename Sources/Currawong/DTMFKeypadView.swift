// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **FR-1.5.** The app's DTMF alphabet, and how to say it out loud.
///
/// Not imported from `IAX2Kit`, which has the authoritative §8.2 list: this app
/// is not allowed to know which protocol is underneath it, and the keypad's
/// contents are a UI decision anyway. The library validates what it is given and
/// will reject anything outside its own alphabet, which is the check that
/// matters.
enum DTMF {
    /// The twelve keys of a telephone keypad, in reading order.
    ///
    /// `A`–`D` are valid DTMF and are deliberately absent: nothing in AllStar
    /// asks for them, and four extra keys would cost the layout more than they
    /// are worth. ``RadioSession/sendDTMF(_:)`` would send one if a later screen
    /// offered it.
    static let keypadDigits: [Character] = [
        "1", "2", "3",
        "4", "5", "6",
        "7", "8", "9",
        "*", "0", "#",
    ]

    /// VoiceOver reads `*` and `#` as punctuation, or not at all. A keypad whose
    /// two most important keys go unannounced is not a keypad a blind operator
    /// can use, and `*` is the first character of nearly every node command.
    static func spoken(_ digit: Character) -> String {
        switch digit {
        case "*": return "star"
        case "#": return "hash"
        default: return String(digit)
        }
    }
}

/// **FR-1.5.** A DTMF keypad, and a log of what went out and what came back.
///
/// This is how an AllStar node is actually operated: node commands are digit
/// strings (`*3` plus a node number to connect, `*1` plus one to disconnect,
/// status and identification commands), and the node answers with its own digits
/// and usually a spoken confirmation. Without a keypad the app can hold a
/// conversation and do nothing else.
///
/// ## Pressing a key cannot put you on air
///
/// DTMF is signalling: it travels as its own reliable frame and does not need
/// PTT, so ``RadioSession/sendDTMF(_:)`` deliberately does not key the
/// transmitter. The UI says so, because a grid of buttons next to a PTT button
/// invites the assumption that they are the same kind of thing.
///
/// ## Why both logs
///
/// "Did that digit go out?" and "did the node hear it?" are different questions
/// with different fixes — the first is the app or the link, the second is the
/// node's configuration or its DTMF decoder. Showing the two streams separately
/// is what makes them separable at all, and it is the reason to keep a log
/// rather than flash the last key pressed.
struct DTMFKeypadView: View {
    let isEnabled: Bool
    let sent: String
    let received: String
    let send: (Character) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DTMF")
                    .font(.headline)
                Spacer()
                Text("Does not transmit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(DTMF.keypadDigits, id: \.self) { digit in
                    Button {
                        send(digit)
                    } label: {
                        Text(String(digit))
                            .font(.title3.weight(.medium))
                            .monospaced()
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isEnabled)
                    .accessibilityLabel(DTMF.spoken(digit))
                }
            }

            log(label: "Sent", digits: sent, systemImage: "arrow.up.circle")
            log(label: "Heard", digits: received, systemImage: "arrow.down.circle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func log(label: String, digits: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Truncating from the head keeps the newest digits visible, which
            // are the ones being watched.
            Text(digits.isEmpty ? "—" : digits)
                .font(.caption.weight(.medium))
                .monospaced()
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            digits.isEmpty
                ? "\(label): nothing"
                : "\(label): \(digits.map(DTMF.spoken).joined(separator: ", "))")
    }
}

#Preview {
    DTMFKeypadView(isEnabled: true, sent: "*3555", received: "1", send: { _ in })
        .padding()
}
