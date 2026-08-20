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
a reflector module, or a node address and an account password — and `RadioMode`
is where that fans out.

**Web Transceiver (APP-11).** AllStarLink has two routes to a node and the app
now offers both. A node secret is something the node's owner sets up for you, per
node, in its configuration. **Web Transceiver** needs no arrangement with anyone:
if the owner has switched it on, an allstarlink.org portal account reaches it. So
the AllStarLink third of the form has a *How to connect* picker — node secret, or
a portal token in place of the username and secret.

It is a credentials variant rather than a fourth mode, because it is the same
protocol to the same nodes; `RadioMode` stays three wide and
`NodeSettings.allStarAccess` says which route a channel takes. The token is
stored in the Keychain under your callsign rather than with the channel, because
the portal issues one per operator and it works on every WT-enabled node — it
stands for your callsign, which the node asks allstarlink.org to confirm. The
four counter-intuitive values a guest call actually presents (a shared guest
username, a static secret, Asterisk's start extension, and the node number moved
into CALLING NUMBER) live in `CompositionRoot.swift` with the evidence for each,
and are pinned by tests. Getting a token is a paste for now; APP-12's settings
screen is where logging in to the portal will fetch one.

**Settings (APP-12).** One app-level screen — the *Settings* tab, and the
*Settings* pane in the split layout — for the things that are yours rather than a
channel's: your callsign, the AllStarLink portal token, the EchoLink account
password, and PTT accessory setup, which used to be reachable only from a row on
the session screen. That was accessory setup as something you find mid-session,
which is a poor moment to be pairing a fob.

The EchoLink account password moved here from the connect form. It was never a
property of a channel — the Keychain has always filed it under
`echolink:<callsign>`, shared by every EchoLink channel with that callsign — so
the form was the wrong shape for what it was editing. What is left on the form is
whether one is set, because an EchoLink connection with no account password
succeeds at every step and is then unreachable.

**The EchoLink proxy is not something you set up (APP-13).** A phone cannot reach
an EchoLink node directly, so every session is tunnelled through a proxy — and
the app sources one for you at the moment it needs one, when you connect or when
you refresh the directory. There is no proxy field to fill in and no *connect to
proxy* step, and the proxy is given back as soon as you disconnect, so the next
session gets a machine that is actually free rather than returning to one that
somebody else has since taken.

If you run your own proxy — the answer for sustained operating, since the public
ones carry one user at a time and are meant for brief use — it goes in *Settings*
once, for the whole station, and its password goes in the Keychain. It used to be
three fields of every channel, inside a collapsed drawer on the connect screen,
which was both the wrong owner and the wrong place: a proxy is the machine your
traffic leaves through, not a property of the node you are calling. The connect
form's proxy drawer now says which proxy is carrying this session and offers to
find another; it asks for nothing.

**Logging in to the portal works from the app.** Type your callsign and
allstarlink.org password, press *Log in and fetch token*, and the token lands in
the Keychain. The request itself is the library's (IAX-13, released in `v0.5.2`);
`AllStarLinkPortalLogin` in `CompositionRoot.swift` is the adapter, and the only
thing in the app that knows the fetch exists. The paste field stays, because it is
what still works if allstarlink.org replaces its login service — which it has a
project open to do.

The portal password is **used once and discarded**: only the token is stored. A
retained password would buy a silent re-fetch, and a token is stable across calls,
so there is nothing to re-fetch — a token that stopped working is one the portal
has changed its mind about, and asking again is then the honest thing to do. The
failures read differently on purpose: a wrong password re-prompts, a changed login
service says the paste field still works, and anything else is reported as not
reached.

**Saved channels (APP-4).** A channel is one place worth going back to: a name,
a mode, and the fields that mode needs. They are listed, reorderable and
deletable, the selected one is remembered between launches, and connecting is
what saves a channel the operator has just typed. An operator upgrading from the
single-node build finds that node as their first channel — the old key is read
once and migrated, never written again.

**Panes rather than one long screen.** A sidebar of channels beside the live
session on macOS and iPad, tabs on iPhone, with the transmit banner outside the
container so it is visible from every pane. Its lock-screen counterpart is the
Live Activity below.

**A Live Activity while transmitting (SF-4).** Transmit state on a locked
iPhone, because the failure this project is arranged around is a phone in a
pocket with the microphone open. It names the channel and the mode, says whether
letting go will unkey, and counts the watchdog down. What it mostly does is
*end*: on release, on the watchdog, on the accessory link dropping, on an
interruption, on a route change that cannot be repaired, on disconnection, and —
because a Live Activity outlives the process that asked for it — on the next
launch after the app was killed mid-over. An indicator that goes on claiming TX
after transmission stopped is worse than none, so it is never red unless the
client is genuinely keyed: through the 300 ms of a route-change recovery it stays
up and says it is *not* transmitting rather than holding the red banner over a
shut microphone. iOS only; macOS has no Live Activities.

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

Hanging up is also on the session screen, directly under the PTT button: one
control that says **Disconnect** while a link is up, **Cancel** while a connect
is still going (which the connect form's button cannot offer — it is inert while
busy), and **Reconnect to _channel_** once there is somewhere to go back to. It
names the channel because it returns to the one the last call was placed to, not
to whatever is selected now — you may pick another channel while disconnected,
and the button still means the place you were just talking to. Before the first
call of a run it is not there at all: a first call starts on the connect form,
where the fields being dialled are visible.

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
| **SF-3** | interruption or route change drops transmit | Met. Also drops on backgrounding, on the view disappearing, and on the gesture being cancelled or dragged off the button. A **route change** additionally keys back down if the button is still held — transmission stops either way, but an operator who never let go should not have to press again. Bounded to three resumes per hold, and never applied to an interruption. |
| **SF-4** | transmit state visible without unlocking | Met (iOS). A Live Activity while keyed, plus the full-bleed banner while the app is on screen; both name the input that keyed and whether letting go will unkey. It ends on all six paths that end transmit and clears anything a terminated launch left behind. **Not yet observed on a locked device** — `docs/BRINGUP.md` `BU-10`. |

**The safety table is what the code does; `docs/BRINGUP.md` is what anyone has
watched happen.** SF-4's row above went from "not met" to "met" on 2026-08-20 on
the strength of the implementation and its tests, and SF-4 is the one of the four
whose whole point is a screen nobody was looking at. `BU-10` is open until
somebody has looked.

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
