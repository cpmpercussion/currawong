// SPDX-License-Identifier: Apache-2.0

import EchoLinkKit
import Foundation
import IAX2Kit
import M17Kit
import RadioCore

/// The one object in Currawong allowed to name a concrete network.
///
/// `RadioCore.NetworkClient` is the boundary between the app and the protocol
/// libraries: views and view models talk to `connect(to:)`, `startTransmit()`,
/// `stopTransmit()`, `disconnect()` and `state`, and know nothing about RFC
/// 5456. Somebody, though, has to decide *which* client is on the other side of
/// that protocol and build it — and this is that somebody. It is the single
/// documented exception to the rule, and it is why `import IAX2Kit`,
/// `import M17Kit` and `import EchoLinkKit` appear in this file and nowhere
/// else.
///
/// ## Three modes
///
/// `settings.mode` chooses between an `IAX2Client`, an `M17Client` and an
/// `EchoLinkClient`, and ``makeLink(settings:secret:)`` is the switch. Nothing
/// above this file knows there is more than one library: all three factories
/// return the same non-generic ``RadioLink``, which is exactly why that type
/// stopped being generic — see its doc comment.
///
/// The third one arriving without any change to ``RadioLink`` or
/// ``RadioLinkEvent`` is the evidence that the seam is in the right place. What
/// it did cost is below: two settings fields that only EchoLink reads, and one
/// pairing rule the library enforces by throwing.
///
/// ## What this file has to do that `NetworkClient` should arguably do for it
///
/// `NetworkClient` covers connecting and keying, and stops there. It has no
/// event stream, no received-audio stream and no way to hand captured audio
/// back — but an app needs all three, and `IAX2Client` has all three on its
/// concrete type. So the translation happens here, into the app's own
/// ``RadioLinkEvent`` and ``RadioLink``, and everything above this file stays
/// protocol-agnostic. Three specific gaps, reported rather than papered over:
///
/// 1. **No event stream.** `IAX2Client.events` carries the SF-1 watchdog
///    expiry, which the UI is required to show. Reaching it means naming the
///    concrete type.
/// 2. **No received audio.** `IAX2Client.receivedAudio` is the only way to get
///    decoded PCM out.
/// 3. **No way in for captured audio.** `IAX2Client.send(pcm:)` is not on the
///    protocol, so the microphone cannot be wired to a generic client.
/// 4. **No DTMF.** `IAX2Client.send(dtmf:)` is not on the protocol either, and
///    FR-1.5 is not optional for a client that has to command a node.
///
/// A `NetworkClient` with an associated event enum, a `receivedAudio` stream,
/// a `send(pcm:)` and a `send(dtmf:)` requirement would let ``RadioSession``
/// build its own link and delete most of this file. Until then, this is the
/// containment.
///
/// ## What this file also owns
///
/// The **PTT input controllers** (PT-2, PT-3, PT-4). They are not protocol
/// knowledge, but they are the other thing with a lifetime as long as the
/// process and a wire that has to be connected exactly once: each takes a weak
/// ``PTTSink``, and the session is it. Assembling that here is what makes SF-2
/// real — before it, `BLEPTTController` computed correct press and release
/// edges and delivered them to a `nil` sink.
///
/// ## Client lifetime
///
/// One client per connection, not one per app. `IAX2Client.disconnect()` shuts
/// its client down permanently — the streams finish and a later `connect(to:)`
/// throws `clientShutDown` — so reconnecting means a new client. That is why
/// this type hands ``RadioSession`` a *factory* rather than a client.
@MainActor
final class CompositionRoot {
    /// The view model everything else in the app is built on.
    ///
    /// No longer generic over the client. `NetworkClient` still has an
    /// `associatedtype Destination` and still has no existential form — but
    /// the parameter had to be *chosen* here, which meant the app could hold
    /// an AllStarLink session or an M17 session and never one of either.
    /// ``RadioLink`` carries closures now instead of a client, so both modes
    /// produce the same type and the choice moves to where it belongs: the
    /// operator's, at connect time.
    let session: RadioSession

    /// **PT-2, PT-3.** The Bluetooth accessory. Owned here for the process
    /// lifetime and pointed at ``session``; it constructs no `CBCentralManager`
    /// and triggers no permission prompt until either an accessory has been
    /// learned or the operator opens the accessory screen.
    let accessory: BLEPTTController

    /// **PT-4.** The headset or remote button. Off unless the operator turned it
    /// on, and it touches nobody's media controls until then.
    let remoteCommand: RemoteCommandPTTController

    /// Transmit state, for anything that only needs to display it.
    var transmitState: TransmitState { session.transmitState }

    /// **EchoLink.** The station browser's state, over the real directory.
    ///
    /// Owned here rather than by the view because a fetch is a network session
    /// that takes seconds and should survive a pane being scrolled away from,
    /// and because the concrete `EchoLinkStationDirectory` is another thing
    /// only this file may name.
    let stationBrowser: StationBrowser

    /// - Parameters:
    ///   - configuration: media grid, jitter buffer and leveller. Injectable so
    ///     a test can build a root without waiting for anything. Note that the
    ///     **watchdog timeout is not taken from here** — it belongs to the
    ///     operator, so it travels in `NodeSettings` and is applied per link;
    ///     see ``makeIAX2Link(settings:secret:configuration:)``.
    ///   - audio: the microphone and speaker. Injectable so a test never opens
    ///     either.
    init(
        configuration: IAX2Client.Configuration = IAX2Client.Configuration(),
        audio: AudioIO = AudioPipelineIO(),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        secretStore: SecretStore = KeychainSecretStore(),
        // `nil` rather than a default-constructed controller: a default argument
        // expression is evaluated in a nonisolated context, and both of these
        // types are `@MainActor`. Built below instead, inside this initialiser,
        // which is isolated.
        accessory: BLEPTTController? = nil,
        remoteCommand: RemoteCommandPTTController? = nil,
        stationDirectory: any StationDirectory = EchoLinkStationDirectory()
    ) {
        let session = RadioSession(
            audio: audio,
            settingsStore: settingsStore,
            secretStore: secretStore,
            makeLink: { settings, secret in
                // Dispatches on the mode in the settings; see `makeLink`.
                // `configuration` is the IAX2 one, so it only applies there.
                switch settings.mode {
                case .allStarLink:
                    return CompositionRoot.makeIAX2Link(
                        settings: settings, secret: secret, configuration: configuration)
                case .m17:
                    return try CompositionRoot.makeM17Link(settings: settings)
                case .echoLink:
                    // The secret is the operator's EchoLink *account* password
                    // here, not a node password — see `makeEchoLinkLink`.
                    return try CompositionRoot.makeEchoLinkLink(
                        settings: settings, secret: secret)
                }
            })
        let accessory = accessory ?? BLEPTTController()
        let remoteCommand = remoteCommand ?? RemoteCommandPTTController()

        self.session = session
        self.accessory = accessory
        self.remoteCommand = remoteCommand
        self.stationBrowser = StationBrowser(directory: stationDirectory)

        // The wire SF-2 depends on. Weak on the controllers' side, so this does
        // not make the three of them immortal.
        accessory.sink = session
        remoteCommand.sink = session
    }

    /// Starts everything with a process-long lifetime. Idempotent, and called
    /// once from ``CurrawongApp``.
    ///
    /// Separate from `init` because two of the three things it does have visible
    /// side effects — a Bluetooth permission prompt and taking over the system's
    /// transport controls — and a constructor that does those while SwiftUI is
    /// still deciding whether to keep the value is a constructor that does them
    /// at a surprising moment. Both are additionally gated on the operator
    /// having asked for the feature at all.
    func activate() {
        session.start()
        accessory.activateIfConfigured()
        remoteCommand.activateIfEnabled()
    }

    /// **SF-1.** The operator's watchdog timeout, as the library wants it.
    ///
    /// A separate function purely so it can be tested: `IAX2Client` keeps its
    /// configuration private, so there is no way to ask a built client what
    /// timeout it got, and a wiring mistake here would be invisible until a
    /// transmission ran for three minutes when the operator asked for ten
    /// seconds. Returning a `Duration` rather than a `Configuration` also keeps
    /// the test from having to import `IAX2Kit`.
    static func watchdogTimeout(for settings: NodeSettings) -> Duration {
        .seconds(settings.transmitTimeout)
    }

    /// Builds one IAX2 connection's worth of plumbing.
    ///
    /// Opens nothing: `IAX2Client` builds its transport lazily inside
    /// `connect(to:)`, so an unused link costs two suspended tasks and is
    /// released by `close()`.
    ///
    /// **`settings.transmitTimeout` overrides `configuration.transmitTimeout`.**
    /// SF-1 is enforced by the library, but the number is the operator's, and
    /// this is where the two meet. `NodeSettings.validated()` has already
    /// clamped it to something sane, and the settings the session hands over are
    /// always validated ones.
    static func makeIAX2Link(
        settings: NodeSettings,
        secret: String,
        configuration: IAX2Client.Configuration = IAX2Client.Configuration()
    ) -> RadioLink {
        var configuration = configuration
        configuration.transmitTimeout = watchdogTimeout(for: settings)

        let client = IAX2Client(configuration: configuration)
        let destination = IAX2Destination(
            host: settings.host,
            port: settings.port,
            callsign: settings.callsign,
            username: settings.username,
            secret: secret,
            node: settings.node)

        var eventEscape: AsyncStream<RadioLinkEvent>.Continuation!
        let events = AsyncStream<RadioLinkEvent> { eventEscape = $0 }
        let eventContinuation = eventEscape!

        // Translation, not forwarding: `IAX2ClientEvent` is the library's
        // vocabulary and must not escape this file.
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

    /// Builds one M17 connection's worth of plumbing.
    ///
    /// The mirror of ``makeIAX2Link(settings:secret:configuration:)``, and the
    /// differences are the protocol's rather than ours:
    ///
    /// - **No secret.** M17 reflectors do not authenticate; the callsign in
    ///   every frame's SRC field is the whole of the identity. There is no
    ///   Keychain round trip on this path and nothing to leak.
    /// - **A module, not a node number.** `settings.module` is the reflector
    ///   module to link.
    /// - **No DTMF.** M17 has no in-band signalling equivalent, so `sendDTMF`
    ///   throws rather than pretending. The connect form hides the keypad in
    ///   this mode, so an operator should never reach it.
    /// - **A codec has to be supplied.** `M17Client` takes an injected
    ///   `VoiceCodec`, because the library's own Codec2 conformance is
    ///   compiled out for SPM consumers. ``Codec2Codec`` is the app's, and
    ///   this is its injection point. See docs/CODEC2.md.
    ///
    /// **Not validated on air.** No M17 transmission has ever reached a real
    /// reflector, so this path is believed correct rather than known to be.
    static func makeM17Link(
        settings: NodeSettings,
        configuration: M17Client.Configuration = M17Client.Configuration()
    ) throws -> RadioLink {
        var configuration = configuration
        configuration.transmitTimeout = watchdogTimeout(for: settings)

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
            callsign: settings.callsign)

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
    /// The same shape as the two above, and again the differences are the
    /// protocol's rather than ours:
    ///
    /// - **`host` and `port` are the proxy's**, not the far node's. EchoLink
    ///   audio is UDP 5198/5199 inbound, which carrier-grade NAT eats, so
    ///   FR-3.3 makes a TCP proxy on 8100 the normal path and the library only
    ///   implements that one. `settings.peer` is the node's own address, and it
    ///   travels inside the proxy's `OPEN` frame rather than being dialled.
    /// - **Two addresses, and one of them must be a dotted quad.** Nothing in
    ///   the proxy protocol resolves DNS: the peer field is four raw octets. So
    ///   `settings.peer` is parsed here and a name that never parsed becomes an
    ///   error the operator can read, not a force-unwrap.
    /// - **The secret is the operator's account password**, and it is optional.
    ///   It authenticates us to the *directory server*, not to the node, and
    ///   skipping it only costs the directory login (FR-3.4). Contrast IAX2,
    ///   where the secret is what the node checks.
    /// - **The account password and the directory server are all or nothing.**
    ///   `connect(to:)` throws `.directoryLoginIncomplete` when exactly one is
    ///   present, on the grounds that half a configuration is a mistake rather
    ///   than an intention. That is a reasonable library position and a hostile
    ///   app one — an operator who typed a password and left the server field
    ///   alone would get a failed connect instead of a working unauthenticated
    ///   session. So the pairing is resolved here: unless both survive parsing,
    ///   both go in as `nil` and the session proceeds without the login.
    /// - **No DTMF.** Same as M17: `EchoLinkClient` has no digit path, so
    ///   `sendDTMF` throws rather than pretending.
    /// - **A codec has to be supplied**, as with M17 — but unlike Codec2 this
    ///   one always exists. `GSMVoiceCodec` ships inside EchoLinkKit on the
    ///   vendored `CGSM` target, so there is no XCFramework to build and no
    ///   `#if` guarding this call; it throws only if the encoder or decoder
    ///   fails to allocate.
    ///
    /// - Parameters:
    ///   - secret: the operator's EchoLink account password. Empty means "no
    ///     directory login", which is a supported way to run.
    ///   - configuration: injectable for tests. The fields that belong to the
    ///     operator — callsign, name, location, watchdog, and the directory
    ///     pair — are overwritten from `settings` regardless, so what a caller
    ///     can usefully supply here is the rest: the jitter buffer, the
    ///     leveller, the tool string, the node-answer timings.
    static func makeEchoLinkLink(
        settings: NodeSettings,
        secret: String,
        configuration: EchoLinkClient.Configuration? = nil
    ) throws -> RadioLink {
        guard let peer = EchoLinkPeerAddress(settings.peer) else {
            throw EchoLinkLinkError.invalidPeerAddress(settings.peer)
        }
        guard !settings.host.isEmpty else {
            throw EchoLinkLinkError.missingProxyHost
        }

        // The all-or-nothing pairing, resolved before it can reach the library.
        // `EchoLinkPeerAddress(_:)` is failable, so a half-typed server address
        // lands in the same bucket as an absent one: no login, rather than a
        // connect that throws.
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
            callsign: settings.callsign)
        configuration.callsign = settings.callsign
        configuration.operatorName = settings.operatorName
        configuration.location = settings.location
        configuration.transmitTimeout = watchdogTimeout(for: settings)
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
                host: settings.host,
                port: settings.port,
                password: EchoLinkProxyPassword(settings.proxyPassword)))

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

    /// The Codec2 conformance, or an error the operator can act on.
    ///
    /// Separate so the failure has somewhere to be explained: ``Codec2Codec``
    /// only exists when `Codec2.xcframework` was linked, and a build without
    /// it should say so plainly rather than fail to find a symbol.
    private static func makeVoiceCodec() throws -> any VoiceCodec {
        #if canImport(Codec2)
        return try Codec2Codec()
        #else
        throw M17LinkError.codecUnavailable
        #endif
    }

    /// The GSM 06.10 conformance EchoLink audio needs.
    ///
    /// The counterpart of ``makeVoiceCodec()``, and deliberately much duller:
    /// GSM is vendored *inside* EchoLinkKit rather than linked from an
    /// XCFramework, so there is no build configuration in which the type is
    /// missing and nothing here to `#if` on. It stays a separate function only
    /// so the two codec decisions read alike, and because `GSMVoiceCodec.init`
    /// can still fail — the C encoder and decoder are heap-allocated.
    private static func makeGSMVoiceCodec() throws -> any VoiceCodec {
        try GSMVoiceCodec()
    }

    /// Builds a link for whichever mode the settings name.
    ///
    /// The one place the app turns a mode into a concrete client, and the
    /// reason ``RadioLink`` stopped being generic — see its doc comment.
    static func makeLink(settings: NodeSettings, secret: String) throws -> RadioLink {
        switch settings.mode {
        case .allStarLink:
            return makeIAX2Link(settings: settings, secret: secret)
        case .m17:
            return try makeM17Link(settings: settings)
        case .echoLink:
            return try makeEchoLinkLink(settings: settings, secret: secret)
        }
    }
}

/// What can go wrong building an EchoLink link, in the app's own vocabulary.
///
/// Separate from ``M17LinkError`` rather than folded into it: these are three
/// different mistakes an operator can make on a form, and merging the enums
/// would put "build Codec2.xcframework" in the same type as "check the proxy
/// address", which is how error text starts drifting away from the mode it
/// belongs to.
enum EchoLinkLinkError: Error, Equatable, CustomStringConvertible {
    /// `settings.peer` is not four decimal octets. The EchoLink proxy carries
    /// the peer as raw address bytes and nothing in the path resolves DNS, so
    /// a hostname cannot be made to work here by trying harder.
    case invalidPeerAddress(String)

    /// No proxy host. `NodeSettings.validated()` should have caught an empty
    /// host; this is the backstop, and it is worth having because the failure
    /// without it happens inside the transport, where the message is about a
    /// socket rather than about a settings field.
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
                No EchoLink proxy is set. Enter the address of a proxy in \
                Settings — EchoLink needs one to reach a node from a phone.
                """
        case .dtmfUnsupported:
            return "EchoLink has no DTMF signalling. Connect to an AllStarLink node to send digits."
        }
    }
}

/// What can go wrong building an M17 link, in the app's own vocabulary.
enum M17LinkError: Error, Equatable, CustomStringConvertible {
    /// The module is not a single letter. `NodeSettings.validated()` should
    /// have caught this; this is the backstop.
    case invalidModule(String)

    /// This build has no Codec2, so M17 audio cannot work.
    case codecUnavailable

    /// DTMF was attempted on a mode that has no such thing.
    case dtmfUnsupported

    var description: String {
        switch self {
        case .invalidModule(let module):
            return "'\(module)' is not a reflector module. Use a single letter, A to Z."
        case .codecUnavailable:
            return """
                This build has no Codec2, so M17 audio is unavailable. Build \
                Codec2.xcframework and rebuild the app — see docs/CODEC2.md.
                """
        case .dtmfUnsupported:
            return "M17 has no DTMF signalling. Connect to an AllStarLink node to send digits."
        }
    }
}

/// The `M17ClientEvent` → ``RadioLinkEvent`` translation, alongside the IAX2
/// one below and for the same reason.
///
/// M17 says things IAX2 has no word for. A reflector module is a shared
/// channel, so the app is told *who* is transmitting and when they stop —
/// which the app renders into the vocabulary it already has rather than
/// growing cases only one mode can ever produce.
extension RadioLinkEvent {
    fileprivate init?(_ event: M17ClientEvent) {
        switch event {
        case .linked:
            // The codec is not negotiated in M17 — a stream frame carries
            // Codec2 3200 by definition — so it is named rather than reported.
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

/// The `IAX2ClientEvent` → ``RadioLinkEvent`` translation. Lives here because
/// this is the only file permitted to name the left-hand side.
///
/// Returns `nil` for events the app has nothing to do with yet, rather than
/// inventing a case for them — a case nobody displays is a case that rots.
extension RadioLinkEvent {
    fileprivate init?(_ event: IAX2ClientEvent) {
        switch event {
        case .connected(let format):
            // `MediaFormat.description` names the RFC's codecs and falls back to
            // the raw bitmask for anything it does not recognise, which is
            // exactly what someone staring at an unexpected negotiation needs.
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

/// The `EchoLinkClientEvent` → ``RadioLinkEvent`` translation, the third of
/// three and for the same reason as the other two.
///
/// EchoLink is point-to-point like IAX2, but it narrates its connect sequence
/// the way M17 does, so the interesting decisions here are about what *not* to
/// forward. Three cases collapse or vanish:
///
/// - **`connecting` and `directoryLoggedIn` are `nil`.** Both happen inside
///   `connect(to:)`, which has not returned yet, so the session is already
///   showing "Connecting" and has nothing to do with either. The library takes
///   the same view in its own `RadioEvent` translation.
/// - **`stationInfo` is `nil`, which loses something.** It is the `oNDATA`
///   text the far node sends on the audio channel — a free-text description,
///   often several lines — and the only case the app could put it in is
///   ``RadioLinkEvent/remoteStation(callsign:)``, which feeds the "receiving
///   from" display. Writing a paragraph into a field that shows a callsign
///   would make the identity from ``nodeAnswered`` worse, not better, so it is
///   dropped until ``RadioLinkEvent`` grows somewhere honest to put it.
/// - **`talkspurtStarted` becomes `receiving`, not a station change.** EchoLink
///   identifies the *session*, not each over: there is no per-talkspurt station
///   identity on the audio channel, so there is no callsign to report. The
///   station shown for the whole session is the one from ``nodeAnswered``.
extension RadioLinkEvent {
    fileprivate init?(_ event: EchoLinkClientEvent) {
        switch event {
        case .connected:
            // Named rather than reported, as in M17: EchoLink negotiates no
            // codec — GSM 06.10 at 8 kHz is what an audio packet contains by
            // definition. The node name the event carries is dropped, because
            // the operator chose the destination and already knows it.
            self = .connected(codec: "GSM 06.10")
        case .transmitting:
            self = .transmitting
        case .receiving, .talkspurtStarted:
            self = .receiving
        case .transmitTimedOut(let timeout):
            self = .transmitWatchdogExpired(timeout)
        case .nodeAnswered(let name):
            // The far end identifying itself in its SDES, which is as close to
            // "who am I talking to" as this protocol gets.
            self = .remoteStation(callsign: name)
        case .disconnected(let reason):
            // `EchoLinkDisconnectReason` is already prose the library wrote for
            // an operator to read — "the node said goodbye" — so it is passed
            // through rather than re-worded here.
            self = .disconnected(reason: reason.description)
        case .connecting, .directoryLoggedIn, .stationInfo:
            return nil
        }
    }
}

/// The real EchoLink station directory (EL-11).
///
/// The listing does not arrive over anything as convenient as HTTP: it comes
/// down a directory-server session, tunnelled inside the same proxy connection
/// a QSO would use. `EchoLinkClient` knows how to open one *without* contacting
/// a node — `SessionMode.directoryOnly` — which is what makes this safe to run
/// from a browser screen. Nothing is transmitted and no node is disturbed.
///
/// A client is single-session, so this builds one per fetch and disposes of it,
/// including when the fetch throws. Leaving a proxy session open would be worse
/// than untidy: public proxies are single-user, so one abandoned is one nobody
/// else can use.
struct EchoLinkStationDirectory: StationDirectory {
    func stations(for settings: NodeSettings, accountPassword: String) async throws
        -> [DirectoryStation]
    {
        if let missing = StationBrowser.whatIsMissing(
            in: settings, accountPassword: accountPassword)
        {
            throw missing
        }
        guard let directoryServer = EchoLinkPeerAddress(settings.directoryServer) else {
            throw StationDirectoryError.missingDirectoryServer
        }

        var configuration = EchoLinkClient.Configuration(callsign: settings.callsign)
        configuration.operatorName = settings.operatorName
        configuration.location = settings.location
        configuration.accountPassword = EchoLinkAccountPassword(accountPassword)
        configuration.directoryServer = directoryServer

        let client = EchoLinkClient(
            codec: try GSMVoiceCodec(),
            configuration: configuration,
            clock: ContinuousClock())

        // The peer goes unused in a directory-only session — no node is
        // contacted — but a destination has to name one, and `unspecified` says
        // "none" rather than picking an address nobody meant.
        let destination = EchoLinkDestination(
            peer: .unspecified,
            node: settings.node,
            route: .proxy(
                host: settings.host,
                port: settings.port,
                password: EchoLinkProxyPassword(settings.proxyPassword)))

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

extension DirectoryStation {
    /// Translates a library station into the app's own.
    ///
    /// `status` is carried as the server's own word rather than parsed into a
    /// pair of booleans, because the listing has more states than the two
    /// anybody remembers, and inventing an enum here would be guessing at a
    /// vocabulary the app does not own.
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
