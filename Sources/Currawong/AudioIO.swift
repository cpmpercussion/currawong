// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// The app's view of the audio hardware.
///
/// `RadioCore.AudioPipeline` is a concrete class that opens `AVAudioEngine` in
/// its initialiser, which makes it exactly the wrong thing to put in a view
/// model that has to be tested fifty times in a row with no microphone and no
/// permission prompt. This protocol is the seam. It is deliberately *not* a
/// general audio abstraction: it is the four calls and one stream the transmit
/// path needs, in `RadioCore` vocabulary (`AudioSessionSignal`), and nothing
/// else.
protocol AudioIO: AnyObject, Sendable {
    /// SF-3. Interruptions and route changes. The pipeline deliberately does
    /// not act on these itself; ``RadioSession`` must, and does.
    var signals: AsyncStream<AudioSessionSignal> { get }

    /// Prepares the audio session. Throws — an app that cannot configure its
    /// session cannot transmit, and pretending otherwise produces a PTT button
    /// that lights up and sends silence.
    func configureSession() throws

    /// Opens the microphone. Frames arrive off the main thread, 50 a second,
    /// 160 samples each.
    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws

    /// Closes the microphone. Must be safe to call at any time, including
    /// before any capture has started and twice in a row — every one of the
    /// PTT release paths calls it without knowing what state it is in.
    func stopCapture()

    /// Queues received audio for playback.
    func enqueuePlayback(_ pcm: [Int16])
}

/// The production ``AudioIO``: one `RadioCore.AudioPipeline`.
///
/// ### Why `stopCapture()` stops the whole engine
///
/// `AudioPipeline.stop()` tears down the microphone tap *and* stops the
/// engine, so it stops playback too. That reads like a bug and is not one
/// here: this is half-duplex push-to-talk, so there is nothing to receive
/// while the microphone is open, and `enqueuePlayback(_:)` restarts the engine
/// by itself on the next inbound frame. The alternative — leaving the tap
/// installed all the time and gating frames in software — keeps the
/// microphone (and the system's recording indicator) live for the whole call,
/// which is precisely the impression this app must never give.
final class AudioPipelineIO: AudioIO, @unchecked Sendable {
    private let pipeline: AudioPipeline

    init(pipeline: AudioPipeline = AudioPipeline()) {
        self.pipeline = pipeline
    }

    var signals: AsyncStream<AudioSessionSignal> { pipeline.signals }

    func configureSession() throws {
        #if os(iOS)
        try pipeline.configureSession()
        #endif
        // macOS has no AVAudioSession. Device selection there is the user's,
        // via System Settings, and there is nothing for the app to configure.
    }

    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws {
        try pipeline.startCapture(onFrame: onFrame)
    }

    func stopCapture() {
        pipeline.stop()
    }

    func enqueuePlayback(_ pcm: [Int16]) {
        pipeline.enqueuePlayback(pcm)
    }
}
