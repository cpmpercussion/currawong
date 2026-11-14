// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// First run: asks for the operator's callsign, which every network needs,
/// before anything else is on screen. Shown while
/// ``RadioSession/needsCallsign`` holds; Settings is where it is changed later.
struct WelcomeView: View {
    /// Receives the callsign as typed; the session normalises it.
    let onContinue: (String) -> Void

    @State private var callsign = ""

    private var trimmed: String {
        callsign.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What is your callsign?")
                .font(.title2.weight(.semibold))

            Text("It identifies you on every network. You can change it later in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("VK1XYZ", text: $callsign)
                .accessibilityLabel("Callsign")
                .accessibilityIdentifier("welcome.callsign")
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .onSubmit(submit)

            Button("Continue", action: submit)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(trimmed.isEmpty)
                .accessibilityIdentifier("welcome.continue")
        }
        .padding(20)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onContinue(trimmed)
    }
}

#Preview {
    WelcomeView(onContinue: { _ in })
}
