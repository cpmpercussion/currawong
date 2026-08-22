// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

#if os(iOS)
import AVFAudio
#else
// `AVCaptureDevice` is how a macOS app asks for the microphone — see
// `requestRecordPermission()`.
import AVFoundation
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

    /// What the audio system thinks is true, in one line, for the key/unkey log.
    ///
    /// On the protocol rather than on the implementation because the *point* is
    /// to log it at key-down and key-up, and those live in ``RadioSession``,
    /// which only ever sees an `AudioIO`. Diagnostic: no behaviour may branch on
    /// this string. See `Diagnostics` and `BU-13`.
    var audioStateDescription: String { get }
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

    /// Applies an audio-session policy (RC-12). Injectable so the policy
    /// switching below is testable without an `AVAudioSession` (AU-5); the
    /// default reaches the library on iOS and does nothing on macOS, where
    /// CoreAudio manages the route itself and gets it right.
    private let applyPolicy: @Sendable (AudioSessionPolicy) throws -> Void

    /// How long ``stopCapture()`` waits before handing the route back to
    /// listening. See ``listeningLingerNanoseconds`` for why a wait exists at
    /// all; injectable so tests can step it rather than sleep it.
    private let listeningLinger: @Sendable () async -> Void

    /// Guards ``current`` and ``forwarder`` — and the policy state below. All
    /// are touched from ``RadioSession`` on the main actor today, but
    /// `stopCapture()` is the call every safety path funnels through and it
    /// must not acquire a dependency on who is calling it, and the lingered
    /// hand-back runs off a detached task by construction.
    private let lock = NSLock()
    private var current: CapturePipeline?
    private var forwarder: Task<Void, Never>?

    /// The policy last applied, so an over that begins inside the linger — the
    /// automatic resume after a route change, most importantly — finds the
    /// session already on radio and does **not** re-apply the category. A
    /// redundant category change is not harmless: it is a fresh route-change
    /// cascade, and re-triggering the cascade from inside its own recovery is
    /// the loop that killed `BU-17`'s first attempt.
    private var appliedPolicy: AudioSessionPolicy?

    /// True between ``startCapture(onFrame:)`` and ``stopCapture()``. A linger
    /// that expires while this is true must not touch the session.
    private var isCapturing = false

    /// Whether a capture has been *attempted* on the current engine. That —
    /// not success — is what instantiates the input audio unit (the attempt
    /// reads the input node's format before it can fail), and an engine
    /// carrying an input unit is the one the hand-back must discard. An engine
    /// that has only ever played stays input-free and is kept.
    private var captureAttemptedOnCurrent = false

    /// Cancels stale hand-backs: every escalation and every new hand-back bumps
    /// it, and a lingered task only acts if its generation is still current.
    private var handbackGeneration = 0

    /// Frames handed to ``enqueuePlayback(_:)``, ever. A hand-back compares the
    /// count at its linger's start with the count at its expiry: a difference
    /// means the far side talked during the linger, and the engine still holds
    /// their audio — replies land at a measured 1.6–2.6 s, comfortably inside
    /// the 3 s linger — so the discard waits out another linger rather than
    /// cutting the reply off mid-word. Not a clock: it observes arriving data,
    /// which is the same rule the BLE probe follows.
    private var playbackFrameCount = 0

    /// Whether the hand-back discards a capture-bearing engine (see
    /// ``completeHandback(_:attempt:playbackBaseline:)``). Platform truth by
    /// default — the discard exists because restarting such an engine re-raises
    /// an input route, and on iOS the only Bluetooth input route is HFP, which
    /// re-mutes the accessory's button; macOS manages its own routes, gets the
    /// per-over SCO behaviour right by itself, and would pay the engine churn
    /// for nothing. Injectable so the discard logic stays testable on macOS.
    private let discardsEngineOnHandback: Bool

    /// SF-3, decoupled from any one pipeline's lifetime. See the type note.
    let signals: AsyncStream<AudioSessionSignal>
    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation

    /// The linger between the microphone closing and the route being handed
    /// back to listening (BU-17).
    ///
    /// macOS keeps SCO up for ~2.1 s after the last capture client closes
    /// (measured 2026-08-22), and that linger is what makes its per-over HFP
    /// behaviour feel instant in a quick exchange. This reproduces it, a little
    /// longer, for a second reason macOS does not have: the drop-and-resume
    /// that SF-3 performs when the escalation's own route-change cascade lands
    /// mid-over takes up to ~1 s (300 ms settle plus engine start plus the
    /// cascade tail), and the hand-back must comfortably outlast it so the
    /// resume re-keys into a session still on radio.
    static let listeningLingerNanoseconds: UInt64 = 3_000_000_000

    init(
        makePipeline: @escaping @Sendable () -> CapturePipeline = { AudioPipeline() },
        applyPolicy: @escaping @Sendable (AudioSessionPolicy) throws -> Void = { policy in
            #if os(iOS)
                if policy == .radio {
                    try AudioPipeline.activateSession(policy)
                } else {
                    // Category-only, no `setActive(true)`: the session is
                    // already active when the route is handed back, and the
                    // redundant re-activation is what refused with `'!pri'`
                    // (insufficient priority, OSStatus 561017449) during the
                    // post-over route shuffle — measured on air 2026-08-22. A
                    // category change on an active session takes effect on its
                    // own. The values are still the library's policy, not a
                    // copy (RC-11).
                    try AVAudioSession.sharedInstance().setCategory(
                        AVAudioSession.Category(rawValue: policy.category),
                        mode: AVAudioSession.Mode(rawValue: policy.mode),
                        options: AVAudioSession.CategoryOptions(rawValue: policy.options))
                }
            #endif
        },
        listeningLinger: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: AudioPipelineIO.listeningLingerNanoseconds)
        },
        discardsEngineOnHandback: Bool = {
            #if os(iOS)
                return true
            #else
                return false
            #endif
        }()
    ) {
        self.makePipeline = makePipeline
        self.applyPolicy = applyPolicy
        self.listeningLinger = listeningLinger
        self.discardsEngineOnHandback = discardsEngineOnHandback
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
        captureAttemptedOnCurrent = false
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
        // macOS never asked, and returning `true` here was a lie that cost the
        // operator their first over: with nothing having prompted, the *first
        // capture attempt* is what triggers the system dialog, and that press
        // puts no audio on air. Observed on 2026-08-20 — press once, nothing;
        // the microphone indicator appears in the menu bar; press again, and
        // now there are levels. Asking here moves the prompt to connect time,
        // where the operator is already waiting and no over is at stake.
        //
        // `AVCaptureDevice` rather than `AVAudioApplication`: the latter is
        // iOS-only, and this app is not sandboxed, so there is no
        // `com.apple.security.device.audio-input` entitlement in play — only
        // TCC, which this is the way to ask.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            // Denied or restricted. Answering instantly and identically on
            // every later connect is the same contract the iOS branch has.
            return false
        }
        #endif
    }

    /// Puts the shared session into the category a half-duplex radio needs, and
    /// activates it.
    func configureSession() throws {
        try activateSession()

        // Build the engine here — immediately after activation, and never
        // before it. Waiting until the first PTT press would work too, but
        // `AudioPipeline.init` is also where the SF-3 interruption observers are
        // registered, and those should be listening from the moment the session
        // exists rather than from the moment somebody keys up.
        //
        // **And it must be built under the *radio* policy** (BU-17): an engine
        // whose input unit is instantiated under a playback-only category
        // reports 0 Hz for the life of the process and never recovers. That is
        // `BU-1`, and this ordering is what keeps `AudioSessionPolicy.listening`
        // from bringing it back.
        _ = pipeline()

        // Then hand the accessory straight back to listening (BU-17, RC-12) —
        // no linger, because configuration happens with nothing on air, so the
        // route-change cascade this causes lands while idle and SF-3 has
        // nothing to drop. Until this existed, configuring the session was
        // what pinned the route to HFP for the whole call: 16 kHz receive
        // audio, a speaker-mic whose "in a call" light never went out, and —
        // the root cause proven on 2026-08-22 — a PTT button the accessory
        // itself mutes for as long as that idle call is held.
        handRouteBack(afterLinger: false)
    }

    /// The session half of ``configureSession()``, on its own so the repair path
    /// in ``startCapture(onFrame:)`` can reach it without building an engine.
    ///
    /// **The policy is the library's** (RC-11, v0.5.3):
    /// `AudioPipeline.activateSession()` is static, so reaching it does not mean
    /// owning a pipeline and therefore having built an engine — which is the
    /// ordering that must not be violated (see the type note). The app kept a
    /// copy of the category while that static did not exist; it no longer does,
    /// and with it went the `allowBluetooth` → `allowBluetoothHFP` shim, because
    /// the library states the options as a raw value.
    ///
    /// What is left here is the platform guard: `AVAudioSession` does not exist
    /// on macOS, where input and output device selection is the user's, via
    /// System Settings, and there is nothing for the app to configure.
    private func activateSession() throws {
        lock.lock()
        handbackGeneration += 1
        lock.unlock()
        try applyPolicy(AudioSessionPolicy.radio)
        lock.lock()
        appliedPolicy = AudioSessionPolicy.radio
        lock.unlock()
    }

    // **Third attempt at `BU-17`, and the first with the mechanism in hand.**
    //
    // The first attempt failed because a category change is a route change and
    // SF-3 dropped the transmission it was enabling — and then looped, because
    // the drop's own `stopCapture()` handed the route straight back, so the
    // automatic resume re-escalated and re-triggered the cascade every cycle.
    // The second attempt (RC-13's cause) failed because one deliberate switch
    // produces a cascade — `categoryChange`, `override`, `newDeviceAvailable`,
    // `engineConfigurationChange` — and only the first is self-evidently ours;
    // the rest are indistinguishable from an accessory being unplugged, and
    // SF-3 must drop transmit for those.
    //
    // This attempt changes neither SF-3 nor the cascade. It removes the loop:
    // the hand-back to listening happens on a **linger** rather than inside
    // `stopCapture()`, so SF-3's transient drop-and-resume completes inside it
    // and re-keys into a session still on radio — no category change, no fresh
    // cascade, convergence. The residual cost is one `BU-15`-style drop-and-
    // resume on the first over after each hand-back, which is SF-3 performing
    // exactly as specified and is the same dance macOS does on a cold SCO link.
    //
    // Why per-over switching is worth that residual, and is not merely the
    // receive-quality nicety it was first costed as: **the Q2L mutes its own
    // BLE PTT notifications for as long as its Classic side sits in an idle
    // HFP call** — proven 2026-08-22 by holding the BLE link from a Mac while
    // the phone held the call. Handing the route back between overs is what
    // lets the button live. That finding is the requirements decision the
    // previous version of this comment said must be taken deliberately: taken
    // 2026-08-22, with the operator, on that evidence — and note that SF-3 is
    // *not* suppressed anywhere in it.

    /// Ask for the radio policy before opening the microphone, skipping the
    /// category change when the session is already there — see
    /// ``appliedPolicy`` for why the skip is load-bearing, not an optimisation.
    private func escalateForCapture() throws {
        lock.lock()
        handbackGeneration += 1
        isCapturing = true
        let alreadyRadio = appliedPolicy == AudioSessionPolicy.radio
        lock.unlock()
        guard !alreadyRadio else { return }
        try applyPolicy(AudioSessionPolicy.radio)
        lock.lock()
        appliedPolicy = AudioSessionPolicy.radio
        lock.unlock()
        Diagnostics.route("audio session escalated to radio for capture")
    }

    /// Hand the route back to listening: `.playback`, which asks for no input,
    /// so iOS stops choosing the hands-free profile, the SCO link drops, and
    /// the accessory — which mutes its PTT while the call idles — comes back.
    ///
    /// **Best effort, and deliberately not throwing.** Every caller is either a
    /// stop path or the tail of configuration, and failing to get back to
    /// listening is a quality regression — narrowband receive audio, a lit
    /// accessory light, a muted button — not a safety one. It is
    /// `stopCapture()`'s job to shut the microphone, and nothing may get in the
    /// way of that.
    private func handRouteBack(afterLinger: Bool) {
        lock.lock()
        isCapturing = false
        handbackGeneration += 1
        let generation = handbackGeneration
        let playbackBaseline = playbackFrameCount
        lock.unlock()

        guard afterLinger else {
            completeHandback(generation, attempt: 1, playbackBaseline: playbackBaseline)
            return
        }
        lingerThenComplete(generation, attempt: 1, playbackBaseline: playbackBaseline)
    }

    /// One linger, then one attempt. The re-linger paths — a refused apply, and
    /// received audio still arriving — funnel through here too, re-baselining
    /// the playback count so each linger judges only its own quiet.
    private func lingerThenComplete(_ generation: Int, attempt: Int, playbackBaseline: Int) {
        let linger = listeningLinger
        Task.detached { [weak self] in
            await linger()
            self?.completeHandback(
                generation, attempt: attempt, playbackBaseline: playbackBaseline)
        }
    }

    /// Attempts beyond this are pointless: five lingers is fifteen seconds,
    /// and a session that still refuses has something structurally wrong that
    /// the log now shows attempt by attempt.
    private static let maximumHandbackAttempts = 5

    /// The second half of ``handRouteBack(afterLinger:)``: discard the engine,
    /// then apply the listening policy.
    ///
    /// **The discard is the half that was missing on the first on-air try.**
    /// After any capture the engine carries an instantiated input audio unit,
    /// and restarting that engine for *received* audio — which is most of what
    /// happens between overs — re-raises an input route. On Bluetooth the only
    /// input route is HFP, so the accessory was pulled straight back into the
    /// call the hand-back had just ended, LED lit and button muted, every time
    /// the far side talked. A fresh engine is playback-only until the next
    /// capture instantiates its input — under the radio policy, which is
    /// `BU-1`'s ordering, preserved.
    ///
    /// A key-down can race the apply; the second locked check catches it. In
    /// that window the session is momentarily on listening under a live
    /// capture, and the capture's own retry path — reactivate, rebuild —
    /// repairs exactly that, so nothing is discarded under it here.
    private func completeHandback(_ generation: Int, attempt: Int, playbackBaseline: Int) {
        lock.lock()
        guard generation == handbackGeneration, !isCapturing,
            appliedPolicy != AudioSessionPolicy.listening
        else {
            lock.unlock()
            return
        }
        // Received audio arrived during the linger: the engine is carrying the
        // far side's reply, and the discard below would cut it off mid-word —
        // `playerNode.stop()` drops every scheduled buffer. Wait out another
        // linger; a linger that passes with nothing arriving is a queue that
        // has drained, because frames arrive faster than once per linger for
        // as long as anyone is talking. Bounded by the same attempt budget as
        // a refused apply, because the hand-back is what revives the button
        // (BU-14) and must not be deferrable forever.
        if playbackFrameCount != playbackBaseline, attempt < Self.maximumHandbackAttempts {
            let rebaselined = playbackFrameCount
            lock.unlock()
            Diagnostics.route(
                "audio hand-back deferred "
                    + "(attempt \(attempt)/\(Self.maximumHandbackAttempts)): "
                    + "received audio is still arriving")
            lingerThenComplete(generation, attempt: attempt + 1, playbackBaseline: rebaselined)
            return
        }
        // Discard *before* the apply: an engine with a running input unit is a
        // live recording client, exactly the kind of thing a session refuses a
        // category change under. Only an engine a capture has been attempted
        // on carries the input unit; one that has only played is already the
        // engine we want and is kept — as is everything, on a platform that
        // manages its own routes (see `discardsEngineOnHandback`). The fresh
        // engine is built eagerly rather than lazily on the next frame, because
        // `AudioPipeline` registers the SF-3 observers in its initialiser and a
        // gap with no pipeline would be a gap in route-change observation.
        let needsDiscard = discardsEngineOnHandback && captureAttemptedOnCurrent
        lock.unlock()

        if needsDiscard {
            // Built outside the lock: `AudioPipeline()` opens an AVAudioEngine,
            // and `enqueuePlayback` takes this lock fifty times a second — the
            // inbound path must not stall behind engine construction.
            let fresh = makePipeline()
            lock.lock()
            // Re-checked: a key-down may have raced the build, and a capture's
            // engine must not be pulled out from under it. The orphaned fresh
            // engine is simply released.
            if generation == handbackGeneration, !isCapturing, captureAttemptedOnCurrent {
                current?.stop()
                forwarder?.cancel()
                forwarder = nil
                _ = adoptLocked(fresh)
                Diagnostics.route("audio hand-back: capture engine discarded")
            }
            lock.unlock()
        }

        do {
            try applyPolicy(AudioSessionPolicy.listening)
        } catch {
            // Best effort by design — a failed hand-back is a quality
            // regression, not a safety one — but never silent (that cost an
            // on-air session), and never final: the refusal observed on air
            // was transient, so try again after another linger.
            Diagnostics.route(
                "audio hand-back to listening failed "
                    + "(attempt \(attempt)/\(Self.maximumHandbackAttempts)): \(error)")
            guard attempt < Self.maximumHandbackAttempts else { return }
            lock.lock()
            let rebaselined = playbackFrameCount
            lock.unlock()
            lingerThenComplete(generation, attempt: attempt + 1, playbackBaseline: rebaselined)
            return
        }

        lock.lock()
        // A key-down can race the apply; if one did, the session is
        // momentarily on listening under a live capture, and the capture's own
        // retry path — reactivate, rebuild — repairs exactly that.
        if generation == handbackGeneration, !isCapturing {
            appliedPolicy = AudioSessionPolicy.listening
        }
        lock.unlock()
        Diagnostics.route("audio route handed back to listening")
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
            // The route is on listening between overs (BU-17), which has no
            // input at all, so the hands-free profile has to be asked for
            // before the microphone can be opened. This is where the SCO link
            // comes up, which is what the accessory's light reports — and it
            // is a no-op inside the linger, which is what keeps SF-3's
            // drop-and-resume from re-triggering its own cascade.
            try escalateForCapture()
            let pipeline = pipeline()
            lock.lock()
            captureAttemptedOnCurrent = true
            lock.unlock()
            try pipeline.startCapture(onFrame: onFrame)
        } catch let first {
            do {
                try activateSession()
                let fresh = rebuildPipeline()
                lock.lock()
                captureAttemptedOnCurrent = true
                lock.unlock()
                try fresh.startCapture(onFrame: onFrame)
            } catch let second {
                // The key-down failed outright: nothing is capturing, so hand
                // the route back now rather than leaving the accessory in a
                // call nobody is having.
                handRouteBack(afterLinger: false)
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
        // Microphone shut first, route handed back second — after the linger,
        // never inline. The order matters twice over: the stop is the
        // safety-relevant half and must not wait on anything, and an inline
        // hand-back here is what turned SF-3's one drop into a loop (this is
        // also every SF-3 stop path, not only the operator's release).
        handRouteBack(afterLinger: true)
    }

    func enqueuePlayback(_ pcm: [Int16]) {
        lock.lock()
        playbackFrameCount += 1
        lock.unlock()
        pipeline().enqueuePlayback(pcm)
    }

    /// What the audio system thinks is true, in one line, for the failure alert.
    ///
    /// A hardware rate of 0 means the session is not really up; a live rate here
    /// beside a `converterUnavailable` from the engine means the session is fine
    /// and the *engine* is the stale one.
    var audioStateDescription: String { Self.audioStateDescription() }

    /// The one-line audio state. `static` because ``startCapture(onFrame:)``
    /// reaches it from a `catch` where building anything is the last thing
    /// wanted.
    static func audioStateDescription() -> String {
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
