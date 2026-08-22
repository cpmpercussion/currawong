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
/// ## Why this exists
///
/// Every accessory fault in `BRINGUP.md` has the same shape: it happens on air,
/// once, to an operator holding a radio, and by the time anyone looks the state
/// that would have explained it is gone. `AudioPipelineIO.audioStateDescription()`
/// has always known the answer — category, mode, hardware rate, route ports —
/// but was reachable only from the "Could not transmit" alert, which is to say
/// only when the failure was already total. A fault that *degrades* audio rather
/// than stopping it never printed anything at all.
///
/// So: log it on every key-down and key-up. One line each, from the main actor,
/// nowhere near the audio thread.
///
/// ## Two outputs, because the phone cannot be read like the Mac
///
/// Every line goes to **both** the unified log and, in `DEBUG` builds, standard
/// output. That is not redundancy, it is the only way to read this on a device:
///
/// * **macOS** — `log stream` on this subsystem, live, on the same machine:
///   ```sh
///   log stream --predicate 'subsystem == "au.charlesmartin.currawong"' --style compact --info
///   ```
///   which interleaves with the Bluetooth side (`subsystem == "com.apple.bluetooth"`,
///   where `Server.Handsfree` carries SCO setup and teardown) on one clock. That
///   pairing is how the 163 ms in `BLUETOOTH-AUDIO.md` was measured.
///
/// * **iOS** — `log stream` **cannot reach a device at all**: its `--device`
///   flag no longer exists. `devicectl` has no console subcommand either, and
///   `devicectl device process launch --console` forwards only stdout and
///   stderr — an `os_log` line does not appear there. Verified 2026-08-22, by
///   launching this app on a phone and watching nothing arrive. Hence the
///   stdout mirror:
///   ```sh
///   xcrun devicectl device process launch --console --device <name> au.charlesmartin.currawong
///   ```
///   The alternative is Console.app, which works and is a GUI. This keeps the
///   phone readable from a terminal, which is this repository's rule.
///
/// `DEBUG` only, so a release build carries the unified-log path and nothing
/// else.
///
/// ## What it is deliberately not
///
/// **Nothing here changes behaviour.** No branch reads these logs, no state is
/// derived from them, and removing this file would leave the transmit path
/// identical. That is the point: an instrument that participates in the thing it
/// measures is not an instrument. In particular ``startRouteLogging()`` adds a
/// *second* observer of the route-change notification, purely to record the
/// reason code the library's `AudioSessionSignal` does not carry — it must never
/// be the thing that drops transmit. SF-3 is served by `RadioSession.handle(_:)`
/// and by nothing in this file.
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

    /// The stdout half. See the type note: this is what makes a phone readable
    /// from a terminal, and it is the *only* thing that does.
    private static func mirror(_ category: String, _ message: String) {
        #if DEBUG
        print("[currawong:\(category)] \(message)")
        #endif
    }

    // MARK: - Route-change reasons (iOS)

    /// Whether ``startRouteLogging()`` has already registered its observer.
    /// Main-actor isolated rather than locked: the only caller is the
    /// composition root, on the main actor, once.
    @MainActor private static var isRouteLoggingStarted = false

    /// Begin recording route-change *reasons*, which the library's
    /// `AudioSessionSignal.routeChanged` does not carry.
    ///
    /// `BU-13` names this instrument specifically: an `oldDeviceUnavailable`
    /// around an unkey would close that item, and no other signal in the app
    /// distinguishes it from the ordinary A2DP↔HFP swap that keying itself
    /// causes (`BU-15`).
    ///
    /// Idempotent, and registers no observer on macOS, which has no
    /// `AVAudioSession` — there the equivalent signal is
    /// `AVAudioEngineConfigurationChange`, which the library already observes on
    /// both platforms and which reaches ``RadioSession`` as `.routeChanged`.
    @MainActor
    static func startRouteLogging() {
        guard !isRouteLoggingStarted else { return }
        isRouteLoggingStarted = true

        // One line at launch, on both platforms, so "the instrument is live"
        // can be confirmed *before* going on air rather than inferred from
        // silence afterwards. Silence is the failure mode these items already
        // suffer from; an instrument that cannot be seen to be running is one
        // more of them.
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
