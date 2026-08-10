// SPDX-License-Identifier: Apache-2.0

import Foundation
import IAX2Kit
import RadioCore

/// The one object in Currawong allowed to name a concrete network.
///
/// `RadioCore.NetworkClient` is the boundary between the app and the protocol
/// libraries: views and view models talk to `connect(to:)`, `startTransmit()`,
/// `stopTransmit()`, `disconnect()` and `state`, and know nothing about RFC
/// 5456. Somebody, though, has to decide *which* client is on the other side of
/// that protocol and build it — and this is that somebody. It is the single
/// documented exception to the rule, and it is why `import IAX2Kit` appears in
/// this file and nowhere else.
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
    /// The view model everything else in the app is built on. Generic over the
    /// client for the reason above: `NetworkClient` has an `associatedtype
    /// Destination`, so there is no existential to hold, and this is the only
    /// place allowed to spell the concrete parameter.
    let session: RadioSession<IAX2Client>

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
        remoteCommand: RemoteCommandPTTController? = nil
    ) {
        let session = RadioSession(
            audio: audio,
            settingsStore: settingsStore,
            secretStore: secretStore,
            makeLink: { settings, secret in
                CompositionRoot.makeIAX2Link(
                    settings: settings, secret: secret, configuration: configuration)
            })
        let accessory = accessory ?? BLEPTTController()
        let remoteCommand = remoteCommand ?? RemoteCommandPTTController()

        self.session = session
        self.accessory = accessory
        self.remoteCommand = remoteCommand

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
    ) -> RadioLink<IAX2Client> {
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
            client: client,
            destination: destination,
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
