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

/// What the connect-time input warm-up managed to do (`BU-22`, `BU-24`).
///
/// The warm-up is opportunistic and never fails a connect, so this is not an
/// error type and nothing branches on it to decide whether to carry on. It
/// exists so a warm-up that could not open the microphone leaves a mark an
/// operator or a device test can find, rather than only a silent first over
/// or a PTT failure with nothing in the session that says why.
///
/// See ``AudioIO/warmUpInput()``.
enum InputWarmUpOutcome: Equatable, Sendable {
    /// The input opened, was held past the route settling, and was closed
    /// again. The device is awake.
    case warmed

    /// The microphone could not be opened, described as the library described
    /// it.
    case couldNotOpenInput(String)

    var didWarm: Bool { self == .warmed }
}

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
    /// iOS shows the microphone prompt only when an app first *touches* the
    /// microphone — installs a tap and starts the engine — not when it sets
    /// and activates the session category, so `configureSession()` alone never
    /// triggers it. And until permission is granted the input node reports a
    /// sample rate of 0 Hz, which `AudioPipeline.startCapture` cannot build a
    /// converter from: without an explicit ask first, the app can never touch
    /// the microphone, so is never asked, so the rate never leaves 0.
    ///
    /// Returns `true` on macOS, which has no `AVAudioSession`: device selection
    /// there belongs to the user, and TCC is attributed to the host process.
    func requestRecordPermission() async -> Bool

    /// Prepares the audio session. Throws — an app that cannot configure its
    /// session cannot transmit, and pretending otherwise produces a PTT button
    /// that lights up and sends silence.
    func configureSession() throws

    /// Puts the session into the policy capture needs, without waiting for
    /// anything. Call before ``startCapture(onFrame:)``; then ``settleRoute()``.
    ///
    /// **`BU-15`.** Escalating to the radio policy is a route change, and so is
    /// opening the microphone; both must happen before the link is keyed —
    /// SF-3 correctly drops any transmission a route change lands on top of,
    /// so keying must wait until nothing is disturbing the route rather than
    /// racing it. ``settleRoute()`` is that wait.
    ///
    /// Deliberately not throwing. A failed escalation here is not the place to
    /// report it: ``startCapture(onFrame:)`` asks again and its failure path
    /// is the one that unkeys, alerts and describes the audio state.
    func prepareForCapture() async

    /// Waits until the route stops moving, having been disturbed by
    /// ``prepareForCapture()`` and ``startCapture(onFrame:)``.
    ///
    /// **Returns immediately when nothing was disturbed**, which is `BU-16`'s
    /// fast path: an over inside the hand-back linger finds the session
    /// already on radio and an engine whose input unit is already
    /// instantiated, so the far end is keyed with the press. The wait is paid
    /// on the first over after a pause and nowhere else.
    ///
    /// Bounded three ways and unable to stall a key-down for ever: see the
    /// implementation's constants.
    func settleRoute() async

    /// Opens the microphone. Frames arrive off the main thread, 50 a second,
    /// 160 samples each.
    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws

    /// Opens the input briefly, discards what it captures, and closes it, so
    /// that the device is awake before the first key-down (`BU-22`).
    ///
    /// **The fault it fixes.** The first over after the input device spins up
    /// is silent — no transmit meter, nothing at the far end — because the
    /// device itself takes a while to start producing signal after it opens;
    /// ``settleRoute()`` waits for the *route* to stop changing, which is a
    /// different thing, and does not cover this. The warm-up is the device's
    /// own wake-up, paid before a key-down is waiting on it rather than during
    /// one.
    ///
    /// **Deliberately not throwing.** A connection must not fail because the
    /// microphone could not be opened a few seconds before anybody asked to
    /// transmit — ``startCapture(onFrame:)`` owns the failure path for when
    /// somebody does. But it does report whether it worked (`BU-24`): a silent
    /// failure here is a first over that is silent, or a PTT that fails, with
    /// nothing in the session that says why. The outcome goes back to
    /// ``RadioSession``, which publishes it; the operator-facing failure stays
    /// on the key-down path, which fails closed and alerts.
    ///
    /// Rejected alternative: hold `OnAirGate` closed until the tap delivers a
    /// non-silent buffer. That would swallow a legitimately quiet start to an
    /// over — silence is not the same thing as a dead device, and the gate must
    /// not be taught to confuse them.
    @discardableResult
    func warmUpInput() async -> InputWarmUpOutcome

    /// Closes the microphone. Must be safe to call at any time, including
    /// before any capture has started and twice in a row — every one of the
    /// PTT release paths calls it without knowing what state it is in.
    func stopCapture()

    /// Queues received audio for playback.
    func enqueuePlayback(_ pcm: [Int16])

    /// How long the last ``startCapture(onFrame:)`` spent opening the
    /// microphone, in milliseconds.
    ///
    /// Diagnostic: `AudioPipelineIO.captureSlowThresholdNanoseconds` is
    /// conditioned on this measurement. Published by ``RadioSession`` on the
    /// transmit strip in DEBUG builds; no behaviour outside `AudioPipelineIO`
    /// may branch on it.
    var lastCaptureStartMilliseconds: Int { get }

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
/// has to fail closed — can be tested without a microphone. Narrower than
/// ``AudioIO`` on purpose: no permission, no session, just the engine.
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
/// first instantiated, and never revisits that decision. On iOS, an engine
/// whose input unit is instantiated while the session is still
/// `.soloAmbient` (playback only) reports an input sample rate of 0 Hz
/// forever, even after the session switches to `.playAndRecord` — and
/// `AudioConverterNew` refuses 0 Hz, so every PTT press for the rest of the
/// process fails with `converterUnavailable`. A fresh engine, built after the
/// session is up, reports the real hardware rate. So:
///
/// 1. The pipeline is created lazily, on first use — always after
///    ``configureSession()`` and after the microphone has been granted, never
///    at launch as a stored property of the composition root would be.
/// 2. ``startCapture(onFrame:)`` retries once on a freshly built pipeline: a
///    poisoned engine cannot recover, so discarding it is the only repair. The
///    second failure is reported with the audio state attached rather than
///    retried again.
///
/// ``signals`` therefore cannot be the pipeline's own stream — that one dies
/// with the pipeline it belongs to, and SF-3 with it. This class owns a durable
/// stream for the process's lifetime and forwards whichever pipeline is current
/// into it, so a rebuild is invisible to ``RadioSession``.
///
/// ### Why `stopCapture()` stops the whole engine
///
/// `AudioPipeline.stop()` tears down the microphone tap *and* stops the
/// engine, so it stops playback too. That is deliberate: this is half-duplex
/// push-to-talk, so there is nothing to receive while the microphone is open,
/// and `enqueuePlayback(_:)` restarts the engine on the next inbound frame.
/// The alternative — leaving the tap installed all the time and gating frames
/// in software — keeps the microphone (and the system's recording indicator)
/// live for the whole call, which this app must never give the impression of.
final class AudioPipelineIO: AudioIO, @unchecked Sendable {
    /// Both halves of a failed key-up, with the state of the audio system at the
    /// moment it failed.
    ///
    /// The operator sees this in the "Could not transmit" alert, the only
    /// diagnostic channel a radio in the field has. `converterUnavailable` on
    /// its own says only that CoreAudio said no — the numbers below say why,
    /// and in particular whether the session was healthy (a live hardware
    /// rate) when the engine claimed it was not.
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
    /// automatic resume after a route change — finds the session already on
    /// radio and does not re-apply the category. A redundant category change
    /// is not harmless: it is a fresh route-change cascade, and re-triggering
    /// one from inside its own recovery is a loop (`BU-17`).
    private var appliedPolicy: AudioSessionPolicy?

    /// Whether anything since the last ``settleRoute()`` actually moved the
    /// route: a category change that was really applied, or a capture opened
    /// on an engine whose input unit had not been instantiated yet. An over
    /// that does neither — every over inside the hand-back linger — must not
    /// wait for one (`BU-15`, and `BU-16`'s fast path).
    private var routeDisturbed = false

    /// ``routeChangeCount`` as it was when the disturbance began, so
    /// ``settleRoute()`` can tell "the cascade has not started" from "the
    /// cascade arrived while the microphone was opening".
    private var routeChangeBeforeDisturbance = 0

    /// Route-change signals forwarded to ``signals``, ever.
    ///
    /// ``prepareForCapture()`` watches this number rather than a clock: the
    /// question it has to answer is "has the cascade my own category change
    /// started finished?", and the only honest evidence for that is signals
    /// arriving and then not arriving. Counting them here rather than in
    /// ``RadioSession`` keeps the wait beside the switch that causes it.
    private var routeChangeCount = 0

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
    /// means the far side talked during the linger and the engine still holds
    /// their audio, so the discard waits out another linger rather than
    /// cutting the reply off mid-word. Not a clock: it observes arriving data.
    private var playbackFrameCount = 0

    /// Whether the hand-back discards a capture-bearing engine (see
    /// ``completeHandback(_:attempt:playbackBaseline:)``). Platform truth by
    /// default — restarting such an engine re-raises an input route, and on
    /// iOS the only Bluetooth input route is HFP, which re-mutes the
    /// accessory's button; macOS manages its own routes and gets the per-over
    /// SCO behaviour right by itself. Injectable so the discard logic stays
    /// testable on macOS.
    private let discardsEngineOnHandback: Bool

    /// One step of ``prepareForCapture()``'s wait. Injectable so the settle
    /// logic is testable without sleeping (AU-5) — the tests step it, the app
    /// sleeps it.
    private let settleTick: @Sendable () async -> Void

    /// A monotonic clock, for timing how long opening the microphone took. See
    /// ``captureSlowThresholdNanoseconds``. Injectable so the settle logic is
    /// testable without a real audio stack (AU-5).
    private let monotonicNanoseconds: @Sendable () -> UInt64

    /// How long the last ``startCapture(onFrame:)`` took to open the
    /// microphone. See ``captureSlowThresholdNanoseconds``.
    private var lastCaptureStartNanoseconds: UInt64 = 0

    /// SF-3, decoupled from any one pipeline's lifetime. See the type note.
    let signals: AsyncStream<AudioSessionSignal>
    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation

    /// The linger between the microphone closing and the route being handed
    /// back to listening (BU-17).
    ///
    /// macOS keeps SCO up for a while after the last capture client closes,
    /// and that linger is what makes its per-over HFP behaviour feel instant
    /// in a quick exchange. This reproduces it, a little longer, for a second
    /// reason macOS does not have: the drop-and-resume that SF-3 performs when
    /// the escalation's own route-change cascade lands mid-over must finish
    /// inside this window, so the resume re-keys into a session still on
    /// radio.
    static let listeningLingerNanoseconds: UInt64 = 3_000_000_000

    // MARK: The settle wait (BU-15)
    //
    // The cascade this waits out starts late relative to the disturbance, so a
    // wait that only looked for quiet would declare victory before it began and
    // hand the whole thing to SF-3 anyway — hence an onset budget separate from
    // the quiet window. And the cascade is dense, so the quiet window has to be
    // wider than any gap it contains internally.

    /// The granularity of the wait. Small enough that the quiet and onset
    /// windows below are expressible, large enough not to spin.
    static let settleTickNanoseconds: UInt64 = 60_000_000

    /// How long to keep waiting for the *first* signal before concluding that
    /// this switch is not going to produce one.
    ///
    /// **Under-shooting here re-creates the whole fault**: the wait gives up,
    /// the carrier goes up, the cascade arrives late, and SF-3 drops the
    /// transmission exactly as it did before — intermittently, which is worse
    /// than reliably. The trade is deliberate in this direction: latency the
    /// operator feels once per cold over, against an intermittent visible drop
    /// mid-over. It is the number to revisit first if the cold over is being
    /// made faster; `APP-24` would make the whole question rarer.
    static let settleOnsetTicks = 12

    /// How much quiet ends the cascade. Under-shooting here lets the tail land
    /// after the carrier is up, which is `BU-15` again.
    static let settleQuietTicks = 3

    /// How slow opening the microphone has to be before it counts as having
    /// brought something up — and therefore as having moved the route.
    ///
    /// **Carries macOS, not iOS.** On macOS `startCapture` blocks on the SCO
    /// link and the configuration change follows it, so the duration is the
    /// whole signal. On iOS capture is fast either way and this never fires —
    /// what fires there is the other half of ``settleRoute()``'s guard,
    /// because the escalation itself blocks the main actor while the forwarder
    /// (a detached task, and so not blocked) counts the cascade arriving. Both
    /// conditions are load-bearing; neither is redundant.
    static let captureSlowThresholdNanoseconds: UInt64 = 100_000_000

    /// How long the warm-up capture stays open once the route has settled
    /// (`BU-22`), on top of whatever ``settleRoute()`` spends getting there.
    ///
    /// **Argued rather than derived, and says so.** Some Bluetooth inputs
    /// deliver frames of exact zeros for well over a second after opening —
    /// nothing above the device can tell that from silence — and it is the
    /// *opening* that wakes the hardware, not holding it open until audio
    /// appears, so a hold shorter than the silence is enough. What
    /// distinguishes an input that has this fault from one that does not is
    /// not established; do not repeat a power-management story as though it
    /// were the finding. If a silent first over is seen again, establish first
    /// whether the warm-up ran at all (`input warmed` in the route log) and
    /// whether the device was still cold when it did — a warm-up that ran and
    /// did not work is a different fault from one that was too short.
    static let warmUpHoldTicks = 17

    /// The hard ceiling: 1.2 s, or half a second past the whole measured
    /// cascade. A route that will not stop changing is not something to wait
    /// on — the key-down proceeds and SF-3, which is untouched by any of this,
    /// resumes being the thing that protects the operator from it.
    static let settleCapTicks = 20

    init(
        makePipeline: @escaping @Sendable () -> CapturePipeline = { AudioPipeline() },
        applyPolicy: @escaping @Sendable (AudioSessionPolicy) throws -> Void = { policy in
            #if os(iOS)
                if policy == .radio {
                    try AudioPipeline.activateSession(policy)
                } else {
                    // Category-only, no `setActive(true)`: the session is
                    // already active when the route is handed back, and a
                    // redundant re-activation can be refused mid-shuffle
                    // (`'!pri'`, insufficient priority). A category change on
                    // an active session takes effect on its own. The values
                    // are still the library's policy, not a copy (RC-11).
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
        }(),
        settleTick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: AudioPipelineIO.settleTickNanoseconds)
        },
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.makePipeline = makePipeline
        self.applyPolicy = applyPolicy
        self.listeningLinger = listeningLinger
        self.discardsEngineOnHandback = discardsEngineOnHandback
        self.settleTick = settleTick
        self.monotonicNanoseconds = monotonicNanoseconds
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
        forwarder = Task.detached { [weak self] in
            for await event in events {
                if case .routeChanged = event { self?.noteRouteChange() }
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
        // Asking here (rather than returning `true` unconditionally) moves the
        // system dialog to connect time: the first *capture attempt* is what
        // would otherwise trigger it, and that press puts no audio on air.
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
        // nothing to drop. Without this, configuring the session pins the
        // route to HFP for the whole call: narrowband receive audio, and a PTT
        // button the accessory mutes for as long as that idle call is held.
        handRouteBack(afterLinger: false)
    }

    /// The session half of ``configureSession()``, on its own so the repair path
    /// in ``startCapture(onFrame:)`` can reach it without building an engine.
    ///
    /// **The policy is the library's** (RC-11): `AudioPipeline.activateSession()`
    /// is static, so reaching it does not mean owning a pipeline and therefore
    /// having built an engine — which is the ordering that must not be
    /// violated (see the type note).
    ///
    /// What is left here is the platform guard: `AVAudioSession` does not exist
    /// on macOS, where input and output device selection is the user's, via
    /// System Settings, and there is nothing for the app to configure.
    private func activateSession() throws {
        lock.lock()
        handbackGeneration += 1
        noteRouteDisturbanceLocked()
        lock.unlock()
        try applyPolicy(AudioSessionPolicy.radio)
        lock.lock()
        appliedPolicy = AudioSessionPolicy.radio
        lock.unlock()
    }

    // BU-17. The hand-back to listening happens on a *linger* rather than
    // inside `stopCapture()`, so SF-3's transient drop-and-resume completes
    // inside it and re-keys into a session still on radio, rather than
    // handing the route straight back and re-triggering the category-change
    // cascade every cycle. `BU-15` (below) removes the residual drop-and-
    // resume this still leaves on the first over after a hand-back, by moving
    // everything that disturbs the route to before anything is keyed, instead
    // of suppressing the cascade or SF-3 itself.
    //
    // Per-over route switching is worth this cost because some Bluetooth
    // accessories mute their own PTT notifications for as long as their
    // Classic side sits in an idle HFP call; handing the route back between
    // overs is what lets the button live. SF-3 is not suppressed anywhere in
    // this.

    /// ``routeChangeCount``, for the settle tests: they have to know the
    /// forwarder has *observed* a signal before stepping the clock, or they
    /// would be racing a detached task rather than testing a wait.
    var routeChangesObserved: Int {
        lock.lock()
        defer { lock.unlock() }
        return routeChangeCount
    }

    /// Runs the capture start and records how long it took, for
    /// ``settleRoute()``. Timed even when it throws: a capture that spent
    /// 800 ms on an SCO link and *then* failed moved the route just the same,
    /// and the repair path that follows will want it waited out.
    private func timingCaptureStart(_ start: () throws -> Void) throws {
        let began = monotonicNanoseconds()
        defer {
            let elapsed = monotonicNanoseconds() &- began
            lock.lock()
            lastCaptureStartNanoseconds = elapsed
            lock.unlock()
        }
        try start()
    }

    /// Records that something is about to move the route. Must be called with
    /// ``lock`` held. Only the *first* disturbance of a group stamps the
    /// baseline, so a category change followed by a first capture is one
    /// disturbance to be waited out once.
    private func noteRouteDisturbanceLocked() {
        if !routeDisturbed {
            routeDisturbed = true
            routeChangeBeforeDisturbance = routeChangeCount
        }
    }

    /// Counted from the forwarder, off the main actor. See
    /// ``routeChangeCount``.
    private func noteRouteChange() {
        lock.lock()
        routeChangeCount += 1
        lock.unlock()
    }

    /// **`BU-15`.** Escalate now, while nothing is on air. The wait for what
    /// that disturbs is ``settleRoute()``, after the microphone is open, so one
    /// wait covers the category change and the input unit's instantiation
    /// together rather than paying for each in turn.
    func prepareForCapture() async {
        do {
            try escalateForCapture()
        } catch {
            // Reported, not thrown: `startCapture(onFrame:)` asks again in a
            // moment and owns the failure path. Silence here would make a
            // refused escalation look like an ordinary cold over.
            Diagnostics.route("audio session escalation before key-down failed: \(error)")
        }
    }

    /// **`BU-15`.** Wait out the route-change cascade this over's own
    /// preparation caused, so the key-down that follows happens on a route that
    /// has stopped moving.
    ///
    /// One wait after both disturbances — the category change and opening the
    /// microphone, which itself posts a route change once the input unit comes
    /// up — rather than one after each: the microphone's cascade largely
    /// arrives while it is still opening, so waiting once costs little more
    /// than waiting for either alone.
    func settleRoute() async {
        lock.lock()
        let disturbed = routeDisturbed
        let baseline = routeChangeBeforeDisturbance
        let start = routeChangeCount
        let openingWasSlow = lastCaptureStartNanoseconds >= Self.captureSlowThresholdNanoseconds
        routeDisturbed = false
        lock.unlock()

        // Two ways to know the route moved, and either is enough.
        //
        // `start > baseline` — signals have **already** arrived since the
        // disturbance began. On iOS the category cascade can land while the
        // microphone is still opening, so this is the common case there.
        //
        // `openingWasSlow` — the microphone took long enough that the audio
        // stack must have brought something up: an input unit, or an SCO link.
        // This is what covers macOS, where the policy bookkeeping means nothing
        // but SCO really does have to come back between overs.
        //
        // Neither, and there is nothing to wait for. Every over inside the
        // hand-back linger takes that exit, which is what keeps `BU-16` intact —
        // as does a Mac on its built-in microphone, which brings nothing up.
        guard disturbed, start > baseline || openingWasSlow else { return }

        var seen = start
        // Signals that arrived while the microphone was opening mean the cascade
        // has already begun, so the onset budget is spent and what is left is to
        // wait for quiet. Waiting out an onset for a cascade that has been and
        // gone is dead air for nothing.
        var started = start > baseline
        /// The tick the last change was seen on; 0 for "none during this wait",
        /// which is also where quiet is measured from for a cascade that began
        /// before it.
        var lastChange = 0
        var ticks = 0
        while ticks < Self.settleCapTicks {
            await settleTick()
            ticks += 1
            lock.lock()
            let now = routeChangeCount
            lock.unlock()
            if now != seen {
                seen = now
                started = true
                lastChange = ticks
                continue
            }
            if !started {
                guard ticks < Self.settleOnsetTicks else { break }
            } else if ticks - lastChange >= Self.settleQuietTicks {
                break
            }
        }
        Diagnostics.route(
            "audio route settled before key-down: \(seen - baseline) route changes in "
                + "\(ticks) x \(Self.settleTickNanoseconds / 1_000_000)ms")
    }

    /// Ask for the radio policy before opening the microphone, skipping the
    /// category change when the session is already there — see
    /// ``appliedPolicy`` for why the skip is load-bearing, not an optimisation.
    private func escalateForCapture() throws {
        lock.lock()
        handbackGeneration += 1
        isCapturing = true
        let alreadyRadio = appliedPolicy == AudioSessionPolicy.radio
        if !alreadyRadio { noteRouteDisturbanceLocked() }
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
    /// **The discard matters.** After any capture the engine carries an
    /// instantiated input audio unit, and restarting that engine for
    /// *received* audio — which is most of what happens between overs —
    /// re-raises an input route. On Bluetooth the only input route is HFP, so
    /// the accessory would be pulled straight back into the call the hand-back
    /// had just ended, LED lit and button muted, every time the far side
    /// talked. A fresh engine is playback-only until the next capture
    /// instantiates its input — under the radio policy, which is `BU-1`'s
    /// ordering, preserved.
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

    /// Opens the microphone: everything a first over would otherwise do at
    /// key-down (escalate, open the microphone, wait out the cascade), except
    /// with no over at stake, plus the hold at the end that a key-down does
    /// not pay (`BU-22`). The captured frames are dropped on the floor —
    /// nothing is keyed, so ``RadioSession`` never sees them, which keeps the
    /// transmit meter honest about only having shown what left.
    ///
    /// Closing through ``stopCapture()`` puts this on the ordinary hand-back
    /// path, so an operator who keys up straight away still takes `BU-16`'s
    /// fast path into a device that is now awake.
    @discardableResult
    func warmUpInput() async -> InputWarmUpOutcome {
        await prepareForCapture()
        do {
            try startCapture { _ in }
        } catch {
            // Opportunistic: the connection is not failed over this, and the
            // key-down path asks again with the failure handling that matters.
            Diagnostics.route("input warm-up could not open the microphone: \(error)")
            return .couldNotOpenInput("\(error)")
        }
        await settleRoute()
        for _ in 0..<Self.warmUpHoldTicks {
            await settleTick()
        }
        stopCapture()
        Diagnostics.route(
            "input warmed for \(Self.warmUpHoldTicks * Int(Self.settleTickNanoseconds / 1_000_000))ms "
                + "past settle: \(Self.audioStateDescription())")
        return .warmed
    }

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
            // **The second half of `BU-15`.** The first capture on an engine
            // instantiates its input audio unit, which posts a route change of
            // its own — a disturbance for `settleRoute()` to wait out, exactly
            // like the category change. A later capture on the same engine is
            // not: the unit is already there.
            if !captureAttemptedOnCurrent { noteRouteDisturbanceLocked() }
            captureAttemptedOnCurrent = true
            lock.unlock()
            try timingCaptureStart { try pipeline.startCapture(onFrame: onFrame) }
        } catch let first {
            do {
                try activateSession()
                let fresh = rebuildPipeline()
                lock.lock()
                // A repair re-applies the policy *and* builds a new engine, so
                // it disturbs the route twice over.
                noteRouteDisturbanceLocked()
                captureAttemptedOnCurrent = true
                lock.unlock()
                try timingCaptureStart { try fresh.startCapture(onFrame: onFrame) }
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

    var lastCaptureStartMilliseconds: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(lastCaptureStartNanoseconds / 1_000_000)
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
