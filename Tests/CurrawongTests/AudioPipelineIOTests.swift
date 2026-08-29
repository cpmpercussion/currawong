// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import Currawong

/// A ``CapturePipeline`` with no `AVAudioEngine` behind it, so the
/// rebuild-and-retry logic can be exercised without a microphone (AU-5).
private final class FakeCapturePipeline: CapturePipeline, @unchecked Sendable {
    let signals: AsyncStream<AudioSessionSignal>
    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation

    private let lock = NSLock()
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var storedPlayed: [[Int16]] = []

    /// Thrown by ``startCapture(onFrame:)``. Set at construction so a factory
    /// can decide per pipeline whether this one is the poisoned engine.
    let startCaptureError: Error?

    init(startCaptureError: Error? = nil) {
        self.startCaptureError = startCaptureError
        var escaped: AsyncStream<AudioSessionSignal>.Continuation!
        self.signals = AsyncStream { escaped = $0 }
        self.signalContinuation = escaped
    }

    /// Run inside ``startCapture(onFrame:)``, so a test can make opening the
    /// microphone *appear* to take time on the injected clock — which is what
    /// `AudioPipelineIO` reads to decide whether the audio stack brought
    /// something up (`BU-15`).
    var duringStartCapture: (@Sendable () -> Void)?

    func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
        duringStartCapture?()
        if let startCaptureError { throw startCaptureError }
        lock.lock()
        storedStartCount += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        storedStopCount += 1
        lock.unlock()
    }

    func enqueuePlayback(_ pcm: [Int16]) {
        lock.lock()
        storedPlayed.append(pcm)
        lock.unlock()
    }

    /// Pretends the operating system reported an interruption or route change.
    func emit(_ signal: AudioSessionSignal) {
        signalContinuation.yield(signal)
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }

    var played: [[Int16]] {
        lock.lock()
        defer { lock.unlock() }
        return storedPlayed
    }
}

/// Hands out a scripted sequence of pipelines and records how many were asked
/// for — the number that says whether a rebuild happened.
private final class PipelineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [FakeCapturePipeline]
    private var handedOut: [FakeCapturePipeline] = []

    init(_ scripted: [FakeCapturePipeline]) {
        self.scripted = scripted
    }

    func make() -> CapturePipeline {
        lock.lock()
        defer { lock.unlock() }
        let next = scripted.isEmpty ? FakeCapturePipeline() : scripted.removeFirst()
        handedOut.append(next)
        return next
    }

    var built: [FakeCapturePipeline] {
        lock.lock()
        defer { lock.unlock() }
        return handedOut
    }
}

private struct StubError: Error, CustomStringConvertible {
    let description: String
}

/// The engine-lifetime rules in ``AudioPipelineIO``.
///
/// These exist because of a real on-air failure: an `AVAudioEngine` built before
/// the audio session was active reports a 0 Hz input rate for the rest of the
/// process, so every PTT press failed with `converterUnavailable` and no amount
/// of retrying on the same engine could ever succeed.
final class AudioPipelineIOTests: XCTestCase {

    /// An `AudioPipelineIO` with **the real audio session kept out of it**, and
    /// a hand-back linger that never elapses.
    ///
    /// These seven tests are about engine lifetime and said nothing about
    /// policy, so they took the initialiser's defaults — which are the real
    /// `AVAudioSession` and a real three-second linger. On the simulator the
    /// hand-back's `setCategory` is refused with `'!pri'`, so each of them left
    /// a **retry chain of up to five attempts, three seconds apart**, running
    /// past the end of the test that started it: fifteen seconds of blocking
    /// audio calls on the cooperative thread pool, for tests that never wanted
    /// a session at all. That is the `!pri` noise smeared across unrelated
    /// tests in every CI log, and `BU-20`'s best candidate for what stops
    /// detached work being scheduled on a small runner.
    ///
    /// **The linger is a gate that is never opened**, which is what the real
    /// three seconds was doing here by accident: these tests assume the
    /// hand-back does *not* complete while they run — `testNoPipelineIsBuilt…`
    /// asserts that nothing was built, and a completed hand-back on iOS builds
    /// the replacement engine. An instant linger would break them; expressing
    /// "this linger does not elapse" as a gate says so out loud.
    private func makeIO(
        _ factory: PipelineFactory, discardsEngineOnHandback: Bool? = nil
    ) -> AudioPipelineIO {
        let neverElapses = LingerGate()
        // Passed through only when a test asks, so the platform default — which
        // is the product's rule, not a number to copy into a test — still
        // applies everywhere else.
        if let discardsEngineOnHandback {
            return AudioPipelineIO(
                makePipeline: factory.make,
                applyPolicy: { _ in },
                listeningLinger: neverElapses.wait,
                discardsEngineOnHandback: discardsEngineOnHandback)
        }
        return AudioPipelineIO(
            makePipeline: factory.make,
            applyPolicy: { _ in },
            listeningLinger: neverElapses.wait)
    }
    func testFirstCaptureBuildsExactlyOnePipeline() throws {
        let factory = PipelineFactory([])
        let io = makeIO(factory)

        try io.startCapture { _ in }

        XCTAssertEqual(factory.built.count, 1, "a successful capture must not rebuild anything")
        XCTAssertEqual(factory.built[0].startCount, 1)
    }

    func testNoPipelineIsBuiltUntilSomethingNeedsOne() {
        let factory = PipelineFactory([])
        let io = makeIO(factory)

        // Reading `signals` is what `RadioSession.start()` does at launch, long
        // before the session is configured. It must not instantiate audio
        // hardware — that is the whole point of building late.
        _ = io.signals
        io.stopCapture()

        XCTAssertEqual(factory.built.count, 0)
    }

    /// The engine must be built by ``AudioPipelineIO/configureSession()`` — after
    /// the session is active, and before the first key-up — because that is also
    /// where the SF-3 interruption observers come from.
    func testConfigureSessionBuildsTheEngineAndCaptureReusesIt() throws {
        let factory = PipelineFactory([])
        let io = makeIO(factory)

        try io.configureSession()
        XCTAssertEqual(factory.built.count, 1)

        try io.startCapture { _ in }
        XCTAssertEqual(factory.built.count, 1, "the session's engine is the one that captures")
        XCTAssertEqual(factory.built[0].startCount, 1)
    }

    func testCaptureRetriesOnAFreshPipelineAndStopsThePoisonedOne() throws {
        let poisoned = FakeCapturePipeline(startCaptureError: StubError(description: "0 Hz input"))
        let healthy = FakeCapturePipeline()
        let factory = PipelineFactory([poisoned, healthy])
        let io = makeIO(factory)

        try io.startCapture { _ in }

        XCTAssertEqual(factory.built.count, 2, "the failed engine must be replaced, not reused")
        XCTAssertEqual(healthy.startCount, 1)
        XCTAssertEqual(
            poisoned.stopCount, 1,
            "an engine dropped with a tap still installed is an open microphone")
    }

    func testCaptureReportsBothFailuresWithTheAudioStateAttached() {
        let first = FakeCapturePipeline(startCaptureError: StubError(description: "first no"))
        let second = FakeCapturePipeline(startCaptureError: StubError(description: "second no"))
        let factory = PipelineFactory([first, second])
        // The discard on, explicitly: the third engine below is the iOS
        // hand-back's, and these tests run on macOS, where it is off by default.
        let io = makeIO(factory, discardsEngineOnHandback: true)

        do {
            try io.startCapture { _ in }
            XCTFail("a capture that never opened must not report success")
        } catch let failure as AudioPipelineIO.CaptureUnavailable {
            XCTAssertEqual("\(failure.first)", "first no")
            XCTAssertEqual("\(failure.afterRebuild)", "second no")
            XCTAssertFalse(
                failure.audioState.isEmpty,
                "the alert is the only diagnostic channel a radio in the field has")
            XCTAssertTrue(failure.description.contains("second no"))
        } catch {
            XCTFail("expected CaptureUnavailable, got \(error)")
        }

        // Three engines, but only two capture attempts: the third is the failed
        // key-down handing the route back and discarding the attempted-on
        // engine (BU-17), not another retry.
        XCTAssertEqual(factory.built.count, 3)
        XCTAssertEqual(
            factory.built.map(\.startCount), [0, 0, 0],
            "exactly one attempt per engine and none on the replacement — not a loop")
    }

    /// **SF-3.** The interruption stream is read once, at launch, and must keep
    /// working across a rebuild — otherwise the repair above silently disables
    /// the release path that drops transmit on an incoming call.
    func testSignalsSurviveARebuild() async throws {
        let poisoned = FakeCapturePipeline(startCaptureError: StubError(description: "0 Hz input"))
        let healthy = FakeCapturePipeline()
        let factory = PipelineFactory([poisoned, healthy])
        let io = makeIO(factory)

        var iterator = io.signals.makeAsyncIterator()

        try io.startCapture { _ in }
        XCTAssertEqual(factory.built.count, 2)

        healthy.emit(.interruptionBegan)
        let received = await iterator.next()
        XCTAssertEqual(received, .interruptionBegan)
    }

    func testPlaybackGoesToTheCurrentPipeline() throws {
        let poisoned = FakeCapturePipeline(startCaptureError: StubError(description: "0 Hz input"))
        let healthy = FakeCapturePipeline()
        let factory = PipelineFactory([poisoned, healthy])
        let io = makeIO(factory)

        try io.startCapture { _ in }
        io.enqueuePlayback([1, 2, 3])

        XCTAssertEqual(healthy.played, [[1, 2, 3]])
        XCTAssertTrue(poisoned.played.isEmpty, "the discarded engine must not still be fed")
    }
}

/// Records every session-policy application, in order, refusing the first
/// `failuresBeforeSuccess` applications of `listening` — the on-air `'!pri'`
/// refusal, scripted.
private final class PolicyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedApplied: [AudioSessionPolicy] = []
    private var remainingFailures = 0

    /// Refuse the next `count` applications of `listening`.
    func failNext(_ count: Int) {
        lock.lock()
        remainingFailures = count
        lock.unlock()
    }

    var apply: @Sendable (AudioSessionPolicy) throws -> Void {
        { [self] policy in
            lock.lock()
            if policy == .listening, remainingFailures > 0 {
                remainingFailures -= 1
                lock.unlock()
                throw StubError(description: "!pri")
            }
            storedApplied.append(policy)
            lock.unlock()
        }
    }

    var applied: [AudioSessionPolicy] {
        lock.lock()
        defer { lock.unlock() }
        return storedApplied
    }

    func clear() {
        lock.lock()
        storedApplied = []
        lock.unlock()
    }
}

/// A linger the test releases by hand. Opening lets every wait — current and
/// future — through.
private final class LingerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var storedWaitsBegun = 0

    /// How many lingers have been entered, ever — a deferred hand-back is
    /// observable as a second linger where there would have been one.
    var waitsBegun: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedWaitsBegun
    }

    var wait: @Sendable () async -> Void {
        { [self] in
            await withCheckedContinuation { continuation in
                lock.lock()
                storedWaitsBegun += 1
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resuming = waiting
        waiting = []
        lock.unlock()
        resuming.forEach { $0.resume() }
    }
}

/// **BU-17.** The session-policy governance in ``AudioPipelineIO``: radio only
/// while capturing, listening otherwise, with the hand-back on a linger so
/// SF-3's drop-and-resume cannot re-trigger its own route-change cascade.
final class AudioPipelineIOPolicyTests: XCTestCase {

    private func makeIO(gate: LingerGate = LingerGate()) -> (
        AudioPipelineIO, PolicyRecorder
    ) {
        let recorder = PolicyRecorder()
        let io = AudioPipelineIO(
            makePipeline: { FakeCapturePipeline() },
            applyPolicy: recorder.apply,
            listeningLinger: gate.wait)
        return (io, recorder)
    }

    /// Configuration builds the engine under radio — that ordering is `BU-1` —
    /// and then hands the route straight back, so an app that never transmits
    /// never holds the accessory in a call.
    func testConfigureSessionEndsOnListening() throws {
        let (io, recorder) = makeIO()

        try io.configureSession()

        XCTAssertEqual(recorder.applied, [.radio, .listening])
    }

    /// Key-down asks for radio before the microphone opens — this is where the
    /// SCO link comes up, and what the accessory's light reports.
    func testStartCaptureEscalatesToRadio() throws {
        let (io, recorder) = makeIO()
        try io.configureSession()
        recorder.clear()

        try io.startCapture { _ in }

        XCTAssertEqual(recorder.applied, [.radio])
    }

    /// Key-up shuts the microphone but does **not** hand the route back inline:
    /// the hand-back waits out the linger. An inline hand-back here is what
    /// turned SF-3's one drop into a loop in `BU-17`'s first attempt.
    func testStopCaptureHandsTheRouteBackOnlyAfterTheLinger() async throws {
        let gate = LingerGate()
        let (io, recorder) = makeIO(gate: gate)
        try io.configureSession()
        try io.startCapture { _ in }
        recorder.clear()

        io.stopCapture()
        XCTAssertEqual(recorder.applied, [], "the hand-back must wait out the linger")

        gate.open()
        await waitUntil("route handed back") { recorder.applied == [.listening] }
    }

    /// **The loop killer.** A key-down inside the linger — the automatic resume
    /// after SF-3's drop, most importantly — finds the session still on radio
    /// and must not re-apply the category: a redundant category change is a
    /// fresh route-change cascade, and re-triggering the cascade from inside
    /// its own recovery is the loop that killed the first attempt. And the
    /// stale linger, once it elapses, must not pull the route out from under
    /// the live capture.
    func testAKeyDownDuringTheLingerKeepsRadioWithoutReapplyingIt() async throws {
        let gate = LingerGate()
        let (io, recorder) = makeIO(gate: gate)
        try io.configureSession()
        try io.startCapture { _ in }
        io.stopCapture()
        recorder.clear()

        try io.startCapture { _ in }
        XCTAssertEqual(recorder.applied, [], "the session is already on radio")

        gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            recorder.applied, [],
            "a stale linger must not hand the route back under a live capture")
    }

    /// A key-down that fails outright hands the route back immediately: nothing
    /// is capturing, so the accessory must not be left in a call nobody is
    /// having, waiting on a linger for an over that never happened.
    func testAFailedKeyDownHandsTheRouteBackImmediately() throws {
        let recorder = PolicyRecorder()
        let io = AudioPipelineIO(
            makePipeline: {
                FakeCapturePipeline(startCaptureError: StubError(description: "no mic"))
            },
            applyPolicy: recorder.apply,
            listeningLinger: LingerGate().wait)
        try io.configureSession()
        recorder.clear()

        XCTAssertThrowsError(try io.startCapture { _ in })

        XCTAssertEqual(recorder.applied.last, .listening)
    }

    /// The hand-back discards the capture engine. After any capture the engine
    /// carries an instantiated input audio unit, and restarting it for
    /// *received* audio — most of what happens between overs — re-raises an
    /// input route; on Bluetooth that is HFP, which pulls the accessory
    /// straight back into the call and re-mutes its button. Observed on air
    /// 2026-08-22: the LED re-latched every time the far side talked.
    func testTheHandbackDiscardsTheCaptureEngine() async throws {
        let gate = LingerGate()
        let recorder = PolicyRecorder()
        let factory = PipelineFactory([])
        let io = AudioPipelineIO(
            makePipeline: factory.make,
            applyPolicy: recorder.apply,
            listeningLinger: gate.wait,
            // Explicit: the default is platform truth, and these tests run on
            // macOS, where the discard is off.
            discardsEngineOnHandback: true)
        try io.configureSession()
        try io.startCapture { _ in }
        io.stopCapture()
        let builtBefore = factory.built.count

        gate.open()
        await waitUntil("route handed back") { recorder.applied.last == .listening }
        await waitUntil("engine discarded") { factory.built.count == builtBefore + 1 }

        io.enqueuePlayback([7])
        XCTAssertEqual(
            factory.built.last?.played, [[7]],
            "received audio must flow through the fresh, input-free engine")
        XCTAssertEqual(
            factory.built[builtBefore - 1].stopCount, 2,
            "the input-bearing engine was stopped when it was discarded")
    }

    /// A refused hand-back retries after another linger rather than giving up.
    /// The refusal observed on air (`'!pri'`, insufficient priority, during the
    /// post-over route shuffle) was transient — and a hand-back that gives up
    /// leaves the accessory in a call forever, which is `BU-14` re-created by
    /// its own fix.
    func testARefusedHandbackRetries() async throws {
        let gate = LingerGate()
        let recorder = PolicyRecorder()
        let io = AudioPipelineIO(
            makePipeline: { FakeCapturePipeline() },
            applyPolicy: recorder.apply,
            listeningLinger: gate.wait)
        try io.configureSession()
        try io.startCapture { _ in }
        recorder.clear()
        recorder.failNext(1)

        io.stopCapture()
        gate.open()

        await waitUntil("route handed back on the retry") {
            recorder.applied == [.listening]
        }
    }

    /// **Reply audio is not discarded with the engine.** Far-side replies land
    /// at a measured 1.6–2.6 s and the linger is 3 s, so the discard would
    /// routinely fall mid-reply — and `playerNode.stop()` drops every scheduled
    /// buffer. Audio arriving during the linger defers the hand-back for
    /// another linger; one that passes quiet is a queue that has drained.
    func testReplyAudioArrivingDuringTheLingerDefersTheHandback() async throws {
        let gate = LingerGate()
        let recorder = PolicyRecorder()
        let factory = PipelineFactory([])
        let io = AudioPipelineIO(
            makePipeline: factory.make,
            applyPolicy: recorder.apply,
            listeningLinger: gate.wait,
            discardsEngineOnHandback: true)
        try io.configureSession()
        try io.startCapture { _ in }
        let lingersBefore = gate.waitsBegun
        io.stopCapture()

        // The far side replies while the linger is still running.
        io.enqueuePlayback([7])
        gate.open()

        await waitUntil("route handed back") { recorder.applied.last == .listening }
        XCTAssertGreaterThanOrEqual(
            gate.waitsBegun, lingersBefore + 2,
            "audio during the linger must buy the reply another linger, not a discard")
        // And the reply reached the engine that was playing it, not the bin.
        XCTAssertEqual(factory.built.first?.played, [[7]])
    }

    /// The platform gate: told not to discard — the macOS default, where the
    /// system manages its own routes — the hand-back still applies the policy
    /// but leaves the engine, and the audio it holds, alone.
    func testTheHandbackLeavesTheEngineAloneWhenDiscardIsOff() async throws {
        let gate = LingerGate()
        let recorder = PolicyRecorder()
        let factory = PipelineFactory([])
        let io = AudioPipelineIO(
            makePipeline: factory.make,
            applyPolicy: recorder.apply,
            listeningLinger: gate.wait,
            discardsEngineOnHandback: false)
        try io.configureSession()
        try io.startCapture { _ in }
        io.stopCapture()

        gate.open()
        await waitUntil("route handed back") { recorder.applied.last == .listening }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(factory.built.count, 1, "no engine may be discarded or rebuilt")
    }

    /// Two overs inside one linger produce exactly one hand-back once the
    /// linger after the *last* of them elapses.
    func testOnlyTheLastLingerHandsTheRouteBack() async throws {
        let gate = LingerGate()
        let (io, recorder) = makeIO(gate: gate)
        try io.configureSession()
        try io.startCapture { _ in }
        io.stopCapture()
        try io.startCapture { _ in }
        io.stopCapture()
        recorder.clear()

        gate.open()
        await waitUntil("route handed back") { !recorder.applied.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.applied, [.listening], "one hand-back, not one per over")
    }
}


/// The settle wait's clock, with the operating system's part of it scripted.
///
/// Each tick returns immediately, having first run whatever the test wants to
/// have "happened" during it — so a wait that needs more ticks than the script
/// provides runs out of ticks rather than parking for ever, and a test that
/// mis-counts fails instead of hanging the suite. `elapsed` is what the
/// assertions read: the number of ticks the wait actually spent.
private final class ScriptedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedElapsed = 0
    private let duringTick: @Sendable (Int) async -> Void

    /// - Parameter duringTick: run at the start of tick *n*, 1-based. This is
    ///   where a test emits the route changes that tick is supposed to carry.
    init(duringTick: @escaping @Sendable (Int) async -> Void) {
        self.duringTick = duringTick
    }

    var elapsed: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedElapsed
    }

    var tick: @Sendable () async -> Void {
        { [self] in
            lock.lock()
            storedElapsed += 1
            let n = storedElapsed
            lock.unlock()
            await duringTick(n)
        }
    }
}

/// **`BU-15`.** The wait that makes the escalation's route-change cascade land
/// while the app is idle, so there is no transmission for SF-3 to drop.
///
/// The fault these are about: `escalateForCapture()` used to run under a live
/// carrier, iOS posted the route change, SF-3 correctly dropped transmit, and
/// the operator watched one press key down, unkey and key down again — losing
/// 385 ms of speech and being told to press a button they were still holding.
/// Measured on melchior, 2026-08-23; the numbers the wait is built from, and
/// the cascade the first test reproduces tick for tick, are in the comment
/// above `settleTickNanoseconds`.
///
/// None of this can be tested on the simulator, and the reason is worth
/// repeating where somebody will read it: `BU15SessionProbeTests` proved on
/// 2026-08-23 that the simulator posts **no** route-change notification for a
/// category change it demonstrably performs. So these tests script the
/// cascade, and the device test is what confirms the real one.
final class AudioPipelineIOSettleTests: XCTestCase {

    /// Builds the subject with a scripted clock. `cascadeTicks` are the ticks
    /// during which the operating system posts a route change.
    /// A monotonic clock the test moves by hand, so "the microphone took
    /// 500 ms to open" is a fact a test can state rather than sleep for.
    private final class FakeMonotonic: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 1_000_000_000

        var read: @Sendable () -> UInt64 {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return nanoseconds
            }
        }

        func advance(_ by: UInt64) {
            lock.lock()
            nanoseconds += by
            lock.unlock()
        }
    }

    /// - Parameter captureTakes: how long the injected clock advances while the
    ///   microphone opens. The default is comfortably past
    ///   ``AudioPipelineIO/captureSlowThresholdNanoseconds``, i.e. a cold over.
    private func makeIO(
        cascadeOn cascadeTicks: Set<Int>,
        captureTakes: UInt64 = 500_000_000
    ) -> (AudioPipelineIO, PolicyRecorder, ScriptedClock, FakeCapturePipeline) {
        let recorder = PolicyRecorder()
        let pipeline = FakeCapturePipeline()
        let monotonic = FakeMonotonic()
        pipeline.duringStartCapture = { monotonic.advance(captureTakes) }
        // Captured and filled in below: the clock's script has to be able to
        // ask the subject what it has observed, and the subject needs the
        // clock. One of the two references has to be late.
        let box = IOBox()
        let clock = ScriptedClock { tick in
            guard cascadeTicks.contains(tick), let io = box.io else { return }
            let target = io.routeChangesObserved + 1
            pipeline.emit(.routeChanged(.oldDeviceUnavailable))
            // Wait for the forwarder — a detached task — to have counted it.
            // Without this the script would race the thing it is scripting.
            while io.routeChangesObserved < target {
                await Task.yield()
            }
        }
        let io = AudioPipelineIO(
            makePipeline: { pipeline },
            applyPolicy: recorder.apply,
            listeningLinger: LingerGate().wait,
            settleTick: clock.tick,
            monotonicNanoseconds: monotonic.read)
        box.io = io
        return (io, recorder, clock, pipeline)
    }

    /// Breaks the reference cycle between the clock's script and the subject.
    private final class IOBox: @unchecked Sendable {
        var io: AudioPipelineIO?
    }

    /// **The measured cascade, tick for tick.** Four quiet ticks (the 290 ms
    /// before iOS posted anything), five signals, then quiet — and the wait
    /// returns only after the quiet, which is what leaves the microphone to be
    /// opened on a route that has stopped moving.
    func testPreparationWaitsOutTheWholeCascade() async throws {
        let (io, recorder, clock, _) = makeIO(cascadeOn: [5, 6, 7, 8, 9])
        try io.configureSession()
        recorder.clear()

        await io.prepareAndCapture()

        XCTAssertEqual(
            recorder.applied, [.radio],
            "escalate once, then wait — waiting must not re-apply the category (BU-17)")
        XCTAssertEqual(
            clock.elapsed, 9 + AudioPipelineIO.settleQuietTicks,
            "the wait ends one quiet window after the last signal, and not before")
        XCTAssertEqual(io.routeChangesObserved, 5)
    }

    /// Under-shooting the quiet window is `BU-15` all over again: the tail of
    /// the cascade lands after the microphone is open and SF-3 drops it. So the
    /// wait must not stop at a gap the cascade itself contains — 80–140 ms
    /// between signals, measured.
    func testAGapInsideTheCascadeDoesNotEndTheWait() async throws {
        let quiet = AudioPipelineIO.settleQuietTicks
        // A signal well inside the onset window, a gap one tick shorter than
        // the quiet window, another signal. The wait must see this through.
        let last = 2 + quiet - 1
        let (io, _, clock, _) = makeIO(cascadeOn: [2, last])
        try io.configureSession()

        await io.prepareAndCapture()

        XCTAssertEqual(clock.elapsed, last + quiet)
        XCTAssertEqual(io.routeChangesObserved, 2)
    }

    /// A switch that posts nothing must not cost a whole cap's worth of dead
    /// air in front of the key-down. The wait gives up looking for a cascade
    /// that never started after ``AudioPipelineIO/settleOnsetTicks``.
    func testPreparationGivesUpWhenTheCascadeNeverStarts() async throws {
        let (io, _, clock, _) = makeIO(cascadeOn: [])
        try io.configureSession()

        await io.prepareAndCapture()

        XCTAssertEqual(
            clock.elapsed, AudioPipelineIO.settleOnsetTicks,
            "a silent route costs the onset window and no more")
    }

    /// **The fast path, and the one that keeps BU-16 intact.** An over inside
    /// the hand-back linger finds the session already on radio: there is no
    /// category change, so there is no cascade, so there is nothing to wait
    /// for. A quick exchange must still key the far end with the press.
    func testAnOverInsideTheLingerWaitsForNothing() async throws {
        let (io, recorder, clock, _) = makeIO(cascadeOn: [1, 2, 3])
        try io.configureSession()
        // A full first over, which is the one that does the disturbing: the
        // category change, and the first capture on this engine.
        await io.prepareAndCapture()
        io.stopCapture()
        let afterTheFirstOver = clock.elapsed
        XCTAssertGreaterThan(afterTheFirstOver, 0, "the first over waits — that is BU-15")
        recorder.clear()

        // A second over inside the linger: still on radio, still the same
        // engine, its input unit already up. Nothing has moved.
        await io.prepareAndCapture()

        XCTAssertEqual(clock.elapsed, afterTheFirstOver, "no wait at all the second time")
        XCTAssertEqual(recorder.applied, [], "and no category change to wait on")
    }

    // MARK: The warm-up (BU-22)

    /// **`BU-22`.** The warm-up is the transmit path's own three calls —
    /// escalate, open the microphone, wait out what that disturbed — plus the
    /// thing a key-down does not do and the reason the first over was silent:
    /// it *holds the input open* for a while afterwards, so the device is
    /// producing signal rather than zeros by the time anybody keys up.
    func testWarmingUpOpensTheInputAndHoldsItPastTheSettle() async throws {
        let (io, recorder, clock, pipeline) = makeIO(cascadeOn: [5, 6, 7, 8, 9])
        try io.configureSession()
        recorder.clear()

        await io.warmUpInput()

        XCTAssertEqual(pipeline.startCount, 1, "the warm-up has to actually open the device")
        XCTAssertEqual(
            recorder.applied, [.radio],
            "escalate once, exactly as a key-down does — a warm-up must not invent a policy")
        XCTAssertEqual(
            clock.elapsed,
            9 + AudioPipelineIO.settleQuietTicks + AudioPipelineIO.warmUpHoldTicks,
            "the hold is on top of the settle, not instead of it")
    }

    /// It closes what it opened. A warm-up that left the microphone running
    /// would be a recording indicator lit for the whole call, which is
    /// precisely the impression this app must never give — and the close is
    /// also what starts the hand-back linger, so an operator who keys up
    /// straight afterwards still takes `BU-16`'s fast path.
    func testWarmingUpClosesTheInputAgain() async throws {
        let (io, _, _, pipeline) = makeIO(cascadeOn: [])
        try io.configureSession()

        await io.warmUpInput()

        XCTAssertEqual(pipeline.stopCount, 1)
    }

    /// Opportunistic, and it does not fail the connect: the connection is not
    /// refused over a microphone nobody has asked for yet, and the key-down
    /// path asks again with the error handling that matters. What it must not
    /// do is hold the route it escalated — a failed `startCapture` hands that
    /// back on its own, and the wait must not be paid for a device that never
    /// opened.
    ///
    /// **It is not silent about it either, which is `BU-24`.** The outcome goes
    /// back to the caller, carrying the library's own description.
    func testAWarmUpThatCannotOpenTheDeviceReturnsWithoutWaiting() async throws {
        let pipeline = FakeCapturePipeline(
            startCaptureError: StubError(description: "no input device"))
        let recorder = PolicyRecorder()
        let clock = ScriptedClock { _ in }
        let io = AudioPipelineIO(
            makePipeline: { pipeline },
            applyPolicy: recorder.apply,
            listeningLinger: LingerGate().wait,
            settleTick: clock.tick,
            monotonicNanoseconds: { 0 })
        try io.configureSession()

        let outcome = await io.warmUpInput()

        XCTAssertEqual(clock.elapsed, 0, "nothing opened, so there is nothing to hold open")
        XCTAssertFalse(outcome.didWarm)
        if case .couldNotOpenInput(let description) = outcome {
            XCTAssertTrue(
                description.contains("no input device"),
                "the library's own words, so a report says which failure it was: \(description)")
        } else {
            XCTFail("a warm-up that could not open the input must say so, not report .warmed")
        }
    }

    /// The other half of `BU-24`: a warm-up that did everything it set out to
    /// do reports that, so `.couldNotOpenInput` means something.
    func testAWarmUpThatOpenedTheDeviceReportsWarmed() async throws {
        let (io, _, _, _) = makeIO(cascadeOn: [])
        try io.configureSession()

        let outcome = await io.warmUpInput()

        XCTAssertEqual(outcome, .warmed)
    }

    /// A route that will not stop changing is not something to wait on. The cap
    /// is what hands the operator back their key-down — and SF-3, untouched by
    /// any of this, is what protects them once it is keyed.
    func testAFlappingRouteIsCappedRatherThanWaitedOnForever() async throws {
        let (io, _, clock, _) = makeIO(cascadeOn: Set(1...AudioPipelineIO.settleCapTicks))
        try io.configureSession()

        await io.prepareAndCapture()

        XCTAssertEqual(
            clock.elapsed, AudioPipelineIO.settleCapTicks,
            "the wait stops at the cap however hard the route flaps")
    }

    /// **A capture that brought nothing up waits for nothing**, even on a cold
    /// over — a Mac on its built-in microphone, say, where the policy
    /// bookkeeping flips but no route is raised and nothing is posted. Opening
    /// the microphone in under
    /// ``AudioPipelineIO/captureSlowThresholdNanoseconds`` is the evidence.
    ///
    /// This is also what stops the simulator paying an onset budget for a
    /// notification it will never send (`BU15SessionProbeTests`).
    func testACaptureThatBroughtNothingUpDoesNotWait() async throws {
        let (io, _, clock, _) = makeIO(cascadeOn: [1, 2, 3], captureTakes: 5_000_000)
        try io.configureSession()

        await io.prepareAndCapture()

        XCTAssertEqual(clock.elapsed, 0, "nothing was raised, so there is nothing to settle")
    }

    /// The other half of that rule: a signal that has **already** arrived is
    /// evidence too, however fast the microphone opened. On iOS the category
    /// cascade can land while the microphone is still coming up.
    func testASignalAlreadyArrivedIsEnoughToWaitOn() async throws {
        let (io, _, clock, pipeline) = makeIO(cascadeOn: [], captureTakes: 5_000_000)
        try io.configureSession()
        // A cascade that lands during the escalation, before the wait begins.
        await io.prepareForCapture()
        pipeline.emit(.routeChanged(.oldDeviceUnavailable))
        while io.routeChangesObserved == 0 { await Task.yield() }
        try? io.startCapture { _ in }

        await io.settleRoute()

        XCTAssertEqual(
            clock.elapsed, AudioPipelineIO.settleQuietTicks,
            "one quiet window, measured from a cascade already in progress")
    }
}

extension AudioPipelineIO {
    /// The three calls the transmit path makes, in the order it makes them:
    /// escalate, open the microphone, wait for what that disturbed to settle.
    /// Test-only, so each test states the sequence once rather than five times.
    fileprivate func prepareAndCapture() async {
        await prepareForCapture()
        try? startCapture { _ in }
        await settleRoute()
    }
}
