// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A horizontal level meter, with the zones an operator actually needs.
///
/// ## Colour is the calibration
///
/// A bar with no marks on it answers "is there audio?" and not "is it the right
/// amount?", which is the question being asked. So the track is tinted into
/// zones and the fill takes the colour of the zone its peak is in:
///
/// | Zone | Peak | Meaning |
/// |---|---|---|
/// | Low | below −30 dBFS | too quiet — the far end will strain to hear you |
/// | Good | −30 to −6 dBFS | where speech should sit |
/// | Hot | −6 to −1 dBFS | loud, still clean, no headroom left for a raised voice |
/// | Clipping | above −1 dBFS | flat-topped, and it will sound like it |
///
/// Those boundaries are for *peak* readings of speech, which is what
/// ``AudioLevelMeter`` reports. Speech has a high crest factor — the peaks run
/// 10-15 dB above the average — so a peak sitting at −12 dBFS is a comfortable
/// average around −25, which is the right place to be for a codec that has no
/// headroom to spare.
///
/// ## Redrawing
///
/// `TimelineView` polls the meter twenty times a second rather than the meter
/// pushing changes through Combine. Fifty published updates a second, each
/// invalidating a view, is a lot of main-thread work to display a bar — and
/// this way a meter nobody is looking at costs nothing at all, because
/// `TimelineView` stops when it is off screen.
struct LevelMeterView: View {
    let label: String
    let meter: AudioLevelMeter

    /// Drawn dimmed when the path is not running, so an idle meter reads as
    /// "not listening" rather than "listening and hearing silence".
    var isActive: Bool = true

    /// Twenty a second: fast enough that the bar tracks speech, slow enough to
    /// be invisible in a battery graph.
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

                // Ticks last, over the fill, so the boundaries stay readable
                // when the bar is sitting on top of one.
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

        /// The boundaries, also drawn as ticks so the colours are not the only
        /// way to read the scale — which matters for anyone who cannot tell
        /// green from amber.
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

/// The two meters and the gain that answers the transmit one.
///
/// Shown together because they answer different halves of one question. A quiet
/// transmit meter is something the operator can fix; a quiet receive meter is
/// the other station's problem, and knowing which is which saves an evening
/// spent adjusting the wrong thing.
///
/// ## The gain belongs here, not on the connect form
///
/// It sat on the connect form to begin with, which was wrong twice over. That
/// form edits *one channel*, and the microphone gain is not a property of
/// anywhere you might connect to — it is a property of this phone, this voice
/// and this room, the same argument that moved the callsign out of
/// `NodeSettings`. And the form disables its fields while a link is up, so the
/// control was unreachable during the only activity that tells you what to set
/// it to.
///
/// Here, the loop closes: speak, watch the bar, drag, watch it move. The slider
/// stays live while transmitting, which is the whole point of it being next to
/// the thing it changes.
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
                // Fixed width, so the row does not shuffle sideways as the
                // number gains a digit while the operator is dragging it.
                .frame(width: 52, alignment: .trailing)
        }
    }
}
