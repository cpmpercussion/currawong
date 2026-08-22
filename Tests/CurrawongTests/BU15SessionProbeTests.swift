// SPDX-License-Identifier: Apache-2.0
//
// **A probe, not a regression test.** It asserts almost nothing: it exists to
// find out whether the iOS *simulator* reproduces the route-change cascade
// that `BU-15` is about, and it reports what it saw by failing with the
// evidence attached. Delete it, or turn it into an assertion, once that
// question is answered.

import AVFoundation
import XCTest

#if os(iOS)

final class BU15SessionProbeTests: XCTestCase {

    private struct Event {
        let elapsed: TimeInterval
        let name: String
        let detail: String
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Event] = []
        let start = Date()

        func record(_ name: String, _ detail: String) {
            lock.lock()
            let event = Event(
                elapsed: Date().timeIntervalSince(start), name: name, detail: detail)
            events.append(event)
            lock.unlock()
            // Streamed as well as collected: the first attempt at this probe
            // crashed inside the run and took the whole log with it.
            print(String(format: "PROBE %7.3fs %@ | %@", event.elapsed, name, detail))
        }

        func drain() -> [Event] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private static func reasonName(_ raw: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .unknown: return "unknown"
        case .none: return "unrecognised(\(raw))"
        @unknown default: return "unknown(\(raw))"
        }
    }

    private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        let ins = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let outs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        return "in=[\(ins)] out=[\(outs)]"
    }

    /// Does the transition `escalateForCapture()` performs — `.playback` →
    /// `.playAndRecord` — post a route change on the simulator, and with which
    /// reason? That is the whole of `BU-15`'s iOS trigger.
    func testProbeCategoryChangeCascade() throws {
        let session = AVAudioSession.sharedInstance()
        let recorder = Recorder()
        let engine = AVAudioEngine()

        let routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
            recorder.record(
                "routeChange",
                "reason=\(Self.reasonName(raw)) "
                    + "previous=\(previous.map(Self.describe) ?? "nil") "
                    + "now=\(Self.describe(session.currentRoute))")
        }
        let configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            recorder.record("engineConfigurationChange", "")
        }
        let interruptObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
            recorder.record("interruption", "type=\(raw)")
        }
        defer {
            NotificationCenter.default.removeObserver(routeObserver)
            NotificationCenter.default.removeObserver(configObserver)
            NotificationCenter.default.removeObserver(interruptObserver)
        }

        func settle(_ label: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            recorder.record("--- \(label)", "route=\(Self.describe(session.currentRoute))")
        }

        recorder.record("start", "route=\(Self.describe(session.currentRoute))")

        // listening — the policy the app idles under (RC-12).
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        settle("after listening (.playback) active")

        // The engine is built under listening in the probe on purpose: BU-1's
        // ordering says production builds it under radio, and the question here
        // is only what notifications the *category change* produces.
        // Touching the mixer is what instantiates the output unit; `prepare()`
        // on an engine with no node attached raises `inputNode != nullptr ||
        // outputNode != nullptr` and takes the test process with it.
        _ = engine.mainMixerNode
        engine.prepare()
        settle("after engine.prepare")

        // radio — exactly what `escalateForCapture()` asks for.
        try session.setCategory(
            .playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        settle("after setCategory(radio), before setActive")

        try session.setActive(true)
        settle("after setActive(true) under radio")

        // **Controls.** A negative result above is only evidence if these show
        // the detector works at all. `overrideOutputAudioPort` is the textbook
        // `.override` route change, and deactivating is the textbook way to
        // make the route go away.
        try session.overrideOutputAudioPort(.speaker)
        settle("CONTROL after overrideOutputAudioPort(.speaker)")

        try session.overrideOutputAudioPort(.none)
        settle("CONTROL after overrideOutputAudioPort(.none)")

        // ...and the hand-back, which is the other half of the loop.
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        settle("after hand-back to listening")

        try session.setActive(false)
        settle("CONTROL after setActive(false)")

        let routeChanges = recorder.drain().filter { $0.name == "routeChange" }.count
        recorder.record("TOTAL routeChange notifications", "\(routeChanges)")

        let log =
            recorder.drain()
            .map { event in
                let elapsed = String(format: "%7.3f", event.elapsed)
                return "\(elapsed)s  \(event.name) | \(event.detail)"
            }
            .joined(separator: "\n")
        let attachment = XCTAttachment(string: log)
        attachment.name = "BU-15 simulator session probe"
        attachment.lifetime = .keepAlways
        add(attachment)

        // **The finding, as a tripwire.** Measured 2026-08-23 on iPhone 17 Pro
        // / iOS 26.5 simulator, Xcode 26.6: the route really does change — the
        // built-in mic appears in `currentRoute.inputs` at the category change
        // and is gone again after the hand-back, exactly as on the device — but
        // `AVAudioSession` posts **no** `routeChangeNotification` for it, nor
        // for either `overrideOutputAudioPort` control, nor for `setActive`.
        //
        // That is why `BU-15` cannot be reproduced in the simulator. Its whole
        // mechanism is SF-3 reacting to that notification, so the simulator
        // shows a clean first transmit and would report a false pass on any fix.
        //
        // **If this assertion ever fails, that is good news, not a regression:**
        // the simulator has gained route-change notifications and `BU-15`
        // becomes reproducible here. Check the log, then rewrite this test as
        // the real reproduction.
        XCTAssertEqual(
            routeChanges, 0,
            "The simulator posted a route change — BU-15 may now be reproducible here:\n\(log)")
    }
}

#endif
