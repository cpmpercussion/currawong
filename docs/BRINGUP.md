# iOS bring-up — getting the app to actually work

Passing tests is not the same as keying a radio. This file tracks the gap: the
work of making Currawong connect to a live node from an iPhone, key it, be
heard, and hear the channel back.

**Where that stands, 2026-08-20. The bring-up is over.** All three modes have
carried traffic from this app, both ways: AllStarLink and EchoLink QSOs, M17
receive against a live net and M17 transmit heard at the far end, and now
AllStarLink through the public parrot (`55553`) with extended overs coming back
clean and DTMF commands reaching the node. `BU-2` and `BU-6` are closed.

What is left is not bring-up. Two safety behaviours have never been *observed*
firing — the transmit watchdog unkeying a held button, and a phone call
dropping transmit — and they are app-level rather than anything to do with a
protocol: the same two mechanisms serve all three modes. They are `BU-7`, they
are wanted before any public beta, and they are deliberately not holding this
phase open. `BU-3` is done in the library and waits on a release. `BU-8` closed the same
day — four overs from the app, each seen to *end* by an independent observer —
and `BU-9` records what trying to automate that turned up about the channel
model.

**Added 2026-08-21: the first accessory.** A TIDRADIO Q2L speaker-mic with a PTT
button is in hand, and neither half of it works for long — `BU-13` (the audio
stops after keying) and `BU-14` (the button stops keying). **Probed properly on
2026-08-22**, which answered the question both items were waiting on — the
device attaches as *two* Bluetooth devices, and the PTT is BLE rather than a
media key — and turned up `BU-15` on the way. The transport map, the measured
HFP costs, and why macOS is the reference behaviour rather than the odd one out
are in `BLUETOOTH-AUDIO.md`; read it before either item. Every one of PT-1 …
PT-4 shipped under APP-5 against a fake, so this is bring-up of the input and
route layer in the same sense `BU-2` was bring-up of the radio path: read the
accessory note before either item.

It is deliberately **not** part of the phase plan. `APP-*` and `BLE-*` in
`DEVELOPMENT-PLAN.md` — beside this file since 2026-08-21, and in the library
repo before that — are features — things the app should
be able to do. The items here are faults: things that are supposed to work
already and do not. They are numbered `BU-n` so a commit can cite one.

## How this work lands

⚠️ **Superseded, 2026-08-20 — `BU-2` closed, so the normal rules are back:
one task per branch, one PR, `make test` green before it opens.** What follows
is the rule that governed this file's items while the bring-up was live, kept
because the commits it produced are in the history.

**Directly on `main`. No task branch, no PR, until the app is confirmed working
on air.** The one-task-one-branch rule in the development plan §1 assumes the
change can be judged by reading it and running the tests. These changes cannot:
the only test that matters is a real node, a real iPhone, and a real radio, and
the loop between "change something" and "find out" runs through an on-air
session rather than through CI. Review gates in the middle of that loop buy
nothing and cost a day each.

The normal rules resume the moment `BU-2` closes — which they now have.
Everything else held meanwhile, and still holds: SPDX headers, the
`NetworkClient` seam, `make test` green before each commit, and no writes to
the library repository.

## Definition of done

`BU-2` was the whole effort, and it is **met**. The app is working when, on an
iPhone, against the live node:

1. ✅ Connect succeeds. (The codec *display* was not separately reported; it is
   a label, and a wrong one would not have produced intelligible audio.)
2. ✅ PTT keys the node, and the audio is judged intelligible — by the parrot
   playing our own over back, rather than by a second operator.
3. ✅ Channel audio is heard back through the phone, without dropouts, for long
   enough to be sure (minutes, not seconds).
4. ✅ Releasing PTT unkeys. ⏳ The watchdog (SF-1) unkeying a *held* button was
   never observed — `BU-7`.
5. ⏳ An incoming phone call drops transmit (SF-3), and PTT works again
   afterwards — never observed, `BU-7`.

The two unticked halves moved to `BU-7` rather than holding this open. Both are
app-level and mode-independent — the watchdog lives in `RadioCore` and the
interruption signal comes from `AudioPipeline`, so neither is an AllStarLink
question — and both are awkward to stage deliberately. Neither is a reason to
keep treating the app as unproven on air.

## Items

| ID | What | Status |
|---|---|---|
| BU-1 | PTT fails immediately: `could not construct an AVAudioConverter for the requested PCM formats` | ✅ **Fixed, confirmed on air 2026-08-11** |
| BU-2 | The on-air session itself — the five checks above | ✅ **Closed 2026-08-20** — parrot node `55553`, extended overs returned clean, DTMF commands accepted. The watchdog and phone-call halves moved to `BU-7` |
| BU-3 | `RadioCore` should expose the audio-session policy without requiring an engine | ✅ **Closed 2026-08-20** — library fix RC-11 (`swift-hamvoip` PR #35) shipped in v0.5.3, which is now the floor; the app's copy of the policy is gone |
| BU-4 | M17 has never been transmitted to a reflector, by this app or anything else | **Transmit confirmed heard 2026-08-17** — receive proven 2026-08-16, transmit from this app to M17-434 B heard via Mseven, an independent client. Check 5 (the far end sees the stream *end*) ✅ **closed 2026-08-20** as `BU-8`; check 6 folded into `BU-7` |
| BU-5 | EchoLink has never been connected from the app, only from the CLI | ✅ **Closed 2026-08-16** — `*ECHOTEST*` QSO from the app, and VK1RBM heard live off-air |
| BU-6 | Web Transceiver has never been connected from the app, only from the CLI | ✅ **Closed 2026-08-20** — nodes `44309` and `61624` reached from the phone over WT |
| BU-7 | The watchdog unkeying a held button (SF-1) and a phone call dropping transmit (SF-3) have never been observed on air | Open, deliberately deferred — wanted before public beta, not before more of this testing |
| BU-9 | The channel model loses edits, silently repoints named channels, and cannot delete a channel that has been connected to (macOS) | ✅ **closed 2026-08-21.** (1) and (2) fixed to the maintainer's decision of the same day — the connect form is a working copy, Save is the only thing that overwrites, Connect may add but never overwrite, and an unsaved edit survives a quit as a draft. (3) was never a defect — a failed connect leaves a modal sheet up and no context menu can open while it stands; the "greyed out" was the menu bar's own `Edit ▸ Delete`, matched by an unscoped query |
| BU-10 | The Live Activity (SF-4, APP-3) has never been seen on a locked iPhone, and the case it exists for — an accessory keying a backgrounded app — has never been staged | Open, and the last thing between SF-4 and a fact rather than a claim. Unit-tested on every end path; never looked at |
| BU-8 | Nobody has watched an M17 over *end* at the far end — the last-frame flag is sent and read, but the pair has never been observed working together | ✅ **Closed 2026-08-20** — four overs from the app, four `ended — end of over` at an independent observer on `m17-cbr.charlesmartin.au` A. Closes `BU-4` check 5 with it |
| BU-11 | An empty rounded panel hangs under the Channel name field on launch, with no interaction | **Diagnosed 2026-08-21, and it is not ours.** It is AppKit's *one-time-code* AutoFill panel — `NSAutoFillHeuristicController` → `SPSafariPlatformSupport`, remote content from `com.apple.SafariPlatformSupport.Helper` — shown with nothing to offer. It goes when the app is re-signed with no entitlements. No public API turns it off; **no app-side fix, and nothing to do but decide whether to report it** |
| BU-12 | **On a short display, the whole app is taller than its window and macOS centres the overflow** — the status panel ends up above the top edge and the sidebar's contents halfway down. Reproduced with an empty channel list, which is a first launch | ✅ **Fixed 2026-08-21.** It was the **sidebar**, not the connect form: a wrapping caption with `.fixedSize(horizontal: false, vertical: true)`, which a `NavigationSplitView` measures at an *unspecified width* — one word per line — and which `fixedSize` then makes a minimum. `ChannelListView` is 67 points tall on its own and demanded 1237.5 in the sidebar. Both `fixedSize` calls are gone, nothing is truncated by their absence, and the sidebar's held-back top alignment shipped with it |
| BU-13 | **A Bluetooth speaker-mic works for a while and then stops carrying audio, and keying is what stops it** — TIDRADIO Q2L, first accessory of any kind this app has met | Open, **not yet reproduced under instrumentation**, 2026-08-21. First suspect is `stopCapture()` stopping the whole engine on every unkey (see the `AudioIO` type note) against a route that goes away with it |
| BU-14 | **The accessory's PTT button keys the app for a while and then stops** — same device, and possibly the same root cause or possibly nothing to do with BU-13 | Open, 2026-08-21. **Which input answered 2026-08-22: BLE GATT** (`FF00/FF01`, `01`/`00`, real edges), so the PT-4 traps are ruled out and the suspects are in `BLEPTTController`. See `BLUETOOTH-AUDIO.md` |
| BU-15 | **The first transmit after launch does a visible dance** — press PTT, handset beeps, a pause, the UI flashes red, goes back to not-red, then red and actually transmitting (macOS, Q2L) | **Diagnosed 2026-08-22, not yet fixed.** Bringing HFP up changes the engine's configuration (A2DP device → HFP device, 44100 → 16000 Hz), `AVAudioEngineConfigurationChange` fires `.routeChanged`, and `resumeAcrossRouteChange()` correctly drops transmit and keys back down. The machinery is working as specified; the operator should not have to watch it |

---

### BU-5 — the EchoLink session from the app ✅ CLOSED 2026-08-16

**It works from the app.** `*ECHOTEST*` was connected and the round trip
confirmed — the greeting heard, our own audio echoed back — which settles
checks 1 through 4 below. Then **VK1RBM**, with the connection heard live off
air on UHF: the strongest confirmation available, because it is the radio side
of the link rather than a report from the other end of the internet.

**What is not settled is the workflow.** Connecting works; the sequence an
operator goes through to get there still has steps that do not quite make
sense, and more sessions are the way to find out which. That is UX work rather
than bring-up — it does not belong in this file, which is for faults. Log the
rough edges as they turn up and they can become an `APP-*` task.

The original write-up follows, since its two warnings still apply to every
session.

EchoLink became selectable in the app on 2026-08-13, against library v0.3.0.
The protocol side is in better shape than M17's was at the same point: the
library's CLI completed a live QSO through `*ECHOTEST*` on 2026-08-13
(Milestone M3), and the same path was re-run from this machine while the app
support was being written — proxy login, directory login, node answered, and
receive audio flowing. So the failure modes left are the app's own: the fields
the operator types, the codec being constructed inside the app rather than the
CLI, and the audio devices.

Two things about EchoLink that the other two modes do not have, and that a
first session will trip over if they are wrong:

- **Public proxies are single-user, and the app now sources one per session
  (APP-13).** A proxy that was free an hour ago is often taken, and a taken one
  accepts the TCP connection and then hangs up before sending its nonce. That
  surfaces as "the proxy stream closed" and is not a fault in the app — press
  *Find another* in the connect form's proxy drawer. Two things to watch for on
  air now that the proxy is not a stored field: that a second connect in one
  sitting goes through the *same* proxy as the directory refresh before it
  (one machine per sitting), and that a fresh launch probes again rather than
  returning to yesterday's. The old behaviour was the opposite of both.
- **The directory login is what registers you as available.** Leave the
  directory server empty and every step still reports success while no node
  ever answers. The connect form warns about this; believe the warning.

Checks, in the order they can be answered:

1. The station browser lists stations — that alone proves proxy and directory
   login from inside the app.
2. Saving `*ECHOTEST*` from the browser produces a channel that connects.
3. `*ECHOTEST*`'s greeting is heard, and is intelligible.
4. PTT is echoed back, and our own audio is intelligible — one operator alone
   can settle the whole round trip on this node, which is what it is for.
5. Releasing PTT ends the over, and the watchdog (SF-1) unkeys a held button.

---

### BU-4 — the M17 session — transmit confirmed 2026-08-17

✅ **Receive is proven, from this app.** A net on **M17-434** was listened to at
length: audio intelligible throughout, and the transmitting stations' callsigns
displayed as they came and went. That is checks 1, 2 and 3 below, and it
settles more than it looks — Codec2 decode, the jitter buffer, the 40 ms → 20 ms
handling, stream receive and the base-40 reading, all against many senders none
of whom are us. M17-434 appears to be the more active VK1 net and is worth
observing over more sessions.

✅ **Transmit is confirmed heard.** On 2026-08-17, a transmission from this app
to **M17-434 module B** was heard readable at the far end via **Mseven**, an
independent M17 client monitoring the reflector. Check 4 is settled: the
encoder, the LSF fields and the SID all survived to a decoder that is not ours.
The scope is still narrow — one reflector, one receiving implementation, one
operator at both ends — but "the reflector took it" and "somebody found it
readable" are no longer different claims. Checks 5 and 6 were not exercised in
that session.

**Check 5 — "releasing PTT ends the over cleanly" — is a far-end observation,
and cannot be settled from this end.** It is now its own item, `BU-8`, with a
method that needs nobody else's cooperation.

**Check 6** (the watchdog unkeying a held button) is not M17-specific at all —
the same `RadioCore` watchdog serves every mode — so it moved to `BU-7`.

The original write-up follows, kept for the record of how the link was
exercised before transmit was confirmed. Its warnings about reflectors
`NACK`ing modules they do not offer, and about arranging a second receiver
before transmitting on a shared channel, still apply to checks 5 and 6.

M17 became selectable on 2026-08-11 (app `4bc870c`, library v0.2.0). **Nothing
about its audio path has ever been exercised against real equipment**, by this
app or by the library's CLI. The one M17 thing that *is* confirmed on air is
receive-only and had no codec in it: the OQ-7 run that established the stream
frame is 54 bytes.

**2026-08-13, one step further and only one.** `hamvoip-cli m17` linked a live
reflector module and held it for five minutes: `CONN` accepted, `ACK` back,
keepalives holding, teardown clean. Nobody transmitted on the module during
that time, so **zero inbound streams were heard** and check 2 below is exactly
as open as it was. What this settles is that the link layer works against a
reflector that is running today; what it does not touch is the codec, the
jitter buffer, or anything audible. Note also that a reflector will `NACK` a
module it does not offer — two modules on one host were refused before a third
elsewhere was accepted — so a refused link is worth re-trying elsewhere before
being read as a fault.

So this is not "check M17 still works". Nobody knows whether it works at all,
and the plausible failure modes are wide open — the reflector may reject our
`CONN`, accept it and ignore our stream, relay a stream nobody can decode, or
relay one that decodes into noise. Any of those is new information worth
writing down.

Easiest first, because it takes the app out of the picture. From the library
repo, which has the same client underneath:

```sh
cd ../swift-hamvoip
scripts/build-codec2-xcframework.sh          # once; needs brew install cmake
swift package reset && swift build           # SwiftPM caches the manifest
swift run hamvoip-cli m17 --host <reflector> --module C --callsign <yours>
```

**Receive first, transmitting nothing.** Link the module, wait for somebody
else to talk, and find out whether their audio is intelligible. That alone
settles the decode path and the jitter buffer, and it puts nothing on air.

Only then transmit, and only with a second receiver — another client on the
same module, or somebody who can say what they heard. A reflector module is a
shared channel: everything transmitted is heard by everyone linked to it, so a
first attempt with an unproven encoder is worth arranging deliberately rather
than doing at random.

Then the same again through the app, with M17 chosen in the picker.

Checks, in the order they can be answered:

1. The link comes up and stays up — the reflector's `PING` keepalives hold it.
2. Another station's audio is heard, and is intelligible.
3. The station currently transmitting is displayed.
4. Our transmission is heard by a second receiver, and is intelligible.
5. Releasing PTT ends the over cleanly — the receiver sees the stream end,
   rather than the audio simply stopping.
6. The watchdog (SF-1) unkeys a held button, as it does on AllStarLink.

Worth capturing while doing it, since a capture is the only thing that can
settle a disagreement afterwards:

```sh
sudo tcpdump -i any -w ../experiment-data/m17-session.pcap 'udp port 17000'
sudo chown "$(id -un):staff" ../experiment-data/*.pcap
```

If a reflector turns out to disagree with what the library implements — a
different frame length, say — that is new information rather than a bug to fix
on sight, and `hamvoip-cli oq7` is the tool that measures it. The OQ-7 row of
the development plan explains why.

---

### BU-1 — every PTT press fails with `converterUnavailable` ✅ FIXED

**Confirmed on air on 2026-08-11**: Currawong keys the AllStarLink node from an
iPhone. This was the app's first transmission.

**Symptom.** Connecting to the node works. The first press of PTT, and every
press after it for the life of the process, raises "Could not transmit — could
not construct an AVAudioConverter for the requested PCM formats". The node is
never keyed.

**Mechanism.** `AVAudioEngine` decides its input format once, when its input
audio unit is first instantiated, and never revisits that decision. On iOS, an
engine whose input unit is instantiated while the audio session is still the
default `.soloAmbient` — playback only — reports an input sample rate of **0 Hz**,
and keeps reporting 0 Hz after the session is switched to `.playAndRecord` and
activated. `AudioPipeline.startCapture` builds its capture converter from that
rate; `AudioConverterNew` refuses 0 Hz; the throw is `converterUnavailable`.

Measured in the simulator, before the fix (`AVAudioEngine` read under
`.soloAmbient`, then the session configured exactly as `configureSession()`
does, then the input node read again):

```
category at launch                 = AVAudioSessionCategorySoloAmbient
input rate, read under soloAmbient = 0.0 Hz   ch=2
session rate after activate        = 48000.0 Hz
same engine, read after activate   = 0.0 Hz   ← never recovers
a new engine, built after activate = 44100.0 Hz
```

`AURemoteIO.cpp:1135 failed: -10851 (enable 1, outf< 2 ch, 0 Hz, …>)` appears in
the log at the moment of the first read, which is the input unit being brought up
against a session that does not permit recording.

The app was building its `AudioPipeline` — and with it an `AVAudioEngine` — in
`CompositionRoot`'s initialiser, at launch, from `@State private var root`. That
is long before `connect()` asks for the microphone and configures the session.

**Not the cause, ruled out by measurement:** merely constructing an
`AVAudioEngine` and touching `outputNode`/`mainMixerNode` early, which is all
`AudioPipeline.init()` does, leaves the input node healthy. Simulator hardware
is a shim, though, so this was not treated as proof for the device — the fix
removes the ordering question either way rather than relying on it.

**Fix** (`Sources/Currawong/AudioIO.swift`):

* The pipeline is built **lazily**, by `configureSession()`, immediately after
  the session is activated and after the microphone has been granted — never at
  launch. `AudioPipelineIO` takes a factory instead of a pipeline.
* `startCapture` **repairs once and retries once**: reactivate the session, throw
  the engine away, build a new one, try again. A poisoned engine cannot be talked
  out of its input format, so a retry is only worth anything on an engine that
  did not exist yet. The same path recovers a session left inactive by an
  interruption, which fails the same way and used to be permanent too.
* `signals` is now a durable stream owned by `AudioPipelineIO`, which forwards
  whichever pipeline is current into it. **This is SF-3 load-bearing**: the
  pipeline's own stream dies with the pipeline, and a rebuild would otherwise
  silently end interruption observation for the rest of the process.
* A second failure is reported with the audio state attached — see below.

The audio session category is now spelled in the app as well as in the library,
which is a duplication with a reason (`BU-3`) and a comment saying so.

Covered by `Tests/CurrawongTests/AudioPipelineIOTests.swift`, over a fake
`CapturePipeline`: no engine before something needs one, one engine for a
successful capture, rebuild-and-stop on failure, exactly one retry, both errors
reported, playback follows the rebuild, and signals survive it.

**If it still fails on air**, the alert now carries the numbers instead of only
the refusal:

```
The microphone could not be opened. <error> (first attempt: <error>) Audio state:
category=… mode=… hardware=…Hz preferred=…Hz inputAvailable=… inputChannels=…
route=… otherAudio=…
```

Read it as follows.

* `hardware=0.0Hz` — the **session** never really came up. Look at the category,
  the route, and whether another app holds the session; the engine is innocent.
* `hardware=48000.0Hz` (or any live rate) with the converter still refused — the
  session is fine and the **engine** is still being handed a bad rate. That
  points at `AudioPipeline.startCapture` reading a stale
  `inputNode.outputFormat`, and the fix moves to the library repo.
* `inputAvailable=false` or `route=none` — no input hardware is routed at all,
  which is a route problem, not a format problem.

**Which half of the fix did it is not known**, and deliberately not guessed at:
if the engine is now always built after activation, the retry never runs, and a
successful first press cannot distinguish the two. Both stay. The retry is not
dead weight either way — the inactive-session case it also repairs is reachable
from any interruption, which the ordering fix does nothing for.

### BU-6 — the Web Transceiver call from the app ✅ CLOSED 2026-08-20

**Closed.** Nodes `44309` and `61624` were both reached from the phone over Web
Transceiver, so the portal token, the CALLING NUMBER routing and the app's
connect form all work together on a real handset — APP-11 and APP-12 confirmed
end to end, not just against canned responses.

The original walkthrough follows, kept because it is still the right order to
debug a *failed* WT call in: each step fails differently, and step 4 is the one
that distinguishes "attached" from "the node answered on its failure path".

The route had already worked from the CLI: `hamvoip-cli iax2` reached a third
party's node with nothing but a portal account (IAX-12), verified from outside
by the callsign appearing in that node's link list.

What to check, in order, because each step fails differently:

1. **The token.** Paste it into the *Portal token* field in AllStarLink mode with
   *Web Transceiver* chosen. `hamvoip-cli wt-token --callsign <yours>` prints one
   (IAX-13). If the field warns that it does not look like a token, the paste was
   truncated or autocapitalised — the app connects anyway, so read the warning.
2. **The node number.** In this route it is not dialled; it travels as CALLING
   NUMBER and selects which node answers. The *Look up this node* button still
   fills in the host from the number, exactly as for a node-secret channel.
3. **The ten-second wait.** A WT node answers, plays "connected to node" and
   speaks the node number before attaching. That delay is normal and is not a
   stall — do not press Disconnect through it.
4. **The check that matters.** A client-side "Connected" is *not* sufficient: the
   node answers on its failure path too, before hanging up. A call that drops
   after about a second means the authority check failed. A call that holds is
   attached, and a WT client appears in the target node's link list **by
   callsign**, so it is verifiable from outside:

   ```sh
   curl -s "https://stats.allstarlink.org/api/stats/<node>" \
       | jq -r '.stats.data.nodes' | tr ',' '\n' | grep "<your callsign>"
   ```

`swift-hamvoip/docs/CLI.md` §11 is the walkthrough this mirrors, and §11.3 is
where that last check comes from.

### BU-2 — the on-air session ✅ CLOSED 2026-08-20

**Check 2 (PTT keys the node) was confirmed 2026-08-11.** The rest closed on
2026-08-20 against the **public parrot, node `55553`** — which is the right
instrument for this and settles more than a QSO with a person would. A parrot
records an over and plays it straight back, so one operator alone closes the
whole round trip, and the audio judged at the end is our own encoder's output
having survived the node: extended overs came back **perfectly**, with no
dropouts, which is checks 2 and 3 together. **DTMF commands were sent from the
keypad and acted on by the node**, which is APP-10's half working against real
equipment rather than a fixture. Releasing PTT unkeyed — the parrot would not
have played anything back otherwise.

`55553` is worth keeping in the node list. It is public, it needs nobody else's
time, and it will answer the same way next month, so it is the node to reach
for whenever a change touches audio.

**Two checks did not close, and are `BU-7`:** the watchdog unkeying a *held*
button, and an incoming phone call dropping transmit. Neither is an
AllStarLink question — the watchdog is `RadioCore.TransmitWatchdog` and the
interruption arrives as an `AudioPipeline` signal, so both behave identically
on M17 and EchoLink — and both are irritating to stage on purpose. They are
wanted before a public beta and are not worth blocking on now.

Bring the failure text, verbatim, of anything that goes wrong — the alerts are
written to be readable off a phone screen precisely because that is the only
instrumentation available in the field.

### BU-3 — the library should not require an engine to set the session category ✅ CLOSED 2026-08-20

`AudioPipeline.configureSession()` is an instance method, so reaching the audio
session policy means owning an `AudioPipeline`, and owning one means having built
an `AVAudioEngine` — the exact thing `BU-1` says must not happen before the
session is configured. The app therefore spells the category itself, and the two
copies have to be kept in step by hand.

The library's fix is a static or free function (`AudioPipeline.activateSession()`
or similar) holding the category, mode and options, with the instance method
calling it. **That change belongs to the library repository and its own agents;
do not make it from here.** Raise it there, then delete the duplicate and its
comment from `AudioIO.swift`.

**The library half has landed** — `swift-hamvoip` RC-11, PR #35, 2026-08-20.
`AudioSessionPolicy` holds the policy and `AudioPipeline.activateSession()` is
static, so the category can be set with no engine anywhere in the call.

**The app half landed with v0.5.3**, which carries RC-11 and is now the floor in
`project.yml`. Gone from `AudioIO.swift`: the category, mode and options; the
comment above `configureSession()` apologising for spelling them twice; and the
`#if compiler(>=6.2)` shim for the `allowBluetooth` → `allowBluetoothHFP`
rename, which had nothing left to gate once the library stated the options as a
raw value. `AudioIO.activateSession()` survives as two lines around
`AudioPipeline.activateSession()`, and the deviation is deliberate: the library's
static is inside `#if os(iOS)`, so deleting the wrapper outright would have put
that guard at both call sites — `configureSession()` and the repair path in
`startCapture(onFrame:)` — and left nowhere to say why macOS needs nothing. What
is left in the app is the platform guard, not the policy.

The engine construction in `configureSession()` — "build it here, immediately
after activation, never before" — is the app's own ordering decision and
**stays**. Only the session half was the library's.

### BU-8 — watch an M17 over end, at the far end ✅ CLOSED 2026-08-20

**A specific test, and a cheap one.** Split out of `BU-4` check 5 on
2026-08-20, because "clean teardown" reads like a link question and is not one.

✅ **Closed 2026-08-20, both halves.** The app was driven by hand against
`m17-cbr.charlesmartin.au` module A with a CLI observer linked to the same
module, and every over ended cleanly at the far end:

```
RX VK1CPM (stream 0x7668)
RX VK1CPM ended — end of over
RX VK1CPM (stream 0x0B87)
RX VK1CPM ended — end of over
RX VK1CPM (stream 0x74DD)
RX VK1CPM ended — end of over
RX VK1CPM (stream 0xC1AF)
RX VK1CPM ended — end of over
```

Four overs, four `.lastFrame` ends read by a client that is not the one that
sent them. That is `BU-4` check 5 as well: the app's release path, confirmed
from outside.

⚠️ **The first press of the session put nothing on air**, and that was a real
fault rather than an artefact — see the microphone note below. Fixed.

The library half was confirmed earlier the same day, with two `hamvoip-cli`
instances against the same module. The observer printed:

```
RX VK1CPM (stream 0xC9E9)
RX VK1CPM ended — end of over
```

`end of over` is `.lastFrame` and not `.preempted`, so the flag was set, sent
and read — and it arrived on the release rather than being cleaned up by a
later stream, since no later stream existed. 75 datagrams for a three-second
over is exactly 3000 ms ÷ 40. **The short-tap edge behaved as predicted**: a
20 ms key-up produced no stream at all at the observer (`Inbound streams heard:
1` across two key-ups), so the `nextSequenceNumber > 0` guard leaves nothing
hanging.

⚠️ **`--no-audio` does not send silence, despite saying it will.** The first
attempt keyed up with `--no-audio` on both ends and transmitted *nothing* —
`Datagrams transmitted: 0`, and the observer heard no stream. The only frame
source is `pipeline.startCapture`, inside the `useAudioDevices` branch, so with
no devices open PTT changes state and feeds no PCM. The banner says "PTT will
send silence". A test that keys up unattended needs the real microphone until
that is fixed, which is why the run above used `--audio` on the transmitting
side. It is a library-repo problem, not one to fix from here.

**The app half is written and blocked on one click.**
`Tests/CurrawongOnAirUITests/M17EndOfOverUITests.swift` drives the real app:
picks M17, fills the reflector and module, connects, holds PTT for three
seconds with `press(forDuration:)`, then hangs up. It has its own target and
its own scheme, `CurrawongOnAir`, and is deliberately **not** in the
`Currawong` scheme's `testTargets` — it transmits, so it must never run under
`make test` or in CI.

```sh
# terminal 1 — the observer
cd ../swift-hamvoip
swift run hamvoip-cli m17 --host m17-cbr.charlesmartin.au --module A \
    --callsign <yours-with-a-suffix> --no-audio --duration 150
# terminal 2 — the app, driven
xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
    -derivedDataPath DerivedData -destination 'platform=macOS' test
```

**What the first sessions established, 2026-08-20.**

- **Accessibility must be granted** to whatever runs the tests, or the run dies
  with `Timed out while enabling automation mode` before the app ever launches.
  It is a one-time grant in System Settings → Privacy & Security →
  Accessibility, and cannot be scripted: the TCC database is SIP-protected.
- ✅ **The app keys and unkeys correctly.** `press(forDuration:)` on the
  `DragGesture`-based PTT control drives a real over, and afterwards the app
  reads `Connected. Listening.` with no `On air.` — the transmit banner renders
  only while transmitting. **A snapshot taken the instant the press returns
  still shows the banner**, which reads alarmingly like a stuck key and is not
  one: it is a frame the app has not re-rendered. Wait before believing it.
- ⚠️ **Match SwiftUI text on `value`, not by subscript.** A SwiftUI `Text`
  arrives with an empty accessibility *label* and its string in `value`, so
  `app.staticTexts["On air."]` matches nothing at all and every assertion built
  on it passes vacuously. An earlier run reported the release as confirmed on
  exactly that basis, having checked nothing. Use
  `app.staticTexts.matching(NSPredicate(format: "value == %@", …))` — and keep
  queries narrow either way: `descendants(matching: .any)` with a predicate ran
  218 seconds against this tree and timed out.
- ✅ **The silent overs were two faults, both now fixed.**

  **The route change.** A run carried the SF-3 banner *"Transmission stopped:
  the audio route changed"*. Rebuilding the app reconfigures the audio graph,
  the configuration-change notification arrives as a route change, and SF-3
  ended the over about 40 ms in — so the first transmission after installing a
  new build was reliably dead, for an operator as much as for a test. A route
  change under a held button now keys back down once the graph settles.

  **The microphone, on macOS.** `AudioIO.requestRecordPermission()` returned
  `true` on macOS without asking anybody, so nothing prompted until the *first
  capture attempt* — and that press put no audio on air. Observed by hand on
  2026-08-20: press once, nothing; the microphone indicator appears in the menu
  bar; press again, and there are levels. It now asks via `AVCaptureDevice` at
  connect time, where the operator is already waiting and no over is at stake.
  A test runner still cannot answer the prompt, so grant it once by running the
  app normally.
- **The form's fields had no accessibility labels at all.** SwiftUI gives a
  `TextField` its placeholder and nothing else, so VoiceOver announced
  "node.example.org, text field" with no way to know it was the host. Fixed in
  `LabelledField`, which now names its content; the fields this test drives
  also carry identifiers (`connect.host`, `connect.module`,
  `connect.channelName`). The UI test hitting that wall was the symptom: if a
  screen reader cannot name the controls, nothing else can either.
- **The test brings its own channel** — adds one, uses it, and tries to delete
  it — after an earlier version silently repointed a real channel at the test
  reflector. The delete does not work: see `BU-9`, which this test found.
- **macOS asks for a password on most runs.** That is developer-tools
  authorisation for the runner taking control of the app, and it recurs because
  the runner is re-signed ad hoc on every build. `sudo DevToolsSecurity -enable`
  stops the asking. The Accessibility grant lapses the same way, showing up as
  `Timed out while enabling automation mode`.

  `ChannelRestoreUITests` puts a channel back where it belongs, driven by
  `TEST_RUNNER_`-prefixed environment variables (the plain names do not reach
  the runner):

```sh
TEST_RUNNER_RESTORE_CHANNEL='<name>' TEST_RUNNER_RESTORE_HOST=<host> \
  TEST_RUNNER_RESTORE_MODULE=<letter> \
  xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
  -derivedDataPath DerivedData -destination 'platform=macOS' \
  -only-testing:CurrawongOnAirUITests/ChannelRestoreUITests test
```

**What is actually being asked.** An M17 stream is a numbered sequence of
frames and the final one sets the last-frame flag, `FN & 0x8000`. A receiver
that gets it closes the over immediately; a receiver that does not simply stops
being fed, and there is **no timeout path** — `StreamEndReason` has exactly two
cases, `.lastFrame` and `.preempted` — so a lost final frame leaves the last
station displayed until somebody else transmits. None of that is visible from
the transmitting side, which is why "it all seems to work" cannot settle it.

**Both halves are implemented**, which is why this is a confirmation rather
than a suspicion. `M17Client.stopTransmit()` pads the leftover half frame and
sends it with `isLast: true`; `M17StreamReceiver` reads the flag and the client
emits `.streamEnded(reason: .lastFrame)`. The pair has just never been observed
working against a real reflector.

**The method: two `hamvoip-cli` instances against `m17-cbr.charlesmartin.au`**,
which is ours — no shared channel, nobody else's session to interrupt, and it
can be repeated as often as it takes.

```sh
cd ../swift-hamvoip
# terminal 1 — the observer, transmitting nothing
swift run hamvoip-cli m17 --host m17-cbr.charlesmartin.au --module <m> --callsign <yours>
# terminal 2 — the transmitter, a different callsign or SSID
swift run hamvoip-cli m17 --host m17-cbr.charlesmartin.au --module <m> --callsign <yours-2>
```

**What passes.** Key terminal 2, say something, release. Terminal 1 should
print `RX <callsign> ended — end of over` **within a moment of the release**,
not seconds later and not only when the next over starts.

**What failure looks like**, and the two are worth telling apart:

- **No `ended` line at all** — the final frame never arrived or never left. The
  observer will sit on the last station indefinitely.
- **`ended — cut off by another station`** — a `.preempted` end, meaning a new
  stream ID began before this one finished. On a two-client test that means the
  flag was missed and the *next* over cleaned up after it.

**Then the same again with the app transmitting** and one CLI observing. That
is the check `BU-4` actually wants — the app's release path, not the library's
— and it is the same setup with terminal 2 replaced by a phone.

**One edge worth trying while set up:** a very short tap. Under 40 ms no packet
is sent at all (`stopTransmit` guards on `nextSequenceNumber > 0`), so the
observer should show no stream rather than a stream that never ends. A brief
over that *does* start must still end.

Capturing it costs nothing and settles any later disagreement:

```sh
sudo tcpdump -i any -w ../experiment-data/m17-bu8.pcap 'udp port 17000'
```

### BU-9 — the channel model is lossy in both directions

**Found by trying to drive the app, 2026-08-20**, and worth stating plainly:
these are not test problems. A UI test is just an operator who never gets
bored, and every one of these is something a person can hit.

**1. Edits are not saved unless you connect or switch channel.** The connect
form edits a *draft*; the draft reaches the channel list only through
`connect()`, `select()` or `addChannel()`. There is no save on quit —
`RootView`'s `scenePhase` handler calls `setForeground(_:)` and nothing else.
So: open the app, correct a channel's host, quit. The correction is gone, with
no warning and nothing to undo. This was measured rather than reasoned: fields
typed and verified on screen, app closed, defaults unchanged.

**2. When an edit *is* saved, it overwrites the selected channel in place, and
the name does not follow.** `name` is only a fallback for `displayName`, so a
channel called `M17-432 H` that gets pointed at a different reflector keeps
calling itself `M17-432 H` for ever. That is how this test repointed a real
channel while looking like it had done nothing.

Together the two are the bad combination: **the edit is lost when you wanted
it, and applied when you did not.**

#### Fixed 2026-08-21, to the maintainer's decision of the same day

The design question — what a channel *is*, and when an edit belongs to it — was
answered rather than worked around, and the answer is one sentence: **you start
from a channel and edit from there, and the channel list does not change unless
you ask it to. "Add channel" gives a fresh start.** Three consequences were
settled explicitly, and they are what the code now does:

- **Save is the only thing that overwrites a stored channel.** The connect form
  has its own Save, enabled only while the draft differs from the channel it came
  from, beside a line saying there are unsaved changes.
- **Connect may add, but never overwrite.** A draft that is in no channel yet — a
  node typed into an empty app, a reflector picked out of the directory — is
  added by connecting, because pressing Connect on somewhere new plainly says it
  is a place you go. A draft that *is* an existing channel connects, and the
  stored channel is left describing where it goes. That is the half that
  repointed `M17-432 H`, and it is gone.
- **Unsaved edits survive a quit**, kept as a draft with the list untouched, and
  the channel's row in the list is marked `Edited` so it is honest about showing
  the stored channel rather than what the form holds.

**The representation is the whole trick.** A dirty draft *is* a `NodeSettings`
carrying the id of the channel it came from — `ChannelSet.update` matches by id
and `validated()` preserves it — so the pending state is `[UUID: NodeSettings]`,
persisted as a plain `[NodeSettings]` under its own defaults key
(`SettingsStore.loadDrafts()`/`saveDrafts(_:)`). A draft whose id is in no
channel is a channel that has never been saved and needs no special case.

`RadioSession.saveDraft()` is now the explicit Save and nothing calls it
implicitly. The five places that used to — `select(_:)`, `addChannel(_:)`,
`chooseChannel(_:)`, `restoreLastConnectedChannel()`, and the settings screen's
callsign field — call `stashDraft()` instead, which keeps the edit and touches
nothing in the list. `RootView`'s `scenePhase` handler calls it too, which is the
save-on-quit that was missing. Fourteen new unit tests in
`RadioSessionChannelTests` and three rewritten ones, including a
quit-and-relaunch built as a second `RadioSession` over the same store.

Three smaller decisions were taken along the way, none of them in the brief:

- **Save on a draft that is in no channel adds it.** Save is the operator saying
  "keep this", and a Save button that did nothing on a channel picked out of a
  directory would be the same class of fault as the one being fixed.
- **A deleted channel's pending draft goes with it** — the opposite of the rule
  for its Keychain secret, and for the opposite reason: a draft is only ever
  reached by selecting its channel, so one for a deleted channel is unreachable.
- **A draft belonging to no channel is pruned at launch.** Within a run it works
  (a directory browse is exactly that), but nothing stored says which draft was
  on screen, so after a relaunch it cannot be found again and would sit in the
  defaults for ever. It is consistent with the rule browsing already has — looking
  around leaves nothing behind — but it does mean a browse-then-quit loses the
  draft. Restoring that too would need a stored "current draft" id, which is new
  persistent state and was not asked for.

**That third one was the last open decision here, and it is settled: the pruning
stays** (maintainer, 2026-08-21). Browse a reflector, edit it, quit, and the draft
is gone — accepted, as the case consistent with the rule browsing already has:
looking around leaves nothing behind. Making it survive would have meant a stored
"current draft" id, which is persistent state nobody asked for, and BU-9 is not
that. **BU-9 has no open questions left.**

One user-visible wart fell out of the fix and was fixed with it: `select(_:)`
returned early when the id was already the selected one, so after a directory
browse — which repoints the draft without moving the selection — tapping the
highlighted row was the one tap in the list that did nothing.

**The form says two different things, because the rule has two halves.** With
edits to a stored channel it says the saved channel is unchanged until you save;
with a draft the list does not hold it says connecting will add it. One sentence
covering both would have been false half the time, which is the fault this whole
item is about — see `RadioSession.isDraftAnUnsavedChannel`.

**One thing that looks like a fault and is not**, pinned by a test so it stays
that way: `connect()` normalises what it dials (`validated()` trims and
uppercases the module) and the draft is normalised with it, so connecting with
untrimmed text does not leave the app reporting unsaved edits over whitespace the
operator never typed.

**3. Delete is dead on macOS for any channel connected to this launch.**
Right-click → Delete is greyed out and does nothing, *after* the link is fully
down — the app reads `Not connected`, the lock label is gone, the row itself is
enabled, and the item is still disabled. A channel never connected to deletes
perfectly well (`ChannelLifecycleUITests` passes), which is what makes this easy
to miss. macOS has no swipe-to-delete, so there is then **no way at all** to
remove that channel from that platform. Ruled out: the menu item's own
`.disabled(!isMutable)`, the order of `.disabled` and `.contextMenu`, `.id()`
on the row, and the session guard in `RadioSession.deleteChannel(_:)` (which is
satisfied). The remaining suspect was the row's context menu not being rebuilt
after the connection state changes — **and it was wrong; read on before acting on
any of this paragraph.**

**Not fixed when this was written, deliberately.** (1) and (2) were one design
question — answering it by adding a `saveDraft()` on quit would have made
accidental overwrites permanent rather than merely possible — and that was the
maintainer's call, taken on 2026-08-21 and recorded above. (3) turned out not to
be a bug at all; it is measured and closed below.

#### What (3) is *not*, measured 2026-08-21

The account above stands as what was observed. What has changed is that the
suspect named in it — the row's `contextMenu` not being rebuilt after the
connection state changes — **has been tested and is not what happens.**

`Tests/CurrawongTests/ChannelListContextMenuTests.swift` hosts `ChannelListView`
in an `NSHostingView`, inside a `NavigationSplitView` the way `RootView` hosts it
on macOS, drives a real `connect()` and `disconnect()` through the fake link, and
reads the `NSMenu` the platform would actually display for each row. It runs
headless under `make test-macos`, opens no socket and transmits nothing. What it
establishes:

- SwiftUI **rebuilds** the row's menu on every read. A menu read while the list
  was locked carries `isEnabled == false` and a `nil` action and keeps them for
  ever, but the row hands out a fresh, live one once `isMutable` is true again.
- After a connect/disconnect cycle, Delete is enabled **both** on the channel
  that was connected to **and** on a row that merely sat in the list while it was
  locked — and firing the item's action really does remove the channel, which an
  enabled-but-inert item would not.

So the four things ruled out by hand were all attacking a mechanism that does not
occur, which is why none of them changed anything. The test is a negative control
as well as a regression test: forcing `isMutable` to `false` makes it fail on five
assertions, so it is not passing vacuously.

**The best-supported explanation is now the query, not the app.**
`app.menuItems["Delete"]` is not scoped to the context menu, and every SwiftUI
app on macOS carries an always-present, always-greyed `Edit ▸ Delete` in the menu
bar. An unscoped query matches *that* — it exists, it reports
`isEnabled == false`, and clicking it does nothing — whether or not the row's own
menu ever opened. That is the reported signature exactly. What could stop the row
menu opening while leaving every other symptom intact ("Not connected", no lock
label, the row enabled) is a **modal alert still standing after the session**:
`handleLinkLoss` presents one, and so does a failed connect, and only a channel
that has been connected to reaches a path that ends in one.

#### (3) is closed, 2026-08-21: there is no defect in Delete

`ChannelDeleteAfterConnectUITests` ran, and it passes. The automation grant came
back, and what the test was written to settle it settled — **Delete works, and the
report was two things at once, neither of them the menu.**

1. **A failed connect leaves a modal alert standing, and it arrives as a *sheet*.**
   With it up, the row is still in the tree and still reads as enabled, the lock
   label is gone, and the app says it is disconnected — but **no context menu can
   open at all**: `=== with the alert up, a context menu opened: false`. Only a
   channel that has been connected to reaches a path that ends in an alert, which
   is the entire asymmetry with the never-connected case that made this look like
   it was about *having been connected to*.
2. **The unscoped query supplies the "greyed out".** With the alert up,
   `app.menuItems["Delete"]` matches and reports `isEnabled: false` — the menu
   bar's own `Edit ▸ Delete`. Existence passes, the item is disabled, the click
   does nothing.

Dismiss the alert and the row's menu opens, Delete is enabled, and clicking it
removes the channel — on the dialled channel and on the bystander alike. So
**there is no production bug here and no production code was changed for item 3**,
which is the reason all four hand-tried fixes did nothing: three mechanisms were
never happening, and the fourth was the measurement.

What is left is a UX point rather than a fault, and it is worth writing down:
after a failed connect the operator is looking at an app where right-click does
nothing at all until the alert is dismissed. Nothing in BU-9 requires a change for
it.

#### Two traps this cost a morning to

Both are in the test tooling, and both produce a confident false positive.

- **`app.menus` holds every menu-bar menu**, open or not. Its count is about
  **thirteen** before anything has been right-clicked, and `app.menus.firstMatch`
  is the Apple menu — so `app.menus.count > 0` is not "a context menu opened", and
  the guard written to be the *scoped* alternative to `app.menuItems["Delete"]`
  was itself unscoped. The row's menu is told apart by holding exactly one item,
  which is its whole contents: Delete.
- **A run that dies before its cleanup edits the operator's real app.** The app
  writes its channel list to the real defaults. Five runs left four rows behind,
  the next run deleted one of two identically-named rows, and the existence check
  reported "Delete did nothing" when it had worked perfectly — which is what kept
  item 3 looking alive for a morning after it was already dead. The test now
  removes every row of its own two names *before* it adds anything, asserts on the
  **count** of matching rows rather than on whether one exists, and keeps
  `continueAfterFailure = true` so an early failure cannot skip its own cleanup.

Also settled in passing: `app.buttons["OK"].firstMatch` clicks the macOS test
host's **Touch Bar** proxy of the default button and throws *"cannot be called
with Touch Bar elements"*. Scope alert buttons to `app.sheets` — a SwiftUI
`alert` on macOS is a sheet, not an `alert`.

### BU-11 — the empty panel under the Channel name field 🔬 DIAGNOSED 2026-08-21

**It is not our panel, and it is not autocorrect.** A small semi-transparent
rounded rectangle hangs below the Channel name field on launch, with no
interaction, in the macOS app. It was blamed on autocorrect on 2026-08-21 and
then on the test window; neither was right.

What it actually is, established by attaching to the running app:

* The window is an **`SPRoundedWindow`** from
  `/System/Library/PrivateFrameworks/SafariPlatformSupport.framework`, at
  `kCGWindowLayer` 101 (`NSPopUpMenuWindowLevel`), 180×110.
* Its `contentView` is an **`NSRemoteView` hosting
  `SPCompletionListServiceViewController` out of process** in
  `com.apple.SafariPlatformSupport.Helper`. That is why it looks empty and why it
  is blank in every screenshot: there is no content in *our* process to draw, and
  the remote surface does not composite into a window capture.
* A breakpoint gives the whole path:
  `-[NSAutoFillHeuristicController _showPasswordAutoFillIfNecessaryForView:withCompletionHandler:]`
  → `-[SPSafariPlatformSupport displayOTPAutoFillRelativeToRect:ofView:oneTimeCodeMode:completionHandler:]`,
  with `oneTimeCodeMode: 1`. **It is the one-time-code AutoFill panel**, offered
  with no code to offer.
* `ofView:` is the Channel name field — read off the stopped process, its
  `stringValue` was the selected channel's name. Disabling that field moves the
  panel down to the next text field, which is the same fact from the other side.

**Four things it is not**, each tested by building and relaunching and then
looking for the second window with `CGWindowListCopyWindowInfo`:

1. **Not autocorrect.** `.autocorrectionDisabled()` on the Channel name field
   changes nothing. (The modifier is worth having anyway — autocorrect on a
   callsign-shaped name is wrong on its own terms — so it stays.)
2. **Not the `SecureField`.** Replacing the node secret's `SecureField` with a
   plain `TextField` changes nothing.
3. **Not the first responder.** Clearing it (`makeFirstResponder(nil)` on every
   window at launch) leaves the panel exactly where it was, and the stopped
   process confirms the key window's first responder is the window itself.
4. **Not naming the credential fields.** `.textContentType(.username)` and
   `.textContentType(.password)` on the account fields changes nothing.

**What does change it: the code signature.** A minimal two-field SwiftUI app —
`TextField`, `TextField`, `SecureField`, a four-digit port and a five-digit node
number, ad-hoc signed with no entitlements — never shows the panel. Re-signing
*Currawong's own build* with an empty entitlements plist makes the panel go away
too. So the trigger is the properly signed identity, not the view code: an app
AppKit considers credential-capable (`com.apple.application-identifier`,
`keychain-access-groups`) gets offered OTP AutoFill on the first text field of a
window. Which of the two entitlements it is could not be isolated — ad-hoc
signing with either one alone is refused at launch (`RBSRequestErrorDomain 5`).

**So there is nothing to fix in the app.** `NSAutoFillHeuristicController` is
private, there is no public opt-out for a text field, and the entitlement it
keys off is one the app needs — the node secret lives in the Keychain. The
options are to report it to Apple as an empty AutoFill panel shown unbidden, or
to leave it. Worth re-checking on the next macOS update: this machine is on
macOS 26.5 (SDK `MacOSX26.5`), and an empty completion list that shows itself
anyway looks like a regression rather than a policy.

**How to check whether it is still happening**, without a screenshot — the panel
is invisible to `screencapture` but not to the window list:

```sh
# with the app running, look for a second Currawong window at layer 101
swift - <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == "Currawong" {
    print(w["kCGWindowNumber"] ?? "?", w["kCGWindowLayer"] ?? "?", w["kCGWindowBounds"] ?? "?")
}
SWIFT
```

### The accessory itself — read this before BU-13 or BU-14

**A TIDRADIO Q2L, in hand 2026-08-21.** A Bluetooth speaker-mic with a PTT
button, of the shape sold for phone-based radio apps. It is the **first
accessory of any kind this app has met**: every one of PT-1 … PT-4 has until now
been exercised by a unit test against a fake, and APP-5 shipped all three inputs
without a device in the room.

> ⚠️ **Answered 2026-08-22 — see `BLUETOOTH-AUDIO.md`.** The device attaches
> **both** ways at once, as two Bluetooth devices with different addresses:
> classic HFP/A2DP/AVRCP for the mic, speaker, CH+/CH- and volume, and a
> *separate* BLE peripheral (service `0xFFE0`) carrying the PTT and nothing
> else. **The PTT is a BLE item (PT-2/PT-3), not a PT-4 item**, so the two PT-4
> traps below do not apply to it — they apply to CH+/CH-, which are AVRCP Next
> and Previous Track. The question below is kept because the *reasoning* still
> holds for the next accessory; the guess that it would be one or the other did
> not.

**The first measurement decides which fault is which**, and it is not a
diagnosis, it is a question about the device: *how does this thing attach?*
Accessories of this class usually pair as **classic Bluetooth handsfree** — a
mic-and-speaker *route* the audio session may select, not a peripheral the app
connects to — and send the button as an HID or AVRCP key, which reaches this app
as `MPRemoteCommandCenter` (PT-4). Some also advertise BLE GATT, which is the
path PT-2/PT-3 and all of `BLEPTTController` were written for. Which of those is
happening here is unknown, and until it is known, the two items below cannot be
told apart from each other.

Answer it first, cheaply, in this order:

1. **`hamvoip-cli` is not the instrument for this** — the accessory is an app and
   OS concern, not a protocol one. Nothing about this belongs in the library.
2. Open the accessory pane and run **learn mode** with the device paired. If no
   notification arrives when the button is pressed, it is not a BLE peripheral
   button, `BLEPTTController` is not in the picture, and BU-14 is a PT-4 item.
3. Note whether the device appears in the iPhone's Bluetooth list as a *paired
   accessory* (handsfree) or only in the app's own scan (BLE), or both.

Two standing traps apply the moment it is a PT-4 button, and both are already
written down in `RemoteCommandPTT.swift` rather than being new discoveries:
**the button latches** — press to key, press again to unkey, because a remote
command has no release edge — and **only the app the system considers "now
playing" receives commands at all**, so anything else that starts audio takes
the button away with no error anywhere. "Works for a while and then stops" is
that trap's exact signature, so rule it in or out before looking for a bug.

### BU-13 — a Bluetooth speaker-mic stops carrying audio, and keying is what stops it 🔧 OPEN 2026-08-21

**What the operator sees.** Audio works through the Q2L "a bit", then stops, and
keying is what precedes the stop.

**Not reproduced under instrumentation yet.** What follows is where to look, in
the order the code makes likely — not findings.

* **`stopCapture()` stops the whole engine, on every single unkey.** That is
  deliberate and documented (`AudioIO.swift`, the type note): half-duplex has
  nothing to receive while the microphone is open, and leaving the tap installed
  keeps the system recording indicator lit for the whole call, which this app
  must never do. With the built-in microphone the cost is invisible, because
  `enqueuePlayback(_:)` restarts the engine on the next inbound frame. **With a
  handsfree route it may not be invisible**: stopping the engine can drop the
  link, the route changes underneath, and the engine that comes back was built
  against a route that no longer exists. `AVAudioEngine` never revisits its
  input format — the same fact that produced the 0 Hz bootstrap deadlock — so
  "the route moved across an engine rebuild" is a fault of a shape this file
  already knows, in a path that does not yet act on it.
  **If this is the cause, the repair is to rebuild on a route change, not to
  stop stopping the engine.** Keeping the tap open is a rejected design, not an
  option that reopens because it would be convenient here.
* **The SF-3 signals may already be telling us.** `AudioPipeline` emits
  `AudioSessionSignal`s and `RadioSession` consumes them. A handsfree route
  coming and going is a route change; find out whether one is arriving and being
  ignored, or arriving and dropping transmit. Either answer is progress.
* **The category and mode are the library's, not the app's** (RC-11, v0.5.3 —
  `AudioPipeline.activateSession()`). Whether they ask for handsfree Bluetooth,
  and what `mode` they set, decides whether the microphone is the accessory's or
  the phone's. **Playing out of the accessory while recording from the phone is a
  different fault** and worth telling apart on the first session, because it
  looks like success until somebody at the far end says the audio sounds like a
  pocket. If the fix is in the category, it is a library change, cited here and
  made there.

**Instruments.**

* `AudioPipelineIO.audioStateDescription()` already prints category, mode,
  hardware rate and the **route's input port types**. Today it is only reached
  from the failure alert. Log it on every key and unkey and this item is either
  diagnosed or narrowed in one session.
  ✅ **Built 2026-08-22.** `Diagnostics` logs it on key-down, key-up and failed
  key-down, plus every `AudioSessionSignal` as it arrives with the transmit state
  around it, plus (iOS) the route-change reason code. It is on the `AudioIO`
  protocol so `RadioSession` can reach it, and it announces itself at launch so
  silence can be told from a dead instrument:
  `log stream --predicate 'subsystem == "au.charlesmartin.currawong"' --style compact --info`.
  **What to look for first: the hardware rate while idle.** 16000 Hz between
  overs means iOS is holding HFP up and `BLUETOOTH-AUDIO.md` applies; 44100 Hz
  means it is not.
* `AVAudioSession.routeChangeNotification` and its reason code, logged the same
  way. `oldDeviceUnavailable` around an unkey would close the question.
* **Run the same thing on macOS.** There the accessory is an ordinary input and
  output device chosen in System Settings and there is no `AVAudioSession` at
  all, so if the audio survives keying on the Mac and not on the phone, the
  fault is the iOS session and the route, not the pipeline.
  **Done, 2026-08-22, and it points at the iOS session.** On macOS the OS brings
  HFP up on capture start and drops it ~2.1 s after capture stops, so listening
  happens on A2DP and only transmitting is narrowband — the behaviour we want,
  and `BLUETOOTH-AUDIO.md` argues it is the reference. On iOS the standing
  `.playAndRecord` + `.allowBluetooth` session holds SCO up for the whole
  session instead, which is both the permanently-lit LED and — the part that
  matters — **16 kHz receive audio for the entire QSO**. That is a strong
  candidate for "the audio stops being good", and it is a *library* change if it
  is the cause. Not yet confirmed as the cause of the audio *stopping*
  outright; the confirming measurement is the idle hardware rate, named in
  `BLUETOOTH-AUDIO.md` step 1.

**Closed when** a full QSO is held through the accessory — heard both ways, more
than one over, with the last over as good as the first.

### BU-14 — the accessory's PTT button keys for a while and then stops 🔧 OPEN 2026-08-21

**What the operator sees.** The button can be got working — "starts working a
bit" — and then stops. Whether this is BU-13's fault wearing a second face, or
independent, is unknown.

**Answered 2026-08-22: it is BLE GATT.** The button is `FF00/FF01` on the
accessory's BLE peripheral — `0x01` press, `0x00` release, with real edges
(3.088 s measured for a three-second hold, 0.090 s for a tap). So **the second
bullet below is the live one and the first is ruled out**: latching and the
now-playing trap cannot be the cause of a PTT that stops keying, because the PTT
never travels over `MPRemoteCommandCenter` on this device. Details and the full
button map are in `BLUETOOTH-AUDIO.md`.

One new suspect for this item, from the same session: **the release `0x00`
arrives twice**, ~1 ms apart. `applyRuntimeMapping` handles that correctly today
(its release path is deliberately unguarded and idempotent), but any future
handler that toggles per notification would key, unkey, key again and stick —
which is "the button stops working" with the radio left on air, the urgent
failure mode this item already flags.

**Read the accessory note above first.** The single most useful thing here is
knowing which input the button arrives on, because the two answers share no
suspects:

* **If it is `MPRemoteCommandCenter` (PT-4)**, start from the two documented
  traps — latching, and the now-playing app being the only one that receives
  commands. Check what else on the phone has claimed now-playing when the button
  goes dead; check whether the app's now-playing entry is still there. If the
  entry is being lost when the audio engine stops on unkey, that is the *same
  root cause as BU-13* and both items close together — which is the outcome to
  hope for and the reason to instrument the engine stop before anything else.
* **If it is BLE GATT (PT-2/PT-3)**, the suspects are in
  `BLEPTTController`: a mapping learned from a characteristic that also carries
  something else (a keepalive on the press path would key on its own schedule),
  the accessory dropping the link to save power, and the reconnect cap — five
  consecutive failures and the controller stops trying and shows **Try again**,
  which is exactly "it stopped working" from the operator's side. The link-state
  indicator says which; look at it *at the moment it stops* rather than after.
* **Either way**, a press must never survive a link drop keyed. SF-2 says a
  disconnection unkeys unconditionally, and `BLEPTTController` does that first,
  before anything else — a session that goes quiet is acceptable, a session that
  stays keyed is not. Watch for the failure mode where the radio is still keyed
  with a dead button, and if it happens, that is more urgent than the rest of
  this item.

**Stage BU-10 in the same session.** "An accessory keys a backgrounded app" is
the case the Live Activity exists for and the one thing nobody has ever watched;
with an accessory finally in hand there is no reason to make a second session of
it. BU-7's two safety checks want a device in hand too, and the parrot (`55553`)
is the right node for all of it — nobody else's channel is occupied while a
button is being fought with.

**Closed when** the button keys and unkeys reliably across a session of several
overs, with the app backgrounded and the phone locked for at least one of them,
and the operator can tell from the screen whether letting go will unkey them.

### BU-15 — the first transmit after launch does a visible dance 🔬 DIAGNOSED 2026-08-22

**What the operator sees**, on macOS with the Q2L, first transmit of a session:
press PTT → the handset beeps → a pause → the UI flashes red → back to not-red
→ then red, and actually transmitting. Subsequent transmits do not do it, or do
it less. Nothing is broken at the end of it; it just looks like the app changed
its mind.

**Diagnosed, and every step is a component behaving as specified.** The
sequence:

1. Key-down. `beginTransmit` → `audio.startCapture(...)` opens the input.
2. Opening the accessory's input brings the HFP SCO link up. The handset beeps
   at that moment — ~100 ms in, and about 60 ms *before* audio actually flows.
3. Bringing SCO up **changes the engine's configuration**: CoreAudio swaps the
   A2DP device for the HFP device and the rate goes 44100 → 16000 Hz.
4. `AVAudioEngine` posts `.AVAudioEngineConfigurationChange`. The library's
   observer for that is **not** inside `#if os(iOS)`
   (`RadioCore/AudioPipeline.swift:1158`), so it yields `.routeChanged` on macOS
   too — correctly, since the graph really was rebuilt.
5. `RadioSession.handle(_:)` routes `.routeChanged` to
   `resumeAcrossRouteChange()`, which does exactly what SF-3 and its own
   doc comment promise: **stop transmitting** (red off), wait
   `routeSettleNanoseconds` for the graph to settle, then key back down (red on).

So the flash is SF-3 firing on a route change that the act of keying caused.
**Nothing here is a bug in isolation** — which is why it needs writing down
rather than fixing in passing.

**Why mostly the first one.** The dance needs the configuration change to land
*while the engine is already running*. On a warm link — inside the ~2.1 s SCO
linger, or when SCO comes up before the engine finishes starting — there is no
change to observe, so no drop. That makes it timing-dependent rather than
strictly once-per-launch, and an operator on a slow first key-up may see it
again later. **Not measured; inferred.** If this item is picked up, measure
before designing: log every `.routeChanged` with its cause against key-down
timestamps for a dozen presses.

**Why it matters beyond cosmetics.**

* Each resume is a **real key-down** and starts its own SF-1 watchdog. The
  transmission the operator thinks they started is not the one being timed.
* `automaticResumes` is capped at `maximumAutomaticResumes` per hold. Spending
  one of those on every first key-up spends a safety budget on a self-inflicted
  route change.
* It puts a red/not-red flicker in front of the operator at exactly the moment
  they are deciding whether they are on air. The `TransmitActivityRequest` for
  a route-change resume already says "keep holding" rather than blinking the
  banner — the same care has not been taken for the main UI.
* **It blocks the iOS harmonisation** in `BLUETOOTH-AUDIO.md`, which would
  deliberately cause a route change on every key-down. On top of an unresolved
  BU-15 that would move the dance from the first over to all of them.

**Where the fix probably is** — not decided, and deliberately not:

* **Suppress the resume when the route change is one we caused**, i.e. arriving
  within a short window after our own `startCapture` and before
  `isTransmitting` is set. Cheapest, and the risk is obvious: a suppression
  window is a hole in SF-3, and SF-3 is not negotiable. Any such window must be
  bounded, must not span an `await`, and needs a test that a *genuine* route
  change inside the window still drops transmit.
* **Let the route settle before keying at all** — bring the input up, wait for
  configuration to stop changing, then `startTransmit()`. Honest, and pushes the
  163 ms out to maybe 300 ms, which is the cost the operator would actually feel.
* **Accept it and make it legible** — do not surface the intermediate state to
  the UI at all until the first resume has settled. Does not touch the safety
  path, and is probably the smallest honest change.

**Closed when** the first transmit of a session looks like every other one, with
SF-3 still demonstrably dropping transmit on a route change the app did not
cause.

### BU-12 — the app is taller than its window, and the overflow is centred ✅ FIXED 2026-08-21

**What an operator sees.** On a 1440×900 display, with **no channels** — a first
launch — or with a blank AllStarLink channel selected, the connect pane opens with
the mode chooser jammed under the window's toolbar, **no status panel at all**,
and the channel sidebar's "Channels" header and `Add channel` button sitting
halfway down an otherwise empty column.

Nothing is wrong with either of those views. The whole app is taller than the
window it is in, and macOS centres what it cannot fit, so the top of the layout is
above the top edge of the window and the bottom is below the bottom.

**Measured**, by wrapping the panes in `GeometryReader`s and logging
`frame(in: .global)` on every layout pass (the app writes to a file; a `print`
never arrives when the app is launched by `open`):

| View | Frame |
|---|---|
| the SwiftUI root, and the split view | `(0, -187.75, 881, 1293.5)` |
| the detail column | `(288, -135.5, 593, 1241.5)` |
| the session pane — the status panel | `(288, -135.5, 593, 141)` |
| the scrolling pane, holding the connect form | `(288, 6.5, 593, 1099.5)` |
| the sidebar | `(8, 428.75, 280, 105)` |

The window's content view is 881×866, and its content minimum is 760×672, so
nothing is forcing 1293.5 from the AppKit side. The number is what the SwiftUI
root is *offered*.

**Ruled out**, each by building and re-measuring:

* **The `ScrollView`'s ideal height.** `.frame(idealHeight: 240)` on the scrolling
  pane changes nothing, and neither does `.frame(height: 300)` — the pane really
  is 300 tall in the last measurement above and the root is *still* 1293.5. So the
  connect form's height is not what the root is asking for, which was the obvious
  theory and is wrong.
* **The sidebar.** 105 points tall, and centred like everything else: a
  consequence, not a cause. `.frame(maxHeight: .infinity)` on it makes the visible
  symptom worse (the header goes off the top instead of sitting halfway down) and
  changes no measurement, so the top-alignment it deserves is being kept back
  until this is fixed rather than shipped into a broken layout.
* **A `GeometryReader` clamp** on the detail column. It reports 1241.5 — the
  overflowing height — so there is nothing constrained to clamp *to*. Whatever
  proposes the height is above the root view.
* **`.frame(minHeight: 620)`** on the detail column: 620 is less than 866, so it
  cannot be the demand. It stays as documentation of what the fixed region needs.

**Why it matters more than it looks.** The status panel is the one region APP-18
says never hides, and this is the one case where it does — silently, on the
screen a new operator sees first. It is also the same *class* as APP-15 (a rigid
column against a window that can be any height), which suggests the answer is
structural rather than another number.

**Where to look next.** The demand comes from above the SwiftUI root, so the
suspects are the `WindowGroup`/`NSHostingView` sizing on macOS 26 — whether the
hosting view is being given `fittingSize` once and kept — and the window-restore
path (the frame is restored from defaults, which is also how the *stale* 866
arrives). Reproducing on a taller display would say whether it is the display
bound or the sizing.

---

#### What it actually was: the sidebar ✅ 2026-08-21

**`ChannelListView`'s empty state, and one modifier on it.** Both texts in the
sidebar carried `.fixedSize(horizontal: false, vertical: true)` — the usual
spelling of "wrap, do not truncate". A `NavigationSplitView` measures its
sidebar's natural height against an **unspecified width**, wrapping text asked
for its height at no width answers with the height it would need *with one word
per line*, and `fixedSize` turns that answer into a **minimum the layout must
satisfy**. Measured, at 881×866:

| | Natural height |
|---|---|
| `ChannelListView`, hosted on its own | **67** |
| the same view as a split view's sidebar | **1237.5** |
| the whole app | **1249.5**, at y = −175.5 in an 866-point window |
| a bare `Text(…).fixedSize(…)` as a sidebar | **1199** |
| the same `Text` without `fixedSize` | **16** |

Removing both calls puts the split view back at the window's own height, and
nothing is truncated by their absence: a sidebar proposes a real width and
hundreds of points of height, so both texts wrap exactly as they did. The
difference is only in what they *demand* when asked to measure at no width at
all.

**Every one of the four ruled-out theories above was right to be ruled out.**
The connect form is not the cause, which is why pinning the scrolling pane's
height changed nothing, and the sidebar was indeed 105 points tall on screen —
it was *demanding* 1237.5 while being *given* 105. What was wrong was the last
paragraph's conclusion: nothing above the SwiftUI root proposes the height. The
root's child asks for it, from the bottom of the tree.

**One wrong fix, recorded because it passed a test.** Capping the *ask* —
`.frame(idealHeight: 700)` on the root — makes `NSHostingView.fittingSize`
report 700 and stops the hosting view growing, and a test asserting on
`fittingSize` goes green. The split view *inside* it still laid out at 1249.5
and y = −175.5, and the app on screen was unchanged. `fixedSize` publishes a
minimum, and **no ideal caps a minimum**. `WindowSizingTests` therefore asserts
on the frames the hosting view's subtree actually got, not on what it asked for,
and it carries a canary that fails if SwiftUI ever stops measuring a sidebar
this way — at which point the modifier could come back.

**The sidebar's top alignment shipped with the fix**, having been held back for
it: an empty channel list now sits at the top of its column instead of centred
in it.

**Confirmed on screen**, not only in a test: an 881×866 window, an empty channel
list, status panel at the top where APP-18 says it stays, "Channels" and `Add
channel` at the top of the sidebar, and the caption wrapping to three lines.

### BU-7 — the two safety behaviours nobody has watched fire

**Deliberately deferred, 2026-08-20.** Wanted before any public beta; not
wanted badly enough to hold up the testing phase that follows `BU-2`.

Two behaviours the app is supposed to have, neither ever observed on air:

1. **The transmit watchdog unkeys a held button (SF-1).** Hold PTT past the
   configured timeout — Settings carries it since the watchdog was hoisted
   there — and transmit should stop on its own, with the banner saying so.
2. **An incoming phone call drops transmit (SF-3), and PTT works again
   afterwards.** The second half matters as much as the first: a session that
   survives the interruption but can never key again has failed the check.

**Not a protocol question.** The watchdog is `RadioCore.TransmitWatchdog` and
the interruption arrives as an `AudioPipeline` signal that `RadioSession`
consumes, so both paths are identical on AllStarLink, M17 and EchoLink.
Whichever mode is convenient will do; there is no need to run this three times.

Both are covered by unit tests, which is why this is a confirmation rather than
a fault — but SF-1 and SF-3 are safety requirements, and a safety mechanism
that has only ever fired in a test is a claim rather than a fact. The parrot
node (`55553`) is the obvious place for check 1: hold the button, let it time
out, and nobody else's channel is occupied while it happens.

### BU-10 — nobody has seen the Live Activity

**Opened 2026-08-20 with APP-3.** The code is there and every path that ends
transmission is unit-tested against a recording presenter, on both platforms.
Nobody has locked a phone and looked at one.

Two checks, and the second is the one that matters:

1. **It appears, and it goes.** Key up with the app on screen, lock the phone,
   and the activity is on the lock screen; release, and it is gone — *dismissed*,
   not left sitting there in its final state. Then each of the interesting ends
   in turn: the watchdog (which `BU-7` also wants), a phone call, unplugging a
   headset mid-over, hanging up. The one to try twice is a **route change under a
   held button**, which must not blink the activity off and back on — it goes
   honest for about 300 ms (`NOT TRANSMITTING`, "keying back down") and then red
   again, without a new activity.
2. **⚠️ An accessory keying a *backgrounded* app.** This is the case SF-4 was
   written for — a phone in a pocket, screen locked, a fob on the steering wheel
   — and it is the one with a known risk attached: Apple documents
   `Activity.request` as something an app does **while in the foreground**.
   Currawong is *running* rather than suspended when this happens (PD-2 gives it
   the `audio` background mode), which is a different thing from being in the
   foreground, and whether ActivityKit accepts the request in that state is not
   something the documentation settles or a simulator will answer. If it is
   refused, the fix is a design change and not a bug fix — see the note at the
   end of `RadioSession.desiredActivity`: the activity would start when the
   *connection* comes up, which is always a foreground action, and go red on
   transmit rather than being created by it. `TransmitActivityController` does not
   care which of the two it is driving, so the change is confined to
   `desiredActivity`.

**Also unobserved, and deliberately not handled:** an operator who has turned
Live Activities off, for the app or for the device. `ActivityKitPresenter` checks
`areActivitiesEnabled` and quietly does nothing, so SF-4's lock-screen half is
absent and nothing says so. Telling them would mean a new `SafetyNotice` kind and
a settings row, which is a bigger change than APP-3 was asked for; the on-screen
banner is unaffected either way. Worth deciding before public beta, with `BU-7`.
