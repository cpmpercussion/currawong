// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Placeholder root view.
///
/// APP-1 is a scaffold: this exists to prove the app launches, that the
/// composition root builds a client, and that the app can read transmit state
/// through `NetworkClient` without knowing which network is underneath.
/// **APP-2 replaces it** with the connect screen and the momentary PTT button
/// (PT-1).
struct RootView: View {
    let root: CompositionRoot

    private var status: TransmitStatusPresentation {
        TransmitStatusPresentation(state: root.transmitState)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Currawong")
                .font(.largeTitle.weight(.semibold))

            Text("AllStarLink and M17 for Apple platforms")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .frame(maxWidth: 200)

            VStack(spacing: 4) {
                Text(status.label)
                    .font(.headline)
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Scaffold only — connect and PTT arrive in APP-2.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RootView(root: CompositionRoot())
}
