// SPDX-License-Identifier: Apache-2.0

#if canImport(Codec2)

import Foundation
import M17Kit
import RadioCore
import XCTest

@testable import Currawong

/// The claim this whole arrangement exists to support: **the app's own codec
/// can drive the library's M17 stream path.**
///
/// `Codec2CodecTests` proves the codec encodes and decodes. That is necessary
/// and not sufficient — the reason the app carries a codec at all is that
/// `M17Client` needs one injected, because the library's own conformance is
/// compiled out for SPM consumers. If the geometry the app produces did not
/// match what an `M17StreamPacket` expects, everything would still compile and
/// every test in that other file would still pass.
///
/// So this runs an over through `M17StreamTransmitter` and back through
/// `M17StreamReceiver` using `Codec2Codec`, and requires recognisable audio to
/// come out the far end. No socket is opened (AU-5) and no reflector is
/// involved: this is the wiring, not the protocol.
final class M17CodecIntegrationTests: XCTestCase {

    private func tone(samples: Int, hertz: Double = 700) -> [Int16] {
        (0..<samples).map { index in
            Int16(clamping: Int(8000 * sin(2 * .pi * hertz * Double(index) / 8000)))
        }
    }

    private func rms(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return 0 }
        return (pcm.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(pcm.count))
            .squareRoot()
    }

    /// The arithmetic the M17 stream layout rests on, checked against the app's
    /// codec rather than the library's. Two of our frames must be exactly one
    /// datagram's payload, or every over would be misaligned on the wire.
    func testTheAppCodecFitsAnM17StreamPayloadExactly() throws {
        let codec = try Codec2Codec()

        XCTAssertEqual(
            codec.bytesPerFrame * M17StreamPayload.framesPerPacket,
            M17StreamPacket.payloadByteCount,
            "two codec frames must be exactly one 16-byte stream payload")
        XCTAssertEqual(
            codec.samplesPerFrame * M17StreamPayload.framesPerPacket,
            M17StreamPayload.samplesPerPacket,
            "and exactly 40 ms of audio")
    }

    /// An over goes out through the transmitter and comes back through the
    /// receiver as audio, carried by the app's codec throughout.
    func testAnOverRoundTripsThroughTheLibraryUsingTheAppsCodec() throws {
        let codec = try Codec2Codec()
        var transmitter = M17StreamTransmitter(
            streamID: 0x4242,
            destination: .broadcast,
            source: try M17Address(callsign: "VK2DEF"))
        var receiver = M17StreamReceiver(codec: codec)

        let speech = tone(samples: M17StreamPayload.samplesPerPacket)
        let overLength = 25  // one second at 40 ms a datagram

        for index in 0..<overLength {
            let packet = try transmitter.next(
                pcm: speech, using: codec, isLast: index == overLength - 1)
            XCTAssertEqual(packet.data.count, M17StreamPacket.byteCount)
            XCTAssertTrue(packet.isCRCValid, "a datagram we sent must check")
            _ = receiver.receive(packet)
        }

        var audioTicks = 0
        var energy = 0.0
        for _ in 0..<(overLength * M17StreamPayload.framesPerPacket) {
            let playout = receiver.pop()
            if playout.kind == .audio {
                audioTicks += 1
                energy += rms(playout.pcm)
            }
        }

        XCTAssertGreaterThan(audioTicks, overLength, "most of the over should play as audio")
        XCTAssertGreaterThan(
            energy / Double(audioTicks), 100,
            "the decoded over must carry signal, not silence")
    }

    /// `M17Client` accepts the app's codec — the actual injection point, and
    /// the one `CompositionRoot` will use when M17 becomes selectable.
    ///
    /// Constructs and tears down without connecting: no transport is built
    /// until `connect(to:)`, so nothing here opens a socket.
    func testM17ClientAcceptsTheAppsCodec() async throws {
        let client = M17Client(codec: try Codec2Codec(), clock: ContinuousClock())

        XCTAssertEqual(client.state, .idle)
        let connected = await client.isConnected
        XCTAssertFalse(connected)

        await client.disconnect()
    }
}

#endif
