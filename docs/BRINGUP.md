# iOS bring-up — getting the app to actually work

Everything in this repository has passed its tests and none of it has keyed a
radio. This file tracks the gap: the work of making Currawong connect to a live
AllStarLink node from an iPhone, key it, be heard, and hear the channel back.

It is deliberately **not** part of the phase plan. `APP-*` and `BLE-*` in
`../swift-hamvoip/docs/DEVELOPMENT-PLAN.md` are features — things the app should
be able to do. The items here are faults: things that are supposed to work
already and do not. They are numbered `BU-n` so a commit can cite one.

## How this work lands

**Directly on `main`. No task branch, no PR, until the app is confirmed working
on air.** The one-task-one-branch rule in the development plan §1 assumes the
change can be judged by reading it and running the tests. These changes cannot:
the only test that matters is a real node, a real iPhone, and a real radio, and
the loop between "change something" and "find out" runs through an on-air
session rather than through CI. Review gates in the middle of that loop buy
nothing and cost a day each.

The normal rules resume the moment `BU-2` closes. Everything else still holds
meanwhile — SPDX headers, the `NetworkClient` seam, `make test` green before
each commit, and no writes to the library repository.

## Definition of done

`BU-2` is the whole effort. The app is working when, on an iPhone, against
the live node:

1. Connect succeeds and the negotiated codec is shown.
2. PTT keys the node, and a second receiver hears the audio and calls it
   intelligible.
3. Channel audio is heard back through the phone, without dropouts, for long
   enough to be sure (minutes, not seconds).
4. Releasing PTT unkeys, and the watchdog (SF-1) unkeys a held button.
5. An incoming phone call drops transmit (SF-3), and PTT works again afterwards.

## Items

| ID | What | Status |
|---|---|---|
| BU-1 | PTT fails immediately: `could not construct an AVAudioConverter for the requested PCM formats` | ✅ **Fixed, confirmed on air 2026-08-11** |
| BU-2 | The on-air session itself — the five checks above | Open — check 2 (keying) confirmed |
| BU-3 | `RadioCore` should expose the audio-session policy without requiring an engine | Open, belongs to the library repo |
| BU-4 | M17 has never been transmitted to a reflector, by this app or anything else | Open — the link comes up, and nothing beyond that is confirmed |
| BU-5 | EchoLink has never been connected from the app, only from the CLI | Open — the whole path works from the CLI, as of 2026-08-13 |

---

### BU-5 — the EchoLink session from the app

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

- **The proxy is chosen, and public proxies are single-user.** A proxy that was
  free an hour ago is often taken, and a taken one accepts the TCP connection
  and then hangs up before sending its nonce. That surfaces as "the proxy
  stream closed" and is not a fault in the app. Try another.
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

### BU-4 — the M17 session

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

### BU-2 — the on-air session

**Check 2 (PTT keys the node) is confirmed, 2026-08-11.** The rest of the five
checks under **Definition of done** are unrun: audio quality as judged by a
second receiver, receive for minutes rather than seconds, the watchdog unkeying
a held button, and an incoming call dropping transmit with PTT still working
afterwards.

Bring the failure text, verbatim, of anything that goes wrong — the alerts are
written to be readable off a phone screen precisely because that is the only
instrumentation available in the field.

Until this closes, changes still land straight on `main` (see **How this work
lands**).

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
