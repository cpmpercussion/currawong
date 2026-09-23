// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

#if os(iOS)
import AVFAudio
#else
// `AVCaptureDevice`, for the macOS microphone permission.
import AVFoundation
#endif

/// What ``AudioIO/warmUpInput()`` managed to do (BU-22, BU-24).
///
/// Not an error, and nothing branches on it: it exists so a failed warm-up
/// leaves a mark in the session rather than only a silent first over.
enum InputWarmUpOutcome: Equatable, Sendable {
    /// The input opened, was held past the route settling, and was closed.
    case warmed

    /// The microphone could not be opened, in the library's words.
    case couldNotOpenInput(String)

    var didWarm: Bool { self == .warmed }
}

/// The app's view of the audio hardware: the seam that lets ``RadioSession``
/// be tested without a microphone, since `RadioCore.AudioPipeline` opens
/// `AVAudioEngine` in its initialiser. Only what the transmit path needs, in
/// `RadioCore` vocabulary; not a general audio abstraction.
protocol AudioIO: AnyObject, Sendable {
    /// SF-3. Interruptions and route changes. The pipeline deliberately does
    /// not act on these itself; ``RadioSession`` must, and does.
    var signals: AsyncStream<AudioSessionSignal> { get }

    /// Asks for microphone access. Must be awaited before ``configureSession()``.
    ///
    /// iOS prompts only when the microphone is first touched, and until access
    /// is granted the input reports 0 Hz, which capture cannot build a
    /// converter from. Without this explicit ask the microphone is never
    /// touched, so the prompt never appears and the rate never leaves 0.
    func requestRecordPermission() async -> Bool

    /// Prepares the audio session. Throws, because an app that cannot configure
    /// its session cannot transmit, and must not show a PTT button that sends
    /// silence.
    func configureSession() throws

    /// Puts the session into the capture policy, without waiting. Call before
    /// ``startCapture(onFrame:)``, then ``settleRoute()``.
    ///
    /// Escalating and opening the microphone are both route changes, and SF-3
    /// drops any transmission a route change lands on, so both happen before
    /// keying (BU-15). Not throwing: ``startCapture(onFrame:)`` asks again and
    /// owns the failure path.
    func prepareForCapture() async

    /// Waits until the route disturbed by ``prepareForCapture()`` and
    /// ``startCapture(onFrame:)`` stops moving. Bounded; see the
    /// implementation's constants.
    ///
    /// Returns at once when nothing was disturbed, as for any over inside the
    /// hand-back linger (BU-16's fast path), so only a cold over pays for it.
    func settleRoute() async

    /// Opens the microphone. Frames arrive off the main thread, 50 a second,
    /// 160 samples each.
    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws

    /// Opens the input briefly and closes it, so the device is awake before
    /// the first key-down (BU-22). Some inputs produce no signal for a while
    /// after opening, which ``settleRoute()`` does not cover: it waits for the
    /// route, not the device.
    ///
    /// Not throwing, since a connection must not fail over this, but the
    /// outcome is returned for ``RadioSession`` to publish (BU-24). Do not
    /// instead gate on a non-silent buffer: a quiet start to an over is not a
    /// dead device.
    @discardableResult
    func warmUpInput() async -> InputWarmUpOutcome

    /// Closes the microphone. Safe to call at any time, including before any
    /// capture and twice in a row: every PTT release path calls it blind.
    func stopCapture()

    /// Queues received audio for playback.
    func enqueuePlayback(_ pcm: [Int16])

    /// How long the last ``startCapture(onFrame:)`` spent opening the
    /// microphone, in milliseconds. Diagnostic (shown in DEBUG builds); nothing
    /// outside `AudioPipelineIO` may branch on it.
    var lastCaptureStartMilliseconds: Int { get }

    /// The audio system's state in one line, for the key/unkey log (BU-13).
    /// Diagnostic: nothing may branch on it.
    var audioStateDescription: String { get }
}

/// The engine half of ``AudioPipelineIO``, as a seam, so its rebuild-and-retry
/// logic can be tested without a microphone. `RadioCore.AudioPipeline`
/// conforms in production.
///
/// No `configureSession()`: the session must be settled before an engine
/// exists, so ``AudioPipelineIO`` configures it itself.
protocol CapturePipeline: AnyObject, Sendable {
    var signals: AsyncStream<AudioSessionSignal> { get }
    func startCapture(onFrame: @escaping ([Int16]) -> Void) throws
    func stop()
    func enqueuePlayback(_ pcm: [Int16])
}

extension AudioPipeline: CapturePipeline {}

/// The production ``AudioIO``: one `RadioCore.AudioPipeline` at a time.
///
/// `AVAudioEngine` fixes its input format when its input unit is first
/// instantiated. On iOS, an engine whose input comes up under a playback-only
/// category reports 0 Hz for ever, and every PTT press then fails with
/// `converterUnavailable`. So the pipeline is built lazily, after the session
/// is configured and the microphone granted, and ``startCapture(onFrame:)``
/// retries once on a fresh pipeline, since a poisoned engine cannot recover.
///
/// Because pipelines are replaced, ``signals`` is a durable stream that
/// forwards whichever pipeline is current. The pipeline's own stream dies with
/// it, and SF-3 would die with it.
///
/// ``stopCapture()`` stops the whole engine, playback included: this is
/// half-duplex, and `enqueuePlayback(_:)` restarts it. Leaving the tap
/// installed and gating in software would keep the microphone, and the
/// recording indicator, live for the whole call.
final class AudioPipelineIO: AudioIO, @unchecked Sendable {
    /// Both attempts of a failed key-up, with the audio state when it failed.
    /// Shown in the "Could not transmit" alert, the only diagnostic channel a
    /// radio in the field has.
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

    /// Applies an audio-session policy (RC-12). Injectable for tests (AU-5);
    /// does nothing on macOS, where CoreAudio manages the route itself.
    private let applyPolicy: @Sendable (AudioSessionPolicy) throws -> Void

    /// The wait before the route is handed back to listening; see
    /// ``listeningLingerNanoseconds``. Injectable so tests can step it.
    private let listeningLinger: @Sendable () async -> Void

    /// Guards ``current``, ``forwarder`` and the state below. A lock rather
    /// than main-actor isolation: `stopCapture()`, which every safety path
    /// calls, must not depend on its caller, and the hand-back runs detached.
    private let lock = NSLock()
    private var current: CapturePipeline?
    private var forwarder: Task<Void, Never>?

    /// The policy last applied, so an over inside the linger does not re-apply
    /// the category. A redundant category change is a fresh route-change
    /// cascade, and triggering one from inside SF-3's resume is a loop (BU-17).
    private var appliedPolicy: AudioSessionPolicy?

    /// Whether anything since the last ``settleRoute()`` moved the route: an
    /// applied category change, or a first capture on an engine.
    private var routeDisturbed = false

    /// ``routeChangeCount`` when the disturbance began, so ``settleRoute()``
    /// can tell a cascade that has not started from one that already arrived.
    private var routeChangeBeforeDisturbance = 0

    /// Route-change signals forwarded to ``signals``, ever. ``settleRoute()``
    /// watches this rather than a clock: a cascade has ended when signals stop
    /// arriving.
    private var routeChangeCount = 0

    /// True between ``startCapture(onFrame:)`` and ``stopCapture()``. A linger
    /// expiring while it is true must not touch the session.
    private var isCapturing = false

    /// Whether a capture has been attempted on the current engine. The attempt,
    /// not success, instantiates the input unit, and an engine carrying one is
    /// what the hand-back discards.
    private var captureAttemptedOnCurrent = false

    /// Cancels stale hand-backs: every escalation and every new hand-back bumps
    /// it, and a lingered task only acts if its generation is still current.
    private var handbackGeneration = 0

    /// Frames handed to ``enqueuePlayback(_:)``, ever. If it moved during a
    /// linger, the far side is talking, and the hand-back waits another linger
    /// rather than cut the reply off.
    private var playbackFrameCount = 0

    /// Whether the hand-back discards a capture-bearing engine (see
    /// ``completeHandback(_:attempt:playbackBaseline:)``). True on iOS only;
    /// injectable so the logic is testable on macOS.
    private let discardsEngineOnHandback: Bool

    /// One step of ``settleRoute()``'s wait. Injectable so tests step it (AU-5).
    private let settleTick: @Sendable () async -> Void

    /// A monotonic clock, for ``captureSlowThresholdNanoseconds``. Injectable
    /// for tests (AU-5).
    private let monotonicNanoseconds: @Sendable () -> UInt64

    /// How long the last ``startCapture(onFrame:)`` took to open the
    /// microphone. See ``captureSlowThresholdNanoseconds``.
    private var lastCaptureStartNanoseconds: UInt64 = 0

    /// SF-3, decoupled from any one pipeline's lifetime. See the type note.
    let signals: AsyncStream<AudioSessionSignal>
    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation

    /// The linger between the microphone closing and the route being handed
    /// back to listening (BU-17). It keeps quick exchanges on the radio route,
    /// as macOS does with SCO, and SF-3's drop-and-resume must finish inside
    /// it so the resume re-keys into a session still on radio.
    static let listeningLingerNanoseconds: UInt64 = 3_000_000_000

    // MARK: The settle wait (BU-15)
    //
    // The cascade starts late, so there is an onset budget as well as a quiet
    // window: waiting only for quiet would finish before it began.

    /// The granularity of the wait. Small enough that the quiet and onset
    /// windows below are expressible, large enough not to spin.
    static let settleTickNanoseconds: UInt64 = 60_000_000

    /// How long to wait for the first signal before concluding there will be
    /// none. Too short and the cascade lands after keying, and SF-3 drops the
    /// over intermittently; the cost of erring long is latency once per cold
    /// over.
    static let settleOnsetTicks = 12

    /// How much quiet ends the cascade. Too short lets its tail land after
    /// keying (BU-15).
    static let settleQuietTicks = 3

    /// How slow opening the microphone must be to count as having moved the
    /// route. This is the signal on macOS, where capture blocks on the SCO
    /// link; on iOS capture is fast, and the route-change count is the signal
    /// instead. ``settleRoute()`` needs both.
    static let captureSlowThresholdNanoseconds: UInt64 = 100_000_000

    /// How long the warm-up stays open after the route settles (BU-22). Argued,
    /// not derived: opening is what wakes the device, so the hold need not
    /// outlast its silence. If a silent first over recurs, check the route log
    /// for `input warmed` before changing this.
    static let warmUpHoldTicks = 17

    /// The ceiling, 1.2 s. A route that will not stop changing is not waited
    /// on: the key-down proceeds, and SF-3 still protects the operator.
    static let settleCapTicks = 20

    init(
        makePipeline: @escaping @Sendable () -> CapturePipeline = { AudioPipeline() },
        applyPolicy: @escaping @Sendable (AudioSessionPolicy) throws -> Void = { policy in
            #if os(iOS)
                if policy == .radio {
                    try AudioPipeline.activateSession(policy)
                } else {
                    // Category only: the session is already active, and a
                    // redundant `setActive(true)` can be refused mid-shuffle
                    // (`'!pri'`). The values are the library's policy (RC-11).
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

    /// Throws the current pipeline away and builds a replacement. The old one
    /// is stopped first: dropped with a live tap, it is an open microphone
    /// nobody holds.
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
        // Forward, never finish: finishing the durable stream when this
        // pipeline goes would end SF-3 observation for the process.
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
        // Answers instantly once decided, without re-prompting, so every
        // connect can safely be gated on it.
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
        // Asking at connect moves the system dialog off the first press, which
        // would otherwise put no audio on air. `AVCaptureDevice`, because
        // `AVAudioApplication` is iOS-only; the sandbox's
        // `com.apple.security.device.audio-input` entitlement allows the access,
        // and this asks TCC for it.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            // Denied or restricted.
            return false
        }
        #endif
    }

    /// Puts the shared session into the category a half-duplex radio needs, and
    /// activates it.
    func configureSession() throws {
        try activateSession()

        // Build the engine now, under the radio policy: `AudioPipeline.init`
        // registers the SF-3 observers, which should listen from the moment the
        // session exists, and an engine built under a playback-only category
        // reports 0 Hz for ever (BU-1).
        _ = pipeline()

        // Then hand the route straight back to listening (BU-17): nothing is on
        // air, so no linger is needed. Left on radio, the route stays on HFP
        // for the whole call, with narrowband receive audio and an accessory
        // that mutes its PTT button.
        handRouteBack(afterLinger: false)
    }

    /// The session half of ``configureSession()``, separate so the repair path
    /// in ``startCapture(onFrame:)`` can reach it without building an engine.
    /// The policy is the library's (RC-11).
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

    // The route goes back to listening between overs because some Bluetooth
    // accessories mute their PTT while an idle HFP call is up. It goes back on
    // a linger, not inside `stopCapture()`, so SF-3's drop-and-resume re-keys
    // into a session still on radio instead of re-triggering the cascade
    // (BU-17). SF-3 itself is never suppressed.

    /// ``routeChangeCount``, so the settle tests can wait for the detached
    /// forwarder to observe a signal before stepping the clock.
    var routeChangesObserved: Int {
        lock.lock()
        defer { lock.unlock() }
        return routeChangeCount
    }

    /// Runs the capture start and records how long it took, for
    /// ``settleRoute()``. Timed even when it throws: a slow failure moved the
    /// route just the same.
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

    /// Records that something is about to move the route. Call with ``lock``
    /// held. Only the first disturbance of a group stamps the baseline, so
    /// they are waited out once.
    private func noteRouteDisturbanceLocked() {
        if !routeDisturbed {
            routeDisturbed = true
            routeChangeBeforeDisturbance = routeChangeCount
        }
    }

    /// Called from the forwarder, off the main actor.
    private func noteRouteChange() {
        lock.lock()
        routeChangeCount += 1
        lock.unlock()
    }

    /// Escalates now, while nothing is on air (BU-15). One ``settleRoute()``
    /// after the microphone opens covers both disturbances.
    func prepareForCapture() async {
        do {
            try escalateForCapture()
        } catch {
            // Logged, not thrown: `startCapture(onFrame:)` asks again and owns
            // the failure path.
            Diagnostics.route("audio session escalation before key-down failed: \(error)")
        }
    }

    /// Waits out the cascade this over's preparation caused, so the key-down
    /// happens on a route that has stopped moving (BU-15).
    func settleRoute() async {
        lock.lock()
        let disturbed = routeDisturbed
        let baseline = routeChangeBeforeDisturbance
        let start = routeChangeCount
        let openingWasSlow = lastCaptureStartNanoseconds >= Self.captureSlowThresholdNanoseconds
        routeDisturbed = false
        lock.unlock()

        // The route moved if signals already arrived (usual on iOS) or opening
        // was slow (macOS, bringing up SCO). Neither, and there is nothing to
        // wait for, as for every over inside the linger (BU-16).
        guard disturbed, start > baseline || openingWasSlow else { return }

        var seen = start
        // Signals already seen mean the cascade has begun: skip the onset
        // budget and wait for quiet.
        var started = start > baseline
        /// The tick of the last change; 0 if none during this wait.
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

    /// Asks for the radio policy, skipping the category change when already
    /// there; see ``appliedPolicy`` for why the skip matters.
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

    /// Hands the route back to listening: a playback category with no input,
    /// so the SCO link drops and the accessory's PTT comes back.
    ///
    /// Best effort and not throwing: failing here costs audio quality, not
    /// safety, and must never get in the way of `stopCapture()` shutting the
    /// microphone.
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

    /// One linger, then one attempt. Retries come through here too, with a new
    /// playback baseline so each linger judges only its own quiet.
    private func lingerThenComplete(_ generation: Int, attempt: Int, playbackBaseline: Int) {
        let linger = listeningLinger
        Task.detached { [weak self] in
            await linger()
            self?.completeHandback(
                generation, attempt: attempt, playbackBaseline: playbackBaseline)
        }
    }

    /// Five lingers is fifteen seconds; a session still refusing after that has
    /// something structurally wrong.
    private static let maximumHandbackAttempts = 5

    /// The second half of ``handRouteBack(afterLinger:)``: discard the engine,
    /// then apply the listening policy.
    ///
    /// An engine that has captured carries an input unit, and restarting it for
    /// received audio re-raises an input route, which on Bluetooth is HFP: the
    /// accessory would be pulled back into a call, button muted, whenever the
    /// far side talked. A fresh engine is playback-only until the next capture
    /// brings its input up under the radio policy (BU-1).
    private func completeHandback(_ generation: Int, attempt: Int, playbackBaseline: Int) {
        lock.lock()
        guard generation == handbackGeneration, !isCapturing,
            appliedPolicy != AudioSessionPolicy.listening
        else {
            lock.unlock()
            return
        }
        // Received audio arrived during the linger, and the discard would cut
        // the reply off (`playerNode.stop()` drops scheduled buffers), so wait
        // another linger. Bounded, because the hand-back revives the
        // accessory's button (BU-14).
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
        // Discard before the apply: a session refuses a category change under a
        // live input unit. The fresh engine is built now rather than lazily,
        // because a gap with no pipeline is a gap in SF-3 observation.
        let needsDiscard = discardsEngineOnHandback && captureAttemptedOnCurrent
        lock.unlock()

        if needsDiscard {
            // Built outside the lock, which `enqueuePlayback` takes fifty times a
            // second.
            let fresh = makePipeline()
            lock.lock()
            // Re-checked: a key-down may have raced the build. If so the fresh
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
            // Best effort, but logged and retried after another linger: the
            // refusal is usually transient.
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
        // A key-down can race the apply; the capture's own retry path repairs
        // the session if so.
        if generation == handbackGeneration, !isCapturing {
            appliedPolicy = AudioSessionPolicy.listening
        }
        lock.unlock()
        Diagnostics.route("audio route handed back to listening")
    }

    /// Does what a cold key-down does (escalate, open, settle) with no over at
    /// stake, then holds and closes through ``stopCapture()``. Captured frames
    /// are discarded, so the transmit meter shows only what was sent.
    @discardableResult
    func warmUpInput() async -> InputWarmUpOutcome {
        await prepareForCapture()
        do {
            try startCapture { _ in }
        } catch {
            // Opportunistic: the key-down path asks again and handles failure.
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
            // Listening has no input, so escalate first; a no-op inside the
            // linger (BU-17).
            try escalateForCapture()
            let pipeline = pipeline()
            lock.lock()
            // The first capture on an engine brings up its input unit, which
            // moves the route (BU-15).
            if !captureAttemptedOnCurrent { noteRouteDisturbanceLocked() }
            captureAttemptedOnCurrent = true
            lock.unlock()
            try timingCaptureStart { try pipeline.startCapture(onFrame: onFrame) }
        } catch let first {
            do {
                try activateSession()
                let fresh = rebuildPipeline()
                lock.lock()
                // A repair re-applies the policy and builds an engine.
                noteRouteDisturbanceLocked()
                captureAttemptedOnCurrent = true
                lock.unlock()
                try timingCaptureStart { try fresh.startCapture(onFrame: onFrame) }
            } catch let second {
                // Nothing is capturing: hand the route back now.
                handRouteBack(afterLinger: false)
                throw CaptureUnavailable(
                    first: first, afterRebuild: second, audioState: Self.audioStateDescription())
            }
        }
    }

    func stopCapture() {
        // Never builds a pipeline: that would bring up audio hardware from the
        // middle of a safety path.
        lock.lock()
        let pipeline = current
        lock.unlock()
        pipeline?.stop()
        // Microphone first, and it waits on nothing: that is the safety half.
        // The route goes back after the linger, never inline, which would turn
        // SF-3's one drop into a loop.
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

    /// The audio state in one line, for the failure alert. A live hardware rate
    /// beside `converterUnavailable` means the engine, not the session, is
    /// stale.
    var audioStateDescription: String { Self.audioStateDescription() }

    /// `static` so a `catch` in ``startCapture(onFrame:)`` can reach it without
    /// building anything.
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
