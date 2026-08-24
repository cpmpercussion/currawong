# Currawong — Development Plan

**Audience:** implementation agents executing one task at a time.
**Moved here 2026-08-21**, from `swift-hamvoip/docs/DEVELOPMENT-PLAN.md`, where
`APP-*` and `BLE-*` were Phases 4 and 5. The text of every task below is that
file's, unchanged but for the relative paths; the history of how they were
written is in the library repo's log, not this one.

## Why this file is here and not in the library

The plan was one document because the *requirements* are one document, and that
part has not changed: **`../../swift-hamvoip/docs/DESIGN-REQUIREMENTS.md` is
still the only authority for requirement IDs** — `FR-*`, `SF-*`, `PD-*`, `PT-*`,
`OQ-*`, `NG-*` — and this file cites them rather than restating them. Two plans
citing one requirements document is the split; two requirements documents would
be the drift the workspace `CLAUDE.md` already warns about.

What did not survive was keeping the *task list* there. Every app task is
executed in this repository, tested by `make test`, and closed by a commit in
this log — and the plan PR recording it went to a repository the work never
touched. That is one PR per app task in the wrong repo, and a task list nobody
editing the app has open.

**The layering rule is unchanged and is why this is safe:** Currawong reads the
library and never writes to it. The corollary now cuts both ways — the library's
plan does not carry the app's task list either.

**When an app task needs a library change** — and it often does; `BU-3` became
`RC-11`, and `BU-13`'s likely repair is in the audio-session category, which is
the library's since RC-11 — the task stays here and the library change gets its
own task, its own branch and its own PR *there*, cited from here by ID. The
seam between the repos is `NetworkClient` and a versioned SPM dependency; a task
that would blur it belongs in the library, not in a cast in the app.

## How to work

**Read `../../swift-hamvoip/docs/DEVELOPMENT-PLAN.md` §1 first.** It governs
here too, and is not duplicated: one task per branch (`task/<id>`), one PR, the
clean-room policy (LP-1, LP-2 — absolute, and it applies to app code as much as
to a parser), SPDX on line 1 of every Swift file, no network in unit tests
(AU-5), no third-party dependencies without a task that names one, no scope
expansion into the permanent exclusions, and the actor-reentrancy rule.

Four things are this repository's own, and `CLAUDE.md` here is the full list:

1. **The project file is generated.** `Currawong.xcodeproj` and
   `Sources/Currawong/Info.plist` are never committed. Change `project.yml`,
   then `make generate`.
2. **Everything works from the terminal.** `make generate && make build &&
   make test`, and `make test-macos`. No task may require opening Xcode.
3. **`CompositionRoot.swift` is the only file that may name a
   protocol-specific client.** A protocol type wanted anywhere else means
   `NetworkClient` is missing a capability, and that is a library task.
4. **The library dependency is versioned, never a path.** The commented-out
   path dependency in `project.yml` is for working on both sides at once and
   must not be committed swapped.

## What is a task here and what is not

`BRINGUP.md` tracks `BU-*` — **faults**: things that are supposed to work and do
not, including everything that has never been confirmed with a real radio, a
real accessory or a real handset. This file tracks **features**: things the app
should be able to do and cannot yet.

The distinction has earned its keep, because the two want different rules — a
fault is often found and fixed in one on-air session, and reviewing it in the
middle of that loop buys nothing (see `BRINGUP.md`, "How this work lands"). When
a fault turns out to want a feature, it becomes an `APP-*` row here and says so.

**Phase 4's task list is closed** (2026-08-21) and Phase 5's work shipped inside
it, under APP-5. Nothing below is open. What is open for this app is in
`BRINGUP.md`: `BU-7`, `BU-10`, `BU-13`, `BU-14`, and `BU-11` is a
decision rather than a defect. `SIL-1` — silent operating mode — is an app task
that has never been scoped; its row is still in the library plan's open list,
pointing here, and it will be written up in this file when it is taken up.

---

## Phase 4 — Currawong, the SwiftUI app ✅ TASK LIST CLOSED 2026-08-21

**The app is called Currawong** — a bird with a distinctive, far-carrying
call, locally notable in VK1. Trademark checked clear in class 9.

- **Repository:** a separate `currawong` repo (OQ-4) — this one — depending on
  `swift-hamvoip` via SPM. **The library repo stays library-only**, which as of
  2026-08-21 includes not carrying this task list.
- **Bundle identifier:** `au.charlesmartin.currawong`. Extensions extend it
  (`au.charlesmartin.currawong.liveactivity`). Keychain access group
  `$(TeamID).au.charlesmartin.currawong`.
- **Project generation:** **xcodegen** (`project.yml`), no checked-in
  `.xcodeproj`, per the repo's Apple development procedures.
- The app talks to `IAX2Client` **only through the `NetworkClient`
  protocol** — it must know nothing about IAX2, M17 or EchoLink specifics.
  If the app needs a protocol-specific type, that is a signal `NetworkClient`
  is missing something; fix it there rather than leaking the detail upward.

- **APP-1** — xcodegen scaffold: iOS 16+ app depending on swift-hamvoip via
  SPM; background modes `audio` + `bluetooth-central` (PD-2); CI via
  `xcodebuild test -destination 'platform=iOS Simulator,…'` from the CLI.
  ✅ **DONE** — `currawong` `19c6e3a`, CI in `30bfd61`.
- **APP-2** — Connect screen + on-screen momentary PTT (PT-1): press-and-hold
  button → `startTransmit`/`stopTransmit`; TX state banner; interruption
  handling — `AVAudioSession.interruptionNotification` and route change
  force `stopTransmit` (SF-3). ViewModel logic unit-tested against a fake
  `NetworkClient`. ✅ **DONE** — `currawong` `8f8b353`. SF-3 went further than
  this row asked: transmit also drops on backgrounding, on the view
  disappearing, and on the gesture being cancelled or dragged off the button.
- **APP-3** — TX visibility without unlock (SF-4): Live Activity showing
  TX/RX state, plus `MPRemoteCommandCenter` toggle-PTT fallback (PT-4).
  ✅ **DONE** — `currawong` `0f06adc` (PR #20), 2026-08-20; the app's
  deployment floor rose to iOS 16.2 with it. Written up below. The PT-4 half
  shipped early, under APP-5.
- **APP-4** — Settings: node list CRUD, watchdog timeout, stored in
  `UserDefaults`; secrets in Keychain. ✅ **DONE** — `currawong` `54bf219`
  (saved channels: a name, a mode, and that mode's fields; reorderable,
  deletable, selection remembered between launches, and the single-node
  build's key read once and migrated) and `c8063c3` (watchdog settable per
  node, 5–600 s, and it cannot be switched off). Operator identity —
  callsign, name, location — was later hoisted out of the per-channel
  settings to be app-wide (`ac2d264`, `dcf45b7`): one operator, not one per
  channel.
- **APP-5** — PTT input layer: BLE, accessory learn mode, remote command
  (PT-2, PT-3, PT-4). ✅ **DONE** — written up below. **This is also where
  Phase 5's BLE-1 … BLE-3 were delivered**; see the note under Phase 5.
- **APP-6** — Microphone permission, asked for explicitly (iOS). ✅ **DONE** —
  written up below. A fault rather than a feature, but it earned a task
  because the app could not bootstrap its own permission.
- **APP-7** — Directories and discovery: two browsers and one lookup.
  ✅ **DONE** — written up below.
- **APP-8** — Three modes through one seam: mode selection, per-mode connect
  forms, EchoLink in the app, and Codec2 embedded for M17. ✅ **DONE** —
  written up below.
- **APP-9** — Level meters and microphone gain. ✅ **DONE** — written up below.
- **APP-11** — Web Transceiver in the app — IAX-12's app half. ✅ **DONE** —
  `currawong` `8be0565`.
- **APP-12** — Settings: the portal login, the two stored accounts and the PTT
  accessory pane. ✅ **DONE** — `currawong` `a24f7f6`. The watchdog joined it
  afterwards (`f46b9d2`), hoisted out of the per-channel settings the way the
  operator identity was under APP-4.
- **APP-13** — The EchoLink proxy stops being a channel field. ✅ **DONE** —
  written up below.
- **APP-14** — One EchoLink password, and no write from a mode that has none.
  ✅ **DONE** — written up below. The open question in it had an answer, and it
  was the fault the maintainer was reporting from the other end.
- **APP-15** — The pane picker cannot be laid out off-screen. ✅ **DONE** —
  written up below.
- **APP-16** — The status panel leads with where the radio is pointed. ✅
  **DONE** — written up below.
- **APP-17** — The link button dials what the panel is showing. ✅ **DONE** —
  written up below.
- **APP-18** — The session pane shows the controls the state actually has. ✅
  **DONE** — written up below.
- **APP-19** — `Add channel` stops writing a blank channel to the list. ✅
  **DONE** — written up below, including why the title it was opened under was
  wrong.
- **APP-20** — Every pane gets the same column, and the sidebar its insets. ✅
  **DONE** — written up below.
- **APP-21** — The view layer is tested on both platforms, and the UI tests stop
  editing the operator's app. ✅ **DONE** — written up below.
- **APP-22** — `Add channel` puts a row in the list, provisionally. ✅ **DONE** —
  written up below. APP-19's rule with the feedback it was missing.

ℹ️ **APP-5 … APP-9 were written up after the fact**, on 2026-08-16, from the
app's commit history. APP-5 and APP-6 were cited by `currawong` commits with no
row here to cite; APP-7 … APP-9 are new identifiers given to work that shipped
without one. Numbering follows what those commits already claimed, so it is
**not chronological** — APP-7, APP-8 and APP-9 all landed before APP-6.

⚠️ **The app keeps a second list this plan does not own.**
`BRINGUP.md` tracks `BU-*` — *faults*, not features: things
supposed to work already that do not, found by trying to key a real radio.
They land straight on `main` in the app repo, no branch and no PR, until the
app is confirmed working on air. That is a deliberate suspension of §1.1 for a
loop that runs through an on-air session rather than through CI, and it is the
app's call to make. **Read that file before planning app work** — it is where
the live-validation state of all three modes actually lives, and one of its
items (BU-3) is a task for *this* repository: see RC-11.

### APP-3 — TX visibility without unlock (SF-4) ✅ DONE
**Delivered** in `currawong` `0f06adc` (PR #20), 2026-08-20. **Depends on:**
APP-2 ✅. This was the last unmet safety requirement; the app README's safety
table now says **Met** against SF-4.

**What was there before.** A full-bleed transmit banner (`TransmitBanner.swift`,
`TransmitStatusPresentation.swift`) outside the pane container, naming the input
that keyed and whether letting go will unkey. A stand-in, and the app README
says so: it is visible only while the app is on screen, which is precisely the
case SF-4 is not about.

**Why SF-4 exists.** A phone in a pocket, screen locked, transmitting — a stuck
open microphone into a repeater that the operator cannot see and other
operators cannot key over. The watchdog (SF-1) bounds how long that lasts; SF-4
makes it visible before the watchdog fires.

**Shape of the work**, with the constraints that are already known:

- A **widget extension target** in `project.yml`, bundle identifier
  `au.charlesmartin.currawong.liveactivity` — already reserved by the OQ-3b
  resolution, so no naming decision is outstanding.
- **ActivityKit is iOS 16.1+, and the deployment target was iOS 16.0.**
  ✅ **DECIDED 2026-08-16 — raise the floor.** The maintainer's call: raise the
  app's minimum rather than scattering availability guards through the call
  sites for versions nobody is on. **The floor the implementation settled on is
  iOS 16.2, not 16.1** — `ActivityContent`, `update(_:)` taking an
  `ActivityContent`, and `end(_:dismissalPolicy:)` are all 16.2, and those three
  are exactly what keeps the activity from displaying a stale transmit state. So
  the floor is what the code calls, not the framework's own minimum: 16.2, set
  in `project.yml`. **The library's own floor stays at iOS 16.0** — nothing in
  `swift-hamvoip` needs ActivityKit, and an app-driven bump to a protocol
  library would be the tail wagging the dog.
- **macOS has no Live Activities.** The macOS build must still compile and
  test; `make test-macos` is part of the definition of done, not an
  afterthought.
- **PD-4 still forbids CallKit**, which is the other way an app gets
  lock-screen presence. It is not an option here, and this row is not a route
  back to it.
- Updates come from the app process, which stays alive during a session under
  the `audio` background mode (PD-2). **No `voip` background mode, and no push
  entitlement** — if the design appears to need either, stop and report it.
- **The stale-state hazard is the real risk.** A Live Activity still showing
  TX after transmit stopped is worse than none at all: it is a safety display
  that lies. It must end on every path that ends transmit — release, watchdog
  expiry (SF-1), BLE loss (SF-2), interruption or route change (SF-3),
  disconnection, and app termination. Whatever the implementation, the test
  that matters is that each of those paths is driven and the activity is
  observed to end.

**Done when:** transmit state is visible on a locked iPhone, it ends on all
six paths above, the macOS build and tests are unaffected, and the README's
safety table can say **Met** against SF-4.

⛔ **Never seen on a locked iPhone, and the case it exists for has never been
staged** — a BLE accessory keying a backgrounded app. Apple documents
`Activity.request` as a foreground operation, which that case is not. Tracked
app-side as `BRINGUP.md` `BU-10`, not here. If a device refuses
the request, the fallback is that the activity becomes connection-scoped rather
than transmit-scoped — a change confined to `RadioSession.desiredActivity` in
the app.

### APP-5 — PTT input layer: BLE, learn mode, remote command ✅ DONE
**Delivered** in `currawong` `cd2a7da` ("APP-5 (partial)") and completed in
`c8063c3`. Written up 2026-08-16.

`RadioSession` conforms to `PTTSink`, so all three input paths — on-screen
button, Bluetooth accessory, headset/remote button — reach **one** release
path rather than three. That is the design point: a key has one way to be let
go of, whichever thing keyed it.

- **PT-2, BLE.** `BLECentral.swift` (a protocol seam over CoreBluetooth, so
  the state logic is testable with a fake central), `CoreBluetoothCentral.swift`
  (the real one), `BLEPTTController.swift` (scan, connect, auto-reconnect).
- **PT-3, learn mode, no device whitelist.** `PTTMapping.swift` and
  `AccessoryView.swift`: scan, press, release, press again, release again, and
  the app records which (service, characteristic, payload) pairs fire on press
  versus release. **It refuses an accessory it cannot learn** rather than
  storing a mapping that would key and never unkey — which is the whole reason
  learn mode exists instead of a device list.
- **PT-4, remote command.** `RemoteCommandPTT.swift`. Off until switched on,
  **latching rather than momentary** — the honest semantics for a button the
  app cannot see the release of — and it says so wherever it can key the radio.
- **SF-2 is met and is deliberately blunt:** every disconnection drops
  transmit unconditionally, before the reconnect logic and before anything is
  awaited, whether or not the accessory was the input holding the key.

Tests: `BLEPTTControllerTests`, `RemoteCommandPTTTests`,
`RadioSessionPTTSinkTests`, with fakes in `PTTFakes.swift`.

⛔ **Never exercised with a real accessory.** Everything above is tested
against a fake central. Learn mode against actual hardware — a commercial PTT
button, a headset — is on-air-style validation and belongs in
`BRINGUP.md` as a `BU-*` item; it is not tracked here, and the
app repo owns that file.

### APP-6 — Ask for the microphone ✅ DONE
**Delivered** in `currawong` `1ecc9e1`. A fault with a task number because the
app could not get out of it on its own.

On iOS the app could never transmit: PTT failed on the first press and every
press after with "could not construct an `AVAudioConverter` for the requested
PCM formats", and Currawong did not appear under Settings ▸ Privacy ▸
Microphone at all. **One deadlock, two symptoms.** iOS shows the microphone
prompt when an app first *touches* the microphone — installs a tap, starts the
engine. Setting the session category and activating it does not count, so
`configureSession()` never triggered it. Until permission is granted the input
node reports a sample rate of 0, and `AudioPipeline.startCapture` builds its
converter from that rate and throws before ever reaching `installTap`. So the
app never touched the microphone, so it was never asked about, so the rate
stayed 0.

The fix is to ask explicitly, which is the only way out of the cycle.

**Related but distinct:** the 0 Hz converter failure also had an ordering
cause, fixed separately as `BU-1` in the app repo and confirmed on air
2026-08-11. Read the two together — `BU-1` is why the pipeline is built lazily
after activation; APP-6 is why there is a permission to activate under.

### APP-7 — Directories and discovery ✅ DONE
**Delivered** in `currawong` `c285b61` (branch `task/app-ux-discovery`), with
the source research in `DISCOVERY.md` (2026-08-16). Written up
after the fact, as IAX-8b was: the work merged while Phase 4 still listed only
APP-1 … APP-4.

Three modes, three shapes of answer — and the asymmetry is the decision, not
an omission:

- **EchoLink — a station browser.** Nothing in the library resolves a callsign
  to an address, so the directory listing *is* how a node is found. Built on
  EL-6 and EL-11; `StationDirectory`, `StationBrowserView`. Opens a directory-only
  session that contacts no node and transmits nothing.
- **M17 — a reflector chooser.** Host names are typeable, but the published
  list ran to 125 reflectors when read. Source is the M17 Project's published
  `M17Hosts.json`; the underlying data is DVRef's under **CC BY 4.0**, which
  requires attribution — carried in the Reflectors pane and the app README.
  `M17HostFile`, `HostFileReflectorDirectory`, `ReflectorBrowserView`.
- **AllStarLink — a lookup, deliberately not a browser.** `NodeLookup.swift`:
  `AllStarLinkNodeLookup` + `NodeLocator`, a button beside the node number on
  the connect form.

**Why AllStarLink got no browser — settled, do not re-litigate.** Two
independent reasons, both established by the DISCOVERY.md survey:

1. **The public bulk lists do not carry addresses.** `allstarlink.org/nodelist/`
   is a searchable web page with no documented export endpoint; `astdb.txt` is
   metadata only (number, callsign, description, location). The real
   number→IP list is `rpt_extnodes`, which only *registered nodes* pull and
   which is not a public endpoint. A browser built from what is public could
   not offer the one field the connect form needs, and building one from the
   web page would mean scraping a human-facing page — which the DVRef-style
   norm recorded in DISCOVERY.md argues against for the M17 data and which is
   no better manners here.
2. **It is the wrong shape for the operator.** A node number is what gets
   quoted on the air, so the operator already has it; what they do not have is
   the address behind it, and for a node on a dynamic address they cannot. So
   `https://stats.allstarlink.org/api/stats/<node>` — public, unauthenticated,
   one node per request — answers one question about one node rather than
   offering the whole register to scroll.

The rationale also sits in the doc comment on `NodeLookup` so it is found from
the code, not only from here. Three outcomes are distinguished because the fix
differs: no such node, listed but never registered, and directory unreachable.
The host field stays editable — a private node is not listed at all and its
owner hands out the address directly, so the lookup is an offer, not a gate.

**Left on the table, knowingly:** the same response carries `keyed` and a
`linkedNodes` tree, neither of which is read. "Is it keyed right now" is the
one that might earn its place next to the summary line; it is not a task yet.

**What this did *not* settle: Web Transceiver — OQ-10, resolved 2026-08-17 and
delivered the same day as IAX-12.**

### APP-8 — Three modes through one seam ✅ DONE
**Delivered** across `currawong` `f0c74c9` (AllStarLink or M17), `4bc870c`
(M17 support: codec and mode selection), `54bf219` (three modes, and panes
instead of one long screen) and `1346058` (EchoLink, with EL-12 proxy
discovery in the app). Written up 2026-08-16.

**The seam held.** Three protocols reach the app through one
`RadioCore.NetworkClient`, and `CompositionRoot.swift` is still the only file
that names a concrete client — which is the property Phase 4's preamble asks
for, now tested rather than asserted (`CompositionRootTests`,
`RadioModeTests`). What each mode asks the operator for differs enough that
the connect form changes shape with the mode — a node number and a secret, a
reflector module, or a proxy plus a node address and an account password — and
`RadioMode` is where that fans out.

**Codec2 is built by the app, not shipped by the library** (`7a2ac94`,
`5b2e043`, and `CODEC2.md` for why). `Codec2.xcframework` is
7.6 MB of LGPL-2.1 binary, is not in version control, and the app's `make`
targets build it on first use. FR-2.4 and LP-4 are satisfied by dynamic
linking, which is also what keeps OQ-6 open rather than decided.

**A caution on screen for M17 only, and that asymmetry was deliberate.** When
this shipped, M17 had never carried audio anywhere, so the mode picker said so;
EchoLink carried no warning even though it had not yet run from the *app*,
because its whole path had run from the library's CLI. "Nobody has heard how
this sounds" is something an operator can act on; "it worked from the CLI" is a
fact about the state of the project, and a caution on two modes out of three is
a caution nobody reads.

✅ **Resolved since, in two steps.** The caution came down in `currawong`
`7f7d92c` (2026-08-16, the same evening receive was proven): a warning on a
mode whose receive path the operator can hear working is a warning they learn
to dismiss, and the app has exactly one user, who knows the project's state
better than any label. `isValidatedOnAir` went with it rather than lingering
as a property nothing reads. Then M17 transmit was confirmed heard on
2026-08-17 (see §2), so nothing the caution guarded remains unproven.

### APP-9 — Level meters and microphone gain ✅ DONE
**Delivered** in `currawong` `e754084` and `4734f13`. Written up 2026-08-16.
`AudioLevel.swift`, `LevelMeterView.swift`, tests in `AudioLevelTests`.

Peak meters for transmit and receive, scaled in dB with the good/hot/clipping
zones marked, because "am I too quiet?" is otherwise a question only a stranger
on the air can answer. Distinct from **AU-4**, which is the library's automatic
levelling of *received* audio; this is the operator's view of both directions,
plus a control over the transmit side.

Three decisions worth not re-making:

- **The gain scales captured samples rather than the microphone.** iOS does not
  let an app change the built-in microphone's own level — `inputGain` is not
  settable there — so the control applies 0 to +30 dB to the samples, hard
  limited so a loud syllable flat-tops rather than wrapping to a click.
- **Fixed gain, not an AGC.** A compressor would pump room noise up between
  words, which on a repeater is antisocial in a way the operator cannot hear
  from their own end.
- **It sits with the meters, not on the connect form.** The gain belongs to the
  phone rather than to any channel, and the form locks its fields while a link
  is up — which is the only time an operator can tell what to set it to.

### APP-11 — Web Transceiver in the app ✅ DONE
**Depends on:** IAX-12 ✅ (library `v0.5.0`), APP-8 ✅. **Where:** `currawong`.
(There is no APP-10; the number was skipped when this task was opened in the
2026-08-17 status table.)

The library half is done: `IAX2Destination` gained `callingNumber` and
`callingName` (IAX-12), and `hamvoip-cli iax2` reaches a WT-enabled node with
nothing but an AllStarLink portal account — `../../swift-hamvoip/docs/CLI.md` §11 is the
walkthrough. The app cannot: its AllStarLink form asks for a node secret,
which is precisely the thing a WT operator does not have. An operator with
only a portal account still cannot use Currawong to reach a node.

Scope:

- **Raise the dependency floor to `v0.5.1`.** `from: 0.4.0` already resolves
  forward, but the WT fields exist only from `v0.5.0`, so the manifest should
  say what the code requires. The bump also carries the SF-1 reentrancy fix —
  a safety fix worth taking even if the WT form waits, so refreshing
  `Package.resolved` should not sit behind this task if it stalls.
- **A credentials variant of the AllStarLink mode, not a fourth mode.** WT is
  the same protocol to the same nodes; `RadioMode` stays three-wide.
  `NodeSettings` grows the WT fields and the connect form changes shape with
  them, the way APP-8 already has it change per mode.
- **Credentials:** the WT parameter mapping (shared username/password pair,
  extension, token carried in CALLING NAME) is in `../../swift-hamvoip/docs/CLI.md` §11. Decide
  what belongs in `NodeSettings` versus entered per session; the token is not
  a node secret and does not belong in the Keychain slot that holds one.
  APP-12 is where the token is obtained and stored; this task consumes it.
- The app README and `BRINGUP.md` catch up as part of the task.

### APP-12 — Settings: accounts and the PTT accessory ✅ DONE
**Depends on:** IAX-13 (portal login), APP-5 ✅ (the accessory layer exists).
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-17.

One app-level settings screen, three panes:

1. **AllStarLink portal login → WT token.** Callsign and portal password in,
   token out through IAX-13's seam, token into the Keychain — `SecretStore`
   grows a slot, because the token is a stable credential (OQ-10), not a
   nonce. The portal password need not persist: default to discarding it
   after a successful fetch and re-prompting on `login failed`; retaining it
   for silent re-fetch is a decision to make inside the task. Surface the
   three typed failures distinctly.
2. **EchoLink account.** The validated callsign/password pair moves from
   per-connect entry to a stored account beside the app-wide operator
   identity (`OperatorIdentity` is the anchor); Keychain for the password.
   OQ-1b binds the copy: the pane says what the account is for and no more.
3. **The PTT accessory.** `AccessoryView` (PT-2/3/4, BLE-3) mounts here —
   connection state, learn mode, the mapping — so accessory setup stops
   being something found mid-session.

Sequencing against APP-11: APP-11's connect form is best fed by APP-12's
stored token, so prefer IAX-13 → APP-12 → APP-11 — or land APP-11 first
accepting a pasted token, and let APP-12 replace the paste.

### APP-13 — The EchoLink proxy stops being a channel field ✅ DONE
**Depends on:** EL-12 ✅ (library `v0.4.0`), APP-8 ✅, APP-12 ✅.
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-19.

A phone cannot reach an EchoLink node directly, so FR-3.3 makes a proxy
mandatory — and Currawong currently models it as three fields of a *channel*:
`NodeSettings.host`, `.port` and `.proxyPassword`. That is the wrong owner, and
it has already produced a fault.

**The fault.** `ProxyPicker.sourceProxyIfNeeded` fires only when `host` is
empty, and `RadioSession.connect()` persists the validated channel. So the first
EchoLink connect writes whichever stranger's machine happened to answer quickest
*into the channel, permanently*. Every later connect goes back to that one
proxy and never probes again — it is very likely taken by then, and the app is
holding a single-user public resource by name. The connect form's own copy tells
the operator to use public proxies briefly; the storage layer quietly does the
opposite.

**The other half.** A private proxy is the answer for sustained operating (see
the EL-12 note and `../../swift-hamvoip/docs/CLI.md` §12), and it is exactly the thing an operator
sets up *once*, for their whole station. Asking for it per channel, inside a
collapsed disclosure group on the connect screen, puts the one durable proxy
setting in the least durable place in the app and repeats it per channel.

Two facts already in the tree say `host` was never channel state for EchoLink:
`NodeSettings.isSamePlace(as:)` compares `peer` and `node` for `.echoLink` and
ignores the host, and `secretAccount(for:)` returns `echolink:<callsign>` with no
host in it. The field is vestigial, and it is persisted anyway.

So: **one app-wide private proxy, or an ephemeral public one, and neither of them
lives in a channel.**

| | Where it lives | Lifetime |
|---|---|---|
| Private proxy host and port | app-wide settings, `UserDefaults` | until the operator changes it |
| Private proxy password | **Keychain** | as above |
| Public proxy (found by probe) | in memory, on the picker | one sitting — released at teardown |
| Nothing | the channel | — |

Scope:

- **`EchoLinkProxySettings`** — an app-wide value beside `OperatorIdentity` and
  `TransmitTimeout`: host, port, and `isConfigured` meaning "a private proxy is
  set". `SettingsStore` grows `loadEchoLinkProxy()` / `saveEchoLinkProxy(_:)`
  under its own key.
- **The private proxy's password goes in the Keychain**, not `UserDefaults`.
  `NodeSettings.proxyPassword`'s own doc comment already flags the discomfort —
  an operator running a private proxy would be storing its password less
  carefully than their account password. Moving it is the chance to stop that.
  `PUBLIC` is a protocol literal, not a secret, and is not stored at all.
- **`EchoLinkProxyRoute`** — the app-vocabulary triple (host, port, password) a
  session actually tunnels through, resolved at the point of use and passed to
  the link factory and the station directory rather than read off the channel.
  Resolution order: private if configured → the current public lease → probe.
- **Delete `proxyPassword` from `NodeSettings`**, and clear `host`/`port` for
  `.echoLink` in `validated()` and at decode, so the fault cannot recur through
  a path that persists a draft. `host` and `port` stay in the type — the other
  two modes dial them; EchoLink joins `node` and `module` as a field its mode
  ignores, which is the union trade-off the type already documents.
- **Migration, and it has to be right.** Existing channels have a proxy baked
  in. A `proxyPassword` other than `PUBLIC` means the operator configured a
  private proxy — the old form defaulted to `PUBLIC`, so anything else was typed
  — so lift host, port and password out of the stored blobs into the new app-wide
  setting and the Keychain. Read as raw JSON, the way `loadIdentity()` and
  `loadTransmitTimeout()` already harvest hoisted fields; the same reason
  applies, `NodeSettings` no longer has the property.

  `PUBLIC` itself is weaker evidence than it looks, and the task should not
  pretend otherwise: it is the *definition* of a public proxy rather than the
  mark of a probe, so a private host whose owner left the password at the default
  is indistinguishable from a captured one. Drop both. The two mistakes are
  different sizes — a dropped private host costs one field re-typed in Settings,
  where adopting a captured public proxy as the operator's own station
  infrastructure would make this task's fault permanent and invisible.
- **The public proxy becomes a lease.** `ProxyPicker` holds the one it found for
  the sitting rather than writing it into the form, and releases it when the link
  is torn down, so the next session probes again. Deliberately *not* released
  between a directory refresh and the connect that follows: those are one sitting
  and one proxy, and re-probing there would take a second stranger's machine to
  do one operator's work. The library already tears the session itself down
  correctly — `EchoLinkClient.releaseSession()` sends the RTCP farewell, then
  `CLOSE`, then closes the transport — so this task adds no protocol work.
- **UI, and it is the point of the task.** The private proxy moves to the
  settings screen's EchoLink pane, beside the account it sits next to
  conceptually. The connect form's proxy drawer stops being three editable
  fields and becomes status — which proxy this session is using, why it was
  picked, and a "find another" button for when it has gone away. Connecting and
  refreshing the directory already source a proxy on their own (`RootView`,
  `StationBrowserView`); after this there is no field to fill in and no step to
  perform.
- The app README and `BRINGUP.md` catch up as part of the task.

**Not in scope:** more than one private proxy. One is app-wide on the same
reasoning that made the EchoLink account app-wide — the Keychain has filed it
per callsign since EL-10 — and a club operator with access to two proxies is a
case to answer when it appears, not to design for now.

**Done when:** an operator with no proxy configured connects to `*ECHOTEST*`
twice in one run and to a station on the next launch, and never sees a proxy
field or presses a proxy button; a private proxy entered once in Settings is
used by every EchoLink channel and its password is in the Keychain; a channel
saved by the current build comes forward with its private proxy intact and its
public one discarded; and no stored channel blob contains a proxy host.

✅ **Landed 2026-08-19/20** in `currawong` `19cc12b` and `58e5e2b`. The proxy is
`EchoLinkProxySettings`, edited on the settings screen and filed in the Keychain
under `EchoLinkProxySettings.passwordAccount`; `NodeSettings.host` is documented
empty and unused for EchoLink and dropped on decode when `mode.usesProxy`, so a
channel written by an older build cannot carry a proxy forward. Covered by
`EchoLinkProxyTests` and `ProxyPickerTests`. **The status line above said OPEN
until 2026-08-21** — the work had been done for two days, which is the sort of
thing that makes an agent pick the task up a second time.

### APP-14 — One EchoLink password, and no write from a mode that has none ✅ DONE
**Depends on:** APP-8 ✅, APP-12 ✅, BU-9 ✅.
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-21.

`RadioSession.connect()` branches on `usesWebTransceiver` and nothing else. The
Web Transceiver arm deliberately leaves the node-secret slot alone — its comment
explains that writing an empty secret would *delete* the secret of every channel
sharing that account string. The `else` arm then does exactly that for every
other channel, M17 included.

M17 has no secret. `ConnectFormView` says so on screen — "M17 reflectors are
unauthenticated. Your callsign identifies you." — and its code comment says
there is "no account and nothing to put in the Keychain". So the form and the
storage layer disagree, and the storage layer is the one that runs: connecting
to a reflector writes an empty string to `m17:<callsign>@<host>:<port>/<module>`,
a slot nothing ever reads.

**Why a harmless write is worth a task.** It is a write that exists only to
fail. It failed for the whole of 2026-08-21's session against `M17-CBR`, and the
alert it raised — "the secret was not stored" — is the *same* alert whose
queue-rather-than-assign fix is documented on `RadioSession.present(title:message:)`:
it once swallowed the real connection error behind a cosmetic one. A cosmetic
alert on the happy path of a mode that has no secrets is that hazard rebuilt.
The keychain failure that surfaced it was a stale unsigned build, not a defect —
but a correct build hides the write rather than making it right.

**Check EchoLink while in here, and decide rather than assume.**
`secretAccount(for:)` returns `echolink:<callsign>` for `.echoLink`, which is the
same app-wide account APP-12 moved the password to. `connect()` therefore writes
the form's in-memory `secret` back over the settings screen's password, and
`RadioSession` holds two separate copies of that one item — `secret`, loaded via
`secretAccount(for:)`, and `echoLinkPassword`, loaded via
`NodeSettings.echoLinkAccount(for:)`. They round-trip today. Whether they can be
made to disagree — by changing the callsign, or by a failed read defaulting to
`""` and then being written back — is the thing to establish. If they can, that
is a lost password, not a cosmetic alert.

**Shape of the fix.** The question the branch asks is not "is this Web
Transceiver?" but "does this channel have a secret, and whose is it?" — which is
a property of the mode, and belongs next to `secretAccount(for:)` in
`NodeSettings` rather than inline in `connect()`. AllStarLink owns a per-channel
node secret; EchoLink owns an app-wide password that the *settings* screen
writes; M17 and Web Transceiver own nothing.

**Not in scope:** removing the M17 case from `secretAccount(for:)`. It costs
nothing, and a mode that never writes has no migration to perform.

**Done when:** connecting an M17 channel performs no Keychain write and raises
no alert; an AllStarLink channel still stores its node secret and a Web
Transceiver channel still stores only its token; the EchoLink question above is
answered in the PR with a test behind whichever answer it has; and `make test`
and `make test-macos` are green.

✅ **Landed** in `currawong` PR #32, 2026-08-21, with the shape this entry
prescribed: `NodeSettings.SecretOwnership` — `channel`, `appWide`, `none` — beside
the account strings.

**The EchoLink question had an answer, and it was worse than the lost password
this entry braced for.** The two copies could be made to disagree three ways, and
the third was the fault the maintainer was reporting from the other end the same
day: *"I don't think the EchoLink password adding to the directory list is
working."*

`StationBrowserView` asked for `session.secret` — the *channel's* secret — while
the settings screen wrote `echoLinkAccountPassword` and mirrored it into `secret`
only `if settings.mode == .echoLink`. So the ordinary path (type the password in
Settings, where the default selected channel is AllStarLink; open Stations; press
Refresh) sent the directory server an **empty string**, and the pane said "Enter
your EchoLink account password" while Settings said "Stored in the Keychain". A
relaunch appeared to fix it, which is the intermittency that shape produces. With
a draft switched to EchoLink, `secret` held the *node secret*, which went to the
directory server as an account password and came back `login rejected` — which
reads as "my password is wrong".

The mirror is gone. `echoLinkAccountPassword` is the only copy, connecting reads
it and never writes it, and which password the browser sends is now
`RadioSession.directoryRequest` so a view has nothing to pick wrongly.

**Three smaller faults in the same path**, each fixed here: the directory login
sent the callsign **as typed** while the QSO path uppercases through
`identity.validated()`, so a lower-case callsign authenticated for a call and
could be rejected for a browse; the password was stored untrimmed, so a pasted
trailing newline passed every "Stored" indicator and then failed the digest at
the server; and the empty-state copy sent the operator to the connect form for a
field APP-12 had moved to Settings.

**On the M17 half:** the test asserts on the fake store's *write log*, not its
contents. An empty write is a removal, so writing `""` to an empty slot left the
contents unchanged — which is exactly why a suite that only read them never saw
this.

⚠️ **Left open, and not a fault of this branch:** editing the callsign moves the
account string with no migration, so a password saved as `VK1XYZ` is orphaned by
adding `/P`. That is a decision about migration.

⚠️ **Also found, and not the app's:** the maintainer's private EchoLink proxy
closes the stream on OPEN — identically for the right proxy password, a wrong one
and `PUBLIC` — so the Stations pane fails while the app is pointed at it whatever
this task does. The account password itself is good: `hamvoip-cli echolink
--list --auto-proxy` fetched **6305 stations** with it through a public proxy.

### APP-15 — The pane picker cannot be laid out off-screen ✅ DONE
**Depends on:** nothing. **Where:** `currawong`. **Raised by:** the maintainer,
2026-08-21, driving the app.

The split layout's detail column is rigid — status panel, level meters, a PTT
button with a `minHeight`, and since `be3e1e4` a link button — so a window
shorter than the column overflows. A `VStack` does not shrink a rigid child: it
**centres** what it could not fit, so the column spills off *both* edges and
whatever is first in the stack goes off the top. That was the pane picker, which
is the only way off the Reflectors pane. Reported twice, both times as some
version of "no way out of this situation".

**It had already been fixed twice, and regressed twice.** Both fixes were a
number or an alignment holding a rigid column against a window that can be any
height: first moving the picker to the top of the stack, then `alignment: .top`
plus `minHeight: 620`. The second held until `SessionLinkControl` added a button
row to the session pane on 2026-08-17 and nobody re-measured the 620, which had
been chosen on 2026-08-16. **The button renders only when there is a
`lastConnectedName`**, so a fresh launch fit and a launch that had connected to
anything did not — the bug was invisible until the app had been used, which is
why it survived a release and two rounds of driving.

**The fix is to stop measuring.** A toolbar item cannot be laid out off-screen by
the column's overflow, at any window height, with any future session-pane
content. macOS is also where a view switcher belongs. iPad keeps the inline
picker: it shares this layout but its windows do not get short enough to
overflow, and `.principal` competes with the navigation title there.

**Not in scope:** making the detail column scroll. The status panel and the
button that ends a transmission must not be scrollable away while a transmission
is running, which is why the column is not a scroll view — that reasoning is
unchanged and is recorded on `detailColumn`.

**Still open underneath this:** `.reflectors`, `.stations` and `.setup` have no
`ScrollView` of their own, where `.connect` and `.keypad` do, so their content
is still clipped by a short window. Nothing load-bearing is in the clipped
region now, but a pane cut off mid-list reads as a rendering fault.

**Done when:** the switcher is reachable at every window height the OS permits,
including one shorter than the session pane; a test drives the app at a short
window size and finds it; and `make test` and `make test-macos` are green.

### APP-16 — The status panel leads with where the radio is pointed ✅ DONE
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-21, driving the app.

The panel led with the *connection state*, so it said "Connected" in bold without
ever saying connected to what. The answer was in the channel list beside it —
and in the compact layout the channel list is a different tab, so the answer was
nowhere.

Laid out like a rig's front panel: the destination is the headline the way a VFO
frequency is, with the mode in a small box beside it ([M17] where a rig shows
[FM] / [SSB] / [DMR]), reusing the channel list's capsule so a channel reads the
same in both places. A new `NodeSettings.addressDescription` supplies the line
under it and deliberately ignores the operator's name — a channel called "Sunday
net" still has to say where it goes, and an unsaved edit stays visible because
the name holds still while the address changes.

Two lines stopped earning their space. **The transmit watchdog** is a setting,
not a state: APP-12 moved it to the settings screen and the panel only restated
a number that cannot change while it is being read. **The codec** is worth
knowing once, on first contact with an unfamiliar node, and is stale the moment
the link drops — it now rides on the address line while connected. The two
*events* stayed, because "why did the link just go away" is asked at the moment
it appears and is invisible from anywhere else.

The PTT button's 190-point floor was chosen for a thumb; macOS takes 120.

✅ **Landed** in `currawong` `37e039f`.

### APP-17 — The link button dials what the panel is showing ✅ DONE
**Depends on:** APP-16 ✅. **Where:** `currawong`. **Raised by:** the maintainer,
2026-08-21, driving the app.

The session pane's link button was built from `lastConnectedChannel` and
restored it before dialling. So selecting a channel moved the status panel and
left the button naming the previous one: the pane showed `M17-432 H` above a
button reading `Reconnect to M17-CBR A`, and pressing it dialled the second. **A
control that keys a transmitter must not disagree with the thing above it about
where.**

It follows the selection now. The word still distinguishes the two cases — the
same channel says "Reconnect", a different one says "Connect" — and both dial
what the panel shows. The affirmative action is prominent; Disconnect stays
bordered, because a second filled slab under the PTT would compete for the
glance SF-3 wants spent on transmit state.

**This reversed a documented decision, and the premise is what changed.** The
old wording existed because a plain Connect here would have been a second entry
point to fields the operator could not see from this pane. APP-16 put the
destination, its address and its mode directly above the button.

`RadioSession.restoreLastConnectedChannel()` is now unused in `Sources/`. Its
tests are kept with a note; delete both when the next task passes through.

✅ **Landed** in `currawong` `04209e8`, together with a test-hygiene fix:
`ChannelListContextMenuTests` hosted a real `NSWindow` and called
`orderFrontRegardless()` without ever closing it, so every `make test-macos` run
threw a 480×480 panel showing a channel list and the word "detail" over whatever
was in front. It was reported twice as a bug in the *app* before being
recognised as the test — the window belongs to the test host, which is also
called Currawong. It is positioned off the display now, which is what the class
comment already claimed by saying it runs headless. **Closing it is not the
fix**: `close()` starts an `_NSWindowTransformAnimation` that over-releases once
the hosting view goes away, crashing the bundle with a SIGSEGV attributed to
whichever unrelated test held the run loop.

### APP-18 — The session pane shows the controls the state actually has ✅ DONE
**Depends on:** APP-15 ✅, APP-16 ✅, APP-17 ✅.
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-21, driving the app.

The pane shows every control for every state, so most of it is dead at any given
moment. That is also the root cause APP-15 worked around rather than removed:
the detail column is rigid and tall because it is the *union* of two modes rather
than either one.

**The organising idea is a rig's display.** One region is always there and
always current; the controls around it change with what you are doing. So: the
status panel never hides, and everything else earns its place by state.

1. **Disconnected** — no level meters and no PTT button. A large PTT slab
   reading "Connect to a node first" is a control that advertises itself and then
   refuses, and it pushes the mode chooser and the connect form off the bottom,
   which are the only things an operator can act on before a link exists. The
   form becomes the pane, not a thing to scroll to.
2. **Connected** — no connect form. It is already `isEditable: connection ==
   .disconnected`, so it is a read-only wall of fields, and APP-16 moved the one
   useful thing in it (where we are pointed) into the status panel.
3. **The accessory row moves into the status panel as an indicator**, and its
   *configuration* moves to the settings screen. The row's own rationale — "is
   my PTT fob still connected?" is asked from the screen you are looking at while
   transmitting — is better served by the panel than by a row, and it is the
   configuration that never belonged here.

**The accessory indicator needs three states, not two.** Nothing configured
(dim); configured and connected (solid); **configured and lost (loud)**. The
third is SF-2 — BLE link loss must drop transmit — and an operator whose fob has
just dropped needs to know why their PTT stopped working. A greyed icon cannot
carry that, and carrying it is the whole reason the row exists.

**Switch on `.connecting`, not `.connected`**, or the layout changes twice for
one action and the second change lands while the operator is watching for the
link to come up. Animate it, and keep the status panel anchored at the top: if
the display stays put and the region below it changes, it reads as a mode
change; if everything shifts, it reads as a glitch.

**The hazard to test, because it stops being belt-and-braces.** A link that
drops mid-transmission now removes the PTT button from the hierarchy under a
held finger. `PushToTalkButton` already ends with
`.onDisappear { onRelease(.viewDisappeared) }` for exactly this, but under this
task that path becomes load-bearing rather than a backstop, and needs a test that
drops the link while keyed and asserts the release.

**Not in scope:** putting the connect form behind the pane picker while
disconnected. Adding a click to reach the thing most needed is the problem, not
the fix. APP-15's toolbar picker stays either way — a view switcher belongs in
the toolbar regardless of whether the column still overflows.

**Done when:** a disconnected pane shows the status panel, the connect button and
the form with no scrolling at the default window size; a connected pane shows the
status panel, the meters and the PTT with no form; the accessory indicator
distinguishes its three states and its configuration is on the settings screen; a
link dropped while keyed still releases, under test; and `make test` and
`make test-macos` are green.

✅ **Landed** in `currawong` PR #27, 2026-08-21. `make test-macos` is 600 tests,
1 skipped, 0 failures; `make test` is green.

**Both states were driven on screen, and the connected one on air.**
Disconnected: the status panel, a prominent `Connect to M17-CBR A` above the
fold, then the form — no meters, no PTT slab, no scrolling to reach the mode
chooser. Connected to `m17-cbr.charlesmartin.au` module A and keyed by hand:
the status panel (destination, `module A · Codec2 3200`, `Audio in`, and the
accessory light reading `No accessory`), the two meters with their gains, the
PTT slab, Disconnect — **and no form anywhere**, with the pane picker down to
`Reflectors | Settings`. An observer linked to the same module as a second
callsign printed `RX VK1CPM (stream 0x0745)` and `RX VK1CPM ended — end of
over`, so the over that pane keyed was heard and its *end* was seen.

An incidental benefit: BU-11's empty AutoFill panel is a popup anchored to the
first text field of the form, so while connected there is no form and no panel.
Counted at zero level-101 windows on the connected screen.

Three things are worth knowing beyond the entry above.

**The decision is a value, not a comparison written twice.** The two halves are
made in different files — `SessionPane` owns the meters and the PTT button,
`RootView` owns the connect form and the pane picker — and they are complements,
so they are both read off one `SessionPaneLayout`. A test asserts that exactly
one of the two shows in every connection state, which is the way they would
otherwise drift: a state showing both, or neither.

**The picker drops `Connect` while a link is up**, rather than keeping a pane
that would render greyed fields. The existing resolve-on-read selection made this
nearly free — the stored choice comes back when its pane does, so connecting
moves the picker on and disconnecting brings it back to where the operator left
it. This is *not* the excluded item: the form is still not behind a click while
disconnected, which is what "not in scope" ruled out.

**The accessory sheet is gone with the row.** `AccessoryView` — a
`NavigationStack`, a title and a Done button around `AccessoryPane` — existed
only for the row to present on iPhone, and APP-12 had already put the
configuration on the settings screen. It had no caller left, and it took with it
the `isTransmitting` flag both it and `SettingsView` carried, which was always
`false` at every remaining call site.

**On the hazard:** the model gets there first. A peer hang-up runs
`handleLinkLoss(reason:)`, which ends transmission with `.disconnecting` *before*
the connection state reaches `.disconnected` and the button leaves the screen —
so `onDisappear` fires into an already-idle session, and `endTransmit(reason:)`
records a stop reason only when something was actually transmitting. That
ordering is what keeps `.viewDisappeared` — an *unexpected* reason, which the
status panel shows to the operator — from turning every dropped link into an
accusation that the app lost its own screen. `SessionPaneStateTests` pins the
ordering, and pins the `onDisappear` line separately by hosting a bare
`PushToTalkButton` and removing it from the hierarchy: deleting that line fails
that test and nothing else, which was checked by deleting it.

### APP-19 — `Add channel` stops writing a blank channel ✅ DONE
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-21; reproduced
while driving.

A clean quit and relaunch — no interaction at all — came up with a third row in
the channel list: **"Unnamed channel", AllStarLink, no host**, selected, with the
connect form showing placeholder values. The two real channels were untouched.

This is almost certainly the source of the orphan rows the 2026-08-20 handoff
recorded as "four `allStarLink` channels with no name and no host, which cannot
be connected to… probably leftovers of an older run". They are not leftovers.
Something is minting them, and it appears to be launch itself.

**Not diagnosed.** The obvious suspects are the BU-9 draft path — `stashDraft()`
on `scenePhase != .active`, and the launch-time pruning of a draft belonging to
no channel that BU-9 resolved to keep — and whatever seeds `settings` when a
stored selection does not resolve. The reproduction is cheap, so start there
rather than from the code.

**Diagnosed 2026-08-21, and the title is wrong: launch does not invent
anything.** Measured, with the app not running, then launched and left alone:
three channels before, three after, and `selectedChannel` unchanged. Nothing on
the launch path can append — `RadioSession.init` reads the list and the drafts
and writes neither, and all three paths that reach `ChannelSet.add` are behind a
button:

* `connect()` adds the **validated** channel, which cannot be blank —
  `validated()` throws on a missing host or node.
* `saveDraft()` adds only when Save is pressed, and Save is disabled on a
  pristine form (`isDraftDirty` is false).
* `addChannel(_ channel: NodeSettings = NodeSettings())` — **the `+` button** —
  adds exactly the observed row: fresh UUID, `mode: allStarLink`, every string
  empty, `port: 4569`, and `ChannelSet.add` selects what it adds. It is the only
  fresh `NodeSettings` in the tree that ever reaches the list.

**Where the taps came from: the UI tests.** `ChannelLifecycleUITests`,
`ChannelDeleteAfterConnectUITests` and `M17EndOfOverUITests` all click
`Add channel` against the operator's **real** defaults, then name and delete what
they added. A run that dies between the click and the naming leaves precisely
this row behind — blank, `allStarLink`, selected — and the 2026-08-20 handoff
records four of them after five runs of which four died. That is the same
mechanism the delete test was already fixed for (it clears its own names first);
the blank row has no name to clear.

So what is left of APP-19 is not a launch bug. It is that **`+` commits an empty
channel to storage immediately, selects it, and nothing says it is unsaved** —
`isDraftAnUnsavedChannel` is false for it, because it *is* in the list — so a
single tap is permanent and only Delete removes it.

**That made the fix a design question rather than a bug fix**, and it was
answered the way BU-9's rule points: if a channel is a working copy and Save is
the only thing that writes one, then `+` hands over an unsaved draft and the row
appears when it is saved or connected — which is what `isDraftAnUnsavedChannel`
exists to describe. The alternative considered and not taken was to keep
committing on `+` and prune blank channels at launch, which is a rule about what
a stored channel may look like rather than about when one is stored.

**Two facts from the defaults, worth keeping either way:** the row is in
`au.charlesmartin.currawong.channels`, so whatever adds it also saves it; and
`channelDrafts` was `[]` at the time, so the BU-9 draft path is not holding it.

⚠️ **A correction to this entry as first written.** It said launch chooses the
invented row over the stored selection, on the evidence that setting
`selectedChannel` by hand and relaunching came up on the unnamed row anyway.
That was `cfprefsd` caching a `defaults write` made moments after the app had
been killed, not the app overriding anything: the hand-set selection was in force
on the following launches, and `ChannelSet.init` keeps a stored id whenever the
list still contains it, falling back to `channels.first` only when it does not.

**Done when:** launching with any stored channel list adds nothing to it; the
existing unnamed rows can be removed; and a test covers the launch path that
produced this.

✅ **Landed** in `currawong` PR #29, 2026-08-21 — and the first of those three
was already true, which is the finding. Launch adds nothing; `+` did.

`addChannel()` is `newChannel()` now and writes nothing: it points the form at a
new channel, and **Save or Connect is what puts it in the list**, which is BU-9's
rule with nothing carved out of it. Two consequences worth having written down:

* **A new channel typed into and neither saved nor connected does not survive a
  quit**, exactly as a reflector picked out of the directory does not. That is
  the trade BU-9 accepted for browsing, and the form says so on screen — "Not
  saved. Connecting will add this to your channels" — from the moment there is
  anything to lose.
* **The channel list's highlight follows the form**, not the stored selection.
  When the two differ no row is highlighted, which is the honest answer and also
  the feedback `+` needs: the row it used to create was the only sign it had done
  anything.

**The existing unnamed row is still the operator's to delete** — Delete works on
it, and nothing prunes blank channels at launch. A prune would be a rule about
what a stored channel may look like, which is a different decision from when one
gets stored, and nothing now creates them.

**Three UI tests moved with it, and two of them were lying.**
`ChannelLifecycleUITests` asserted on the *existence* of a row of its own name,
which a previous dead run had already left behind, and so reported "Delete did
nothing"; it also asserted `app.menus.count > 0` as "a context menu opened",
which is thirteen menu-bar menus, and then read `app.menus.firstMatch` — the
Apple menu. **It was green only because this machine's automation grant had
lapsed**, and failed the moment it could really right-click. Both it and
`M17EndOfOverUITests` now count rows, clear their own leftovers first, and scope
the menu query by its contents.

`M17EndOfOverUITests` deliberately does **not** press Save: the button is at the
bottom of the form, clicking it scrolls, and the fields typed into afterwards
then report frames outside the visible scroll area — so the clicks land on the
pane above and the field never takes focus. That reads like a broken text field
and is a scrolled one. Its connect is what adds the channel.

**Verified against the real app, not only in unit tests.**
`ChannelLifecycleUITests` passes on macOS — `+` writes nothing, Save adds the
row, Delete removes it — and it swept the leftover row a dead run had left in the
operator's list on the way through. On a branch carrying APP-18 as well,
`M17EndOfOverUITests` passed on air: connected to `m17-cbr.charlesmartin.au`
module A, keyed, unkeyed, disconnected, deleted its channel.

**The observer heard nothing during that automated run, and the hand-keyed over
that followed settles why.** Same app, same channel, same observer: keying the
PTT slab by hand produced `RX VK1CPM (stream 0x0745)` and `RX VK1CPM ended — end
of over`. So the transmit path is intact and the automated run's silence is the
microphone-grant case that test's own header documents — **an app launched by a
test runner cannot answer a TCC prompt, so every over it keys carries no frames
at all.** Worth knowing before anyone reads a silent `M17EndOfOverUITests` run as
a transmit fault: its app-side assertions are the half it can see, and the
observer is the other half only when a human has granted the microphone.

### APP-20 — Every pane gets the same column, and the sidebar its insets ✅ DONE
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-21, from
screenshots. ✅ **Landed** in PR #30.

Two spacing faults with one cause each, both of them a pane that had been left
out of a rule the other panes followed.

**The channel list's header sat flush against both edges of the macOS sidebar.**
The horizontal inset was applied at the *call site*, and only the tab layout
applied it — the split layout put `ChannelListView` in the sidebar bare. The rows
looked right either way, because a `List` insets its own rows; that is precisely
why the header, which is outside the `List`, did not. The view owns its insets
now. Padding the whole view instead would inset the rows *twice* and leave the
header hanging left of the names it labels.

**The Stations and Reflectors panes ran into both edges of the detail column,
with the Refresh button clipped off the right.** They were the only two panes
inserted into `detailContent` raw; the connect form, the keypad and the settings
screen all sit in a padded, width-capped `paneColumn()`. Unbounded, the reflector
rows' module chips — a dozen on a busy reflector, wrapped over three lines —
pushed the list wider than the column and took the header row with them. Both
panes use `paneColumn()` now, so the app has **one column width** rather than a
number chosen per pane, and the iOS directory tabs get it for the same reason.

Driven on both platforms rather than reasoned about. It also turned up **BU-12**,
which is in `BRINGUP.md` rather than here: on a short display the whole app was
taller than its window and macOS centred the overflow, which put the status panel
above the top edge with an empty channel list. **Fixed the same day** — a
`fixedSize` on wrapping text in the sidebar, which a `NavigationSplitView`
measures at an unspecified width — and the sidebar's *top* alignment, held back
for it, shipped with the fix.

### APP-21 — The view layer is tested on both platforms, and the UI tests stop editing the operator's app ✅ DONE
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-21, asking whether
the macOS-only UI testing was a compromise. It was, in two separable ways.
✅ **Landed** in PR #31.

**The hosted-view tests only ran on macOS**, and the case they cover is *iOS's*:
`PushToTalkButton`'s `onDisappear` release exists because leaving the Session tab
while keyed must unkey, and tabs are a compact-layout case. The one platform
covered was the one without the problem. `ViewHost` owns the difference —
`NSHostingView` in an off-screen `NSWindow`, or `UIHostingController` in a
`UIWindow` attached to the test host's scene — including the *never close the
window* rule that cost an afternoon under APP-18. The four pane tests now run in
`make test` as well as `make test-macos`, and deleting the `onDisappear` fails
the isolation test on **both**; checked by deleting it on both, so neither run is
vacuous. `ChannelListContextMenuTests` still reads an `NSMenu` and so stays
macOS-only in substance, but it no longer carries its own window.

**The UI tests wrote to the operator's real defaults**, which cost twice: a run
that died before its cleanup left a row behind, and the next run found two rows of
one name, deleted one, and reported that Delete did nothing — read as a live bug
for a morning under BU-9 and again under APP-19. The blank rows APP-19 was opened
for were made this way too. `DefaultsSuite` reads two launch arguments out of
`UserDefaults`' own argument domain, so only a launcher can set them, and it is
`#if DEBUG` so the hook cannot exist in a shipped binary. The **app** performs the
reset, not the runner, because on iOS a suite that is not an app group lives in the
app's container where the runner cannot reach it — one rule, both platforms. The
three mutating tests now assert they *started* from an empty list instead of
sweeping up after themselves, which makes a broken isolation visible rather than
silent.

One consequence has teeth: the on-air test's identity comes up empty now, and **a
test that transmits must not invent a callsign.** It reads the operator's own out
of the app's real defaults and fails with an explanation if there is none, rather
than putting a made-up callsign on a reflector. The delete test still types one
and says why that is safe there: it dials TEST-NET-1 and nothing leaves the
machine.

**Still a compromise, and named as one:** no XCUITest drives the *iOS* app.
`CurrawongOnAirUITests` is `supportedDestinations: [macOS]` and its 28 call sites
use `click()`, `rightClick()` and `typeKey(_:modifierFlags:)`, none of which exist
on iOS. Making it multiplatform means those behind `tap()`/`click()` helpers plus
the interactions that genuinely differ — swipe-to-delete versus a context menu,
and a SwiftUI `alert` being a *sheet* on macOS — and splitting the target so the
non-transmitting half can run in CI. Not done; the hosted-view layer was the
cheaper and more trustworthy half, and it is the one that catches APP-18-class
faults.

### APP-22 — `Add channel` puts a row in the list, provisionally ✅ DONE
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-21. ✅ **Landed**
in PR #33.

APP-19 stopped `+` writing a blank channel to storage, which was right about
storage and left the button with no visible effect: the row it used to create was
the only feedback it had.

So the draft appears in the list, at the bottom, marked **Not saved**, and **Save
or Connect is still the only thing that stores it.** Quit without either and it is
gone, exactly as a reflector picked out of the directory is, so nothing can leave
a permanent hostless row behind.

**The maintainer chose this over two alternatives**, and the rejected ones are
worth keeping: saving the row immediately is the fault APP-19 was opened for (one
stray tap, a hostless row only Delete removes), and saving it but pruning blank
rows at launch means the app silently deleting a stored channel, including one
half-filled on purpose.

A browsed reflector gets the same row, because it is the same state — the form
pointed somewhere that is not in the list — which makes it a rule rather than a
special case for one button. Three details: the row says **"New channel"** rather
than "Unnamed channel", which is the wording the connect form's own placeholder
already uses and reads as an invitation rather than a fault; the row is outside
the `ForEach`, because `onDelete` and `onMove` work in offsets into the *stored*
array; and its menu offers **Discard**, not Delete, because there is nothing
stored to delete — `discardDraftChannel()` refuses when the draft *is* a stored
channel, so it cannot become a second, quieter way of losing one.

### APP-23 — the channel flow: nothing moves, a channel is one tap, and one Connect ✅ DONE
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-22, after the
BU-16/BU-17 session. Four complaints, filed as one task because each is part of
the same journey — *choose a channel, connect, talk* — and fixing any one alone
leaves that journey stranger than it is now.

**1. The transmit banner must not move the UI.** `TransmitBanner` is inserted
above the pane container when transmit begins, so keying pushes everything down
— including the PTT button under the operator's finger. Colour and wording
carrying the state is right; motion is not. The slot becomes **permanent**: one
strip that is always in the hierarchy and changes only its colour and its text.
SF-4's structural guarantee is untouched, because what makes the banner
unhideable is that it is a sibling of the `TabView`/`NavigationSplitView`, not
that it comes and goes.

**2. A channel can be switched while connected.** The list greys out with
"Disconnect to switch, add or delete channels." The backstop it explains is real
— `select(_:)` refuses unless disconnected, because a destination changing under
a live call would leave the screen describing one node while the audio came from
another. But *tap another channel to go there* is what a radio does, and making
the operator disconnect, choose, then connect is three steps for one intent. So
the gesture is answered rather than refused: choosing a channel while connected
**hangs up, selects, and dials the new one**, as one sequence owned by
`RootView` beside the connect sequence it already owns. The invariant holds at
every frame, because the selection still only changes while disconnected. Add,
edit and delete stay locked while connected — those are not "go there now".

**3. One Connect button, not two.** There is one under the PTT slab
(`SessionLinkButton`) and one at the foot of the connect form. The form's goes.
`SessionLinkControl`'s own note already argues the case from the other side: the
session pane's button exists because that is the screen an operator watches
while talking. And since APP-16 the status panel names the destination, so the
session button is not a blind second entry point. The form keeps **Save**, which
is the thing only it can do.

**4. iOS: the channel list gets the screen, and choosing takes you to the
radio.** The Channels tab currently splits into a list capped at 320 points and
a connect form under it, so the list is squished when it is the most important
thing and the form is cramped when it is needed. With the form's Connect gone
(3) the split has less to justify it. The list takes the tab, and the channel
details move behind navigation — a push from the row, which is the iPhone idiom
for list-then-detail. **Selecting a channel goes to the Session tab**, which is
the pattern the Stations and Reflectors tabs already use (`onChosen:`, today
pointing at `.channels`; it points at `.session`). A left popover was considered
and not taken: that is what the split layout already is on iPad and Mac, and on
iPhone it is a non-idiom that would need building.

**Not in scope:** the split layout's arrangement (Mac and iPad are the case that
works), and anything about what a channel *is* — APP-19 and APP-22 settled that
and this task changes no storage rule.

**What landed.** `RadioSession.switchChannel(to:)` is the sequence for (2): it
hangs up, selects, and answers whether the caller should dial, with `RootView`
placing the call so the EchoLink proxy is sourced the one way it already is.
`select(_:)`'s refusal is untouched, and the tests that pin it still pass — the
sequence reaches the new channel legally rather than by relaxing the invariant.
The link state is preserved rather than forced: tapping a row while connected
moves the call, tapping one while disconnected only selects, because a single tap
in a list must not key a transmitter.

Two things worth knowing for the next reader:

* **The strip is drawn without an `NSView` of its own**, so on macOS the pane
  container is still the only child AppKit is handed — inset 55 points from the
  top. `WindowSizingTests` asserted on that child's *height*, which silently
  became "55 short of the window" once the strip was permanent. The assertions
  are about where the region **ends** now, which answers the same question in
  both layouts. BU-12's canary is untouched.
* **The ⓘ is disabled while a link is up, and the row is not.** The details form
  edits the draft, the draft follows the selection, and selecting is refused
  mid-call — so an enabled ⓘ would open the form on somewhere other than the row
  that was tapped. The row has no such problem, because going somewhere includes
  hanging up.

Verified with 680 tests on macOS and an iOS device build. **The iPhone layout has
not been driven by hand** — no XCUITest reaches iOS (see APP-21) and this
machine's automation grant has lapsed, so the push, the ⓘ and the jump to the
Session tab are covered by the hosted-view and view-model tests rather than by a
run on the phone.
### APP-24 — the audio policy follows the route, so a cold over stops existing
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-23, while
`BU-15` was being fixed — and it is their idea, recorded in their words: *"in
the olden days when I coded up iOS apps using my own brain and hands, I was
totally comfortable having a music app in `.playAndRecord` from launch. So
opening after connect doesn't seem wrong."*

`BU-15` is fixed: one press, one key-down, on iOS and macOS, with and without an
accessory. What it costs is **~1.0–1.2 s from press to carrier on a cold over**,
because everything that moves the route now happens before anything is keyed and
the route has to be waited out. A warm over — one inside the 3 s hand-back
linger — costs **23 ms**, measured.

**So the fix is not a shorter wait. It is to stop making overs cold.** The
per-over hand-back exists for `BU-14`, which is a *Bluetooth* problem: the Q2L
mutes its own BLE PTT notifications while its Classic side sits in an idle HFP
call, so the session must drop back to `.listening` between overs to keep the
button alive. **With no Bluetooth device in the route there is nothing to hand
back** — no HFP to pin, no LED, no muted button — so the session could hold
`.radio` and keep its engine, and a cold over would stop existing.

That is the configuration the maintainer says they will mostly be running
(2026-08-23): *"mostly I'll just run currawong on iOS and macOS with normal
audio hardware."* It is also the configuration every operator without a
Bluetooth PTT accessory is in.

**The shape.** `AudioSessionPolicy` selection becomes conditional on whether a
Bluetooth device is in the current route, rather than unconditional:

| route at connect | policy between overs | first PTT |
|---|---|---|
| speaker, wired, receiver | `.radio`, held from connect | instant, no wait, no dance |
| Bluetooth (Q2L, AirPods, car) | `.listening`, as now — `BU-14` requires it | ~1.0 s, as now |

Bluetooth arriving or leaving mid-QSO is itself a route change while idle, which
the app already observes (`RadioSession.onIdleAudioRouteChange`), so the policy
can follow the route rather than being decided once at connect.

**Two things to verify on a device before believing the table**, both raised when
this was costed and neither measured yet:

* That a held `.radio` on a speaker route does **not** light the recording
  indicator. It should not — that follows the microphone tap, not the category —
  but it is the one outcome that would make this unshippable, because an app
  showing a live-microphone dot while merely connected is exactly the impression
  this app must never give.
* That `.voiceChat` mode is not quietly degrading receive audio on the speaker
  for the whole QSO. If it is, the held policy wants `.playAndRecord` without
  `.voiceChat` while idle, and only the full `.radio` policy while capturing.

**Related, and possibly the same change:** `BU-18`. macOS holds HFP for the whole
session after the first over — measured 69 s, across overs and idle — because
`discardsEngineOnHandback` is false there, so the engine keeps its input unit and
CoreAudio keeps the route. Both items are about what the app holds between overs;
whoever takes one should read the other.

**Closed when** a cold over on a non-Bluetooth route keys the carrier in the same
tens of milliseconds a warm one does, `BU15FirstOverUITests` still passes with the
Q2L attached, and the two verifications above are recorded rather than assumed.

### APP-25 — a TestFlight build somebody outside can install
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-23: *"I'll also
want to get to the point where I can setup the testflight entry in appstore
connect in case someone wants to see a beta."*

Not started, and deliberately scoped as **the plumbing only** — the first
question is whether an archive can be built, uploaded and installed at all, not
whether the app is finished.

**What exists already:** the bundle identifier (`au.charlesmartin.currawong`),
the team (`DEVELOPMENT_TEAM: EDH387FRHA`, `CODE_SIGN_STYLE: Automatic`), a
version and build number (`CFBundleShortVersionString: 0.1.0`,
`CFBundleVersion: 1`), the usage descriptions the two prompts need
(`NSMicrophoneUsageDescription`, `NSBluetoothAlwaysUsageDescription`), and an
entitlements file. All in `project.yml`, which is where they must be changed —
the `.xcodeproj` and `Info.plist` are generated.

**What is missing, in the order it will bite:**

1. ✅ **An App Store Connect record** for the identifier. Created 2026-08-23,
   against an explicit App ID registered in the portal — the New App form's
   bundle-ID picker lists only explicit identifiers, so that registration has
   to come first. `au.charlesmartin.currawong.liveactivity` needs an identifier
   too, but nothing waits on it: it never appears in that picker and automatic
   signing registers it on the first archive. It gets no record of its own.
2. ✅ **`CFBundleVersion` has to move per upload.** App Store Connect refuses a
   build number it has already accepted, and `"1"` is hard-coded in
   `project.yml` for both the app and the extension — which must move
   *together*, or the upload is rejected rather than the build. Handled by
   `ci_scripts/ci_post_clone.sh` from Xcode Cloud's `CI_BUILD_NUMBER`, which is
   better than the `make` target imagined here because nothing has to be
   remembered. `CFBundleShortVersionString` is untouched: that one is a
   release decision and belongs in a commit.
3. **The `CurrawongOnAir` scheme must not ship.** It transmits on air, under a
   callsign from the environment, against live reflectors. Confirm it is not in
   the archived scheme's dependencies and cannot be.
4. ✅ **Export compliance.** `ITSAppUsesNonExemptEncryption: false`, declared in
   `project.yml` rather than answered on a web form each upload. `false` is the
   true answer and was checked rather than assumed: no cipher is implemented
   anywhere in either tree. M17's TYPE encryption bits are *read* only, so an
   encrypted stream is refused instead of played as noise (`FR-2.5`,
   `M17ReflectorProtocol.Playability`); the IAX2 and EchoLink MD5
   challenge-response is authentication; the portal login rides the OS's TLS.
   All exempt. Revisit the day any of that stops being true.
5. **App privacy answers**: no data collected, no tracking, no analytics. Worth
   writing down here once so the form is filled the same way twice.
6. **`UIBackgroundModes: audio`** will draw a review question — the honest answer
   is `PD-2`'s: it is what keeps a *received* signal alive with the screen
   locked. `PD-4` (no CallKit) and `PD-3` (no multicast entitlement) are the two
   things reviewers might otherwise expect of a VoIP-shaped app and which this
   app deliberately does not do.
7. **Beta test information**: what the tester is being asked to look at. Given
   `BRINGUP.md`, the honest brief is short — connect to a node, hold PTT, check
   the strip agrees with what they hear.

**The route: Xcode Cloud, triggered by a release tag.** Chosen 2026-08-23 over
the `xcrun altool` path this task first assumed, so that signing is Apple's
problem rather than a set of certificates in CI secrets.

The obstacle is that Xcode Cloud clones the repository and expects to open a
project, and there is none — `*.xcodeproj` and `Codec2.xcframework` are both
generated and gitignored. `ci_scripts/ci_post_clone.sh` covers it: Apple runs
that hook after the clone and before dependency resolution, which is early
enough to install xcodegen, build the framework and generate the project. Two
consequences of that ordering are written into the script and are easy to
forget:

- **No SPM checkout exists yet**, so `build-codec2-xcframework.sh` takes its
  clone fallback and builds the tag pinned *in that script*, not the one in
  `project.yml`'s `from:`. Keep the two in step.
- **No `Package.resolved` exists yet either, and Xcode Cloud will not compute
  one.** It resolves with automatic resolution disabled, so a clone with no
  resolved file fails at *Resolve package dependencies* with "a resolved file
  is required when automatic dependency resolution is disabled" — the first
  cloud build failed exactly there, 2026-08-23. The file belongs inside the
  generated `.xcodeproj`, which is never committed, so the pin is committed as
  `ci_scripts/Package.resolved` and the post-clone script copies it into
  `Currawong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` after
  generating. That pin, not `project.yml`'s `from:`, is what the cloud build
  builds; `make resolved` refreshes it and it belongs in the same commit as any
  package change, because a stale pin fails the same way a missing one does.
- **The framework is rebuilt on every cloud build**, roughly four minutes.
  Xcode Cloud caches SPM checkouts and derived data; an xcframework at the
  repository root is neither. If that cost starts to matter the answer is a
  prebuilt binary somewhere fetchable — never a static link, which `LP-4`
  forbids.

Configuring the workflow needs a **locally** generated project, because the
setup wizard reads the scheme list off disk. Run `make generate` first. What
the wizard stores is only the project and scheme names, both of which the
post-clone script reproduces. The scheme is `Currawong`; both it and
`CurrawongOnAir` are generated into `xcshareddata`, so item 3 above is settled
by *selecting* the right one. The start condition is a tag change matching
`v*` — a GitHub release creates the tag, which fires the build.

**Two things this route does not cover:**

- **macOS.** `PD-5` wants Developer ID plus notarisation for the Mac build, and
  Xcode Cloud distributes to TestFlight and the App Store only. The Mac side
  stays separate, most likely as an extension of `.github/workflows/ci.yml`.
  Xcode Cloud is the iOS half of `PD-5`, not both halves.
- **The terminal-first rule.** Xcode Cloud workflows are configured in Xcode or
  App Store Connect and have no terminal equivalent, which is a real exception
  to the rule in `CLAUDE.md` and is taken deliberately. Everything that *can*
  live in the repository does: the post-clone script is an ordinary shell
  script and runs by hand.

**Not in scope:** anything about whether the app is *ready*. `BU-7`, `BU-10` and
`BU-18` are all open, and a beta build with known open faults is fine so long as
the tester is told which.

### APP-26 — a Mac download, and the licences that let it exist ✅ DONE
**Where:** `currawong`. **Raised by:** the maintainer, 2026-08-24: a
non-App-Store macOS build is fine from an LGPL perspective — so build it in CI,
attach it to the release, and say in the app what the licences require.

The other half of `PD-5`. `APP-25` routes iOS through Xcode Cloud, which
distributes only to TestFlight and the App Store; the Mac build needs Developer
ID plus notarisation and so lives in `.github/workflows/release-macos.yml`,
triggered by the same published release.

**What shipped:**

- `scripts/package-macos-release.sh` — builds, signs, notarises and packages.
  The workflow is the trigger, the secrets and the upload; the work is in a
  script because everything must run from a terminal (`CLAUDE.md`) and a release
  you cannot reproduce on your own machine is one you cannot debug. `make
  release-macos`.
- The release carries the app, `LICENSES/`, a `README-FIRST.txt`, `SHA256SUMS.txt`
  and **`codec2-<commit>-source.tar.gz`** — the corresponding source, which
  LGPL-2.1 §6 wants offered from the same place as the binary.
- `Settings → About` (`AboutPane`, `Acknowledgements`) — every component, its
  licence, how it is linked, and its notice. §6 asks for a *prominent* notice,
  and a line in a README is not one given to the person running the app.
- `Sources/Currawong/Currawong-macOS.entitlements`, applied for `sdk=macosx*`
  only, carrying `com.apple.security.cs.disable-library-validation`.
- `scripts/check-licence-notices.sh`, run by CI on every push and by the
  packaging script before it packages anything. Two of these obligations are
  conditions on the right to distribute, so the moment to fail is before an
  artefact exists to attach.
- `AcknowledgementsTests` — 11 tests, each asserting something a licence asks
  for by name rather than testing prose.

**Two things this task learned, both written up in `docs/LICENSING.md`:**

1. **`keychain-access-groups` is a restricted entitlement and needs an embedded
   provisioning profile.** Without one, `codesign --verify --deep --strict` says
   *valid on disk* and *satisfies its Designated Requirement*, and the kernel
   then SIGKILLs the app on launch with no message. An earlier version of the
   script signed the bundle directly with `codesign` to avoid profiles
   altogether and produced exactly that: an app that passed every check and died
   on launch. It now archives and exports (`method: developer-id`), which embeds
   the profile, and asserts the profile is present so it cannot be silent again.
2. **The LGPL substitution works, and the re-signing step is not optional.**
   Replace the framework and re-sign the whole application: verifies and
   launches, using the replacement. Replace the framework and keep our
   signature: killed, because a signature seals nested code. Both measured
   2026-08-24, which is why `README-FIRST.txt` gives the procedure rather than
   an assurance.

`OQ-6` is **narrowed, not closed.** For the direct download §6 is satisfied
rather than argued about. Nothing here helps an App Store build, whose bundle
cannot be modified at all, so the iOS question stands exactly where it did.

**Not in scope:** whether the app is *ready*. `BU-7`, `BU-10` and `BU-18` are
open, and the read-me the download carries says what it is.

**Unverified at hand-off: notarisation, and only that.** Both signing routes
have now been run end to end and the resulting apps launch — Developer ID chain
to the Apple Root CA, secure timestamp, hardened runtime, profile sealed in the
bundle, universal. Which is the check that counts, because the failure above
produced something `codesign` called *valid on disk* and the kernel killed.

**Two ways to sign, because CI and a laptop want different things.** The default
archives and exports, which fetches the profile and wants a signed-in Xcode or an
App Store Connect API key. `MACOS_PROVISIONING_PROFILE` instead takes a profile
as a file and signs directly. The second is what CI wants when the credentials to
hand are a certificate and an app-specific password: neither the private key nor
a profile can be *fetched* with those, so both are files regardless, and once the
profile is a file there is nothing left for an API key to do. A Developer ID
profile is long-lived — the one this was built against expires 2044 — so it is
not a yearly chore. `LICENSING.md` has the table of which credential answers
which question.

Comparing the two routes is also what turned up the missing strip settings:
`archive` strips the installed product and a plain `build` does not, worth about
2 MB of symbols on a 4 MB download.

**On credentials**, since the two legs want different ones: an app-specific
password covers notarisation and nothing else. `xcodebuild
-allowProvisioningUpdates` takes only a signed-in Xcode account or an App Store
Connect API key — its own help says so — so the profile fetch cannot use one.
The upshot is that *locally* an app-specific password is all that is missing:
fix the Xcode account and the whole release runs with no API key involved. In CI
the key is still wanted, for the profile rather than the notary. The script takes
the password three ways, preferring `NOTARY_KEYCHAIN_PROFILE` so it lives in the
Keychain rather than in shell history.

## Phase 5 — BLE PTT (after APP-2)

✅ **DELIVERED — but in the app, under APP-5, not as BLE-1 … BLE-3.** The three
rows below were written before the app existed and describe work that has since
shipped as one input layer, because `RadioSession` conforms to `PTTSink` and
all three inputs share one release path. They are kept for their requirement
citations and their "no whitelist" instruction, both of which the
implementation honours. **Do not open a `task/ble-1` branch expecting to find
this work undone** — read APP-5, then `BRINGUP.md` for the part
that genuinely remains, which is that none of it has met a real accessory.

- **BLE-1** — `BLEPTTManager` (CoreBluetooth, `bluetooth-central`
  background mode): scan, connect, auto-reconnect; connection loss while
  transmitting forces `stopTransmit` (SF-2). Wrap CoreBluetooth behind a
  protocol so the state logic is unit-testable with a fake central.
- **BLE-2** — **Learn mode (PT-3):** subscribe to all notifying
  characteristics of a chosen accessory; record which
  (service, characteristic, payload) pairs fire on press vs release; persist
  as a mapping. No device whitelist anywhere.
- **BLE-3** — Runtime: apply learned mapping → press/release edges drive
  PTT; UI indicator for accessory link state.

