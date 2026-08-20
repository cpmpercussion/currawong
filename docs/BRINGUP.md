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

It is deliberately **not** part of the phase plan. `APP-*` and `BLE-*` in
`../swift-hamvoip/docs/DEVELOPMENT-PLAN.md` are features — things the app should
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
| BU-3 | `RadioCore` should expose the audio-session policy without requiring an engine | Library fix done (RC-11, `swift-hamvoip` PR #35). Open **here** until a release carries it and this app deletes its copy |
| BU-4 | M17 has never been transmitted to a reflector, by this app or anything else | **Transmit confirmed heard 2026-08-17** — receive proven 2026-08-16, transmit from this app to M17-434 B heard via Mseven, an independent client. Check 5 (the far end sees the stream *end*) ✅ **closed 2026-08-20** as `BU-8`; check 6 folded into `BU-7` |
| BU-5 | EchoLink has never been connected from the app, only from the CLI | ✅ **Closed 2026-08-16** — `*ECHOTEST*` QSO from the app, and VK1RBM heard live off-air |
| BU-6 | Web Transceiver has never been connected from the app, only from the CLI | ✅ **Closed 2026-08-20** — nodes `44309` and `61624` reached from the phone over WT |
| BU-7 | The watchdog unkeying a held button (SF-1) and a phone call dropping transmit (SF-3) have never been observed on air | Open, deliberately deferred — wanted before public beta, not before more of this testing |
| BU-9 | The channel model loses edits, silently repoints named channels, and cannot delete a channel that has been connected to (macOS) | Open — found 2026-08-20 by the on-air UI test. (1) and (2) answered by the maintainer 2026-08-21 and being implemented; (3) is no longer unexplained — the suspect was disproved 2026-08-21 and the cause is most likely the test's own unscoped menu query, unconfirmed while the automation grant is lapsed |
| BU-10 | The Live Activity (SF-4, APP-3) has never been seen on a locked iPhone, and the case it exists for — an accessory keying a backgrounded app — has never been staged | Open, and the last thing between SF-4 and a fact rather than a claim. Unit-tested on every end path; never looked at |
| BU-8 | Nobody has watched an M17 over *end* at the far end — the last-frame flag is sent and read, but the pair has never been observed working together | ✅ **Closed 2026-08-20** — four overs from the app, four `ended — end of over` at an independent observer on `m17-cbr.charlesmartin.au` A. Closes `BU-4` check 5 with it |

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

### BU-3 — the library should not require an engine to set the session category

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

**What is left here, and it waits on a release.** When a tagged version carrying
RC-11 is the floor in `project.yml`, `AudioIO.activateSession()` and the comment
above `configureSession()` explaining why the policy is spelled twice both come
out, and the app calls `AudioPipeline.activateSession()` instead. Two things to
know when doing it:

- The app's `#if compiler(>=6.2)` shim for the `allowBluetooth` →
  `allowBluetoothHFP` rename goes too. The library expresses the options as a
  raw value, which is the same for both spellings, so there is nothing left to
  gate.
- The engine construction in `configureSession()` — "build it here, immediately
  after activation, never before" — is the app's own ordering decision and
  stays. Only the session half is the library's.

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

**3. Delete is dead on macOS for any channel connected to this launch.**
Right-click → Delete is greyed out and does nothing, *after* the link is fully
down — the app reads `Not connected`, the lock label is gone, the row itself is
enabled, and the item is still disabled. A channel never connected to deletes
perfectly well (`ChannelLifecycleUITests` passes), which is what makes this easy
to miss. macOS has no swipe-to-delete, so there is then **no way at all** to
remove that channel from that platform. Ruled out: the menu item's own
`.disabled(!isMutable)`, the order of `.disabled` and `.contextMenu`, `.id()`
on the row, and the session guard in `RadioSession.deleteChannel(_:)` (which is
satisfied). The remaining suspect is the row's context menu not being rebuilt
after the connection state changes.

**Not fixed here, deliberately.** (1) and (2) are one design question — what a
channel *is*, and when an edit belongs to it — and answering it by adding a
`saveDraft()` on quit would make accidental overwrites permanent rather than
merely possible. That is the maintainer's call. (3) is a bug with no design
question in it, but no fix found yet.

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

⚠️ **Not closed, and this is the honest state of it.** The scoped-query queries
are fixed in `ChannelLifecycleUITests` and `M17EndOfOverUITests`, and
`ChannelDeleteAfterConnectUITests` is written to settle it — it arms the lock with
a connect attempt to `192.0.2.1` (TEST-NET-1, so nothing goes on air), records
whether an alert is up and what an unscoped query reports while it is, and then
deletes a bystander channel through a scoped one. **It has never been run:** this
machine's UI-test automation grant has lapsed, and every run dies with `Timed out
while enabling automation mode` before the app launches. Restore the grant in
System Settings → Privacy & Security → Accessibility and run

```sh
xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
    -derivedDataPath DerivedData -destination 'platform=macOS' \
    -only-testing:CurrawongOnAirUITests/ChannelDeleteAfterConnectUITests test
```

The `=== ` prints in its output are the diagnosis. Until then item 3 has a
best-supported cause rather than a confirmed one, and **no production code has
been changed for it** — deliberately, because every candidate fix would have been
a fifth attempt at a mechanism now measured not to happen.

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
