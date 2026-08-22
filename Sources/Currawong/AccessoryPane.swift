// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// **PT-2, PT-3, PT-4 and BLE-3's indicator.** Where the operator sets up a
/// physical PTT.
///
/// The state machine is all in ``BLEPTTController`` and ``PTTLearner``; this
/// renders it and calls its methods. Nothing here decides anything, which is
/// why there is no view model between them: the controller *is* the view model,
/// and duplicating its decisions in a second place is how the screen and the
/// radio would come to disagree about whether the button is held.
///
/// ## No device list
///
/// PT-3 forbids a supported-accessory whitelist, so this screen shows whatever
/// is advertising and lets the operator pick. The consequence is that the list
/// is full of somebody's headphones, a television and three unnamed beacons,
/// and the operator has to know which line is theirs. That is the deliberate
/// trade: a whitelist would be tidier and would stop working the moment somebody
/// bought a fob nobody had heard of.
///
/// ## A section of the settings screen, not a sheet
///
/// This is the screen's content with no navigation chrome of its own, and
/// nothing wraps it any more. There used to be an `AccessoryView` around it — a
/// `NavigationStack`, a title and a Done button — for the row at the bottom of
/// the session pane to present on iPhone. APP-12 moved the configuration to the
/// settings screen, which embeds this directly, and APP-18 removed the row; the
/// wrapper had no caller left. Both layouts now reach it the same way.
struct AccessoryPane: View {
    @ObservedObject var accessory: BLEPTTController
    @ObservedObject var remoteCommand: RemoteCommandPTTController

    /// Whether this is a section of a larger screen (APP-12's settings screen)
    /// rather than the whole of one.
    ///
    /// It drops this view's own `ScrollView` and padding. Two nested scroll views
    /// is not a layout nicety: the inner one takes the drag, so the outer screen
    /// cannot be scrolled by starting the gesture anywhere over this content —
    /// which, on a settings screen, is most of it.
    var isEmbedded = false

    var body: some View {
        content
            // Scanning holds the radio awake and is foreground-only by design, so
            // it stops when this screen goes away — whether that is the sheet
            // being dismissed mid-scan, or the pane being switched away from,
            // which are the same thing as far as the scan is concerned.
            .onDisappear { accessory.stopScanning() }
    }

    @ViewBuilder
    private var content: some View {
        if isEmbedded {
            sections
        } else {
            ScrollView {
                sections
                    .padding(20)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 22) {
            bluetoothSection
            Divider()
            remoteCommandSection
        }
    }

    // MARK: - Bluetooth (PT-2, PT-3)

    @ViewBuilder
    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Bluetooth button",
                detail:
                    "Any BLE accessory that reports its button over a notifying characteristic. "
                    + "Currawong learns what yours sends; there is no supported-device list.")

            linkStateRow

            if let problem = accessory.availability.problem, accessory.mapping == nil {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let learner = accessory.learner {
                LearnModeView(learner: learner, accessory: accessory)
            } else if let mapping = accessory.mapping {
                learnedMappingView(mapping)
            } else {
                scanningView
            }
        }
    }

    private var linkStateRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(linkColour)
                .frame(width: 10, height: 10)
            Text(accessory.linkState.label)
                .font(.subheadline.weight(.medium))
            Spacer()
            if accessory.isAccessoryKeyed {
                Text("BUTTON DOWN")
                    .font(.caption2.weight(.black))
                    .monospaced()
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    private var linkColour: Color {
        switch accessory.linkState {
        case .connected: return .green
        case .scanning, .connecting, .reconnecting: return .orange
        case .failed, .unavailable: return .red
        case .noAccessory: return .secondary
        }
    }

    /// The state where an accessory is learned and in use.
    private func learnedMappingView(_ mapping: BLEPTTMapping) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Accessory", value: mapping.accessoryDisplayName)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 4) {
                signalLine("Press", mapping.press)
                signalLine("Release", mapping.release)
                if mapping.usesOneCharacteristic {
                    Text("Both on one characteristic.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let signal = accessory.lastSignal {
                Text("Last heard: \(signal.payloadDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Last signal heard from the accessory")
            }

            if accessory.linkState.isConnected, !accessory.isButtonVerified {
                // The operator's way out of BU-14's dead end. Connected and
                // silent is exactly the state that used to read as "ready" and
                // leave them with no button and nothing to press.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connected, but nothing has been heard from the button yet.")
                        .font(.caption)
                    Text(
                        "Press it to check. If it does nothing, rebuild the link — "
                            + "and the on-screen button always works.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Reconnect") { accessory.reconnectAccessory() }
                        .buttonStyle(.borderedProminent)
                }
                .accessibilityElement(children: .combine)
            }

            if case .failed = accessory.linkState {
                Button("Try again") { accessory.retryConnection() }
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                Button("Teach it again") { accessory.relearnCurrentAccessory() }
                    .buttonStyle(.bordered)
                Button("Forget", role: .destructive) { accessory.forgetAccessory() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func signalLine(_ label: String, _ signal: BLESignal) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(signal.payloadDescription)
                .font(.caption)
                .monospaced()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The state where nothing is learned yet: scan, then pick.
    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if accessory.linkState == .scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for accessories…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { accessory.stopScanning() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Button {
                    accessory.startScanning()
                } label: {
                    Label("Find accessories", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(accessory.availability == .unsupported)
            }

            ForEach(accessory.discovered) { found in
                Button {
                    accessory.beginLearning(with: found)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(found.displayName)
                                .font(.subheadline)
                            if let rssi = found.rssi {
                                Text("Signal \(rssi) dBm")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }

            if accessory.linkState == .scanning, accessory.discovered.isEmpty {
                Text("Nothing yet. Some accessories only advertise for a few seconds after being switched on or paired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Remote command (PT-4)

    private var remoteCommandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Headset or remote button",
                detail: PTTSource.remoteCommand.holdDescription)

            Toggle(
                "Use the headset button",
                isOn: Binding(
                    get: { remoteCommand.isEnabled },
                    set: { remoteCommand.setEnabled($0) }))

            // Both of these are real, both bite, and neither is discoverable by
            // experiment in under an hour. They belong on the screen that offers
            // the feature.
            Text(
                "This latches: press once to transmit, press again to stop. It also takes over "
                + "the system's play and pause controls while it is on, and it only works while "
                + "Currawong is the app the system considers to be playing — if another app takes "
                + "over playback, the button follows it and stops keying the radio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// **BLE-2 / PT-3.** Learn mode: press, release, press again, release again.
///
/// One view per ``PTTLearner/Step``, and the "nothing else arrived" escape hatch
/// on every step that can be stuck. That button is not a convenience — it is the
/// only way out for an accessory whose press and release send the same bytes,
/// which cannot be detected by waiting.
private struct LearnModeView: View {
    let learner: PTTLearner
    @ObservedObject var accessory: BLEPTTController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch learner.step {
            case .awaitingPress:
                instruction("Press and hold the button on your accessory.", systemImage: "hand.point.up.left")
                stuckButton
            case .awaitingRelease:
                instruction("Now let go.", systemImage: "hand.raised")
                stuckButton
            case .confirmingPress:
                instruction("Once more: press and hold.", systemImage: "arrow.clockwise")
                stuckButton
            case .confirmingRelease:
                instruction("And let go.", systemImage: "arrow.clockwise")
                stuckButton
            case .learned(let mapping):
                learned(mapping)
            case .unlearnable(let problem):
                unlearnable(problem)
            }

            if !learner.observed.isEmpty {
                observedList
            }

            if !learner.isFinished {
                Text(
                    accessory.subscribedPaths.isEmpty
                        ? "Waiting for the accessory to connect…"
                        : "Listening to \(accessory.subscribedPaths.count) characteristic(s).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Cancel", role: .cancel) { accessory.cancelLearning() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.10)))
    }

    private func instruction(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
    }

    /// The only way out of a press and release that look identical, so it is
    /// offered on every unfinished step rather than buried.
    private var stuckButton: some View {
        Button("I did that and nothing happened") { accessory.nothingElseArrived() }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func learned(_ mapping: BLEPTTMapping) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Learned", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text("Press sends \(mapping.press.payloadDescription); release sends \(mapping.release.payloadDescription).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Use this accessory") { accessory.adoptLearnedMapping() }
                    .buttonStyle(.borderedProminent)
                Button("Start again") { accessory.restartLearning() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func unlearnable(_ problem: PTTLearner.Problem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cannot use this accessory", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(problem.message)
                .font(.caption)
            HStack(spacing: 12) {
                Button("Try again") { accessory.restartLearning() }
                    .buttonStyle(.bordered)
                Button("Cancel", role: .cancel) { accessory.cancelLearning() }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Every distinct notification seen, with a count. An operator whose
    /// accessory is chattering can see that it is, instead of looking at a
    /// screen that says nothing is happening.
    private var observedList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Heard so far")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(learner.observed) { observation in
                Text("\(observation.signal.payloadDescription)  ×\(observation.count)")
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    AccessoryPane(
        accessory: BLEPTTController(makeCentral: { PreviewBLECentral() }),
        remoteCommand: RemoteCommandPTTController(makeSource: { PreviewRemoteSource() }))
}

/// Previews must not construct a `CBCentralManager` — it would ask Xcode's
/// preview host for Bluetooth permission.
private final class PreviewBLECentral: BLECentral, @unchecked Sendable {
    let events: AsyncStream<BLECentralEvent> = AsyncStream { $0.finish() }
    let availability: BLECentralAvailability = .poweredOn
    func startScan() {}
    func stopScan() {}
    func connect(_ id: UUID) {}
    func disconnect(_ id: UUID) {}
    func subscribeToAllNotifyingCharacteristics(_ id: UUID) {}
    func probeForLiveness(_ id: UUID) {}
}

private final class PreviewRemoteSource: RemoteCommandSource, @unchecked Sendable {
    let commands: AsyncStream<RemoteCommandEvent> = AsyncStream { $0.finish() }
    func enable() {}
    func disable() {}
}
