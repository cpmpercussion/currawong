// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Foundation
import RadioCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A staged app for the App Store screenshots: seeded channels, a link that
/// opens no socket, and audio that touches no microphone or speaker.
///
/// Chosen by launch argument, and only honoured together with a throwaway
/// defaults suite (``DefaultsSuite``), because the stage writes its channels
/// and identity into whatever suite it is given:
///
/// ```sh
/// Currawong -currawong-defaults-suite au.charlesmartin.currawong.screenshots \
///           -currawong-defaults-reset YES \
///           -currawong-screenshot-scene transmitting \
///           -currawong-appearance dark
/// ```
///
/// `#if DEBUG` only. Nothing here goes on air: every ``RadioLink`` it builds
/// is a local fake, whatever the channel says, so the scenes are free to show
/// real destinations. `Tests/CurrawongScreenshots` drives it; `make
/// screenshots` runs that.
struct ScreenshotStage {
    static let sceneArgument = "currawong-screenshot-scene"
    static let appearanceArgument = "currawong-appearance"

    /// One screenshot's worth of state.
    enum Scene: String, CaseIterable {
        /// The channel list, disconnected, with a channel's details beside it.
        case channels
        /// An AllStarLink node, connected and receiving.
        case receiving
        /// An M17 reflector module, keyed.
        case transmitting
    }

    let scene: Scene
    let colorScheme: ColorScheme?

    /// The stage the launch arguments ask for, or `nil` for the ordinary app.
    static let current: ScreenshotStage? = {
        let arguments = UserDefaults.standard
        guard
            let raw = arguments.string(forKey: sceneArgument),
            let scene = Scene(rawValue: raw),
            DefaultsSuite.resolved !== UserDefaults.standard
        else { return nil }
        let colorScheme: ColorScheme?
        switch arguments.string(forKey: appearanceArgument) {
        case "dark": colorScheme = .dark
        case "light": colorScheme = .light
        default: colorScheme = nil
        }
        return ScreenshotStage(scene: scene, colorScheme: colorScheme)
    }()

    // MARK: - What each scene shows

    static let identity = OperatorIdentity(
        callsign: "VK1CPM", operatorName: "Charles", location: "Canberra")

    private static let host = "m17-cbr.charlesmartin.au"

    static let allStarNode = NodeSettings(
        name: "Canberra hub", mode: .allStarLink, host: host, node: "44309",
        username: identity.callsign)
    static let m17Reflector = NodeSettings(
        name: "M17-CBR A", mode: .m17, host: host, port: 17_000, module: "A")
    static let echoTest = NodeSettings(
        name: "Echo test", mode: .echoLink, node: "*ECHOTEST*",
        directoryServer: NodeSettings.defaultDirectoryServer)
    static let parrot = NodeSettings(
        name: "Parrot", mode: .allStarLink, host: host, node: "55553",
        username: identity.callsign)

    static let channels = [allStarNode, m17Reflector, echoTest, parrot]

    private var selectedChannel: NodeSettings {
        switch scene {
        case .channels, .receiving: return Self.allStarNode
        case .transmitting: return Self.m17Reflector
        }
    }

    /// Whether the compact layout opens on the Session tab rather than Channels.
    var opensOnSessionTab: Bool { scene != .channels }

    /// The split layout's pane under the session pane.
    var detailPane: DetailPane {
        switch scene {
        case .channels: return .connect
        case .receiving: return .keypad
        case .transmitting: return .session
        }
    }

    // MARK: - Building it

    /// A composition root over the seeded suite, the fake link and fake audio.
    @MainActor
    func makeRoot() -> CompositionRoot {
        let store = UserDefaultsSettingsStore(defaults: DefaultsSuite.resolved)
        store.saveChannels(Self.channels)
        store.saveSelectedChannelID(selectedChannel.id)
        store.saveIdentity(Self.identity)
        store.saveLicenceAcknowledgement(LicenceAcknowledgement.currentVersion)

        let secrets = StagedSecretStore()
        try? secrets.setSecret(
            "staged", for: Self.allStarNode.secretAccount(for: Self.identity))

        return CompositionRoot(
            audio: StagedAudio(),
            settingsStore: store,
            secretStore: secrets,
            stationDirectory: StagedDirectories(),
            proxyFinder: StagedDirectories(),
            reflectorDirectory: StagedDirectories(),
            nodeLookup: StagedDirectories(),
            portalLogin: nil,
            makeLink: { settings, _, _, _, _ in StagedLink.make(for: settings) },
            resolver: StagedDirectories())
    }

    /// Puts the session into the scene's state. Run once the root view is up.
    @MainActor
    func perform(on session: RadioSession) async {
        #if os(macOS)
        // After the window exists, which the first `task` can precede.
        try? await Task.sleep(nanoseconds: 300_000_000)
        applyWindowAppearance()
        #endif
        guard scene != .channels else { return }
        await session.connect()
        if scene == .transmitting {
            session.beginTransmit()
        }
    }

    #if os(macOS)
    /// The Mac App Store's 2560 × 1600 at 2×, title bar included, and the
    /// chrome in the requested appearance, which `preferredColorScheme` alone
    /// does not reach.
    @MainActor
    private func applyWindowAppearance() {
        switch colorScheme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        let size = CGSize(width: 1280, height: 800)
        let visible = window.screen?.visibleFrame ?? .zero
        window.setFrame(
            CGRect(
                x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                width: size.width, height: size.height),
            display: true)
    }
    #endif
}

// MARK: - The fakes

/// A link that connects at once, receives a synthetic voice while unkeyed, and
/// keys without sending anything anywhere.
private final class StagedLink: @unchecked Sendable {
    private let lock = NSLock()
    private var state: TransmitState = .idle
    private var pump: Task<Void, Never>?

    @MainActor
    static func make(for settings: NodeSettings) -> RadioLink {
        let link = StagedLink()
        var eventSink: AsyncStream<RadioLinkEvent>.Continuation!
        let events = AsyncStream<RadioLinkEvent> { eventSink = $0 }
        var audioSink: AsyncStream<[Int16]>.Continuation!
        let audio = AsyncStream<[Int16]> { audioSink = $0 }
        let (eventContinuation, audioContinuation) = (eventSink!, audioSink!)
        let codec = settings.mode == .m17 ? "Codec 2 3200" : "G.711 µ-law"

        return RadioLink(
            mode: settings.mode,
            connect: {
                link.set(.receiving)
                eventContinuation.yield(.connected(codec: codec))
                link.startPump(into: audioContinuation)
            },
            disconnect: {
                link.set(.idle)
                eventContinuation.yield(.disconnected(reason: nil))
                eventContinuation.finish()
                audioContinuation.finish()
            },
            startTransmit: {
                // Back-dated so the on-air clock is not at 0:00.
                link.set(.transmitting(since: Date().addingTimeInterval(-12)))
                eventContinuation.yield(.transmitting)
            },
            stopTransmit: {
                link.set(.receiving)
                eventContinuation.yield(.receiving)
            },
            transmitState: { link.current },
            events: events,
            receivedAudio: audio,
            sendCapturedFrame: { _ in },
            sendDTMF: { _ in },
            close: { link.stopPump() })
    }

    private var current: TransmitState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func set(_ newState: TransmitState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    private func startPump(into sink: AsyncStream<[Int16]>.Continuation) {
        let task = Task.detached { [weak self] in
            var frame = 0
            while !Task.isCancelled, let self {
                if case .receiving = self.current {
                    sink.yield(SyntheticVoice.frame(frame))
                }
                frame += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        lock.lock()
        pump = task
        lock.unlock()
    }

    private func stopPump() {
        lock.lock()
        pump?.cancel()
        lock.unlock()
    }
}

/// Audio that grants the microphone, plays nothing, and captures a synthetic
/// voice so the transmit meter moves.
private final class StagedAudio: AudioIO, @unchecked Sendable {
    let signals: AsyncStream<AudioSessionSignal> = AsyncStream { _ in }
    private let lock = NSLock()
    private var capture: Task<Void, Never>?

    var lastCaptureStartMilliseconds: Int { 0 }
    var audioStateDescription: String { "staged for screenshots" }

    func requestRecordPermission() async -> Bool { true }
    func configureSession() throws {}
    func prepareForCapture() async {}
    func settleRoute() async {}
    func warmUpInput() async -> InputWarmUpOutcome { .warmed }
    func enqueuePlayback(_ pcm: [Int16]) {}

    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws {
        let task = Task.detached {
            var frame = 0
            while !Task.isCancelled {
                onFrame(SyntheticVoice.frame(frame))
                frame += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        lock.lock()
        capture?.cancel()
        capture = task
        lock.unlock()
    }

    func stopCapture() {
        lock.lock()
        capture?.cancel()
        capture = nil
        lock.unlock()
    }
}

/// 20 ms frames of a tone under a syllable-rate envelope: loud enough, and
/// uneven enough, that a level meter reads as speech.
private enum SyntheticVoice {
    static func frame(_ index: Int) -> [Int16] {
        let t = Double(index) * 0.02
        let envelope = 0.35 + 0.3 * sin(2 * .pi * 3.1 * t) * sin(2 * .pi * 0.7 * t)
        return (0..<160).map { sample in
            let phase = 2 * .pi * 220 * (t + Double(sample) / 8_000)
            return Int16(envelope * 20_000 * sin(phase))
        }
    }
}

/// Secrets held in memory, so the stage never reads or writes the Keychain.
private final class StagedSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func secret(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func setSecret(_ secret: String?, for account: String) throws {
        lock.lock()
        secrets[account] = secret?.isEmpty == false ? secret : nil
        lock.unlock()
    }
}

/// Every lookup the app can make, refused without touching the network.
private struct StagedDirectories: StationDirectory, ProxyFinder, ReflectorDirectory,
    NodeLookup, HostResolver
{
    private struct Offline: Error {}

    func stations(
        for settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute
    ) async throws -> [DirectoryStation] { throw Offline() }

    func fastestProxy(
        onProgress: @escaping @Sendable (Int) -> Void
    ) async throws -> ProxyCandidate { throw Offline() }

    func reflectors() async throws -> [M17Reflector] { throw Offline() }

    func registration(forNode node: String) async throws -> NodeRegistration {
        throw Offline()
    }

    /// Names are returned as they are: the staged link dials nothing.
    func ipv4Address(for host: String) async throws -> String { host }
}
#endif
