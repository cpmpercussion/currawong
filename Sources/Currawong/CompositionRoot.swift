// SPDX-License-Identifier: Apache-2.0

import EchoLinkKit
import Foundation
import IAX2Kit
import M17Kit
import RadioCore

/// The one object in Currawong allowed to name a concrete network.
///
/// Views and view models see ``RadioSession``, ``RadioLink`` and
/// ``RadioLinkEvent``, never a protocol library. This file is the documented
/// exception: it is the only place `IAX2Kit`, `M17Kit` and `EchoLinkKit` are
/// imported, and ``makeLink(settings:identity:credentials:transmitTimeout:proxy:)`` is where
/// `settings.mode` chooses an `IAX2Client`, `M17Client` or `EchoLinkClient`.
/// All three factories return the same non-generic ``RadioLink``.
///
/// ## Why the factories name concrete clients
///
/// Each factory maps its client's own `events` stream into ``RadioLinkEvent``,
/// and wires DTMF sending to the client's `send(dtmf:)`. `NetworkClient` has
/// generic equivalents for events, received audio and captured audio
/// (`radioEvents`, `receivedAudio`, `send(pcm:)`), which the factories do not
/// yet use. Sending DTMF (FR-1.5) is still not on the protocol, so that one
/// genuinely needs the concrete type.
///
/// ## Also owned here
///
/// The PTT input controllers (PT-2, PT-3, PT-4), which live as long as the
/// process and must be wired exactly once, each to a weak ``PTTSink`` — the
/// session. That wiring is what delivers SF-2's release edges.
///
/// ## Client lifetime
///
/// One client per connection. `NetworkClient.disconnect()` is terminal — it
/// finishes the client's streams for good — so reconnecting needs a new client,
/// and ``RadioSession`` is handed a factory rather than a client.
@MainActor
final class CompositionRoot {
    /// The view model everything else in the app is built on.
    let session: RadioSession

    /// **PT-2, PT-3.** The Bluetooth accessory, for the process lifetime. No
    /// permission prompt until an accessory is learned or its screen opened.
    let accessory: BLEPTTController

    /// **PT-4.** The headset or remote button. Off until the operator enables it.
    let remoteCommand: RemoteCommandPTTController

    /// Transmit state, for anything that only needs to display it.
    var transmitState: TransmitState { session.transmitState }

    /// **EchoLink.** The station browser's state. This and the three helpers
    /// below are owned here so a fetch outlives the pane that started it.
    let stationBrowser: StationBrowser

    /// **EchoLink.** The public proxy search (EL-12).
    let proxyPicker: ProxyPicker

    /// **M17.** The reflector chooser, over the published host file.
    let reflectorBrowser: ReflectorBrowser

    /// **AllStarLink.** The node-number lookup, over the public stats API.
    let nodeLocator: NodeLocator

    /// **APP-12.** The portal login, over ``AllStarLinkPortalLogin``. A `nil`
    /// login (previews, tests) means no logging in.
    let portalLogin: PortalLoginController

    /// - Parameters:
    ///   - configuration: the IAX2 media grid, jitter buffer and leveller. The
    ///     watchdog timeout is not taken from here: it is the operator's
    ///     app-wide ``TransmitTimeout``, applied per link.
    ///   - audio: the microphone and speaker; a test injects a fake.
    init(
        configuration: IAX2Client.Configuration = IAX2Client.Configuration(
            leveller: CompositionRoot.receiveLeveller),
        audio: AudioIO = AudioPipelineIO(),
        // A UI test may substitute a throwaway suite; see ``DefaultsSuite``.
        settingsStore: SettingsStore = UserDefaultsSettingsStore(
            defaults: DefaultsSuite.resolved),
        secretStore: SecretStore = KeychainSecretStore(),
        // `nil` defaults: a default argument is evaluated nonisolated, and these
        // are `@MainActor`, so they are built in the body instead.
        accessory: BLEPTTController? = nil,
        remoteCommand: RemoteCommandPTTController? = nil,
        stationDirectory: any StationDirectory = EchoLinkStationDirectory(),
        proxyFinder: any ProxyFinder = EchoLinkPublicProxyFinder(),
        reflectorDirectory: any ReflectorDirectory = HostFileReflectorDirectory(),
        nodeLookup: any NodeLookup = AllStarLinkNodeLookup(),
        portalLogin: (any PortalLogin)? = AllStarLinkPortalLogin(),
        // `nil` for the same isolation reason.
        activity: TransmitActivityController? = nil
    ) {
        // Diagnostic route-change reasons (BU-13). Here, not in the lazily built
        // pipeline, so changes before the first key-down are logged too.
        Diagnostics.startRouteLogging()

        // Before the session, whose release hook captures it (APP-13).
        let proxyPicker = ProxyPicker(finder: proxyFinder)

        let session = RadioSession(
            audio: audio,
            settingsStore: settingsStore,
            secretStore: secretStore,
            makeLink: { settings, identity, credentials, transmitTimeout, proxy in
                switch settings.mode {
                case .allStarLink:
                    return CompositionRoot.makeIAX2Link(
                        settings: settings, identity: identity, credentials: credentials,
                        transmitTimeout: transmitTimeout,
                        configuration: configuration)
                case .m17:
                    return try CompositionRoot.makeM17Link(
                        settings: settings, identity: identity,
                        transmitTimeout: transmitTimeout)
                case .echoLink:
                    // The secret is the EchoLink account password here.
                    return try CompositionRoot.makeEchoLinkLink(
                        settings: settings, identity: identity, secret: credentials.secret,
                        proxy: proxy, transmitTimeout: transmitTimeout)
                }
            },
            releaseProxyLease: { proxyPicker.releaseLease() },
            // **SF-4.** The lock-screen transmit indicator.
            activity: activity ?? CompositionRoot.makeActivityController())
        // Same suite as the settings store, so a UI test isolates both.
        let pttStore = UserDefaultsPTTSettingsStore(defaults: DefaultsSuite.resolved)
        let accessory = accessory ?? BLEPTTController(store: pttStore)
        let remoteCommand = remoteCommand ?? RemoteCommandPTTController(store: pttStore)

        self.session = session
        self.accessory = accessory
        self.remoteCommand = remoteCommand
        self.stationBrowser = StationBrowser(directory: stationDirectory)
        self.proxyPicker = proxyPicker
        self.reflectorBrowser = ReflectorBrowser(directory: reflectorDirectory)
        self.nodeLocator = NodeLocator(lookup: nodeLookup)
        self.portalLogin = PortalLoginController(login: portalLogin)

        // The wire SF-2 depends on (weak on the controllers' side).
        accessory.sink = session
        remoteCommand.sink = session

        // BU-14's repair: only the session knows when nothing is on air, the
        // one time the accessory may rebuild a silently dead link (SF-2).
        session.onIdleAudioRouteChange = { [weak accessory] in
            accessory?.audioRouteDidChange()
        }
        // Asked again before a timer-scheduled repair: the operator may have
        // keyed on the on-screen button since, which the controller cannot see.
        accessory.isRebuildSafe = { [weak session] in
            session?.isIdleForAccessoryRepair ?? false
        }
        // The SF-1 watchdog fires exactly when no release arrived, so it is what
        // withdraws an accessory-keyed claim whose release is never coming;
        // without it that claim would block every repair, Reconnect included.
        session.onWatchdogUnkey = { [weak accessory] in
            accessory?.radioUnkeyedExternally()
        }
    }

    /// Starts everything with a process-long lifetime. Idempotent. Separate from
    /// `init` because a permission prompt and taking the transport controls
    /// should not happen while SwiftUI may still discard the value.
    func activate() {
        session.start()
        accessory.activateIfConfigured()
        remoteCommand.activateIfEnabled()
    }

    /// **SF-4.** The transmit Live Activity's controller; a disabled one on
    /// macOS, so the same code paths still run there.
    private static func makeActivityController() -> TransmitActivityController {
        #if os(iOS)
        return TransmitActivityController(presenter: ActivityKitPresenter())
        #else
        return .disabled
        #endif
    }

    /// **AU-4.** The received-audio leveller for every mode: −12 dBFS rather
    /// than the library's −18, which is too quiet from a phone speaker.
    static let receiveLeveller = AudioLeveller(targetRMSdBFS: -12)

    /// **SF-1.** The operator's watchdog timeout, as the library wants it. A
    /// function so it can be tested: a built client's timeout cannot be read back.
    static func watchdogTimeout(for timeout: TransmitTimeout) -> Duration {
        .seconds(timeout.seconds)
    }

    // MARK: - Web Transceiver (APP-11)

    /// The shared guest account every Web Transceiver call authenticates as
    /// (IAX-12). The operator's callsign draws a bare REJECT.
    static let webTransceiverUsername = "allstar-public"

    /// The guest account's secret, the same on every ASL3 node. Not the token.
    static let webTransceiverSecret = "allstar"

    /// The extension a WT call dials: `s`, never the node number. CALLING
    /// NUMBER decides which node answers.
    static let webTransceiverExtension = "s"

    /// What a Web Transceiver guest call presents. Exists so the mapping, which
    /// is mostly counter-intuitive, can be tested.
    struct WebTransceiverCall: Equatable {
        /// The shared guest account, not the operator's callsign.
        let username: String
        /// The static secret that account uses. Not the token.
        let secret: String
        /// The extension dialled — `s`, never the node number.
        let dialledExtension: String
        /// CALLING NUMBER: becomes NODENUM and selects the node.
        let callingNumber: String
        /// CALLING NAME: the token, which the node resolves to a callsign.
        let callingName: String
        /// CALLING NAME's counterpart — who we say we are on the air.
        let callsign: String
    }

    /// The guest-call parameters for a channel, or `nil` when it is not a Web
    /// Transceiver one (IAX-12).
    ///
    /// The node sends CALLING NAME to allstarlink.org to resolve a callsign —
    /// that is the whole of the authentication — so the token goes there,
    /// unaltered; `callsign` is upper-cased and would corrupt it.
    static func webTransceiverCall(
        settings: NodeSettings,
        identity: OperatorIdentity,
        credentials: RadioSession.LinkCredentials
    ) -> WebTransceiverCall? {
        guard settings.usesWebTransceiver else { return nil }

        return WebTransceiverCall(
            username: webTransceiverUsername,
            secret: webTransceiverSecret,
            dialledExtension: webTransceiverExtension,
            callingNumber: settings.node,
            callingName: credentials.webTransceiverToken,
            callsign: identity.callsign)
    }

    /// ``webTransceiverCall(settings:identity:credentials:)`` as a library
    /// destination.
    private static func webTransceiverDestination(
        _ settings: NodeSettings,
        _ identity: OperatorIdentity,
        _ credentials: RadioSession.LinkCredentials
    ) -> IAX2Destination? {
        guard
            let call = webTransceiverCall(
                settings: settings, identity: identity, credentials: credentials)
        else { return nil }

        return IAX2Destination(
            host: settings.host,
            port: settings.port,
            callsign: call.callsign,
            username: call.username,
            secret: call.secret,
            node: call.dialledExtension,
            callingNumber: call.callingNumber,
            callingName: call.callingName)
    }

    /// Builds one IAX2 connection's worth of plumbing. Opens nothing until
    /// `connect`; an unused link costs two suspended tasks, released by `close()`.
    ///
    /// `transmitTimeout` overrides `configuration.transmitTimeout`: the library
    /// enforces SF-1, with the operator's number. The other factories do the same.
    static func makeIAX2Link(
        settings: NodeSettings,
        identity: OperatorIdentity,
        credentials: RadioSession.LinkCredentials,
        transmitTimeout: TransmitTimeout = .default,
        configuration: IAX2Client.Configuration = IAX2Client.Configuration(
            leveller: CompositionRoot.receiveLeveller)
    ) -> RadioLink {
        var configuration = configuration
        configuration.transmitTimeout = watchdogTimeout(for: transmitTimeout)

        let client = IAX2Client(configuration: configuration)
        let destination = webTransceiverDestination(settings, identity, credentials)
            ?? IAX2Destination(
                host: settings.host,
                port: settings.port,
                callsign: identity.callsign,
                username: settings.username,
                secret: credentials.secret,
                node: settings.node)

        var eventEscape: AsyncStream<RadioLinkEvent>.Continuation!
        let events = AsyncStream<RadioLinkEvent> { eventEscape = $0 }
        let eventContinuation = eventEscape!

        // Translated, because `IAX2ClientEvent` must not escape this file.
        let clientEvents = client.events
        let eventPump = Task.detached {
            for await event in clientEvents {
                if let translated = RadioLinkEvent(event) {
                    eventContinuation.yield(translated)
                }
            }
            eventContinuation.finish()
        }

        // The audio thread must not await an actor, so captured frames go
        // through a bounded relay and an ordinary task feeds them in.
        let relay = CapturedFrameRelay()
        let frames = relay.frames
        let sendPump = Task.detached {
            for await frame in frames {
                _ = try? await client.send(pcm: frame)
            }
        }

        return RadioLink(
            mode: .allStarLink,
            connect: { try await client.connect(to: destination) },
            disconnect: { await client.disconnect() },
            startTransmit: { try await client.startTransmit() },
            stopTransmit: { await client.stopTransmit() },
            transmitState: { client.state },
            events: events,
            receivedAudio: client.receivedAudio,
            sendCapturedFrame: { relay.submit($0) },
            sendDTMF: { digit in try await client.send(dtmf: digit) },
            close: {
                relay.finish()
                sendPump.cancel()
                eventPump.cancel()
                eventContinuation.finish()
            })
    }

    /// Builds one M17 connection's worth of plumbing. Unlike IAX2: no secret
    /// (reflectors do not authenticate), a reflector module instead of a node
    /// number, no DTMF (`sendDTMF` throws), and an injected codec from
    /// ``makeVoiceCodec()``.
    static func makeM17Link(
        settings: NodeSettings,
        identity: OperatorIdentity,
        transmitTimeout: TransmitTimeout = .default,
        configuration: M17Client.Configuration = M17Client.Configuration(
            leveller: CompositionRoot.receiveLeveller)
    ) throws -> RadioLink {
        var configuration = configuration
        configuration.transmitTimeout = watchdogTimeout(for: transmitTimeout)

        guard settings.module.count == 1, let module = settings.module.first else {
            throw M17LinkError.invalidModule(settings.module)
        }

        let client = M17Client(
            codec: try makeVoiceCodec(),
            configuration: configuration,
            clock: ContinuousClock())
        let destination = M17Destination(
            host: settings.host,
            port: settings.port,
            module: module,
            callsign: identity.callsign)

        var eventEscape: AsyncStream<RadioLinkEvent>.Continuation!
        let events = AsyncStream<RadioLinkEvent> { eventEscape = $0 }
        let eventContinuation = eventEscape!

        let clientEvents = client.events
        let eventPump = Task.detached {
            for await event in clientEvents {
                if let translated = RadioLinkEvent(event) {
                    eventContinuation.yield(translated)
                }
            }
            eventContinuation.finish()
        }

        let relay = CapturedFrameRelay()
        let frames = relay.frames
        let sendPump = Task.detached {
            for await frame in frames {
                _ = try? await client.send(pcm: frame)
            }
        }

        return RadioLink(
            mode: .m17,
            connect: { try await client.connect(to: destination) },
            disconnect: { await client.disconnect() },
            startTransmit: { try await client.startTransmit() },
            stopTransmit: { await client.stopTransmit() },
            transmitState: { client.state },
            events: events,
            receivedAudio: client.receivedAudio,
            sendCapturedFrame: { relay.submit($0) },
            sendDTMF: { _ in throw M17LinkError.dtmfUnsupported },
            close: {
                relay.finish()
                sendPump.cancel()
                eventPump.cancel()
                eventContinuation.finish()
            })
    }

    /// Builds one EchoLink connection's worth of plumbing.
    ///
    /// - The proxy is a parameter, not a setting (APP-13, FR-3.3).
    /// - `settings.peer` must be a dotted quad: the proxy protocol carries raw
    ///   octets and resolves no DNS.
    /// - The account password authenticates to the directory server, not the
    ///   node (FR-3.4). The library throws when only one of it and the server
    ///   is present, so unless both parse, both go in as `nil` and the session
    ///   runs unauthenticated rather than failing.
    /// - No DTMF: `sendDTMF` throws.
    ///
    /// - Parameters:
    ///   - secret: the account password; empty means no directory login.
    ///   - proxy: resolved by ``ProxyPicker``; `nil` throws.
    ///   - configuration: for tests. The operator's fields (callsign, name,
    ///     location, watchdog, directory pair) are overwritten regardless.
    static func makeEchoLinkLink(
        settings: NodeSettings,
        identity: OperatorIdentity,
        secret: String,
        proxy: EchoLinkProxyRoute?,
        transmitTimeout: TransmitTimeout = .default,
        configuration: EchoLinkClient.Configuration? = nil
    ) throws -> RadioLink {
        guard let peer = EchoLinkPeerAddress(settings.peer) else {
            throw EchoLinkLinkError.invalidPeerAddress(settings.peer)
        }
        guard let proxy, !proxy.host.isEmpty else {
            throw EchoLinkLinkError.missingProxyHost
        }

        // All or nothing; a server address that fails to parse counts as absent.
        var accountPassword: EchoLinkAccountPassword? =
            secret.isEmpty ? nil : EchoLinkAccountPassword(secret)
        var directoryServer: EchoLinkPeerAddress? =
            settings.directoryServer.isEmpty
            ? nil : EchoLinkPeerAddress(settings.directoryServer)
        if accountPassword == nil || directoryServer == nil {
            accountPassword = nil
            directoryServer = nil
        }

        var configuration = configuration ?? EchoLinkClient.Configuration(
            callsign: identity.callsign, leveller: Self.receiveLeveller)
        configuration.callsign = identity.callsign
        configuration.operatorName = identity.operatorName
        configuration.location = identity.location
        configuration.transmitTimeout = watchdogTimeout(for: transmitTimeout)
        configuration.accountPassword = accountPassword
        configuration.directoryServer = directoryServer

        let client = EchoLinkClient(
            codec: try makeGSMVoiceCodec(),
            configuration: configuration,
            clock: ContinuousClock())
        let destination = EchoLinkDestination(
            peer: peer,
            node: settings.node,
            route: .proxy(
                host: proxy.host,
                port: proxy.port,
                password: EchoLinkProxyPassword(proxy.password)))

        var eventEscape: AsyncStream<RadioLinkEvent>.Continuation!
        let events = AsyncStream<RadioLinkEvent> { eventEscape = $0 }
        let eventContinuation = eventEscape!

        let clientEvents = client.events
        let eventPump = Task.detached {
            for await event in clientEvents {
                if let translated = RadioLinkEvent(event) {
                    eventContinuation.yield(translated)
                }
            }
            eventContinuation.finish()
        }

        let relay = CapturedFrameRelay()
        let frames = relay.frames
        let sendPump = Task.detached {
            for await frame in frames {
                _ = try? await client.send(pcm: frame)
            }
        }

        return RadioLink(
            mode: .echoLink,
            connect: { try await client.connect(to: destination) },
            disconnect: { await client.disconnect() },
            startTransmit: { try await client.startTransmit() },
            stopTransmit: { await client.stopTransmit() },
            transmitState: { client.state },
            events: events,
            receivedAudio: client.receivedAudio,
            sendCapturedFrame: { relay.submit($0) },
            sendDTMF: { _ in throw EchoLinkLinkError.dtmfUnsupported },
            close: {
                relay.finish()
                sendPump.cancel()
                eventPump.cancel()
                eventContinuation.finish()
            })
    }

    /// The M17 path's Codec 2 3200: the library's pure-Swift
    /// `WeebillVoiceCodec` (M17-7). Not `private`, so a test can check the
    /// codec actually injected.
    static func makeVoiceCodec() throws -> any VoiceCodec {
        return try WeebillVoiceCodec()
    }

    /// EchoLink's GSM 06.10 codec. Throws if the C state fails to allocate.
    private static func makeGSMVoiceCodec() throws -> any VoiceCodec {
        try GSMVoiceCodec()
    }

    /// Builds a link for whichever mode the settings name.
    static func makeLink(
        settings: NodeSettings,
        identity: OperatorIdentity,
        credentials: RadioSession.LinkCredentials,
        transmitTimeout: TransmitTimeout = .default,
        proxy: EchoLinkProxyRoute? = nil
    ) throws -> RadioLink {
        switch settings.mode {
        case .allStarLink:
            return makeIAX2Link(
                settings: settings, identity: identity, credentials: credentials,
                transmitTimeout: transmitTimeout)
        case .m17:
            return try makeM17Link(
                settings: settings, identity: identity, transmitTimeout: transmitTimeout)
        case .echoLink:
            return try makeEchoLinkLink(
                settings: settings, identity: identity, secret: credentials.secret,
                proxy: proxy, transmitTimeout: transmitTimeout)
        }
    }
}

/// What can go wrong building an EchoLink link.
enum EchoLinkLinkError: Error, Equatable, CustomStringConvertible {
    /// `settings.peer` is not four decimal octets.
    case invalidPeerAddress(String)

    /// No proxy was sourced. A backstop behind ``ProxyPicker``, which would
    /// otherwise surface as a socket error.
    case missingProxyHost

    /// DTMF was attempted on a mode that has no such thing.
    case dtmfUnsupported

    var description: String {
        switch self {
        case .invalidPeerAddress(let peer):
            let quoted = peer.isEmpty ? "The node address is empty" : "'\(peer)' is not an address"
            return """
                \(quoted). EchoLink needs the node's IP address as four numbers, \
                like 192.0.2.10 — a hostname will not work. Look the node up in \
                the EchoLink directory to find it.
                """
        case .missingProxyHost:
            return """
                No EchoLink proxy could be found. Public proxies carry one user at a time and \
                are heavily contended, so this is usually contention rather than a fault — try \
                again, or set your own proxy in Settings.
                """
        case .dtmfUnsupported:
            return "EchoLink has no DTMF signalling. Connect to an AllStarLink node to send digits."
        }
    }
}

/// What can go wrong building an M17 link.
enum M17LinkError: Error, Equatable, CustomStringConvertible {
    /// The module is not a single letter; a backstop behind validation.
    case invalidModule(String)

    /// DTMF was attempted on a mode that has no such thing.
    case dtmfUnsupported

    var description: String {
        switch self {
        case .invalidModule(let module):
            return "'\(module)' is not a reflector module. Use a single letter, A to Z."
        case .dtmfUnsupported:
            return "M17 has no DTMF signalling. Connect to an AllStarLink node to send digits."
        }
    }
}

/// The `M17ClientEvent` → ``RadioLinkEvent`` translation.
extension RadioLinkEvent {
    fileprivate init?(_ event: M17ClientEvent) {
        switch event {
        case .linked:
            // Not negotiated: an M17 voice stream is Codec 2 3200.
            self = .connected(codec: "Codec2 3200")
        case .transmitting:
            self = .transmitting
        case .receiving:
            self = .receiving
        case .transmitWatchdogExpired(let timeout):
            self = .transmitWatchdogExpired(timeout)
        case .streamStarted(let source, _):
            self = .remoteStation(callsign: source.callsign)
        case .streamEnded:
            self = .remoteStation(callsign: nil)
        case .streamRejected(let rejection):
            self = .mediaRejected("Incoming audio is being dropped: \(rejection).")
        case .disconnected(let reason):
            self = .disconnected(reason: reason.map { "The link dropped: \($0)." })
        case .connecting:
            return nil
        }
    }
}

/// The `IAX2ClientEvent` → ``RadioLinkEvent`` translation; `nil` for events
/// the app does not use.
extension RadioLinkEvent {
    fileprivate init?(_ event: IAX2ClientEvent) {
        switch event {
        case .connected(let format):
            // Names the RFC's codecs, or the raw bitmask for anything unknown.
            self = .connected(codec: format.map(String.init(describing:)))
        case .transmitting:
            self = .transmitting
        case .receiving:
            self = .receiving
        case .transmitWatchdogExpired(let timeout):
            self = .transmitWatchdogExpired(timeout)
        case .mediaRejected(let rejection):
            self = .mediaRejected("Incoming audio is being dropped: \(rejection).")
        case .disconnected(let termination):
            self = .disconnected(reason: termination.map { "The node ended the call: \($0)." })
        case .dtmf(let digit):
            self = .dtmfReceived(digit.character)
        }
    }
}

/// The `EchoLinkClientEvent` → ``RadioLinkEvent`` translation.
///
/// - `connecting` and `directoryLoggedIn` happen inside `connect(to:)`, which
///   the session already shows, so they are dropped.
/// - `stationInfo`, the far node's free-text description, is dropped:
///   ``RadioLinkEvent`` has nowhere to put it but the station identity.
/// - `talkspurtStarted` is only `receiving`: EchoLink identifies the session,
///   not each over, so the station stays the one from `nodeAnswered`.
extension RadioLinkEvent {
    fileprivate init?(_ event: EchoLinkClientEvent) {
        switch event {
        case .connected:
            // Not negotiated: EchoLink audio is GSM 06.10. The node name is
            // dropped; the operator chose the destination.
            self = .connected(codec: "GSM 06.10")
        case .transmitting:
            self = .transmitting
        case .receiving, .talkspurtStarted:
            self = .receiving
        case .transmitTimedOut(let timeout):
            self = .transmitWatchdogExpired(timeout)
        case .nodeAnswered(let name):
            // The far end's SDES identity.
            self = .remoteStation(callsign: name)
        case .disconnected(let reason):
            // Already operator-facing prose.
            self = .disconnected(reason: reason.description)
        case .connecting, .directoryLoggedIn, .stationInfo:
            return nil
        }
    }
}

/// The real EchoLink station directory (EL-11): a directory-only session
/// through the proxy, which contacts no node and transmits nothing.
///
/// One client per fetch, disconnected even when the fetch throws — a public
/// proxy is single-user, so an abandoned session blocks it for everyone.
struct EchoLinkStationDirectory: StationDirectory {
    /// Resolves the directory server's name; injectable so tests skip DNS.
    private let resolver: any HostResolver

    init(resolver: any HostResolver = SystemHostResolver()) {
        self.resolver = resolver
    }

    func stations(
        for settings: NodeSettings, identity: OperatorIdentity, accountPassword: String,
        proxy: EchoLinkProxyRoute
    ) async throws -> [DirectoryStation] {
        if let missing = StationBrowser.whatIsMissing(
            in: settings, identity: identity, accountPassword: accountPassword, proxy: proxy)
        {
            throw missing
        }

        // The library takes four octets and resolves nothing.
        let address = try await resolver.ipv4Address(for: settings.directoryServer)
        guard let directoryServer = EchoLinkPeerAddress(address) else {
            throw StationDirectoryError.missingDirectoryServer
        }

        // `normalisedCallsign` (APP-14): uppercased, as on the QSO path, so
        // both authenticate the same whatever case was typed.
        var configuration = EchoLinkClient.Configuration(
            callsign: identity.normalisedCallsign)
        configuration.operatorName = identity.operatorName
        configuration.location = identity.location
        configuration.accountPassword = EchoLinkAccountPassword(accountPassword)
        configuration.directoryServer = directoryServer

        let client = EchoLinkClient(
            codec: try GSMVoiceCodec(),
            configuration: configuration,
            clock: ContinuousClock())

        // Unused in a directory-only session, but a destination must name one.
        let destination = EchoLinkDestination(
            peer: .unspecified,
            node: settings.node,
            route: .proxy(
                host: proxy.host,
                port: proxy.port,
                password: EchoLinkProxyPassword(proxy.password)))

        try await client.connect(to: destination, mode: .directoryOnly)
        do {
            let list = try await client.fetchStationList()
            await client.disconnect()
            return list.stations.map(DirectoryStation.init)
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

/// Wraps the library's `WebTransceiverTokenSource`, which exchanges a portal
/// login for a Web Transceiver token (APP-12).
///
/// The library owns the request; a replacement endpoint (OQ-10, caveat 2)
/// would be another conformance injected here, with no change to this file.
struct AllStarLinkPortalLogin: PortalLogin {
    /// Injectable for tests. The default endpoint is HTTPS-only.
    private let source: any WebTransceiverTokenSource

    init(source: any WebTransceiverTokenSource = AllStarLinkPortalTokenFetcher()) {
        self.source = source
    }

    func token(callsign: String, password: String) async throws -> String {
        do {
            // `.value`, because `WebTransceiverToken` may not leave this file.
            // Its `description` is redacted, so this unwrap is the one place
            // that could leak it; the caller files it straight in the Keychain.
            return try await source.token(username: callsign, password: password).value
        } catch let error as WebTransceiverTokenError {
            throw PortalLoginFailure(error)
        }
        // Anything else propagates; `PortalLoginController` reports it as
        // `.unreachable`.
    }
}

extension PortalLoginFailure {
    /// The library's error cases in the app's, merging those that mean the
    /// same to an operator.
    init(_ error: WebTransceiverTokenError) {
        switch error {
        case .loginFailed:
            self = .wrongPassword
        case .invalidJSONPayload, .invalidJSONFields:
            self = .endpointChanged
        case .rejected(let message):
            self = .refused(message)
        case .malformedResponse(let detail), .requestFailed(let detail):
            self = .unreachable(detail)
        case .insecureEndpoint:
            // Only reachable with an injected non-HTTPS endpoint. A
            // configuration fault, with the same remedy: paste a token.
            self = .endpointChanged
        }
    }
}

/// The real public proxy finder (EL-12), over the library's
/// `EchoLinkProxySelector`: fetch the list, keep public and ready entries,
/// probe the nearest in batches until one answers. EchoLink-only, so not a
/// `NetworkClient` capability.
struct EchoLinkPublicProxyFinder: ProxyFinder {
    /// Injectable for tests.
    private let selector: EchoLinkProxySelector

    init(selector: EchoLinkProxySelector = EchoLinkProxySelector()) {
        self.selector = selector
    }

    func fastestProxy(onProgress: @escaping @Sendable (Int) -> Void) async throws -> ProxyCandidate
    {
        // The library reports each batch; the app keeps the running total.
        let probed = ProbeTally()

        do {
            let result = try await selector.selectFastest { batch in
                onProgress(probed.add(batch.count))
            }
            return ProxyCandidate(
                name: result.proxy.name,
                host: result.proxy.address,
                port: result.proxy.port,
                distanceKilometres: result.proxy.distanceKilometres,
                latencyMilliseconds: result.latency.milliseconds)
        } catch let error as EchoLinkProxyDirectoryError {
            throw ProxyFinderError(error, probed: probed.value)
        }
    }
}

/// A counter safe to touch from the arbitrary task the progress callback
/// runs on.
private final class ProbeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add(_ increment: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += increment
        return count
    }
}

extension ProxyFinderError {
    /// Translates the library's outcome; `probed` is the app's tally, so the
    /// count shown agrees with the progress count.
    fileprivate init(_ error: EchoLinkProxyDirectoryError, probed: Int) {
        switch error {
        case .noProxyAvailable:
            self = .noneAvailable
        case .noProxyAnswered(let libraryProbed):
            self = .noneAnswered(probed: max(libraryProbed, probed))
        default:
            // The list itself failed; the library's wording is used as is.
            self = .listUnavailable(detail: "\(error)")
        }
    }
}

extension Duration {
    /// Whole milliseconds, for display.
    fileprivate var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}

extension DirectoryStation {
    /// Translates a library station. `status` stays the server's own word: the
    /// listing has more states than the app could safely enumerate.
    fileprivate init(_ station: EchoLinkStation) {
        self.init(
            callsign: station.callsign,
            location: station.location,
            nodeNumber: station.nodeNumber,
            address: station.address,
            isConnectable: station.isConnectable,
            status: station.status)
    }
}
