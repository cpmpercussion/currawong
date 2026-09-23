// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

/// What a remote-control button asked for: a one-button headset sends toggle,
/// a media remote sends play and pause.
enum RemoteCommandEvent: Sendable, Equatable {
    case toggle
    case key
    case unkey
}

/// The seam over `MPRemoteCommandCenter`, so tests need no audio session or
/// physical button.
protocol RemoteCommandSource: AnyObject, Sendable {
    var commands: AsyncStream<RemoteCommandEvent> { get }

    /// Takes over the transport controls. Only when the operator has switched
    /// this on, so media controls are otherwise untouched.
    func enable()

    /// Hand the transport controls back.
    func disable()
}

/// Headset and HID buttons as a PTT (PT-4).
///
/// `MPRemoteCommandCenter` delivers commands, not edges: nothing arrives on
/// release, so this input **latches** — press to transmit, press again to stop.
/// Everything keyed this way is ``PTTSource/remoteCommand``, and the transmit
/// banner says it is latched: an operator unsure whether letting go unkeys them
/// is about to leave a microphone open. The only fallback, given PT-5 and PT-6.
@MainActor
final class RemoteCommandPTTController: ObservableObject {

    /// Whether the transport controls are taken over. Off by default;
    /// persisted.
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

    /// Re-arms at launch if left on. Constructs nothing when off.
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

/// The real ``RemoteCommandSource``; the only file importing `MediaPlayer`.
///
/// Commands go only to the "now playing" app, so a minimal now-playing entry is
/// published while enabled. If another app takes over playback, the button
/// follows it and PTT stops with no error — the accessory screen warns of this.
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

/// Stand-in for platforms without MediaPlayer.
final class MediaPlayerRemoteCommandSource: RemoteCommandSource, @unchecked Sendable {
    let commands: AsyncStream<RemoteCommandEvent>

    init() {
        self.commands = AsyncStream { $0.finish() }
    }

    func enable() {}
    func disable() {}
}

#endif
