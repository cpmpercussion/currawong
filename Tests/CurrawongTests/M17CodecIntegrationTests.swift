// SPDX-License-Identifier: Apache-2.0

import Foundation
import M17Kit
import RadioCore
import XCTest

@testable import Currawong

/// The claim this arrangement exists to support: **the codec the app injects
/// can drive the library's M17 stream path.**
///
/// The codec is `M17Kit.WeebillVoiceCodec` since APP-27, and is the library's
/// own pure-Swift Codec 2 rather than anything the app builds — so its encode
/// and decode behaviour is the library's to test, and this file does not
/// duplicate that. What is still the app's to prove is the *fit*: if the
/// geometry ``CompositionRoot/makeVoiceCodec()`` returns did not match what an
/// `M17StreamPacket` expects, everything would still compile and the library's
/// own tests would still pass, while every over went out misaligned.
///
/// So these go through ``CompositionRoot/makeVoiceCodec()`` — the actual
/// injection point, not a named type — run an over through
/// `M17StreamTransmitter` and back through `M17StreamReceiver`, and require
/// recognisable audio out the far end. No socket is opened (AU-5) and no
/// reflector is involved: this is the wiring, not the protocol.
///
/// `@MainActor` because ``CompositionRoot`` is: reaching the real injection
/// point rather than a named type means adopting its isolation, which is the
/// small price of testing what the app actually does.
@MainActor
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

    /// The arithmetic the M17 stream layout rests on, checked against the codec
    /// the composition root hands `M17Client`. Two of its frames must be
    /// exactly one datagram's payload, or every over would be misaligned on the
    /// wire.
    func testTheInjectedCodecFitsAnM17StreamPayloadExactly() throws {
        let codec = try CompositionRoot.makeVoiceCodec()

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
    /// receiver as audio, carried by the injected codec throughout.
    func testAnOverRoundTripsThroughTheLibraryUsingTheInjectedCodec() throws {
        let codec = try CompositionRoot.makeVoiceCodec()
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

    /// `M17Client` accepts the injected codec — the actual injection point
    /// ``CompositionRoot/makeM17Link(settings:identity:transmitTimeout:configuration:)``
    /// uses.
    ///
    /// Constructs and tears down without connecting: no transport is built
    /// until `connect(to:)`, so nothing here opens a socket.
    func testM17ClientAcceptsTheInjectedCodec() async throws {
        let client = M17Client(
            codec: try CompositionRoot.makeVoiceCodec(), clock: ContinuousClock())

        XCTAssertEqual(client.state, .idle)
        let connected = await client.isConnected
        XCTAssertFalse(connected)

        await client.disconnect()
    }
}
