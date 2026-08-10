# Currawong

A SwiftUI client for internet-linked amateur radio voice modes, on iOS and
macOS. Named for a bird with a distinctive, far-carrying call, locally notable
in VK1.

Currawong is the app half of the project. The protocols live in
[`swift-hamvoip`](https://github.com/cpmpercussion/swift-hamvoip) — AllStarLink/IAX2 today, M17 and possibly
EchoLink later — and **no protocol code lives in this repository**. The app
talks to the libraries through `RadioCore.NetworkClient` and knows nothing about
RFC 5456. The one place a concrete client is named is
`Sources/Currawong/CompositionRoot.swift`.

## Status

**Connect screen and on-screen PTT (APP-2).** There is a form for one node —
host, port, node number, callsign, username, secret and the transmit watchdog
timeout — a connect/disconnect control, and a press-and-hold PTT button (PT-1).
Audio is wired both ways: the microphone into the client while transmitting,
received audio into playback. The secret is stored in the Keychain.

**DTMF (FR-1.5).** A keypad, and a log of digits sent and digits heard back.
Sending a digit deliberately does **not** key the transmitter — DTMF travels as
its own reliable frame — which is the property the tests pin. Commanding an
AllStar node means sending digit strings and watching what comes back, so the
two directions are logged separately: "did that go out?" and "did the node hear
it?" have different answers and different fixes.

**Phase 5 input layer, wired (PT-2, PT-3, PT-4).** `RadioSession` conforms to
`PTTSink`, so all three inputs reach one release path. The Bluetooth accessory
has a learn-mode UI (`AccessoryView.swift`): scan, press, release, press again,
release again, and it refuses an accessory it cannot learn rather than storing a
mapping that would key and never unkey. There is no device whitelist (PT-3). The
headset/remote button (PT-4) is off until switched on, latches rather than being
momentary, and says so wherever it can key the radio.

### Safety requirements

| | | |
|---|---|---|
| **SF-1** | transmit watchdog | Met. Enforced in the library; the timeout is per node and settable from 5 to 600 seconds, and cannot be switched off. Shown on screen when it fires. |
| **SF-2** | BLE link loss drops transmit | Met. Unconditional on every disconnection, before the reconnect logic and before anything is awaited, whether or not the accessory was the input holding the key. |
| **SF-3** | interruption or route change drops transmit | Met. Also drops on backgrounding, on the view disappearing, and on the gesture being cancelled or dragged off the button. |
| **SF-4** | transmit state visible without unlocking | **Not met** — the Live Activity is APP-3. There is a full-bleed banner while the app is on screen, and it names the input that keyed and whether letting go will unkey. |

Not yet: the Live Activity (SF-4, APP-3) and multiple stored nodes (APP-4 —
there is one node, with its watchdog timeout).

Nothing here has been on the air.

## Building and testing from the terminal

You need Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The library is resolved from its tag, so this
repository is all you need to clone.

The `.xcodeproj` is generated from `project.yml` and is not in version control,
so generate it first:

```sh
make generate      # xcodegen generate
make build         # build for a generic iOS device
make build-macos   # build for macOS
make test          # run the unit tests on an iOS simulator
make test-macos    # run the unit tests on macOS
make clean         # remove the generated project and all build output
```

`make test` picks an installed iPhone simulator for you
(`scripts/pick-simulator.sh`); override it with `make test SIMULATOR='iPhone 16'`.

Or without make:

```sh
xcodegen generate
xcodebuild build -scheme Currawong -destination 'generic/platform=iOS'
xcodebuild test  -scheme Currawong -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Signing is set to the maintainer's team. Building under a different account
wants `DEVELOPMENT_TEAM=XXXXXXXXXX` on the command line, or
`CODE_SIGNING_ALLOWED=NO` for an unsigned CI build.

## Pointing it at a node on your own network

Two permission prompts stand between a fresh install and audio, and both are
easy to mistake for a bug:

- **Local network** (iOS only). iOS gates all local-network traffic behind a
  prompt, so connecting to a node at a LAN address asks for permission the
  first time. Denying it presents as a connection that times out with nothing
  on screen to explain why — the app never sees a refusal it could report.
  Settings ▸ Privacy & Security ▸ Local Network is where to undo that.
  `NSLocalNetworkUsageDescription` in `project.yml` is what makes the prompt
  appear at all; this is unrelated to the multicast entitlement, which is
  forbidden by PD-3 and is not requested.
- **Microphone.** Refusing it leaves a PTT button that lights up and sends
  silence, which is why `connect()` fails loudly rather than continuing when the
  audio session will not configure.

Set the transmit watchdog short — 10 or 15 seconds — for the first session. It
is the quickest way to see SF-1 work, and on a strange node it is the
difference between a mistake that is embarrassing and one that is rude.

Running the macOS build is the shortest path to a first test if the node is in a
VM on the same machine: no device, no provisioning, no local-network prompt.

## Dependency on the library

`project.yml` declares `swift-hamvoip` as an ordinary versioned SPM dependency,
`from: 0.1.0`. Note that the library is 0.x and says in its own changelog that
the API may change in any release, so `from:` is a looser promise here than it
would be after 1.0.

Nothing in this repository pins the resolved version: the `Package.resolved`
that would do it lives inside the generated `.xcodeproj`, which is not in
version control, so a fresh `make generate` takes the newest matching release.
Pin the version in `project.yml` if that ever matters.

To work on the app and the library together, swap the dependency for a path
dependency on a sibling checkout and regenerate — there is a commented-out
block in `project.yml` for it. Don't commit the swap.

## What the app is allowed to know

- Views and view models use `RadioCore` vocabulary only — `NetworkClient`,
  `TransmitState`. If something up here needs an IAX2-shaped type, the fix
  belongs in the library's protocol, not in a cast.
- Background modes are `audio` and `bluetooth-central`, and nothing else.
- No CallKit, no volume-button PTT, no multicast entitlement.

## Licence

Apache-2.0, the same as the library. See [LICENSE](LICENSE).
