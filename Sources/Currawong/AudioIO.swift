// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

#if os(iOS)
import AVFAudio
#endif

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

    /// Asks the operating system for microphone access, returning what it
    /// decided. Must be called — and awaited — before ``configureSession()``.
    ///
    /// ### Why this cannot be left implicit
    ///
    /// iOS shows the microphone prompt when an app first *touches* the
    /// microphone: installs a tap and starts the engine. Setting the session
    /// category and activating it does not count, so `configureSession()` alone
    /// never triggers it.
    ///
    /// That produced a deadlock. Until permission is granted, the input node
    /// reports a sample rate of 0; `AudioPipeline.startCapture` builds its
    /// converter from that rate and throws `converterUnavailable` *before*
    /// reaching `installTap` — so the app never touched the microphone, so it
    /// was never asked about, so the rate stayed 0. The app could not bootstrap
    /// its own permission, PTT failed on the first press and every press after
    /// it, and the app did not appear under Settings → Privacy → Microphone at
    /// all. Asking explicitly is the only way out of the cycle.
    ///
    /// Returns `true` on macOS, which has no `AVAudioSession`: device selection
    /// there belongs to the user, and TCC is attributed to the host process.
    func requestRecordPermission() async -> Bool

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

    func requestRecordPermission() async -> Bool {
        #if os(iOS)
        // Both spellings take a completion handler, and both answer instantly
        // once the user has decided: a second call never re-prompts, and
        // returns the standing answer. That is what makes it safe to gate every
        // connect on this rather than only the first.
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        }
        #else
        return true
        #endif
    }

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
