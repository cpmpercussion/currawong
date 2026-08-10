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
        let io = AudioPipelineIO(makePipeline: factory.make)

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

        XCTAssertEqual(factory.built.count, 2, "exactly one retry, not a loop")
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
