// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog

#if os(iOS)
import AVFoundation
#endif

/// **Diagnostic logging for the key path** (BU-13, BU-14, BU-15; see
/// `docs/BLUETOOTH-AUDIO.md`).
///
/// One line per key-down and key-up, from the main actor, with the audio state
/// at that moment. Every line goes to the unified log and, in DEBUG builds
/// only, to standard output.
///
/// * **macOS**: `log stream --predicate 'subsystem == "au.charlesmartin.currawong"' --style compact --info`
///   interleaves with the Bluetooth side (`subsystem == "com.apple.bluetooth"`,
///   where `Server.Handsfree` carries SCO setup and teardown) on one clock.
/// * **iOS**: `log stream` cannot reach a device at all, and
///   `devicectl device process launch --console` forwards only stdout and
///   stderr, not `os_log` lines. Hence the stdout mirror, read with
///   `xcrun devicectl device process launch --console --device <name> au.charlesmartin.currawong`.
///
/// **Nothing here changes behaviour**; no branch reads these logs.
/// ``startRouteLogging()``'s route-change observer only records reasons and
/// must never drop transmit — SF-3 is `RadioSession.handle(_:)`'s alone.
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

    /// A key-down that failed, at `error` level so a long session's `info`
    /// buffer cannot wrap it away.
    static func keyingFailure(_ message: String) {
        keyingLog.error("\(message, privacy: .public)")
        mirror("keying", message)
    }

    /// An `AudioSessionSignal`, or an iOS route change with its reason.
    static func route(_ message: String) {
        routeLog.info("\(message, privacy: .public)")
        mirror("route", message)
    }

    /// The stdout half, timestamped in seconds since launch because
    /// `devicectl`'s console adds no timestamps.
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
    @MainActor private static var isRouteLoggingStarted = false

    /// Begins logging route-change *reasons*, which the library's
    /// `AudioSessionSignal.routeChanged` does not carry (BU-13). Idempotent; a
    /// no-op on macOS, which has no `AVAudioSession`.
    @MainActor
    static func startRouteLogging() {
        guard !isRouteLoggingStarted else { return }
        isRouteLoggingStarted = true

        // Proves the instrument is live, rather than leaving silence ambiguous.
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

    /// Which route-change machinery is in play on this platform.
    private static var platform: String {
        #if os(iOS)
        return "iOS, AVAudioSession route reasons logged"
        #else
        return "macOS, no AVAudioSession — engine configuration changes only"
        #endif
    }

    #if os(iOS)
    /// The reason code as a readable word.
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
