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

**Three modes.** AllStarLink over IAX2, M17 over a reflector, and EchoLink
through a proxy, all against `swift-hamvoip` (pinned `from: 0.5.2`) and all
reached through one `RadioCore.NetworkClient`. `CompositionRoot.swift` is still the only file that
names a concrete client. What each mode asks the operator for differs enough
that the connect form changes shape with the mode — a node number and a secret,
a reflector module, or a proxy plus a node address and an account password —
and `RadioMode` is where that fans out.

**Saved channels (APP-4).** A channel is one place worth going back to: a name,
a mode, and the fields that mode needs. They are listed, reorderable and
deletable, the selected one is remembered between launches, and connecting is
what saves a channel the operator has just typed. An operator upgrading from the
single-node build finds that node as their first channel — the old key is read
once and migrated, never written again.

**Panes rather than one long screen.** A sidebar of channels beside the live
session on macOS and iPad, tabs on iPhone, with the transmit banner outside the
container so it is visible from every pane (SF-4's stand-in until the Live
Activity lands).

**Station browser (EchoLink).** Nothing in the library resolves a callsign to an
address, so the directory listing is how a node is found: browse, search, and
save a station as a channel ready to connect. It opens a directory-only session
that contacts no node and transmits nothing.

**Reflector chooser (M17).** The same idea for a milder problem: M17 host names
are stable and can be typed, but the published list ran to 125 reflectors when
it was last read, which is not something to remember. The list is the host file
the
M17 Project publishes at
[`M17Hosts.json`](https://m17-project.github.io/hostfiles/M17Hosts.json) — the
underlying data is DVRef's, used under CC BY 4.0 and credited in the pane — and
the module is what you actually pick, since a reflector without one is
nowhere. Multiprotocol URF reflectors are included but
marked, and only their M17 and transcoding modules are offered; linking a DMR
module from here would be a connection that fails or, worse, succeeds into
silence. Unlike the station browser it fetches on first appearance, because a
static JSON file inconveniences nobody where seizing a single-user proxy does.

**Node lookup (AllStarLink).** A node number is what gets quoted on the air; the
address behind it is not something anyone carries around, and for a node on a
dynamic address it cannot be. AllStarLink publishes where each node last
registered, so the connect form asks: type the number, press Look up, and the
host fills itself in. A private node is not listed and the field stays
editable — the lookup is an offer, not a gate.

**Level meters and microphone gain.** Peak meters for transmit and receive,
scaled in dB with the good/hot/clipping zones marked, because "am I too quiet?"
is otherwise a question only a stranger on the air can answer. iOS does not let
an app change the microphone's own level (`inputGain` is not settable on the
built-in mic), so the gain control scales the captured samples instead — 0 to
+30 dB, hard-limited so a loud syllable flat-tops rather than wrapping to a
click. The slider sits with the meters rather than on the connect form, because
the gain belongs to the phone and not to any channel, and because the form locks
its fields while a link is up — which is the only time you can tell what to set
it to. It applies to the transmission in progress. Fixed gain rather than an AGC: a compressor would also pump the room
noise up between words, which on a repeater is antisocial in a way you cannot
hear from your own end.

**Connect screen and on-screen PTT (APP-2).** A connect/disconnect control and a
press-and-hold PTT button (PT-1). Audio is wired both ways: the microphone into
the client while transmitting, received audio into playback. Node secrets and
EchoLink account passwords are stored in the Keychain.

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

Not yet: the Live Activity (SF-4, APP-3).

**On the air.** Currawong keyed a live AllStarLink node from an iPhone for the
first time on 2026-08-11. All three modes have since been used from the app,
both directions of each now proven on air:

- **AllStarLink** — keyed on 2026-08-11.
- **EchoLink** — 2026-08-16: a `*ECHOTEST*` round trip, our own audio echoed
  back, and then VK1RBM with the connection heard live off air on UHF.
- **M17 receive** — 2026-08-16: a net on M17-434, intelligible for its length,
  with transmitting stations' callsigns displayed.
- **M17 transmit** — 2026-08-17: sent from Currawong to M17-434 module B and
  heard readable at the far end via Mseven, an independent M17 client. The
  scope is narrow — one reflector, one receiving implementation, one operator
  at both ends — but the encoder and LSF fields are no longer unproven.

**There is no longer a caution beside the mode picker.** There used to be one on
M17, which was right while nobody had heard the mode at all. Both directions of
every mode are now confirmed on the air, and a warning on a mode whose receive
and transmit paths the operator can hear working is a warning they learn to
dismiss. Development status lives here and in the plan, where it can be stated
precisely; the interface says things an operator can act on.

What remains of the bring-up — audio quality judged from the other end,
sustained receive, the watchdog and the interruption path, all exercised on real
equipment rather than in a test — is tracked in
[`docs/BRINGUP.md`](docs/BRINGUP.md): faults rather than features, landing
straight on `main` until that list is clear.

## Building and testing from the terminal

You need Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and `cmake` (`brew install cmake`). The library is
resolved from its tag, so this repository is all you need to clone.

`cmake` is there for `Codec2.xcframework`, which the app embeds for M17 audio
(FR-2.4) and which is not in version control — 7.6 MB of LGPL-2.1 binary. The
`make` targets below build it automatically the first time, which takes about
four minutes and then never again unless you run `make distclean`. Why the app
builds its own rather than getting one from the library:
[`docs/CODEC2.md`](docs/CODEC2.md).

The `.xcodeproj` is generated from `project.yml` and is not in version control,
so generate it first:

```sh
make generate      # xcodegen generate
make codec2        # build Codec2.xcframework (implied by the targets below)
make build         # build for a generic iOS device
make build-macos   # build for macOS
make test          # run the unit tests on an iOS simulator
make test-macos    # run the unit tests on macOS
make clean         # remove the generated project and all build output
make distclean     # ...and the Codec2 framework, forcing a four-minute rebuild
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
