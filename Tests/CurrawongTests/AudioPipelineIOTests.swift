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

    func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
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
    func testFirstCaptureBuildsExactlyOnePipeline() throws {
        let factory = PipelineFactory([])
        let io = AudioPipelineIO(makePipeline: factory.make)

        try io.startCapture { _ in }

        XCTAssertEqual(factory.built.count, 1, "a successful capture must not rebuild anything")
        XCTAssertEqual(factory.built[0].startCount, 1)
    }

    func testNoPipelineIsBuiltUntilSomethingNeedsOne() {
        let factory = PipelineFactory([])
        let io = AudioPipelineIO(makePipeline: factory.make)

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
        let io = AudioPipelineIO(makePipeline: factory.make)

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
        let io = AudioPipelineIO(makePipeline: factory.make)

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
        let io = AudioPipelineIO(makePipeline: factory.make, discardsEngineOnHandback: true)

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
        let io = AudioPipelineIO(makePipeline: factory.make)

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
        let io = AudioPipelineIO(makePipeline: factory.make)

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
