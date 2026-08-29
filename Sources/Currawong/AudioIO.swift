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
/// exists so that a warm-up that could not open the microphone leaves a mark
/// somewhere an operator or a device test can find, instead of only in a
/// diagnostic log: without one, its consequence — a silent first over, or a PTT
/// that fails — arrives with nothing in the session that says why.
///
/// See ``AudioIO/warmUpInput()``.
enum InputWarmUpOutcome: Equatable, Sendable {
    /// The input opened, was held past the route settling, and was closed
    /// again. The device is awake.
    case warmed

    /// The microphone could not be opened, described as the library described
    /// it. **Reachable for the first time since RC-15**: the interesting
    /// failure used to be an Objective-C `NSException` that terminated the
    /// process rather than an error anything could catch (`BU-24`).
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

    /// Puts the session into the policy capture needs, without waiting for
    /// anything. Call before ``startCapture(onFrame:)``; then ``settleRoute()``.
    ///
    /// **`BU-15`.** Escalating to the radio policy is a route change, and so is
    /// opening the microphone. Both used to happen after the link was keyed, so
    /// SF-3 — correctly, and non-negotiably — dropped the transmission they were
    /// enabling. The fix is the ordering: everything that disturbs the route
    /// happens first, ``settleRoute()`` waits for the disturbance to finish, and
    /// only then is anything keyed. There is no transmission to drop while it is
    /// going on, so nothing is suppressed and no route change has to be told
    /// apart from an unplugged accessory.
    ///
    /// Deliberately not throwing. A failed escalation here is not the place to
    /// report it: ``startCapture(onFrame:)`` asks again and its failure path
    /// is the one that unkeys, alerts and describes the audio state.
    func prepareForCapture() async

    /// Waits until the route stops moving, having been disturbed by
    /// ``prepareForCapture()`` and ``startCapture(onFrame:)``.
    ///
    /// **Returns immediately when nothing was disturbed**, which is what keeps
    /// `BU-16`'s fast path: an over inside the hand-back linger finds the
    /// session already on radio and an engine whose input unit is already
    /// instantiated, so there is no cascade to wait for and the far end is
    /// keyed with the press. The wait is paid on the first over after a pause
    /// and nowhere else.
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
    /// is silent: no transmit meter, and nothing at the far end. Overs 2..n are
    /// normal. The silent one is always the one preceded by an escalation —
    /// i.e. the one where the device had just been opened — and about a second
    /// elapsed between the two, so it is not a race ``settleRoute()`` is
    /// losing: that waits for the *route* to stop changing, which it had, and
    /// it does not wait for the device to produce signal. Corroborated off the
    /// app entirely, in a different process: a scratch tool driving the library
    /// directly got four seconds of exact zeros on its first run and normal
    /// room noise moments later. The warm-up is the device's, and no amount of
    /// app-side bookkeeping can see it as anything but silence.
    ///
    /// **This is `BU-2`'s shape one layer down**, and takes `BU-2`'s fix: that
    /// one was the macOS permission prompt, and moving the ask to connect time
    /// put it "where the operator is already waiting and no over is at stake".
    /// The same sentence holds with *device warm-up* in place of *permission*.
    ///
    /// **Deliberately not throwing. It does report whether it worked, and that
    /// is `BU-24`.** A warm-up is opportunistic — a connection must not fail
    /// because the microphone could not be opened a few seconds before anybody
    /// asked to transmit, and ``startCapture(onFrame:)`` owns the failure path
    /// for when somebody does — but "opportunistic" is not the same as
    /// "invisible", and it used to be both.
    ///
    /// Reporting it costs nothing and settles a real question. Until RC-15 the
    /// interesting failure here could not be caught at all: `installTap`
    /// rejected a format the input device had moved on from by raising an
    /// Objective-C `NSException`, which took the process with it — through this
    /// `do/catch`, which exists precisely to tolerate it. The library reports
    /// that as a Swift error now, so this path is reachable for the first time
    /// and wants a deliberate answer rather than a `return`.
    ///
    /// **The answer is: the connect continues, and the failure is recorded.**
    /// Failing the connect would be wrong — receiving is most of what a
    /// connection is for, and the microphone is asked for again at key-down,
    /// behind ``startCapture(onFrame:)``'s reactivate-and-rebuild repair. But a
    /// silent failure here is a first over that is silent (`BU-22`'s fault,
    /// returning) or a PTT that fails, with nothing in the session that says
    /// why. So the outcome goes back to ``RadioSession``, which publishes it;
    /// the operator-facing failure stays where it belongs, on the key-down path
    /// that fails closed and alerts.
    ///
    /// Rejected alternative, recorded because it is the obvious one: hold
    /// `OnAirGate` closed until the tap delivers a non-silent buffer. It fixes
    /// the symptom and breaks something real — a legitimately quiet start to an
    /// over would be swallowed, and an operator whose first word is soft would
    /// key up into nothing. Silence is not the same thing as a dead device, and
    /// the gate must not be taught to confuse them.
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
    /// Diagnostic, and the evidence for
    /// `AudioPipelineIO.captureSlowThresholdNanoseconds` — which is the one
    /// number the `BU-15` wait is conditioned on, so it should be a measurement
    /// rather than an inference. Published by ``RadioSession`` on the transmit
    /// strip in DEBUG builds; no behaviour outside `AudioPipelineIO` may branch
    /// on it.
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

    /// Whether anything since the last ``settleRoute()`` actually moved the
    /// route: a category change that was really applied, or a capture opened on
    /// an engine whose input unit had not been instantiated yet. Those are the
    /// two things measured to produce a cascade, and an over that does neither
    /// — every over inside the hand-back linger — must not wait for one
    /// (`BU-15`, and `BU-16`'s fast path).
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
    /// macOS keeps SCO up for ~2.1 s after the last capture client closes
    /// (measured 2026-08-22), and that linger is what makes its per-over HFP
    /// behaviour feel instant in a quick exchange. This reproduces it, a little
    /// longer, for a second reason macOS does not have: the drop-and-resume
    /// that SF-3 performs when the escalation's own route-change cascade lands
    /// mid-over takes up to ~1 s (300 ms settle plus engine start plus the
    /// cascade tail), and the hand-back must comfortably outlast it so the
    /// resume re-keys into a session still on radio.
    static let listeningLingerNanoseconds: UInt64 = 3_000_000_000

    // MARK: The settle wait (BU-15)
    //
    // All four numbers come from holds measured on melchior on 2026-08-23, no
    // accessory attached. The one the fix was finally built against, read out
    // of the app's own instrument by `BU15FirstOverUITests` (times in ms from
    // the press):
    //
    //     press@0  escalate@16  mic@518   ... the microphone takes ~500 ms
    //     signal@851, 859, 861             ... 333 ms after the mic, 8 ms apart
    //     settled@1083  carrier@1089       ... one key-down, and it stays
    //
    // Two things in that shape decide the constants. **The cascade starts late**
    // — 290, 333 and 534 ms after the disturbance across four runs — so a wait
    // that only looked for quiet would declare victory before it began and hand
    // the whole thing to SF-3 anyway; hence an onset budget separate from the
    // quiet window. **And it is dense** — 8 to 140 ms between signals — so the
    // quiet window has to be wider than any gap the cascade itself contains.

    /// The granularity of the wait. Small enough that the quiet and onset
    /// windows below are expressible, large enough not to spin.
    static let settleTickNanoseconds: UInt64 = 60_000_000

    /// How long to keep waiting for the *first* signal before concluding that
    /// this switch is not going to produce one.
    ///
    /// 720 ms nominal, against onsets of 290, 333 and 534 ms measured across
    /// several runs on melchior — deliberately several times the spread, because
    /// **under-shooting here re-creates the whole fault**: the wait gives up, the
    /// carrier goes up, the cascade arrives late, and SF-3 drops the
    /// transmission exactly as it did before. Intermittently, which is worse
    /// than reliably.
    ///
    /// **This is the wait's one real cost, and it has been paid on air.** A
    /// macOS run on 2026-08-23 opened the microphone in 111 ms — 11 ms past
    /// ``captureSlowThresholdNanoseconds``, because SCO was already up from an
    /// earlier session — and then saw **no signals at all**, so it spent the
    /// whole budget, ~850 ms of wall clock, waiting for a cascade that was never
    /// coming. One key-down, no dance, and 850 ms of latency for nothing.
    ///
    /// The trade is deliberate in this direction: latency the operator feels
    /// once per cold over, against an intermittent visible drop mid-over. But it
    /// is the number to revisit first if the cold over is being made faster, and
    /// `APP-24` is the change that would make the whole question rarer by making
    /// cold overs rare.
    static let settleOnsetTicks = 12

    /// How much quiet ends the cascade. 180 ms, comfortably past the 8–140 ms
    /// spacing measured within it. Under-shooting here lets the tail land after
    /// the carrier is up, which is `BU-15` again.
    static let settleQuietTicks = 3

    /// How slow opening the microphone has to be before it counts as having
    /// **brought something up** — and therefore as having moved the route.
    ///
    /// Measured, 2026-08-23, by carrying the capture-start duration out of the
    /// app on the transmit strip (`micMs` in `BU15FirstOverUITests`'s trace) —
    /// which had to be instrumented, because the timeline in `holdTrace` cannot
    /// show it: its gaps bracket the escalation and this wait as well.
    ///
    /// | | cold over | warm over |
    /// |---|---|---|
    /// | iOS, built-in mic | 16 ms | 0 ms |
    /// | macOS, Q2L as the route | 798 ms, and 111 ms with SCO already up | 1 ms |
    ///
    /// **So this threshold is what carries macOS, and it is not what carries
    /// iOS.** On macOS `startCapture` blocks on the SCO link and the
    /// configuration change follows it, so the duration is the whole signal. On
    /// iOS capture is fast either way and this never fires — what fires there is
    /// the other half of ``settleRoute()``'s guard, because the escalation
    /// itself blocks the main actor for ~480 ms while the forwarder (a detached
    /// task, and so not blocked) counts the cascade arriving. Both conditions
    /// are load-bearing; neither is redundant.
    ///
    /// 100 ms is an order of magnitude above every warm figure and comfortably
    /// below the cold ones. **The 111 ms case is the one to watch**: it is 11 ms
    /// over, and it bought a full onset budget — see ``settleOnsetTicks``.
    static let captureSlowThresholdNanoseconds: UInt64 = 100_000_000

    /// How long the warm-up capture stays open once the route has settled
    /// (`BU-22`), on top of whatever ``settleRoute()`` spends getting there.
    ///
    /// **This one number is argued rather than derived, and says so.** Every
    /// other constant here came off a recorded hold. What was measured for this
    /// one (melchior, 2026-08-28, `experiment-data/bu22-input-warmup.txt`) is
    /// the fault and the fix, not the duration:
    ///
    /// | cold Bluetooth input, this code path | |
    /// |---|---|
    /// | warm-up capture | frames from 178 ms, **audio only from 1574 ms** |
    /// | the next open, 1.5 s later | **audio in the first frame, 151 ms** |
    ///
    /// Nearly a second and a half of zeros *with frames arriving the whole
    /// time* — which is why nothing above the device can tell it from silence —
    /// and then, after the warm-up, audio immediately. Note that the fault is a
    /// **Bluetooth** one: a USB webcam is permanently powered and showed nothing
    /// at all, which is why it would not reproduce on demand during the day.
    ///
    /// **What that pair could not settle was this number**: the 1.6 s warm-up
    /// *outlasted* the 1574 ms, so it did not separate "opening the device wakes
    /// it" from "holding it open until audio appears wakes it" — and if it were
    /// the latter, 1020 ms would be short. A second measurement settled it. On a
    /// cold device, a **0.8 s warm-up that never saw audio itself** (35 frames,
    /// every one of them zero) still left the next open carrying audio 98 ms in,
    /// against roughly 1400 ms cold. It is the opening that wakes the hardware,
    /// so a hold shorter than the silence is enough — and in this class the hold
    /// is paid on top of a ``settleRoute()`` that spends most of a second on a
    /// cold SCO open anyway.
    ///
    /// **The second device, 2026-08-29: a TIDRADIO Q2L, and it does not have the
    /// fault at all.** Three trials — 20 minutes idle as the default input, 10
    /// minutes idle with the default moved away so macOS released the audio
    /// profile, and a genuine power cycle measured within a second of the device
    /// reappearing — all delivered audio in the *first frame*: 265–279 ms to
    /// that frame, 0–1 ms from it to audio. Against cold AirPods' 1574 ms of
    /// exact zeros, this device sits with the USB webcam.
    ///
    /// So the fault is not simply "Bluetooth" — but **what distinguishes the two
    /// devices is not established.** What was measured is behaviour: one input
    /// delivered frames of exact zeros for 1574 ms after the open, another
    /// delivered audio in its first frame. Why is unknown, and there are several
    /// candidates that no measurement here separates — SCO setup timing, profile
    /// switching, the device's own DSP or AGC start-up, noise gating, or the
    /// link simply being kept active. Do not repeat a power-management story as
    /// though it were the finding. **That does not argue for removing this
    /// warm-up** — it costs a device like the Q2L
    /// nothing it was not already paying, since the hold sits on top of a
    /// ``settleRoute()`` the cold SCO open dominates — but it does mean a second
    /// device failing to reproduce a silent first over says nothing about
    /// whether the number is right. Only an AirPods-class input tests it.
    ///
    /// If a silent first over is ever seen again after this, **do not simply
    /// raise this number**: the thing to establish first is whether the
    /// warm-up ran at all (`input warmed` in the route log) and whether the
    /// device was still cold when it did. A warm-up that ran and did not work
    /// is a different fault from one that was too short.
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
        noteRouteDisturbanceLocked()
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
    // cascade, convergence. The residual cost was one `BU-15`-style drop-and-
    // resume on the first over after each hand-back, which is SF-3 performing
    // exactly as specified and is the same dance macOS does on a cold SCO link.
    //
    // **`BU-15` removed that residual on 2026-08-23**, and note *how*, because
    // it is the same discipline as the paragraph above: not by suppressing the
    // cascade, but by moving everything that causes one — this escalation, and
    // the microphone opening — to before anything is keyed. See
    // `prepareForCapture()` and `settleRoute()`.
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
    /// Measured on melchior, 2026-08-23, with no accessory attached — and the
    /// measurement is why this is one wait after both disturbances rather than
    /// one after each:
    ///
    /// ```
    /// press@0  escalate@19   category cascade@553,559,569   settled@797
    /// carrier@801  mic@801   on air@1179   ROUTE CHANGE@1242,1261   ← dropped
    /// ```
    ///
    /// The first fix caught the category cascade and the dance survived: opening
    /// the microphone posts a route change of its own, 63 ms after the input
    /// unit comes up, and the original diagnosis had folded that into the
    /// category change. The microphone takes ~380 ms to open, which the category
    /// cascade largely arrives during — so disturbing both and then waiting once
    /// costs little more than waiting for either.
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
    /// `BU-22`. See the protocol requirement for the fault and why it is fixed
    /// here rather than at the gate.
    ///
    /// Everything it does, the first over would otherwise do at key-down:
    /// escalate, open the microphone, wait out the cascade. The point is only
    /// *when* — with no over at stake — plus the hold at the end, which is the
    /// part a key-down does not do and the reason the first over was silent.
    ///
    /// The captured frames are dropped on the floor. Nothing is keyed, so there
    /// is nowhere for them to go; `RadioSession` does not even see them, which
    /// keeps the transmit meter honest about having shown only what left.
    ///
    /// Closing through ``stopCapture()`` puts this on the ordinary hand-back
    /// path: the route goes back to listening after the usual linger, so an
    /// operator who keys up straight away still takes `BU-16`'s fast path into
    /// a device that is now awake. On iOS the hand-back also discards the
    /// engine the capture was attempted on, which is a cost this pays once per
    /// connect and is worth it — the warm-up is the *device's*, and survives
    /// the engine that woke it.
    @discardableResult
    func warmUpInput() async -> InputWarmUpOutcome {
        await prepareForCapture()
        do {
            try startCapture { _ in }
        } catch {
            // Opportunistic: the connection is not failed over this, and the
            // key-down path asks again with the failure handling that matters.
            // Reported rather than swallowed, though — see the protocol
            // requirement, and `BU-24` for what used to happen instead of an
            // error arriving here at all.
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
            // instantiates its input audio unit, and that posts a route change
            // of its own — measured 63 ms after the microphone came up, which is
            // what survived the first attempt at this fix. So it is a
            // disturbance for `settleRoute()` to wait out, exactly like the
            // category change. A later capture on the same engine is not: the
            // unit is already there.
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
