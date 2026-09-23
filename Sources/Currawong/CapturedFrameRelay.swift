// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The hand-off from the real-time capture thread to the network client. The
/// clients are actors, and awaiting on the audio thread causes dropouts, so the
/// tap hands the frame over and returns, and an ordinary task picks it up.
///
/// Bounded, dropping the oldest and counting drops: late speech is worthless,
/// and a count makes a dropout visible. The library's CLI has its own copy
/// (`AudioFrameBridge`); a third caller should move it into `RadioCore`.
final class CapturedFrameRelay: @unchecked Sendable {
    /// Half a second at 20 ms: rides out a scheduling hiccup, while a real
    /// stall is heard as a gap rather than growing delay.
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

    /// Hands one frame over. Called on the audio thread; never awaits.
    func submit(_ frame: [Int16]) {
        let result = continuation.yield(frame)
        lock.lock()
        submitted += 1
        if case .dropped = result { dropped += 1 }
        lock.unlock()
    }

    /// Frames dropped because the consumer fell behind: lost transmit audio.
    var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// Frames the tap has produced; zero means no microphone, not silence.
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
