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
/// imported, and ``makeLink(settings:identity:credentials:)`` is where
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
    ///
    /// Not generic over the client: ``RadioLink`` carries closures instead of a
    /// concrete type, so an AllStarLink session and an M17 session are the same
    /// type and the choice of mode is the operator's, at connect time.
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
    /// Owned here, not by the view: a fetch is a network session measured in
    /// seconds that should survive a pane being scrolled away from, and the
    /// concrete `EchoLinkStationDirectory` is a type only this file may name.
    let stationBrowser: StationBrowser

    /// **EchoLink.** The "find me a public proxy" state, over the real
    /// echolink.org list and a real probe (EL-12). Owned here for the same two
    /// reasons as ``stationBrowser``.
    let proxyPicker: ProxyPicker

    /// **M17.** The reflector chooser's state, over the M17 Project's published
    /// host file. Owned here so the download survives a pane being scrolled
    /// away from; `HostFileReflectorDirectory` names no library type, but lives
    /// alongside the other network-backed pickers for the same reason.
    let reflectorBrowser: ReflectorBrowser

    /// **AllStarLink.** The node-number lookup's state, over the public stats
    /// API. Owned here so a round trip survives a pane being scrolled away
    /// from, like the other three network-backed helpers.
    let nodeLocator: NodeLocator

    /// **APP-12.** The settings screen's portal-login state, over
    /// ``AllStarLinkPortalLogin`` (the adapter over IAX-13's
    /// `WebTransceiverTokenSource`). Owned here for ``stationBrowser``'s two
    /// reasons. The default is a live login, not `nil`, because the app's
    /// floor already carries the fetch; `nil` is still supported and means "no
    /// logging in", for a preview or a test with no business talking to
    /// allstarlink.org.
    let portalLogin: PortalLoginController

    /// - Parameters:
    ///   - configuration: media grid, jitter buffer and leveller. Injectable so
    ///     a test can build a root without waiting for anything. Note that the
    ///     **watchdog timeout is not taken from here** — it belongs to the
    ///     operator, so it travels in `NodeSettings` and is applied per link;
    ///     see ``makeIAX2Link(settings:identity:credentials:configuration:)``.
    ///   - audio: the microphone and speaker. Injectable so a test never opens
    ///     either.
    init(
        configuration: IAX2Client.Configuration = IAX2Client.Configuration(
            leveller: CompositionRoot.receiveLeveller),
        audio: AudioIO = AudioPipelineIO(),
        // `DefaultsSuite.resolved` rather than `.standard`: the operator's
        // defaults in every ordinary launch, and a throwaway suite when a UI test
        // asked for one on the command line. See ``DefaultsSuite``.
        settingsStore: SettingsStore = UserDefaultsSettingsStore(
            defaults: DefaultsSuite.resolved),
        secretStore: SecretStore = KeychainSecretStore(),
        // `nil` rather than a default-constructed controller: a default argument
        // expression is evaluated in a nonisolated context, and both of these
        // types are `@MainActor`. Built below instead, inside this initialiser,
        // which is isolated.
        accessory: BLEPTTController? = nil,
        remoteCommand: RemoteCommandPTTController? = nil,
        stationDirectory: any StationDirectory = EchoLinkStationDirectory(),
        proxyFinder: any ProxyFinder = EchoLinkPublicProxyFinder(),
        reflectorDirectory: any ReflectorDirectory = HostFileReflectorDirectory(),
        nodeLookup: any NodeLookup = AllStarLinkNodeLookup(),
        portalLogin: (any PortalLogin)? = AllStarLinkPortalLogin(),
        // `nil` for the same isolation reason as the two controllers above. A
        // test that passes one gets to read what the app asked the lock screen
        // for; a test that passes nothing gets the real thing on iOS and
        // nothing on macOS, which is what the app itself gets.
        activity: TransmitActivityController? = nil
    ) {
        // Route-change *reasons*, which `AudioSessionSignal` does not carry.
        // Diagnostic only, registers one observer, and is a no-op on macOS —
        // see `Diagnostics` and `BU-13`. Here rather than in `AudioPipelineIO`
        // because the pipeline is built lazily on first capture, and a route
        // change before the first key-down is exactly the kind this is for.
        Diagnostics.startRouteLogging()

        // Before the session, so the session can be handed its release hook
        // (APP-13). The order is load-bearing rather than tidy: a closure
        // capturing `self` cannot be built until every property is initialised,
        // and capturing the picker itself needs the picker to exist first.
        let proxyPicker = ProxyPicker(finder: proxyFinder)

        let session = RadioSession(
            audio: audio,
            settingsStore: settingsStore,
            secretStore: secretStore,
            makeLink: { settings, identity, credentials, transmitTimeout, proxy in
                // `configuration` is the IAX2 one; it only applies in that case.
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
                    // The secret is the operator's EchoLink *account* password
                    // here, not a node password — see `makeEchoLinkLink`.
                    return try CompositionRoot.makeEchoLinkLink(
                        settings: settings, identity: identity, secret: credentials.secret,
                        proxy: proxy, transmitTimeout: transmitTimeout)
                }
            },
            releaseProxyLease: { proxyPicker.releaseLease() },
            // **APP-3 (SF-4).** The lock-screen transmit indicator. Built here
            // and nowhere else, for the same reason the clients are: this is the
            // one file that names a platform framework's concrete type.
            activity: activity ?? CompositionRoot.makeActivityController())
        // Same suite as the settings store, for the same reason: a UI test that
        // isolates one and not the other would still be editing the operator's
        // learned accessory.
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

        // The wire SF-2 depends on. Weak on the controllers' side, so this does
        // not make the three of them immortal.
        accessory.sink = session
        remoteCommand.sink = session

        // The other direction, for BU-14's repair: the session knows when
        // nothing is on air, and only then may the accessory rebuild a link
        // that has silently stopped delivering. Captured weakly so the pair is
        // not made immortal.
        session.onIdleAudioRouteChange = { [weak accessory] in
            accessory?.audioRouteDidChange()
        }
        // And the other half of it: the controller asks before a repair it
        // scheduled itself, because an escalation fires on a timer and by then
        // the operator may have keyed up on the on-screen button, which the
        // controller cannot see.
        accessory.isRebuildSafe = { [weak session] in
            session?.isIdleForAccessoryRepair ?? false
        }
        // And the claim's backstop: the SF-1 watchdog fires precisely when no
        // release has arrived, so it is the one event that can withdraw an
        // accessory-keyed claim whose release is never coming — without it the
        // claim guards every repair path closed, Reconnect included.
        session.onWatchdogUnkey = { [weak accessory] in
            accessory?.radioUnkeyedExternally()
        }
    }

    /// Starts everything with a process-long lifetime. Idempotent, and called
    /// once from ``CurrawongApp``.
    ///
    /// Separate from `init`: two of the three things it does have visible side
    /// effects — a Bluetooth permission prompt and taking over the system's
    /// transport controls — which should not happen while SwiftUI is still
    /// deciding whether to keep the value. Both are additionally gated on the
    /// operator having asked for the feature at all.
    func activate() {
        session.start()
        accessory.activateIfConfigured()
        remoteCommand.activateIfEnabled()
    }

    /// **APP-3 (SF-4).** The transmit Live Activity's controller.
    ///
    /// iOS only. macOS has no Live Activities, so the macOS app gets a disabled
    /// controller rather than a compile-time hole: `RadioSession` then calls a
    /// controller that does nothing, and every SF-4 code path is still exercised
    /// by `make test-macos`.
    private static func makeActivityController() -> TransmitActivityController {
        #if os(iOS)
        return TransmitActivityController(presenter: ActivityKitPresenter())
        #else
        return .disabled
        #endif
    }

    /// **AU-4.** The received-audio leveller every mode is built with.
    ///
    /// −12 dBFS, not the library's default of −18: that headroom is right for a
    /// mixing stage but too quiet out of a phone speaker, especially with iOS's
    /// voice-processing path on top of it. The rest of the leveller's shape —
    /// attack, release, the +18 dB ceiling — stays the library's; only the
    /// output level is a property of the device rather than of the protocol.
    static let receiveLeveller = AudioLeveller(targetRMSdBFS: -12)

    /// **SF-1.** The operator's watchdog timeout, as the library wants it.
    ///
    /// A separate function purely so it can be tested: `IAX2Client` keeps its
    /// configuration private, so there is no way to ask a built client what
    /// timeout it got, and a wiring mistake here would be invisible until a
    /// transmission ran for three minutes when the operator asked for ten
    /// seconds. Returning a `Duration` rather than a `Configuration` also keeps
    /// the test from having to import `IAX2Kit`.
    static func watchdogTimeout(for timeout: TransmitTimeout) -> Duration {
        .seconds(timeout.seconds)
    }

    // MARK: - Web Transceiver (APP-11)

    /// The guest account every Web Transceiver call authenticates as — a
    /// shared account, not the operator's callsign, which draws a bare REJECT
    /// with no CAUSE or challenge (IAX-12; `swift-hamvoip/docs/CLI.md` §11.2).
    static let webTransceiverUsername = "allstar-public"

    /// The static secret that guest account uses. The same on every ASL3
    /// node — it ships in `iax.conf` — so it is a constant rather than
    /// something to ask an operator for. **Not** the token, and not a portal
    /// password.
    static let webTransceiverSecret = "allstar"

    /// The extension a WT call dials: `s`, the Asterisk start extension. WT
    /// never dials the node number — it calls in like a telephone, and CALLING
    /// NUMBER decides which node answers.
    static let webTransceiverExtension = "s"

    /// What a Web Transceiver guest call presents, in the app's own vocabulary.
    ///
    /// Exists so the mapping can be *tested*: a destination cannot be asked
    /// afterwards what it was built from, and a wiring mistake among five
    /// values, four of them counter-intuitive, would otherwise be invisible
    /// until a node rejected the call.
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

    /// The guest-call parameters for a channel, or `nil` when the channel is not
    /// a Web Transceiver one. Four of these are not what anyone would guess
    /// (IAX-12; `swift-hamvoip/docs/CLI.md` §11.2).
    ///
    /// The identity mapping is the part worth understanding: the node passes
    /// CALLING NAME to allstarlink.org, which resolves it to a callsign — the
    /// whole of the authentication, and why the token must reach the wire
    /// unaltered. `callsign` is upper-cased on the way out and would corrupt a
    /// lowercase-hex token, so the token travels in `callingName` instead.
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

    /// The destination for a Web Transceiver guest call, or `nil` when this
    /// channel is not one. The reasoning is in ``webTransceiverCall(settings:identity:credentials:)``;
    /// this is only the translation into the library's vocabulary.
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

    /// Builds one IAX2 connection's worth of plumbing.
    ///
    /// Opens nothing: `IAX2Client` builds its transport lazily inside
    /// `connect(to:)`, so an unused link costs two suspended tasks, released by
    /// `close()`.
    ///
    /// **`transmitTimeout` overrides `configuration.transmitTimeout`** — SF-1 is
    /// enforced by the library, but the number is the operator's, and this is
    /// where the two meet. `TransmitTimeout` clamps itself on the way in.
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
    ///   `VoiceCodec`; ``makeVoiceCodec()`` supplies it, and this is its
    ///   injection point.
    ///
    /// **Not validated on air.** No M17 transmission has ever reached a real
    /// reflector, so this path is believed correct rather than known to be.
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
    /// The same shape as the two above, and again the differences are the
    /// protocol's rather than ours:
    ///
    /// - **The proxy arrives as a parameter, not in the settings** (APP-13).
    ///   FR-3.3 makes a TCP proxy on 8100 the normal path, because EchoLink's
    ///   UDP audio (5198/5199) does not survive carrier-grade NAT, but which
    ///   proxy is the operator's station infrastructure rather than a property
    ///   of the node — a public one is leased for a sitting.
    /// - **Two addresses, one of which must be a dotted quad.** The proxy
    ///   protocol resolves no DNS — the peer field is four raw octets — so
    ///   `settings.peer` is parsed here, and a name that fails to parse becomes
    ///   an error the operator can read rather than a force-unwrap.
    /// - **The secret is the operator's account password**, and it is optional:
    ///   it authenticates to the *directory server*, not the node, so skipping
    ///   it only costs the directory login (FR-3.4). Contrast IAX2, where the
    ///   secret is what the node checks.
    /// - **The account password and the directory server are all or nothing.**
    ///   The library throws `.directoryLoginIncomplete` when exactly one is
    ///   present. An operator who typed a password and left the server field
    ///   alone should get a working unauthenticated session, not a failed
    ///   connect, so the pairing is resolved here: unless both survive parsing,
    ///   both go in as `nil`.
    /// - **No DTMF.** Same as M17: `EchoLinkClient` has no digit path, so
    ///   `sendDTMF` throws rather than pretending.
    /// - **A codec has to be supplied**, as with M17. `GSMVoiceCodec` ships
    ///   inside EchoLinkKit on the vendored `CGSM` target, so it throws only if
    ///   the encoder or decoder fails to allocate.
    ///
    /// - Parameters:
    ///   - secret: the operator's EchoLink account password. Empty means "no
    ///     directory login", which is a supported way to run.
    ///   - proxy: the proxy to tunnel through, resolved by ``ProxyPicker``.
    ///     `nil` is a caller that has not sourced one, which cannot be made to
    ///     work and is reported as such.
    ///   - configuration: injectable for tests. The fields that belong to the
    ///     operator — callsign, name, location, watchdog, and the directory
    ///     pair — are overwritten from `identity`, `transmitTimeout` and
    ///     `settings` regardless, so what a caller
    ///     can usefully supply here is the rest: the jitter buffer, the
    ///     leveller, the tool string, the node-answer timings.
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

    /// The Codec 2 3200 conformance the M17 path encodes and decodes with:
    /// `M17Kit.WeebillVoiceCodec`, the library's pure-Swift Codec 2 (M17-7). See
    /// docs/CODEC2.md.
    ///
    /// Not `private`, so `M17CodecIntegrationTests` can assert the fit against
    /// the codec that is actually injected rather than against a named type.
    static func makeVoiceCodec() throws -> any VoiceCodec {
        return try WeebillVoiceCodec()
    }

    /// The GSM 06.10 conformance EchoLink audio needs. A separate function only
    /// so the two codec decisions read alike; `GSMVoiceCodec.init` can still
    /// fail, since the C encoder and decoder are heap-allocated.
    private static func makeGSMVoiceCodec() throws -> any VoiceCodec {
        try GSMVoiceCodec()
    }

    /// Builds a link for whichever mode the settings name.
    ///
    /// The one place the app turns a mode into a concrete client, and the
    /// reason ``RadioLink`` stopped being generic — see its doc comment.
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

/// What can go wrong building an EchoLink link, in the app's own vocabulary.
///
/// Separate from ``M17LinkError`` rather than folded into it, so error text
/// does not drift between unrelated mistakes on different forms.
enum EchoLinkLinkError: Error, Equatable, CustomStringConvertible {
    /// `settings.peer` is not four decimal octets. The EchoLink proxy carries
    /// the peer as raw address bytes, and nothing in the path resolves DNS.
    case invalidPeerAddress(String)

    /// No proxy was sourced. ``ProxyPicker`` resolves one and stops when it
    /// cannot; this is the backstop, worth having because the failure without
    /// it happens inside the transport, as a socket error rather than this one.
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

/// What can go wrong building an M17 link, in the app's own vocabulary.
enum M17LinkError: Error, Equatable, CustomStringConvertible {
    /// The module is not a single letter. `NodeSettings.validated()` should
    /// have caught this; this is the backstop.
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
/// EchoLink is point-to-point like IAX2, but narrates its connect sequence the
/// way M17 does, so what matters here is what is deliberately not forwarded:
///
/// - **`connecting` and `directoryLoggedIn` are `nil`.** Both happen inside
///   `connect(to:)`, which has not returned yet, so the session is already
///   showing "Connecting" and there is nothing more to say.
/// - **`stationInfo` is `nil`, which loses something.** It is the `oNDATA`
///   free-text description the far node sends, often several lines, and the
///   only place it could go is ``RadioLinkEvent/remoteStation(callsign:)`` —
///   which would make the identity from ``nodeAnswered`` worse, not better. It
///   is dropped until ``RadioLinkEvent`` has somewhere honest to put it.
/// - **`talkspurtStarted` becomes `receiving`, not a station change.** EchoLink
///   identifies the *session*, not each over — there is no per-talkspurt
///   station identity on the audio channel — so the station shown for the
///   whole session stays the one from ``nodeAnswered``.
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
/// The listing arrives down a directory-server session tunnelled inside the
/// same proxy connection a QSO would use. `EchoLinkClient` opens one *without*
/// contacting a node (`SessionMode.directoryOnly`), so browsing transmits
/// nothing and disturbs no node.
///
/// A client is single-session, so this builds one per fetch and disposes of it
/// even when the fetch throws — public proxies are single-user, so an
/// abandoned session is one nobody else can use.
struct EchoLinkStationDirectory: StationDirectory {
    /// Turns the directory server's host name into the address the library
    /// takes. Injectable so a test never asks DNS anything.
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

        // The operator may have typed a name. The library takes four octets and
        // resolves nothing, so this is where a name becomes an address — the
        // same step `RadioSession.connect()` does for the QSO path.
        let address = try await resolver.ipv4Address(for: settings.directoryServer)
        guard let directoryServer = EchoLinkPeerAddress(address) else {
            throw StationDirectoryError.missingDirectoryServer
        }

        // **`normalisedCallsign`, not `callsign`** (APP-14): matches the
        // uppercasing `identity.validated()` applies on the QSO path, so the
        // proxy login and the directory login line authenticate the same way
        // regardless of the case the operator typed.
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

        // The peer goes unused in a directory-only session — no node is
        // contacted — but a destination has to name one, and `unspecified` says
        // "none" rather than picking an address nobody meant.
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

/// Wraps IAX-13's `WebTransceiverTokenSource` — the POST to allstarlink.org that
/// exchanges a portal login for a Web Transceiver token (APP-12, pane 1).
///
/// The same shape of adapter as ``EchoLinkPublicProxyFinder``, and here for the
/// same two reasons: `AllStarLinkPortalTokenFetcher` and
/// `WebTransceiverTokenError` are library types, which only this file may name,
/// and translating gives the app an error vocabulary of its own.
///
/// **The library owns the request.** Nothing here builds a URL, a body or a
/// header. The endpoint is named `legacy`, and AllStarLink's replacement
/// project (OQ-10, caveat 2) should arrive as a second conformance to
/// `WebTransceiverTokenSource` inside the library, injected below — this file
/// should not have to change at all.
struct AllStarLinkPortalLogin: PortalLogin {
    /// Injectable so a test can drive the translation without a network. The
    /// default is the library's real endpoint, which is HTTPS-only and refuses
    /// anything else before a password is sent.
    private let source: any WebTransceiverTokenSource

    init(source: any WebTransceiverTokenSource = AllStarLinkPortalTokenFetcher()) {
        self.source = source
    }

    func token(callsign: String, password: String) async throws -> String {
        do {
            // `.value` rather than the token type: `WebTransceiverToken` may not
            // travel above this file, and what the app does with it is store the
            // string in the Keychain and hand it back as a calling name. Its
            // `description` is redacted, so this unwrap is the one place that
            // could leak it — and it goes straight to `SecretStore`.
            return try await source.token(username: callsign, password: password).value
        } catch let error as WebTransceiverTokenError {
            throw PortalLoginFailure(error)
        }
        // Anything else — a `URLError` that escaped the library, a cancellation —
        // propagates, and `PortalLoginController` reports it as `.unreachable`,
        // which is what an unclassifiable failure to reach a web service is.
    }
}

extension PortalLoginFailure {
    /// The library's five cases in the app's four, as ``PortalLoginFailure``
    /// documents.
    ///
    /// The merge is the app making a decision the library should not: `Invalid
    /// JSON payload` and `Invalid JSON fields` are the same news to an operator —
    /// the login service has changed and nothing they type will help — while a
    /// wrong password is the one case where re-typing is the answer.
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
            // Only reachable through an injected non-HTTPS endpoint, which the
            // shipping wiring cannot produce. Reported as a changed endpoint
            // rather than as unreachable, because it is a configuration fault
            // and the operator's remedy is the same one: the paste field still
            // works.
            self = .endpointChanged
        }
    }
}

/// The real public proxy finder (EL-12).
///
/// Wraps `EchoLinkProxySelector`, which fetches echolink.org's list, keeps the
/// entries advertised as public and ready, sorts them by distance, and probes
/// them in batches until one answers.
///
/// **Why this is a `CompositionRoot` type, not a `NetworkClient` capability.**
/// Proxy selection produces a host and port for an `EchoLinkDestination`,
/// meaningless for IAX2 and M17, so the library leaves it below the seam: the
/// root picks the proxy and fills in the field, and the view never meets an
/// `EchoLinkPublicProxy`.
struct EchoLinkPublicProxyFinder: ProxyFinder {
    /// Injectable so a test can drive the translation without a network. The
    /// default is the library's real endpoint and a `Network.framework` probe.
    private let selector: EchoLinkProxySelector

    init(selector: EchoLinkProxySelector = EchoLinkProxySelector()) {
        self.selector = selector
    }

    func fastestProxy(onProgress: @escaping @Sendable (Int) -> Void) async throws -> ProxyCandidate
    {
        // The library reports each batch it is about to probe; the app counts.
        // A running total is what the operator can read at a glance, and it
        // keeps `EchoLinkPublicProxy` from travelling up to the view.
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

/// A counter the library's progress callback can reach from any task.
///
/// `selectFastest(onProgress:)` documents that it calls back "on an arbitrary
/// task", so the tally it feeds has to be safe to touch from one.
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
    /// Translates the library's outcome into the app's.
    ///
    /// `probed` is carried from the app's own tally rather than read off the
    /// error, so the two cases agree about the number the operator is shown.
    fileprivate init(_ error: EchoLinkProxyDirectoryError, probed: Int) {
        switch error {
        case .noProxyAvailable:
            self = .noneAvailable
        case .noProxyAnswered(let libraryProbed):
            self = .noneAnswered(probed: max(libraryProbed, probed))
        default:
            // Everything else is the list itself failing — a fetch that did not
            // arrive, or XML that did not parse. The library's own wording is
            // better than anything this layer could invent about it.
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
