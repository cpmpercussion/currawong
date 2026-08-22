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
/// `EchoLinkClient`, and ``makeLink(settings:identity:credentials:)`` is the switch. Nothing
/// above this file knows there is more than one library: all three factories
/// return the same non-generic ``RadioLink``, which is exactly why that type
/// stopped being generic — see its doc comment.
///
/// The third one arriving without any change to ``RadioLink`` or
/// ``RadioLinkEvent`` is the evidence that the seam is in the right place. What
/// it did cost is below: two operator details that only EchoLink transmits, and
/// one pairing rule the library enforces by throwing.
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

    /// **EchoLink.** The "find me a public proxy" state, over the real
    /// echolink.org list and a real probe (EL-12).
    ///
    /// Owned here for the same two reasons as ``stationBrowser``: it is a
    /// network job measured in seconds, and `EchoLinkProxySelector` is a
    /// library type only this file may name.
    let proxyPicker: ProxyPicker

    /// **M17.** The reflector chooser's state, over the M17 Project's published
    /// host file.
    ///
    /// Owned here for the first of ``stationBrowser``'s two reasons only: a
    /// download that should survive a pane being scrolled away from. The second
    /// does not apply — `HostFileReflectorDirectory` names no library type and
    /// could have been built anywhere. It is here so that all three of the
    /// app's network-backed pickers are assembled in one place.
    let reflectorBrowser: ReflectorBrowser

    /// **AllStarLink.** The node-number lookup's state, over the public stats
    /// API. Owned here so a round trip survives a pane being scrolled away
    /// from, like the other three network-backed helpers.
    let nodeLocator: NodeLocator

    /// **APP-12.** The settings screen's portal-login state.
    ///
    /// Owned here for ``stationBrowser``'s two reasons — a network round trip
    /// that must survive the pane being scrolled away from, and a library type
    /// only this file may name.
    ///
    /// It logs in through ``AllStarLinkPortalLogin``, the adapter over IAX-13's
    /// `WebTransceiverTokenSource`. That is why the default is a live login rather
    /// than `nil`: the app's floor is `v0.5.2`, the release that carries the
    /// fetch. A `nil` login is still meaningful and still supported — it means
    /// "no logging in", which is what a preview, or a test with no business
    /// talking to allstarlink.org, should get.
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
        // `nil` rather than a default expression, again because the controller is
        // `@MainActor`. A test that passes one gets to read what the app asked
        // the lock screen for; a test that passes nothing gets the real thing on
        // iOS and nothing on macOS, which is what the app itself gets.
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
                // Dispatches on the mode in the settings; see `makeLink`.
                // `configuration` is the IAX2 one, so it only applies there.
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

        // The wire BU-14's repair depends on, in the other direction: the
        // session knows when nothing is on air, and only then may the accessory
        // rebuild a link that has silently stopped delivering. Unowned rather
        // than weak-and-optional inside the closure would make the pair
        // immortal, so this captures weakly and does nothing if the controller
        // has gone.
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
    /// The library's own default targets −18 dBFS RMS, which is a sensible
    /// headroom figure for a mixing stage and is too quiet coming out of a phone:
    /// a signal normalised there peaks around −3 dB, and with iOS's
    /// voice-processing output path on top of it the speaker at full volume
    /// sounds mid-scale. −12 dBFS is 6 dB louder while still leaving room for the
    /// peaks the leveller does not touch.
    ///
    /// The rest of the leveller's shape — attack, release, the +18 dB ceiling
    /// that stops a near-silent node being amplified into hiss — is the library's
    /// and is deliberately not second-guessed here. This is the app choosing an
    /// output level for a handheld device, which is the one part of it that is a
    /// property of the device rather than of the protocol.
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

    /// The guest account every Web Transceiver call authenticates as.
    ///
    /// A shared account, not the operator's callsign — a callsign here draws a
    /// bare REJECT with no CAUSE and no challenge. Observed against a live node
    /// (IAX-12); `swift-hamvoip/docs/CLI.md` §11.2 is the walkthrough.
    static let webTransceiverUsername = "allstar-public"

    /// The static secret that guest account uses.
    ///
    /// The same on every ASL3 node — it ships in `iax.conf` — which is why it is
    /// a constant here rather than something to ask an operator for. It is
    /// **not** the token and not a portal password.
    static let webTransceiverSecret = "allstar"

    /// The extension a WT call dials.
    ///
    /// `s`, the Asterisk start extension: WT never dials the node number, it
    /// calls in like a telephone and the node answers. Dialling the node number
    /// gives *No such context/extension*. Which node you end up attached to is
    /// decided by CALLING NUMBER instead.
    static let webTransceiverExtension = "s"

    /// What a Web Transceiver guest call presents, in the app's own vocabulary.
    ///
    /// Exists so the mapping can be *tested*. The rest of this file hands
    /// `IAX2Destination`s straight to a client, and neither the destination nor
    /// the client can be asked afterwards what it was built from — so a wiring
    /// mistake in five values, four of which are counter-intuitive, would be
    /// invisible until a node rejected the call. The tests do not import
    /// `IAX2Kit`, and this is what keeps that true.
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
    /// a Web Transceiver one.
    ///
    /// Four of these are not what anyone would guess, and every one was
    /// established by observation against a live node rather than from a
    /// document (IAX-12; `swift-hamvoip/docs/CLI.md` §11.2).
    ///
    /// The identity mapping is the part worth understanding: the node passes
    /// CALLING NAME to allstarlink.org, which resolves the token to a callsign.
    /// That is the whole of the authentication — which is why the token is a
    /// credential, and why it must reach the wire unaltered. `callsign` is
    /// upper-cased on the way out and would corrupt a lowercase-hex token, so the
    /// token travels in `callingName` and the operator's real callsign stays in
    /// `callsign`.
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
    /// `connect(to:)`, so an unused link costs two suspended tasks and is
    /// released by `close()`.
    ///
    /// **`transmitTimeout` overrides `configuration.transmitTimeout`.** SF-1 is
    /// enforced by the library, but the number is the operator's, and this is
    /// where the two meet. `TransmitTimeout` clamps itself on the way in, so
    /// there is no unreasonable value to defend against here.
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
    ///   `VoiceCodec`, because the library's own Codec2 conformance is
    ///   compiled out for SPM consumers. ``Codec2Codec`` is the app's, and
    ///   this is its injection point. See docs/CODEC2.md.
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
    ///   EchoLink audio is UDP 5198/5199 inbound, which carrier-grade NAT eats,
    ///   so FR-3.3 makes a TCP proxy on 8100 the normal path and the library only
    ///   implements that one — but which proxy is the operator's station
    ///   infrastructure rather than a property of the node, and a public one is
    ///   leased for a sitting. `settings.peer` is the node's own address, and it
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

    /// No proxy was sourced. `ProxyPicker` is what resolves one and the caller
    /// stops when it cannot; this is the backstop, and it is worth having because
    /// the failure without it happens inside the transport, where the message is
    /// about a socket rather than about a proxy.
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

        // **`normalisedCallsign`, not `callsign`** (APP-14). The QSO path
        // uppercases by way of `identity.validated()` before it builds a link;
        // this path did not, so a callsign typed in lower case authenticated for
        // a call and could be rejected for a browse — with the password correct
        // and correctly filed. The proxy login and the directory login line are
        // both built from this string.
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

/// The real public proxy finder (EL-12).
///
/// Wraps `EchoLinkProxySelector`, which fetches echolink.org's list, keeps the
/// entries advertised as public and ready, sorts them by distance and probes
/// them in batches until one answers.
///
/// **Why this is a `CompositionRoot` type and not a `NetworkClient` capability.**
/// Proxy selection produces a host and a port for an `EchoLinkDestination`; it
/// is meaningless for IAX2 and M17, so the library deliberately left it below
/// the seam. That puts it here, which is the rule working rather than the rule
/// being bent: the root picks the proxy, fills in the field, and the view never
/// meets an `EchoLinkPublicProxy`.
/// Wraps IAX-13's `WebTransceiverTokenSource` — the POST to allstarlink.org that
/// exchanges a portal login for a Web Transceiver token (APP-12, pane 1).
///
/// The same shape of adapter as ``EchoLinkPublicProxyFinder``, and here for the
/// same two reasons: `AllStarLinkPortalTokenFetcher` and
/// `WebTransceiverTokenError` are library types, which only this file may name,
/// and translating gives the app an error vocabulary of its own.
///
/// **The library owns the request.** Nothing here builds a URL, a body or a
/// header. The endpoint is named `legacy` and AllStarLink has a replacement
/// project open (OQ-10, caveat 2), so when the successor arrives it should be a
/// second conformance to `WebTransceiverTokenSource` inside the library, injected
/// below — and this file should not have to change at all.
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
