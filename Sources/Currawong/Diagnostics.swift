// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog

#if os(iOS)
import AVFoundation
#endif

/// **Diagnostic logging for the key path.** Named instruments for `BU-13`,
/// `BU-14` and `BU-15`, and step 1 of the iOS harmonisation in
/// `docs/BLUETOOTH-AUDIO.md`.
///
/// Logs every key-down and key-up, one line each from the main actor, nowhere
/// near the audio thread — the audio state at that moment
/// (`AudioPipelineIO.audioStateDescription()`) is otherwise only reachable from
/// the "Could not transmit" alert, once a failure is already total.
///
/// Every line goes to both the unified log and, in `DEBUG` builds, standard
/// output — `DEBUG` only, so a release build carries the unified-log path and
/// nothing else.
///
/// * **macOS**: `log stream --predicate 'subsystem == "au.charlesmartin.currawong"' --style compact --info`
///   interleaves with the Bluetooth side (`subsystem == "com.apple.bluetooth"`,
///   where `Server.Handsfree` carries SCO setup and teardown) on one clock.
/// * **iOS**: `log stream` cannot reach a device at all, and
///   `devicectl device process launch --console` forwards only stdout and
///   stderr, not `os_log` lines. Hence the stdout mirror, read with
///   `xcrun devicectl device process launch --console --device <name> au.charlesmartin.currawong`.
///   Console.app also works but is a GUI; this keeps the phone readable from a
///   terminal.
///
/// **Nothing here changes behaviour.** No branch reads these logs and removing
/// this file leaves the transmit path identical — an instrument that
/// participates in the thing it measures is not an instrument.
/// ``startRouteLogging()`` in particular adds a *second* observer of the
/// route-change notification, purely to record the reason code the library's
/// `AudioSessionSignal` does not carry; it must never be the thing that drops
/// transmit. SF-3 is served by `RadioSession.handle(_:)` and nothing in this
/// file.
enum Diagnostics {

    private static let subsystem = "au.charlesmartin.currawong"

    /// Key-down and key-up, with the audio state at that moment.
    private static let keyingLog = Logger(subsystem: subsystem, category: "keying")

    /// Route changes and interruptions — SF-3's inputs, as they arrive.
    private static let routeLog = Logger(subsystem: subsystem, category: "route")

    // MARK: - The three call sites

    /// A key-down, a key-up, or a key-down that failed.
    static func keying(_ message: String) {
        keyingLog.info("\(message, privacy: .public)")
        mirror("keying", message)
    }

    /// A key-down that failed. Separate only so it lands at `error` level in the
    /// unified log, where `info` is a memory buffer that a long session can wrap
    /// and `error` is not.
    static func keyingFailure(_ message: String) {
        keyingLog.error("\(message, privacy: .public)")
        mirror("keying", message)
    }

    /// An `AudioSessionSignal`, or an iOS route change with its reason.
    static func route(_ message: String) {
        routeLog.info("\(message, privacy: .public)")
        mirror("route", message)
    }

    /// The stdout half — the only thing that makes a phone readable from a
    /// terminal.
    ///
    /// Timestamped, unlike the unified-log half which gets timestamps for
    /// free: `devicectl`'s console adds none, and this instrument exists to
    /// answer questions of ordering and duration. Seconds since process start
    /// rather than a wall clock, since a short relative number is easier to
    /// subtract by eye.
    private static func mirror(_ category: String, _ message: String) {
        #if DEBUG
        let t = Date().timeIntervalSince(processStart)
        print(String(format: "[%8.3f] [currawong:%@] %@", t, category, message))
        #endif
    }

    #if DEBUG
    private static let processStart = Date()
    #endif

    // MARK: - Route-change reasons (iOS)

    /// Whether ``startRouteLogging()`` has already registered its observer.
    /// Main-actor isolated rather than locked: the only caller is the
    /// composition root, on the main actor, once.
    @MainActor private static var isRouteLoggingStarted = false

    /// Begin recording route-change *reasons*, which the library's
    /// `AudioSessionSignal.routeChanged` does not carry.
    ///
    /// `BU-13`'s instrument: an `oldDeviceUnavailable` around an unkey would
    /// close that item, and no other signal in the app distinguishes it from
    /// the ordinary A2DP↔HFP swap that keying itself causes (`BU-15`).
    ///
    /// Idempotent, and registers no observer on macOS, which has no
    /// `AVAudioSession` — there the equivalent signal is
    /// `AVAudioEngineConfigurationChange`, which the library already observes
    /// on both platforms and reaches ``RadioSession`` as `.routeChanged`.
    @MainActor
    static func startRouteLogging() {
        guard !isRouteLoggingStarted else { return }
        isRouteLoggingStarted = true

        // Confirms "the instrument is live" before going on air, rather than
        // inferring it from silence afterwards — the failure mode these items
        // already suffer from.
        keying("diagnostics started: \(platform)")

        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let session = AVAudioSession.sharedInstance()
            let inputs = session.currentRoute.inputs.map(\.portType.rawValue)
                .joined(separator: "+")
            let outputs = session.currentRoute.outputs.map(\.portType.rawValue)
                .joined(separator: "+")
            let reason = Self.name(of: AVAudioSession.RouteChangeReason(rawValue: raw))
            Diagnostics.route(
                "route changed: reason=\(reason) "
                    + "in=\(inputs.isEmpty ? "none" : inputs) "
                    + "out=\(outputs.isEmpty ? "none" : outputs) "
                    + "rate=\(session.sampleRate)Hz")
        }
        #endif
    }

    /// Which route-change machinery is actually in play, since it differs by
    /// platform and that difference is the subject of `BLUETOOTH-AUDIO.md`.
    private static var platform: String {
        #if os(iOS)
        return "iOS, AVAudioSession route reasons logged"
        #else
        return "macOS, no AVAudioSession — engine configuration changes only"
        #endif
    }

    #if os(iOS)
    /// The reason code as the word `BU-13` is looking for, rather than a number
    /// nobody can read at 2 a.m. on a hilltop.
    private static func name(of reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .unknown: return "unknown"
        case .none: return "absent"
        @unknown default: return "unhandled"
        }
    }
    #endif
}
