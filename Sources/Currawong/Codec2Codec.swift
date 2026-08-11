// SPDX-License-Identifier: Apache-2.0

#if canImport(Codec2)

import Codec2
import Foundation
import RadioCore

/// Codec2 3200 bit/s (FR-2.4), the voice codec an M17 stream frame carries.
///
/// ## Why the app has its own conformance
///
/// `M17Kit` already contains a `Codec2VoiceCodec`, and this is knowingly its
/// sibling rather than a reuse of it. That one is behind `#if CODEC2`, a flag
/// the library only defines when `Codec2.xcframework` is sitting in its own
/// checkout — and the XCFramework is not committed, nor can it be built from
/// inside the checkout SPM makes of a resolved dependency. So for every
/// downstream consumer, including this app, the library's conformance does not
/// exist at all. Currawong embeds the framework itself, so Currawong supplies
/// the conformance and injects it into `M17Client`; the library keeps its own
/// for its tests and CLI.
///
/// The guard here is `canImport(Codec2)` and not a build flag, because the app
/// has no equivalent of the library's `CODEC2` define and does not want one:
/// whether the framework has been built is a fact the compiler can already see.
///
/// The framework is linked **dynamically and never statically** — that is LP-4,
/// and it is a licence constraint rather than a packaging preference.
///
/// ## Frame arithmetic
///
/// Mode 3200 is 160 samples in, 64 bits out, asserted again at construction
/// below. At 8 kHz that is **20 ms of audio per 8-byte frame**, which is also
/// the frame size `AudioIO` hands out of the microphone tap, and half of the
/// 16-byte payload an `M17StreamPacket` carries — 40 ms per datagram.
///
/// ## Why a lock rather than an actor
///
/// `struct CODEC2` is mutable internal state and is not thread-safe, but
/// `VoiceCodec` is a synchronous protocol. It has to be: encoding happens on
/// the frame the audio tap just delivered, in a real-time context where `await`
/// is not available and where suspending is how dropouts get manufactured. So
/// the state is guarded by a lock rather than by actor isolation.
///
/// Encode and decode get **separate** codec2 instances behind separate locks.
/// They are independent state machines, and a single instance shared between
/// the two directions would serialise a full-duplex path against itself for no
/// reason — inbound audio would wait on the operator's own microphone.
final class Codec2Codec: VoiceCodec, @unchecked Sendable {

    /// `CODEC2_MODE_3200`. Hard-coded because the header's macro does not
    /// import into Swift as a constant.
    private static let mode3200: Int32 = 0

    /// 160 samples at 8 kHz — 20 ms.
    let samplesPerFrame: Int

    /// 8 bytes, from 64 bits.
    let bytesPerFrame: Int

    private let encoder: OpaquePointer
    private let decoder: OpaquePointer
    private let encodeLock = NSLock()
    private let decodeLock = NSLock()

    /// Creates a codec, or throws if the embedded framework reports a geometry
    /// this code was not written for.
    init() throws {
        // Created one at a time rather than in a single `guard`, so that a
        // decoder that fails after the encoder succeeded does not strand the
        // encoder. Only reachable when codec2 cannot allocate at all, but a
        // leak on the failure path is still a leak.
        guard let encoder = codec2_create(Codec2Codec.mode3200) else {
            throw Codec2CodecError.unavailable
        }
        guard let decoder = codec2_create(Codec2Codec.mode3200) else {
            codec2_destroy(encoder)
            throw Codec2CodecError.unavailable
        }

        let samples = Int(codec2_samples_per_frame(encoder))
        let bits = Int(codec2_bits_per_frame(encoder))
        // Checking rather than assuming means a future codec2 bump that moved
        // either number fails loudly here, at composition time, instead of
        // producing quietly misaligned audio on the air.
        guard samples == 160, bits == 64 else {
            codec2_destroy(encoder)
            codec2_destroy(decoder)
            throw Codec2CodecError.unexpectedGeometry(
                samplesPerFrame: samples, bitsPerFrame: bits)
        }

        self.encoder = encoder
        self.decoder = decoder
        self.samplesPerFrame = samples
        self.bytesPerFrame = bits / 8
    }

    deinit {
        codec2_destroy(encoder)
        codec2_destroy(decoder)
    }

    func encode(_ pcm: [Int16]) throws -> [UInt8] {
        guard pcm.count == samplesPerFrame else {
            throw Codec2CodecError.wrongSampleCount(
                expected: samplesPerFrame, actual: pcm.count)
        }
        var frame = [UInt8](repeating: 0, count: bytesPerFrame)
        encodeLock.lock()
        defer { encodeLock.unlock() }
        // `codec2_encode` takes a mutable input pointer even though it does not
        // write through it, so the samples are copied into a var to satisfy it.
        var input = pcm
        frame.withUnsafeMutableBufferPointer { out in
            input.withUnsafeMutableBufferPointer { samples in
                codec2_encode(encoder, out.baseAddress, samples.baseAddress)
            }
        }
        return frame
    }

    func decode(_ frame: [UInt8]) throws -> [Int16] {
        guard frame.count == bytesPerFrame else {
            throw Codec2CodecError.wrongFrameSize(
                expected: bytesPerFrame, actual: frame.count)
        }
        var pcm = [Int16](repeating: 0, count: samplesPerFrame)
        decodeLock.lock()
        defer { decodeLock.unlock() }
        var input = frame
        pcm.withUnsafeMutableBufferPointer { out in
            input.withUnsafeMutableBufferPointer { bits in
                codec2_decode(decoder, out.baseAddress, bits.baseAddress)
            }
        }
        return pcm
    }
}

/// Failures constructing or driving ``Codec2Codec``.
enum Codec2CodecError: Error, Equatable, CustomStringConvertible {
    /// `codec2_create` returned null — the framework is present but would not
    /// give us a codec.
    case unavailable
    /// The framework reports a frame geometry this code was not written for.
    case unexpectedGeometry(samplesPerFrame: Int, bitsPerFrame: Int)
    /// ``Codec2Codec/encode(_:)`` was handed something other than one frame.
    case wrongSampleCount(expected: Int, actual: Int)
    /// ``Codec2Codec/decode(_:)`` was handed something other than one frame.
    case wrongFrameSize(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .unavailable:
            return "codec2_create(CODEC2_MODE_3200) returned null"
        case .unexpectedGeometry(let samples, let bits):
            return """
                codec2 3200 reports \(samples) samples and \(bits) bits per frame; \
                this code is written for 160 and 64
                """
        case .wrongSampleCount(let expected, let actual):
            return "codec2 encode wants exactly \(expected) samples, got \(actual)"
        case .wrongFrameSize(let expected, let actual):
            return "codec2 decode wants exactly \(expected) bytes, got \(actual)"
        }
    }
}

#endif
