// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The tests below are conditional on the framework being linked, which means
/// that without it they compile to nothing and the suite passes having tested
/// no codec at all. This one is *not* conditional, so that a missing framework
/// is a failure rather than a silence.
///
/// `project.yml` links `Codec2.xcframework` unconditionally and `make` builds
/// it when it is absent, so this should never fire. It exists because the
/// failure it guards against is invisible by construction.
final class Codec2AvailabilityTests: XCTestCase {
    func testTheCodec2FrameworkIsLinked() {
        #if canImport(Codec2)
        #else
        XCTFail(
            """
            Codec2.xcframework is not linked, so every codec test in this file \
            was compiled out and M17 audio is unavailable. Run \
            scripts/build-codec2-xcframework.sh (or `make codec2`) and \
            regenerate the project.
            """)
        #endif
    }
}

#if canImport(Codec2)

import RadioCore

@testable import Currawong

/// The app's own Codec2 3200 conformance (FR-2.4).
///
/// Nothing here asserts bit-exact codec output. Doing so would pin the test to
/// one upstream build of codec2 rather than to anything this file owns, and the
/// next bump of the XCFramework would fail it for no fault of ours. What is
/// ours is the geometry, the buffer sizes, the input validation, and the claim
/// that audio survives a round trip — so that is what is checked.
final class Codec2CodecTests: XCTestCase {

    /// Frames run through the codec before anything is measured. Codec2 is a
    /// vocoder with internal state: the first frames out of a cold instance are
    /// still converging and are not representative of steady-state audio.
    private static let warmUpFrames = 10

    // MARK: - Geometry

    func testFrameGeometryIsTwentyMillisecondsAtEightKilohertz() throws {
        let codec = try Codec2Codec()

        XCTAssertEqual(codec.samplesPerFrame, 160)
        XCTAssertEqual(codec.bytesPerFrame, 8)
    }

    func testEncodeAndDecodeProduceExactlyOneFrame() throws {
        let codec = try Codec2Codec()
        let tone = Self.sine(hertz: 440, samples: codec.samplesPerFrame, amplitude: 8000)

        let frame = try codec.encode(tone)
        XCTAssertEqual(frame.count, 8, "an M17 stream payload is exactly two of these")

        let pcm = try codec.decode(frame)
        XCTAssertEqual(pcm.count, 160)
    }

    // MARK: - Audio survives the round trip

    func testToneRoundTripsWithItsEnergyRoughlyIntact() throws {
        let codec = try Codec2Codec()
        let tone = Self.sine(hertz: 440, samples: codec.samplesPerFrame, amplitude: 8000)

        for _ in 0..<Self.warmUpFrames {
            _ = try codec.decode(codec.encode(tone))
        }
        let decoded = try codec.decode(codec.encode(tone))

        // A vocoder resynthesises rather than reproduces, so the bounds are
        // wide on purpose: they catch silence, catastrophic attenuation and
        // runaway gain, and deliberately say nothing about waveform shape.
        let input = Self.rms(tone)
        let output = Self.rms(decoded)
        XCTAssertGreaterThan(output, input * 0.25, "audio all but vanished on the way through")
        XCTAssertLessThan(output, input * 4, "the decoder is manufacturing energy")
    }

    func testSilenceInGivesNearSilenceOut() throws {
        let codec = try Codec2Codec()
        let silence = [Int16](repeating: 0, count: 160)

        for _ in 0..<Self.warmUpFrames {
            _ = try codec.decode(codec.encode(silence))
        }
        let decoded = try codec.decode(codec.encode(silence))

        // An unkeyed radio must sound unkeyed. Some vocoder noise is expected;
        // anything approaching speech level is not.
        XCTAssertLessThan(Self.rms(decoded), 500)
    }

    func testDifferentTonesDoNotEncodeIdentically() throws {
        let codec = try Codec2Codec()
        let low = Self.sine(hertz: 300, samples: 160, amplitude: 8000)
        let high = Self.sine(hertz: 1800, samples: 160, amplitude: 8000)

        for _ in 0..<Self.warmUpFrames {
            _ = try codec.encode(low)
        }
        let lowFrame = try codec.encode(low)
        let highFrame = try codec.encode(high)

        // The weakest useful statement that still fails if the encoder were
        // wired to a dead buffer or a constant.
        XCTAssertNotEqual(lowFrame, highFrame)
    }

    // MARK: - Input validation

    func testEncodeRejectsAnythingOtherThanOneFrameOfPCM() throws {
        let codec = try Codec2Codec()

        for count in [0, 159, 161, 320] {
            XCTAssertThrowsError(try codec.encode([Int16](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? Codec2CodecError,
                    .wrongSampleCount(expected: 160, actual: count))
            }
        }
    }

    func testDecodeRejectsAnythingOtherThanOneEncodedFrame() throws {
        let codec = try Codec2Codec()

        for count in [0, 7, 9, 16] {
            XCTAssertThrowsError(try codec.decode([UInt8](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? Codec2CodecError,
                    .wrongFrameSize(expected: 8, actual: count))
            }
        }
    }

    // MARK: - Helpers

    /// A sine tone at the codec's 8 kHz sample rate.
    private static func sine(hertz: Double, samples: Int, amplitude: Double) -> [Int16] {
        let sampleRate = 8000.0
        return (0..<samples).map { index in
            let phase = 2 * Double.pi * hertz * Double(index) / sampleRate
            return Int16(clamping: Int(amplitude * sin(phase)))
        }
    }

    /// Root mean square level, the one measure of "is there audio here" that
    /// survives a vocoder resynthesising the waveform.
    private static func rms(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return 0 }
        let sum = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(pcm.count)).squareRoot()
    }
}

#endif
