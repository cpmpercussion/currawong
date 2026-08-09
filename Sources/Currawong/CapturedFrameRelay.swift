// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The hand-off between the microphone tap and the network client.
///
/// `AudioIO.startCapture(onFrame:)` calls back synchronously on a real-time
/// audio thread, fifty times a second. `NetworkClient` implementations are
/// actors, so getting a frame to one means `await`, and awaiting on a
/// real-time thread is the textbook way to manufacture dropouts that then get
/// blamed on the network. So the tap hands the frame over and returns, and an
/// ordinary task picks it up.
///
/// The policy is **bounded, dropping the oldest, and counting what it
/// dropped**. Unbounded would grow without limit behind a stalled consumer,
/// and the audio it accumulated would be worthless anyway — speech two seconds
/// late is not speech. Dropping the oldest keeps the audio the other operator
/// is actually waiting for. ``droppedFrameCount`` exists so a dropout is a
/// number somebody can read rather than a mystery.
///
/// (The library's CLI has the same type for the same reason. It is duplicated
/// rather than shared because it is not part of the library's public surface;
/// if a third caller wants it, it should move into `RadioCore`.)
final class CapturedFrameRelay: @unchecked Sendable {
    /// Frames buffered before the oldest is dropped: half a second at 20 ms.
    /// Long enough to ride out a scheduling hiccup, short enough that a real
    /// stall is heard as a gap rather than as growing delay.
    static let defaultCapacity = 25

    /// Captured frames, oldest first, exactly as the tap produced them.
    let frames: AsyncStream<[Int16]>

    private let continuation: AsyncStream<[Int16]>.Continuation
    private let lock = NSLock()
    private var dropped = 0
    private var submitted = 0

    init(capacity: Int = CapturedFrameRelay.defaultCapacity) {
        var escaped: AsyncStream<[Int16]>.Continuation!
        self.frames = AsyncStream<[Int16]>(bufferingPolicy: .bufferingNewest(capacity)) {
            escaped = $0
        }
        self.continuation = escaped
    }

    /// Hands one captured frame to the consumer. **Called on the audio
    /// thread** — takes a short uncontended lock and never awaits.
    func submit(_ frame: [Int16]) {
        let result = continuation.yield(frame)
        lock.lock()
        submitted += 1
        if case .dropped = result { dropped += 1 }
        lock.unlock()
    }

    /// Frames discarded because the consumer could not keep up. Anything but
    /// zero on a live contact is lost transmit audio.
    var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// Frames the tap has produced. Zero is the difference between "no audio"
    /// and "no microphone".
    var submittedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return submitted
    }

    /// Ends ``frames``, so the consuming task's `for await` returns.
    func finish() {
        continuation.finish()
    }
}
