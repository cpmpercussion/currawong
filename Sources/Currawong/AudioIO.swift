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

/// The engine-side half of ``AudioPipelineIO``, as a seam.
///
/// `RadioCore.AudioPipeline` satisfies this in production (see the retroactive
/// conformance below); it exists as a protocol only so the rebuild-and-retry
/// logic in ``AudioPipelineIO`` — which is on the transmit path and therefore
/// has to fail closed — can be tested without a microphone. It is deliberately
/// narrower than ``AudioIO``: no permission, no session, just the engine.
///
/// `configureSession()` is absent on purpose. On iOS the audio session is
/// process-wide state that has to be settled *before* an engine is built, so
/// ``AudioPipelineIO`` configures it itself rather than asking a pipeline that
/// does not exist yet.
protocol CapturePipeline: AnyObject, Sendable {
    var signals: AsyncStream<AudioSessionSignal> { get }
    func startCapture(onFrame: @escaping ([Int16]) -> Void) throws
    func stop()
    func enqueuePlayback(_ pcm: [Int16])
}

extension AudioPipeline: CapturePipeline {}

/// The production ``AudioIO``: one `RadioCore.AudioPipeline` at a time.
///
/// ### Why the pipeline is built late, and can be rebuilt
///
/// `AVAudioEngine` decides its input format once, when its input audio unit is
/// first instantiated, and **never revisits that decision**. On iOS, an engine
/// whose input unit is instantiated while the audio session is still the default
/// `.soloAmbient` — playback only — reports an input sample rate of 0 Hz, and
/// keeps reporting 0 Hz after the session is switched to `.playAndRecord` and
/// activated. `AudioPipeline.startCapture` builds its converter from that rate,
/// `AudioConverterNew` refuses 0 Hz, and every PTT press for the rest of the
/// process fails with `converterUnavailable`. A fresh engine, built after the
/// session is up, reports the real hardware rate.
///
/// Two consequences, both visible in the code below:
///
/// 1. The pipeline is created lazily, on first use, which is always after
///    ``configureSession()`` and after the microphone has been granted — never
///    at launch, as a stored property of the composition root would be.
/// 2. ``startCapture(onFrame:)`` retries once on a **freshly built** pipeline.
///    A poisoned engine cannot recover, so retrying on the same one would be
///    pointless; discarding it is the only repair. The second failure is
///    reported with the audio state attached rather than retried again.
///
/// ``signals`` therefore cannot be the pipeline's own stream — that one dies
/// with the pipeline it belongs to, and SF-3 with it. This class owns a durable
/// stream for the process's lifetime and forwards whichever pipeline is current
/// into it, so a rebuild is invisible to ``RadioSession``.
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
    /// Both halves of a failed key-up, with the state of the audio system at the
    /// moment it failed.
    ///
    /// The operator sees this in the "Could not transmit" alert, which is the
    /// only diagnostic channel a radio in the field has: nobody is going to
    /// attach a debugger on a hilltop. `converterUnavailable` on its own says
    /// only that CoreAudio said no — the numbers below say *why*, and in
    /// particular whether the session was healthy (a live hardware rate) when
    /// the engine claimed it was not.
    struct CaptureUnavailable: Error, CustomStringConvertible {
        let first: Error
        let afterRebuild: Error
        let audioState: String

        var description: String {
            "The microphone could not be opened. \(afterRebuild) "
                + "(first attempt: \(first)) Audio state: \(audioState)"
        }
    }

    private let makePipeline: @Sendable () -> CapturePipeline

    /// Guards ``current`` and ``forwarder``. Both are touched from
    /// ``RadioSession`` on the main actor today, but `stopCapture()` is the
    /// call every safety path funnels through and it must not acquire a
    /// dependency on who is calling it.
    private let lock = NSLock()
    private var current: CapturePipeline?
    private var forwarder: Task<Void, Never>?

    /// SF-3, decoupled from any one pipeline's lifetime. See the type note.
    let signals: AsyncStream<AudioSessionSignal>
    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation

    init(makePipeline: @escaping @Sendable () -> CapturePipeline = { AudioPipeline() }) {
        self.makePipeline = makePipeline
        var escaped: AsyncStream<AudioSessionSignal>.Continuation!
        self.signals = AsyncStream { escaped = $0 }
        self.signalContinuation = escaped
    }

    deinit {
        forwarder?.cancel()
        signalContinuation.finish()
    }

    // MARK: - Pipeline lifetime

    /// The current pipeline, building one if there is none.
    private func pipeline() -> CapturePipeline {
        lock.lock()
        defer { lock.unlock() }
        if let current { return current }
        return adoptLocked(makePipeline())
    }

    /// Throws the current pipeline away and builds a replacement.
    ///
    /// The outgoing pipeline is stopped first: it may have installed a tap
    /// before failing, and an engine that is dropped with a live tap is an open
    /// microphone with nobody left holding the reference.
    private func rebuildPipeline() -> CapturePipeline {
        lock.lock()
        defer { lock.unlock() }
        current?.stop()
        forwarder?.cancel()
        forwarder = nil
        current = nil
        return adoptLocked(makePipeline())
    }

    /// Must be called with ``lock`` held.
    private func adoptLocked(_ pipeline: CapturePipeline) -> CapturePipeline {
        current = pipeline
        let events = pipeline.signals
        let continuation = signalContinuation
        // Forward, never finish: this pipeline's stream ends when the pipeline
        // is released, and finishing the durable stream there would end SF-3
        // observation for the rest of the process.
        forwarder = Task.detached {
            for await event in events {
                continuation.yield(event)
            }
        }
        return pipeline
    }

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

    /// Puts the shared session into the category a half-duplex radio needs, and
    /// activates it.
    ///
    /// This duplicates `AudioPipeline.configureSession()`, three lines of it,
    /// and does so knowingly. That method is an *instance* method, so reaching
    /// it means owning a pipeline, and owning a pipeline means having built an
    /// engine — which is the one thing that must not happen before this call
    /// (see the type note). The library should expose the session policy without
    /// requiring an engine; until it does, the category lives in both places and
    /// the two must be kept in step.
    func configureSession() throws {
        try activateSession()

        // Build the engine here — immediately after activation, and never
        // before it. Waiting until the first PTT press would work too, but
        // `AudioPipeline.init` is also where the SF-3 interruption observers are
        // registered, and those should be listening from the moment the session
        // exists rather than from the moment somebody keys up.
        _ = pipeline()
    }

    /// The session half of ``configureSession()``, on its own so the repair path
    /// in ``startCapture(onFrame:)`` can reach it without building an engine.
    private func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // `.allowBluetoothHFP` is the current spelling of the library's
        // `.allowBluetooth` — same option, same raw value, available since
        // iOS 1.0, and not deprecated. Hands-free profile is the one that
        // carries a microphone, which is the half that matters here.
        try session.setCategory(
            .playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        #endif
        // macOS has no AVAudioSession. Device selection there is the user's,
        // via System Settings, and there is nothing for the app to configure.
    }

    /// Opens the microphone, repairing the audio stack once if the first attempt
    /// fails.
    ///
    /// The repair is "reactivate the session, then build a new engine", in that
    /// order, and it addresses two different real failures with one path:
    ///
    /// * An engine that settled on a 0 Hz input format because it was built
    ///   before the session was active. It cannot be talked out of that, so the
    ///   only repair is a different engine (see the type note).
    /// * A session left deactivated by something else — the usual culprit being
    ///   an interruption whose end we handled by dropping transmit and not by
    ///   reactivating. `engine.start()` fails against an inactive session, and
    ///   the operator's response to a dead PTT button is to press it again,
    ///   which should work rather than fail identically forever.
    ///
    /// Exactly one retry. A loop here would be a loop on the transmit path, and
    /// the second failure is more useful reported than retried.
    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws {
        do {
            try pipeline().startCapture(onFrame: onFrame)
        } catch let first {
            do {
                try activateSession()
                try rebuildPipeline().startCapture(onFrame: onFrame)
            } catch let second {
                throw CaptureUnavailable(
                    first: first, afterRebuild: second, audioState: Self.audioStateDescription())
            }
        }
    }

    func stopCapture() {
        // Deliberately does not build a pipeline: every PTT release path calls
        // this without knowing whether anything was ever started, and creating
        // an engine in order to stop it would instantiate audio hardware from
        // the middle of a safety path.
        lock.lock()
        let pipeline = current
        lock.unlock()
        pipeline?.stop()
    }

    func enqueuePlayback(_ pcm: [Int16]) {
        pipeline().enqueuePlayback(pcm)
    }

    /// What the audio system thinks is true, in one line, for the failure alert.
    ///
    /// A hardware rate of 0 means the session is not really up; a live rate here
    /// beside a `converterUnavailable` from the engine means the session is fine
    /// and the *engine* is the stale one.
    private static func audioStateDescription() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
        return
            "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
            + "hardware=\(session.sampleRate)Hz preferred=\(session.preferredSampleRate)Hz "
            + "inputAvailable=\(session.isInputAvailable) "
            + "inputChannels=\(session.inputNumberOfChannels) "
            + "route=\(inputs.isEmpty ? "none" : inputs) "
            + "otherAudio=\(session.isOtherAudioPlaying)"
        #else
        return "macOS, no AVAudioSession"
        #endif
    }
}
