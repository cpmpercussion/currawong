// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

/// What a remote-control button asked for.
///
/// Three cases rather than one because `MPRemoteCommandCenter` has three
/// commands and different accessories send different ones: a one-button headset
/// sends toggle, a media remote with separate transport keys sends play and
/// pause. Where the app is given separate edges it uses them; where it is given
/// a toggle it toggles.
enum RemoteCommandEvent: Sendable, Equatable {
    case toggle
    case key
    case unkey
}

/// The seam over `MPRemoteCommandCenter`, for the same reason ``BLECentral``
/// exists over CoreBluetooth: the real thing needs a running audio session, a
/// now-playing item and a physical button, and a unit test has none of those.
protocol RemoteCommandSource: AnyObject, Sendable {
    var commands: AsyncStream<RemoteCommandEvent> { get }

    /// Start taking over the transport controls. Only ever called when the
    /// operator has switched this on: a radio app that swallows the pause
    /// button by default is a radio app that breaks everybody's podcast.
    func enable()

    /// Hand the transport controls back.
    func disable()
}

/// **PT-4.** Headset and HID buttons as a PTT, with the toggle semantics that
/// come with them.
///
/// ## The honest part
///
/// `MPRemoteCommandCenter` delivers *commands*, not *edges*. A headset button
/// sends "toggle play/pause" when it is pressed and says nothing at all when it
/// is let go. There is no release to hang an unkey on, so this input **latches**:
/// press once to transmit, press again to stop. That is a materially different
/// contract from PT-1 and PT-2 and the requirement acknowledges it.
///
/// What the requirement does not license is leaving the operator to guess.
/// Everything keyed this way sets ``PTTSource/remoteCommand`` on the session,
/// and the transmit banner says "latched — press again to stop" for as long as
/// it lasts. An operator who is unsure whether letting go will unkey them is an
/// operator about to leave a microphone open.
///
/// PT-5 and PT-6 both apply here and are why this is the *only* fallback:
/// `GCKeyboard` is foreground-only, and volume-button interception fails App
/// Store review.
@MainActor
final class RemoteCommandPTTController: ObservableObject {

    /// Whether the transport controls are being taken over. Off by default and
    /// persisted; see the note above about podcasts.
    @Published private(set) var isEnabled: Bool

    weak var sink: PTTSink?

    private let makeSource: () -> RemoteCommandSource
    private let store: PTTSettingsStore
    private var source: RemoteCommandSource?
    private var commandTask: Task<Void, Never>?

    init(
        makeSource: @escaping () -> RemoteCommandSource = { MediaPlayerRemoteCommandSource() },
        store: PTTSettingsStore = UserDefaultsPTTSettingsStore()
    ) {
        self.makeSource = makeSource
        self.store = store
        self.isEnabled = store.loadRemoteCommandEnabled()
    }

    deinit {
        commandTask?.cancel()
    }

    /// Re-arms at launch if the operator left it on. Nothing is constructed
    /// when it is off, so an operator who does not use this never has their
    /// media controls touched.
    func activateIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        store.saveRemoteCommandEnabled(enabled)
        if enabled {
            start()
        } else {
            source?.disable()
            // A latched transmission must not survive the input that latched it
            // being switched off.
            sink?.pttReleased(from: .remoteCommand, reason: .remoteCommandToggled)
        }
    }

    private func start() {
        if source == nil {
            let source = makeSource()
            self.source = source
            let commands = source.commands
            commandTask = Task { @MainActor [weak self] in
                for await command in commands {
                    self?.handle(command)
                }
            }
        }
        source?.enable()
    }

    private func handle(_ command: RemoteCommandEvent) {
        guard isEnabled else { return }
        switch command {
        case .toggle:
            sink?.pttToggled(from: .remoteCommand)
        case .key:
            sink?.pttPressed(from: .remoteCommand)
        case .unkey:
            sink?.pttReleased(from: .remoteCommand, reason: .remoteCommandToggled)
        }
    }
}

#if canImport(MediaPlayer)

import MediaPlayer

/// The real ``RemoteCommandSource``. The only file that imports `MediaPlayer`.
///
/// Remote commands are only delivered to an app the system considers to be the
/// current "now playing" app, so a minimal now-playing entry is published while
/// this is enabled. That is a real constraint rather than a detail: if another
/// app takes over playback, the headset button follows it, and the operator's
/// PTT stops working with no error anywhere. The accessory screen says so.
final class MediaPlayerRemoteCommandSource: RemoteCommandSource, @unchecked Sendable {
    let commands: AsyncStream<RemoteCommandEvent>
    private let continuation: AsyncStream<RemoteCommandEvent>.Continuation
    private var isEnabled = false

    init() {
        var escaped: AsyncStream<RemoteCommandEvent>.Continuation!
        self.commands = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
    }

    deinit {
        continuation.finish()
    }

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        let centre = MPRemoteCommandCenter.shared()
        let continuation = self.continuation

        centre.togglePlayPauseCommand.isEnabled = true
        centre.togglePlayPauseCommand.addTarget { _ in
            continuation.yield(.toggle)
            return .success
        }
        centre.playCommand.isEnabled = true
        centre.playCommand.addTarget { _ in
            continuation.yield(.key)
            return .success
        }
        centre.pauseCommand.isEnabled = true
        centre.pauseCommand.addTarget { _ in
            continuation.yield(.unkey)
            return .success
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Currawong",
            MPMediaItemPropertyArtist: "Push to talk",
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        let centre = MPRemoteCommandCenter.shared()
        centre.togglePlayPauseCommand.removeTarget(nil)
        centre.playCommand.removeTarget(nil)
        centre.pauseCommand.removeTarget(nil)
        centre.togglePlayPauseCommand.isEnabled = false
        centre.playCommand.isEnabled = false
        centre.pauseCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

#else

/// A platform with no MediaPlayer framework. Not reachable on iOS or macOS.
final class MediaPlayerRemoteCommandSource: RemoteCommandSource, @unchecked Sendable {
    let commands: AsyncStream<RemoteCommandEvent>

    init() {
        self.commands = AsyncStream { $0.finish() }
    }

    func enable() {}
    func disable() {}
}

#endif
