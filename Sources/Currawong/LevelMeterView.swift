// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A horizontal level meter, tinted into zones so it answers "is this the
/// right amount?" and not only "is there audio?". The fill takes the colour of
/// its peak's zone:
///
/// | Zone | Peak | Meaning |
/// |---|---|---|
/// | Low | below −30 dBFS | too quiet — the far end will strain to hear you |
/// | Good | −30 to −6 dBFS | where speech should sit |
/// | Hot | −6 to −1 dBFS | loud, still clean, no headroom left for a raised voice |
/// | Clipping | above −1 dBFS | flat-topped, and it will sound like it |
///
/// The boundaries are for peak readings of speech, whose peaks run 10–15 dB
/// above its average.
///
/// `TimelineView` polls the meter rather than the meter publishing fifty
/// updates a second, and stops when off screen.
struct LevelMeterView: View {
    let label: String
    let meter: AudioLevelMeter

    /// Dimmed when the path is not running, so idle does not read as silence.
    var isActive: Bool = true

    /// Twenty a second: tracks speech, costs nothing noticeable.
    private static let refresh: TimeInterval = 1.0 / 20.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refresh)) { _ in
            let decibels = meter.decibels
            let fraction = AudioLevelMeter.fraction(ofDecibels: decibels)
            let zone = Zone(decibels: decibels)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                    Text(verbatim: reading(decibels))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isActive ? zone.colour : .secondary)
                }

                bar(fraction: fraction, zone: zone)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(
                isActive ? "\(zone.spokenName), \(reading(decibels))" : "not running")
        }
    }

    private func reading(_ decibels: Double) -> String {
        guard isActive, decibels > AudioLevelMeter.floorDB else { return "—" }
        return "\(Int(decibels.rounded())) dB"
    }

    private func bar(fraction: Double, zone: Zone) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                Capsule()
                    .fill(isActive ? zone.colour : Color.secondary)
                    .frame(width: max(0, width * fraction))
                    .opacity(isActive ? 1 : 0.4)

                // Ticks last, so they stay readable over the fill.
                ForEach(Zone.tickDecibels, id: \.self) { tick in
                    let position = AudioLevelMeter.fraction(ofDecibels: tick) * width
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: position)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    /// Where the peak is sitting, and what to call it.
    enum Zone {
        case silent
        case low
        case good
        case hot
        case clipping

        /// Tick marks, so colour is not the only way to read the scale: the
        /// low and hot boundaries, and −12 dBFS between them.
        static let tickDecibels: [Double] = [-30, -12, -6]

        init(decibels: Double) {
            switch decibels {
            case ..<AudioLevelMeter.floorDB: self = .silent
            case ..<(-30): self = .low
            case ..<(-6): self = .good
            case ..<(-1): self = .hot
            default: self = .clipping
            }
        }

        var colour: Color {
            switch self {
            case .silent, .low: return .secondary
            case .good: return .green
            case .hot: return .orange
            case .clipping: return .red
            }
        }

        var spokenName: String {
            switch self {
            case .silent: return "silent"
            case .low: return "too quiet"
            case .good: return "good level"
            case .hot: return "hot"
            case .clipping: return "clipping"
            }
        }
    }
}

/// The transmit and receive meters, each with its gain slider under it.
/// Together, so the operator can tell a problem they can fix from the other
/// station's.
///
/// Gain lives here rather than on a channel: it belongs to this phone, voice
/// and room, and it is set by watching the meter, live, mid-over.
struct LevelMetersView: View {
    @ObservedObject var session: RadioSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelMeterView(
                label: "Transmit",
                meter: session.transmitMeter,
                isActive: session.isTransmitting)

            gain

            LevelMeterView(
                label: "Receive",
                meter: session.receiveMeter,
                isActive: session.connection.isConnected)

            receiveGain
        }
    }

    private var gain: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { session.transmitGain.decibels },
                    set: { session.transmitGain = TransmitGain(decibels: $0) }),
                in: TransmitGain.range,
                step: 1)
                .accessibilityLabel("Microphone gain")
                .accessibilityValue("plus \(Int(session.transmitGain.decibels.rounded())) decibels")

            Text(verbatim: "+\(Int(session.transmitGain.decibels.rounded())) dB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                // Fixed width, so the row does not shift as digits change.
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// The receive gain, under its meter, which reads after the gain. Here
    /// rather than in Settings: it can only be set while someone is talking.
    private var receiveGain: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { session.receiveGain.decibels },
                    set: { session.receiveGain = ReceiveGain(decibels: $0) }),
                in: ReceiveGain.range,
                step: 1)
                .accessibilityLabel("Receive gain")
                .accessibilityValue("plus \(Int(session.receiveGain.decibels.rounded())) decibels")

            Text(verbatim: "+\(Int(session.receiveGain.decibels.rounded())) dB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
