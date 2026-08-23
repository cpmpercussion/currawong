# Currawong

[![CI](https://github.com/cpmpercussion/currawong/actions/workflows/ci.yml/badge.svg)](https://github.com/cpmpercussion/currawong/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016.2%20%7C%20macOS%2013-lightgrey)](project.yml)
[![Modes](https://img.shields.io/badge/modes-AllStarLink%20%7C%20M17%20%7C%20EchoLink-brightgreen)](#what-it-does)
[![Codecs](https://img.shields.io/badge/codecs-%CE%BC--law%20%7C%20GSM%20%7C%20Codec2-blue)](docs/CODEC2.md)
[![Library](https://img.shields.io/badge/swift--hamvoip-0.5.4-informational)](https://github.com/cpmpercussion/swift-hamvoip)
[![Licence](https://img.shields.io/badge/licence-Apache--2.0-blue)](LICENSE)

Currawong is an app for communicating on internet-linked amateur radio voice modes.
The app is designed for iOS and macOS.

The app supports three open digital communication protocols:
AllStarLink (IAX2), M17, and EchoLink. These protocols allow access to group communication nodes
maintained by the amateur radio community.
Digital modes using AMBE/AMBE+2 are out of scope at least as long as
patents block open implementations.

The priorities of the app are to be clear and functional,
to have excellent user experience and usability,
and to be open with a permissive license for other radio amateurs to learn from or improve.

Currawong is named for a bird with a distinctive, far-carrying call, locally notable
in VK1.

Currawong is the app half of the project. The protocols live in
[`swift-hamvoip`](https://github.com/cpmpercussion/swift-hamvoip). The app
talks to the libraries through `RadioCore.NetworkClient`.

## What it does

### Three modes

AllStarLink over IAX2, M17 to a reflector, and EchoLink through a proxy, all
reached through one `RadioCore.NetworkClient` — `CompositionRoot.swift` is the
only file that names a concrete client. What each mode asks the operator for
differs enough that the connect form changes shape with the mode: a node number
and a secret, a reflector and module, or a node address and an account
password. `RadioMode` is where that fans out.

**AllStarLink has two routes to a node, and the app offers both.** A node secret
is something the node's owner sets up for you, per node. **Web Transceiver**
needs no arrangement with anyone: if the owner has switched it on, an
allstarlink.org portal account reaches it. A _How to connect_ picker chooses
between them and `NodeSettings.allStarAccess` records which route a channel
takes. It is a credentials variant rather than a fourth mode — same protocol,
same nodes. The token is stored under your callsign rather than with the
channel, because the portal issues one per operator and it works on every
WT-enabled node.

**Logging in to the portal works from the app.** Callsign and allstarlink.org
password, press _Log in and fetch token_, and the token lands in the Keychain.
The password is **used once and discarded**: only the token is stored. Pasting
a token by hand still works, which is what will save you if allstarlink.org
replaces its login service — it has a project open to do that.

**The EchoLink proxy is not something you set up.** A phone cannot reach an
EchoLink node directly, so every session is tunnelled through a proxy, and the
app sources one at the moment it needs one — connecting, or refreshing the
directory. There is no proxy field and no _connect to proxy_ step, and the
proxy is released at disconnect so the next session gets a machine that is
actually free. If you run your own — the answer for sustained operating, since
the public ones carry one user at a time — it goes in _Settings_ once, for the
whole station, with its password in the Keychain.

### Finding somewhere to go

- **Station browser (EchoLink).** Nothing in the library resolves a callsign to
  an address, so the directory listing is how a node is found: browse, search,
  and save a station as a channel. It opens a directory-only session that
  contacts no node and transmits nothing.
- **Reflector chooser (M17).** The host file the M17 Project publishes at
  [`M17Hosts.json`](https://m17-project.github.io/hostfiles/M17Hosts.json) — the
  underlying data is DVRef's, used under CC BY 4.0. The
  module is what you actually pick, since a reflector without one is nowhere.
  Multiprotocol URF reflectors are included but marked, and only their M17 and
  transcoding modules are offered: linking to a DMR module is not supported.
- **Node lookup (AllStarLink).** A node number is what gets quoted on the air;
  the address behind it is not something anyone carries around, and for a node
  on a dynamic address it cannot be. Type the number, press _Look up_, and the
  host fills itself in. A private node is not listed and the field stays
  editable — the lookup is an offer, not a gate.

### Saved channels

A channel is one place worth going back to: a name, a mode, and the fields that
mode needs. They are listed, reorderable and deletable, the selected one is
remembered between launches, and **connecting is what saves** a channel the
operator has just typed. An operator upgrading from the single-node build finds
that node as their first channel.

### Transmitting

Three inputs, one release path — `RadioSession` conforms to `PTTSink`, so
nothing can key by a route that cannot unkey:

- **On-screen PTT** (PT-1), press and hold.
- **A Bluetooth accessory** (PT-2, PT-3), with a learn mode: scan, press,
  release, press again, release again. It refuses an accessory it cannot learn
  rather than storing a mapping that would key and never unkey. There is no
  device whitelist.
- **The headset or remote button** (PT-4), off until switched on. It latches
  rather than being momentary, and says so wherever it can key the radio.

Hanging up sits directly under the PTT button: **Disconnect** while a link is
up, **Cancel** while a connect is still going, and **Reconnect to _channel_**
once there is somewhere to go back to. It names the channel because it returns
to where the last call went, not to whatever is selected now. Before the first
call of a run it is not there at all.

### Audio

Peak meters for transmit and receive, scaled in dB with the good/hot/clipping
zones marked to track signal level.
Two gain controls sit with the meters rather than on the
connect form, because they belong to the phone and not to any channel — and
because the form locks its fields while a link is up, which is the only time you
can tell what to set them to. Both apply to the transmission in progress.

- **Microphone gain, 0 to +30 dB.** iOS does not let an app change the
  microphone's own level (`inputGain` is not settable on the built-in mic), so
  this scales the captured samples, hard-limited so a loud syllable flat-tops
  rather than wrapping to a click.
- **Receive gain, 0 to +20 dB.** Boost only.

### DTMF (FR-1.5)

A keypad, and a log of digits sent and digits heard back. Sending a digit
does **not** key the transmitter — DTMF travels as its own reliable
frame.

A command reference sheet is readable while connected: `*3` plus a node number
links, `*1` unlinks, and so on. It is transcribed from AllStarLink's own
operator manual, which documents the _suggested_ defaults — the authority for
any node is that node's `rpt.conf`, so the sheet is a memory aid for accepted practice rather than a
contract.

### On screen

A sidebar of channels beside the live
session on macOS and iPad, tabs on iPhone, with the transmit banner outside the
container so it is visible from every pane. The status panel is laid out like a
radio's front panel, led by _where you are connected_ rather than by the
connection state.

**A Live Activity while transmitting (SF-4, iOS only).** Transmit state on a
locked iPhone, because the failure this project is arranged around is a phone in
a pocket with the microphone open. It names the channel and the mode, says
whether letting go will unkey, and counts the watchdog down. What it mostly does
is _end_: on release, on the watchdog, on the accessory link dropping, on an
interruption, on an unrepairable route change, on disconnection, and — because a
Live Activity outlives the process that asked for it — on the next launch after
the app was killed mid-over. Through the 300 ms of a route-change recovery it
stays up and says it is _not_ transmitting rather than holding a red banner over
a shut microphone. macOS has no Live Activities.

### Settings

One app-level screen for your
callsign, the transmit watchdog timer, the AllStarLink portal token, the EchoLink
account password, your own proxy if you run one, and PTT accessory setup.

The EchoLink account password lives here and not on the connect form: the
Keychain has always filed it under `echolink:<callsign>`, shared by every
EchoLink channel with that callsign. What is left on the form is _whether_ one
is set.

### Diagnostics

The audio route, category, mode and hardware rate are logged on every key-down
and key-up, not only when a transmission fails outright. An accessory fault
happens once, on air, to an operator holding a radio, and the state that would
have explained it is gone by the time anyone looks.

## Safety requirements

|          |                                             |                                                                                                                                                                                                                                                                                                                                                                                 |
| -------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **SF-1** | transmit watchdog                           | Met. Enforced in the library; the timeout is per node and settable from 5 to 600 seconds, and cannot be switched off. Shown on screen when it fires.                                                                                                                                                                                                                            |
| **SF-2** | BLE link loss drops transmit                | Met. Unconditional on every disconnection, before the reconnect logic and before anything is awaited, whether or not the accessory was the input holding the key.                                                                                                                                                                                                               |
| **SF-3** | interruption or route change drops transmit | Met. Also drops on backgrounding, on the view disappearing, and on the gesture being cancelled or dragged off the button. A **route change** additionally keys back down if the button is still held — transmission stops either way, but an operator who never let go should not have to press again. Bounded to three resumes per hold, and never applied to an interruption. |
| **SF-4** | transmit state visible without unlocking    | Met (iOS). A Live Activity while keyed, plus the full-bleed banner while the app is on screen; both name the input that keyed and whether letting go will unkey. It ends on all six paths that end transmit and clears anything a terminated launch left behind. **Not yet observed on a locked device** — `docs/BRINGUP.md` `BU-10`.                                           |

**The table is what the code does; [`docs/BRINGUP.md`](docs/BRINGUP.md) is what
anyone has watched happen.** That distinction is the point of keeping two lists:
SF-4 is met in the implementation and in its tests, and is the one of the four
whose whole purpose is a screen nobody was looking at.

## Maturity

All three modes have been used on the air, in both directions, from the app.
This is version 0.1.0 and has not been released; the audio quality judged from
the far end, sustained receive, and the watchdog and interruption paths on real
equipment are all still being worked through in
[`docs/BRINGUP.md`](docs/BRINGUP.md) — faults rather than features, landing
straight on `main` until that list is clear. What is planned rather than built
is in [`docs/DEVELOPMENT-PLAN.md`](docs/DEVELOPMENT-PLAN.md).

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
`from: 0.5.4`. Note that the library is 0.x and says in its own changelog that
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
