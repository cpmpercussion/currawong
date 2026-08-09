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
///
/// A `NetworkClient` with an associated event enum, a `receivedAudio` stream
/// and a `send(pcm:)` requirement would let ``RadioSession`` build its own
/// link and delete most of this file. Until then, this is the containment.
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

    /// Transmit state, for anything that only needs to display it.
    var transmitState: TransmitState { session.transmitState }

    /// - Parameters:
    ///   - configuration: watchdog timeout (SF-1, 180 s by default), media
    ///     grid, jitter buffer and leveller. Injectable so a test can build a
    ///     root without waiting three minutes for anything.
    ///   - audio: the microphone and speaker. Injectable so a test never opens
    ///     either.
    init(
        configuration: IAX2Client.Configuration = IAX2Client.Configuration(),
        audio: AudioIO = AudioPipelineIO(),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        secretStore: SecretStore = KeychainSecretStore()
    ) {
        self.session = RadioSession(
            audio: audio,
            settingsStore: settingsStore,
            secretStore: secretStore,
            makeLink: { settings, secret in
                CompositionRoot.makeIAX2Link(
                    settings: settings, secret: secret, configuration: configuration)
            })
    }

    /// Builds one IAX2 connection's worth of plumbing.
    ///
    /// Opens nothing: `IAX2Client` builds its transport lazily inside
    /// `connect(to:)`, so an unused link costs two suspended tasks and is
    /// released by `close()`.
    static func makeIAX2Link(
        settings: NodeSettings,
        secret: String,
        configuration: IAX2Client.Configuration = IAX2Client.Configuration()
    ) -> RadioLink<IAX2Client> {
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
        // vocabulary and must not escape this file. DTMF is dropped for now —
        // there is nothing above to show it until APP-4 adds a keypad.
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
        case .connected:
            self = .connected
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
        case .dtmf:
            // APP-4 adds a keypad and somewhere to show inbound digits.
            return nil
        }
    }
}
