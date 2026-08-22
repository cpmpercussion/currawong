# Bluetooth accessories, HFP, and why the two platforms differ

> 📄 **If you are picking this up cold, read `HANDOFF-BU14.md` first.** This file
> is organised by discovery rather than by conclusion, and several of its sections
> are superseded by later ones in the same file. The handoff is the summary, with
> the eleven attempts and why each failed.

What a Bluetooth speaker-mic actually does, measured against a TIDRADIO Q2L on
2026-08-22. This exists because the accessory note in `BRINGUP.md` asked one
question — *how does this thing attach?* — and could not tell `BU-13` from
`BU-14` until it was answered. It is answered here.

Read this before touching `AudioIO.swift`, `BLEPTTController.swift`, or the
session policy in the library's `RadioCore/AudioPipeline.swift`.

## The answer: it attaches twice

The accessory note offered two possibilities — classic handsfree with an
AVRCP/HID button, or a BLE peripheral — and guessed it would be one of them.
**It is both, simultaneously, as two Bluetooth devices with different
addresses.**

| | Address (Q2L) | Carries |
|---|---|---|
| Classic | `DC:C8:15:5A:3B:9A` | HFP + A2DP + AVRCP — the mic and speaker, and three of the buttons |
| BLE | `DC:C8:15:DD:46:58` | GATT, advertising service `0xFFE0` — the PTT button, and only that |

Same advertised name (`TID-MIC-Q2L-0aaf`), same `DC:C8:15` OUI, two independent
links. **Pairing the headset does not get you the button**, and nothing receives
a button press until a central connects to the BLE peripheral and subscribes.

### Which button goes where

| Button | Transport | Signal | Which PT item |
|---|---|---|---|
| **PTT** | BLE GATT | `FF00/FF01` notify: `0x01` press, `0x00` release | PT-2 / PT-3 — `BLEPTTController` |
| CH+ | Classic AVRCP | Next Track | PT-4 — `RemoteCommandPTT` |
| CH- | Classic AVRCP | Previous Track | PT-4 — `RemoteCommandPTT` |
| Vol +/- | Classic AVRCP | absolute-volume notification, `0x00`–`0x7f` | none — the OS consumes these |

So **the PTT is a BLE item, not a PT-4 item.** That settles the branch point in
`BU-14`: the suspects are in `BLEPTTController`, and the two documented PT-4
traps — the latching button, and only the now-playing app receiving commands —
**do not apply to the PTT on this device.** They do apply to CH+/CH-, which
arrive as ordinary media keys and today skip tracks in whatever app owns
now-playing.

Two properties of the PTT worth knowing before writing a handler:

* **Real press and release edges.** Measured 3.088 s for a three-second hold and
  0.090 s for a tap, so hold-to-talk is viable. This is not a latching button.
* **The release `0x00` is sent twice**, about 1 ms apart. A release handler must
  be idempotent. `applyRuntimeMapping` already is — its release path is
  deliberately unguarded — and a toggle-on-each-notification handler would key,
  unkey, and then key again and stick.

The volume keys need no handling at all: the handset is an absolute-volume
controller, so it reports its own level and the OS follows.

## What HFP costs, measured

HFP is the only Bluetooth profile that carries a microphone. A2DP is
output-only, so the moment the app wants the accessory's mic it is on HFP, at
16 kHz mono, over a SCO link.

Bringing that SCO link up, on macOS, from cold:

| | |
|---|---|
| capture start → first audio sample | **160–164 ms** (median 163 ms, n=9 over two runs) |
| of which: engine start → eSCO requested | ~55 ms |
| of which: eSCO requested → `HFP streaming: on` | 47–104 ms |
| SCO linger after capture stops | **~2.1 s** ("Delayed Transport Disconnect") |

**The SCO handshake is not additive.** The total sat at 163 ms ±2 ms while the
internal split swung between 47 and 104 ms, which means the handshake completes
*inside* CoreAudio's fixed startup window rather than adding to it. The
bottleneck is the audio graph starting, not Bluetooth.

The ~2.1 s linger matters more than the 163 ms: back-to-back overs inside two
seconds reuse the warm link and pay nothing. Only the first key-up after a pause
costs 163 ms, and that is also the only one that makes the handset beep.

## macOS is the reference behaviour. Do not "harmonise" it away

On macOS there is no `AVAudioSession`. CoreAudio brings HFP up when a client
opens the input device and drops it ~2.1 s after the last client closes. The
consequence is the behaviour we want:

* **Listening happens on A2DP** at 44.1 kHz stereo.
* **Transmitting switches the whole device to HFP** at 16 kHz mono.
* **Unkeying switches it back**, on the OS's own initiative
  (`HFP shim Requesting Reconfigure output device to Best sample rate After 2sec`).

`bluetoothd` maintains two separate audio device objects for the one accessory
and swaps `mCurrentAudioDevice` between them, so this is the OS's design rather
than an accident.

**This aligns exactly with simplex operation.** On a simplex channel nobody
listens and talks at once, so the output dropping to narrowband during transmit
costs nothing real, and the operator gets hi-fi receive audio for free. The red
LED tracks the SCO link, so on macOS it tracks transmit, which makes it a usable
TX indicator.

> ⚠️ **Corrected 2026-08-22.** An earlier version of this file said the
> handset's *beep* was the SCO-established tone, landing ~100 ms into the
> key-up and ~60 ms before audio flows. **That was wrong.** On iOS the Q2L was
> observed beeping on every button press with SCO down the whole time, so the
> beep is the handset's own button feedback and says nothing about the audio
> link. The 163 ms figure above is unaffected — it was measured from
> `coreaudiod`/`bluetoothd` timestamps, never from the beep. The LED, unlike the
> beep, really does track SCO.

> **Therefore: the fact that macOS holds SCO only while transmitting is a
> feature, not an inconsistency to be fixed.** A future change that makes macOS
> hold HFP open for the whole session — for symmetry with iOS, or to shave the
> 163 ms — would trade hi-fi receive audio and a meaningful TX indicator for a
> saving the operator did not ask for. Do not make it.

## iOS does not match, and iOS is the one that is wrong

The library sets, for iOS only
(`RadioCore/AudioPipeline.swift`, `SessionPolicy`; RC-11):

```
category .playAndRecord
mode     .voiceChat
options  [.allowBluetooth, .defaultToSpeaker]
```

`.allowBluetooth` is `AVAudioSession.CategoryOptions.allowBluetoothHFP` under
the iOS 26 SDK — same option, same value `0x4` — and it selects the hands-free
profile. It is *required* to reach the accessory's microphone.

The problem is duration, not selection. **An active `.playAndRecord` session
with HFP selected holds the SCO link up for the whole session, not just while a
tap is installed.** Two costs follow, and the second is the substantive one:

1. The accessory's LED stays lit the entire time the app is connected, so it
   reports "in a call" rather than "transmitting" and is useless as a TX
   indicator. This is the visible symptom.
2. Received audio is 16 kHz mono for the entire QSO, not just while
   transmitting. **Overstated — see the correction later in this file:** the
   sources are all 8 kHz, so the real cost is a second lossy codec generation and
   unwanted voice processing, which is smaller than this implies.

**Corroborated by the operator, 2026-08-22.** Receive audio was independently
reported as sounding "more normal on macOS than iOS" — noticed from the
listening, without reference to this analysis and before it was written down.
That takes cost (2) from inference to an observation with a mechanism behind it,
and it is the reason this section is worth acting on rather than filing. It is
still not a *measurement*: step 1 below is what turns it into one.

Note what this is *not*: it is not the mic tap. `stopCapture()` tears the tap
down on every release, deliberately, and that is why the system recording
indicator behaves correctly. The SCO link is held by the session's *route*, one
layer below the tap.

### ~~HFP starves the BLE button~~ — WRONG, superseded 2026-08-22

> ### ⛔ This section's conclusion was refuted the same day it was written
>
> A second phone session, with timestamps and `.subscribed`/`.disconnected`
> logging, showed **notifications flowing normally with the route on
> `BluetoothHFP` at 16000 Hz** — both a full learn sequence and runtime
> press/release edges — provided the accessory had been *freshly reconnected*.
> And the button stayed dead with SCO **down** (LED green, route back on A2DP)
> until it was forgotten and retrained.
>
> So HFP state does not determine whether the button works. **The subscription
> dies, silently, and only a fresh connect-and-subscribe restores it.** The HFP
> *transition* remains the likely trigger — the button died immediately after
> `categoryChange` in both sessions — but starvation is not the mechanism and
> the fix is not the session policy.
>
> **Consequences, both important:**
>
> * **The release-edge hazard below is CLOSED.** Releases arrive fine over an
>   established SCO link: two clean instances, 13.3 s and 11.6 s after the press,
>   each more than 10 s after `key-down on air`, with the LED lit until release.
>   The harmonisation is safe to implement as originally sketched.
> * **The harmonisation is *not* the fix for `BU-14`.** It remains the right fix
>   for `BU-17` and for receive quality, which is reason enough — but it will not
>   revive a dead subscription.
>
> The evidence table below is kept because the observations in it are real and
> were correctly recorded. Only the conclusion drawn from them was wrong: with no
> `.subscribed` logging at the time, a dead subscription and a starved link were
> indistinguishable.

### The observations (conclusion superseded above)

**Measured on iOS, 2026-08-22, with `Diagnostics` streaming from the phone.**
The accessory's PTT notifications are delivered when the route is A2DP and are
**not delivered at all** when the route is HFP:

| Phase | Route | PTT presses | Notifications |
|---|---|---|---|
| Learn mode, before connecting | `BluetoothA2DPOutput` 44100 Hz | several | **all delivered** — full learn sequence, both edges |
| After `categoryChange` | `BluetoothHFP` 16000 Hz | several | **none** |
| App backgrounded (session deactivated) | `BluetoothA2DPOutput` 44100 Hz | ~25 | **all delivered** |
| Foreground + connected again | `BluetoothHFP` 16000 Hz | several | **one**, at the transition instant, then none |

Four transitions, and the button tracked the route every time.

> **Read the "one" in that table carefully — it corrects the row above it.** The
> single cycle delivered after `categoryChange` was a *complete* one: press,
> release **and** the duplicate release, all three delivered with the route
> already `BluetoothHFP`. So the discriminator is **not** the route label. It is
> whether the **SCO link is actually established**, which happens when IO starts
> — during the key-down — and lags the category change by the ~163 ms measured
> above. That press landed before SCO was up; its release, 90 ms later, was still
> inside the setup window; everything after SCO settled was starved.
>
> **This inverts which case is dangerous.** A tap's release outruns SCO and gets
> through. A real over — hold for several seconds, release long after SCO is
> established — releases squarely into the starved window. The failure mode is
> therefore worst for *normal operating practice*, and any experiment must use a
> multi-second hold. A tap will look fine and prove nothing.

The link never reported a disconnection — `linkState` stayed `.connected` throughout, and the
accessory pane went on saying so while nothing arrived. **The link-state
indicator alone cannot be trusted to tell you the button is alive.**

Mechanism not yet distinguished, and it matters for the fix:

* **Coexistence starvation.** SCO is a reserved, periodic voice channel; BLE
  connection events on the same 2.4 GHz radio get squeezed. macOS logs show
  explicit machinery here (`Server.MacCoex`, `Server.Coex`, and sniff-parameter
  adjustment that counts SCO connections).
* **The handset changes mode.** The Q2L may stop reporting the button over BLE
  while it is in an HFP call, on the assumption the host will take the button as
  a hook-switch instead. This fits the device class and fits the operator's
  original description of a "PTT mode".

**Why this makes macOS work and iOS fail.** Same accessory, same app code. On
macOS SCO is up only while transmitting, so the button is free the rest of the
time — which is all the time that matters, because the *press* is what has to
get through. On iOS SCO is up for the whole session, so the button is dead for
the whole session.

#### Correction: the receive-quality cost was overstated

Written down because it was the main argument for `BU-17` and it does not survive
contact with what the three modes actually carry:

| Mode | Codec | Rate |
|---|---|---|
| AllStarLink / IAX2 | µ-law (G.711) | 8 kHz, 64 kbit/s |
| EchoLink | GSM 06.10, 33-byte frames | 8 kHz, 13 kbit/s |
| M17 | Codec2 mode 3200 | 8 kHz, **3.2 kbit/s** |

**Every source is 8 kHz.** A 44.1 kHz A2DP link cannot add information that was
never in a 3.2 kbit/s Codec2 stream, so "16 kHz for the whole call" was never the
cost it was described as here. The sample-rate comparison was the wrong axis.

**The operator's ear was still right, and the mechanism is different.** Two
things happen on the HFP path that do not happen on A2DP, and neither is about
bandwidth:

1. **Tandem coding.** The already-lossy 8 kHz stream is re-encoded by SCO's own
   codec — mSBC at best, CVSD at worst — so it goes through a *second* lossy
   generation. A2DP's SBC at 44.1 kHz is close to transparent by comparison
   against an 8 kHz source. Cascading two low-rate speech codecs is audibly
   worse than either alone, and this is the more likely explanation for
   "more normal on macOS than iOS".
2. **`.voiceChat` voice processing.** The mode exists for echo cancellation and
   the routing a call wants, and it brings noise suppression and AGC with it.
   Applied to *received* radio audio — which is not a near-end voice being echoed
   — that processing has nothing useful to do and can thin or pump it.

So `BU-17` retains a real but much smaller benefit: avoiding a second codec
generation and unwanted DSP on audio that is already at the limit. Not enough on
its own to justify a suppression window in SF-3, which is why the
deprioritisation above stands — but the reason is "the gain is small", not "there
is no gain".

### The handset's beep is transmitted, 2026-08-22

Heard at the far end through the EchoLink test server: press PTT, and the beep
arrives at the receiving station. So **the over begins before the handset
beeps** — the microphone is already live and carrying audio by the time the tone
is produced.

Two consequences, one operational and one a correction:

* **Every over starts with a beep going out.** Not merely a local cue: it is on
  air. Worth knowing before anyone uses this accessory on a busy channel.
* **The beep is useless as a "you may speak now" cue**, which is the opposite of
  what an earlier note in this file suggested. By the time you hear it you have
  already been transmitting for its duration. The LED remains the only indicator
  worth reading, and it tracks the SCO link.

This also refines the earlier correction rather than reversing it. The beep is
*not* the SCO-established tone — it was observed with SCO down, on a
backgrounded app, so the handset does beep on a button press by itself. But when
a transmission *is* starting, the tone lands after the audio path is open and
therefore goes out with the over. Both observations hold; the beep simply is not
a reliable indicator of anything the app can use.

## Inflection point, 2026-08-22: reliability over the indicator

After two failed attempts at `BU-17`, the operator settled the priority:

> "I might be ok with red light all the time as long as PTT worked."

That reorders the remaining work, and it is worth stating plainly because most of
this document was written while chasing the other goal.

### The LED is not what blocks the button

They look linked and are not. Both are consequences of one event:

* The LED tracks the **SCO link**, which lights when the session activates HFP.
* The button dies **at that transition**, not because HFP is up.

The decisive pair of observations, both measured on the phone:

1. After a fresh reconnect the button works **perfectly with the LED lit** and the
   route on `BluetoothHFP` at 16 kHz — press, release and the duplicate release
   all delivered.
2. The button stayed dead **after** the LED went out and the route returned to
   A2DP, until the link was rebuilt.

So HFP state does not gate the button. The HFP *transition* kills the BLE
subscription and nothing recovers it; the LED stays lit for the same reason the
session stays active. Correlated, not causal.

### What follows

* **`BU-17` is deprioritised, not solved.** Its remaining route needs a
  suppression window on the transmit path — an SF-3 decision — and the operator
  does not want the thing it buys badly enough to pay that. The two partial
  options stay recorded for whoever wants the battery and idle-LED win later.
* **`BU-14` is the work.** Not "stop HFP being held" but "make the accessory
  link survive the transition, or recover from it without the operator
  noticing".
* **The receive-quality cost stands and is now a known, accepted limitation on
  iOS**: 16 kHz mono for the whole call, where macOS gives 44.1 kHz between
  overs. It is a documented platform difference rather than an open defect.

### Where reliability work should go next

The repair as it stands fires once per route change, with a four-second cooldown
and **no check that it worked** — and it demonstrably does not always work: a
full reconnect was observed completing and leaving the button dead. The obvious
next move, and the one the evidence supports:

> **Escalate.** After a repair, if nothing has arrived on the link within a few
> seconds, repair again — bounded, a small number of attempts, and only ever
> while idle so `SF-2` is untouched. Give up loudly rather than quietly, since
> `isButtonVerified` already drives an honest indicator and a Reconnect button.

That is safe in a way `BU-17` was not: it runs between overs, never on the
transmit path, and touches no requirement.

## `BU-14`: the BLE subscription dies silently and never recovers

**Established 2026-08-22, second phone session.** The accessory's notifications
stop arriving and the app never notices:

* `linkState` stays `.connected`, and the accessory pane goes on saying so.
* **No `.disconnected` event is delivered** — the logging for it was added
  specifically to check this, and it stayed silent through both dead periods.
* The subscription is dead in *both* route states: the button did not work with
  SCO up, and it did not work after SCO dropped and the route returned to A2DP.
* **A fresh connect-and-subscribe fixes it every time.** Forget-and-retrain
  restored it twice, and immediately afterwards notifications flowed with the
  route on `BluetoothHFP` — the state that supposedly starved them.

**Trigger versus state.** In both sessions the button died immediately after
`categoryChange` took the route to HFP, so the *transition* is the suspect. The
plausible mechanism is that the accessory drops or renegotiates its BLE link when
it enters hands-free call mode, and iOS never surfaces the disconnection. The
*state* is not the problem: once re-subscribed, HFP is fine.

**The fault, stated for a fix.** Not "HFP breaks BLE" but: **the app trusts
`.connected` and has no way to notice that a subscription has stopped
delivering.** There is no liveness check, and CoreBluetooth is not telling it
anything.

**Answered 2026-08-22: a bare re-subscribe revives it, but not reliably.**
Tested with "Teach it again", which calls
`subscribeToAllNotifyingCharacteristics` without reconnecting when the link is
already `.connected` — confirmed from the log by the *absence* of any
`link -> connecting` or `DISCONNECTED` line:

```
[1237.360] route changed: reason=categoryChange → HFP    ← button killed
[1251.242] accessory subscribed to 1: AE30/AE02          ← bare re-subscribe
[1253.374] accessory notify FF00/FF01 = 01 (learning)    ← revived
```

Then, after the button was killed again, **five** further bare re-subscribes
(`1276.3`, `1290.9`, `1294.4`, `1299.6`, `1308.6`) revived nothing at all.

**The sharpest part of that result: every one of those five subscribes was
reported as successful.** `didUpdateNotificationStateFor` returned without
error, `subscribedPaths` was populated, and no notification ever followed. So
**subscribe success is not a liveness signal**, any more than `.connected` is.
The only evidence that this link works is data arriving on it.

That kills the cheap fix — "re-subscribe on route change" would work about one
time in six — and specifies the real one:

> **Re-subscribe, then verify, then escalate.** Attempt a re-subscribe; if no
> notification arrives within a bounded window, disconnect and reconnect. Treat
> neither `.connected` nor a successful subscribe as proof of anything.

The escalation has to be designed around `SF-2`: a disconnect unkeys
unconditionally, so a reconnect cycle must not be triggerable while transmitting,
or it becomes a mechanism for dropping the operator mid-over. The safe window is
between overs — which is also when the operator is not looking, so it wants to
be silent when it works and visible when it does not.

### The fix, implemented 2026-08-22

**On an audio route change that finds the session idle, rebuild the link.**

* `RadioSession.handle(.routeChanged)` calls `onIdleAudioRouteChange` — but only
  when `!isTransmitting`, `heldSource == nil` and `!routeResumeInFlight`. **The
  idle test lives there because that is the class that knows the answer**, and it
  is what lets SF-2 stay unconditional: nothing suppresses the unkey, the repair
  simply is not requested while anything is on air.
* `BLEPTTController.audioRouteDidChange()` waits for the route to go quiet
  (`routeSettleDelay`, 1.5 s, injected) and then **disconnects**. The existing
  `.disconnected` path reconnects, so there is one reconnection routine rather
  than two.
* The wait coalesces a burst into a single repair. `BU-17` has route changes
  flapping about once a second, and repairing on each would thrash the link it is
  trying to fix.
* Refused during learn mode, and refused while the accessory itself holds the
  key — the controller's own guard, on top of the session's.

**Why a reconnect and not a re-subscribe** is the measured part: a bare
re-subscribe revived the link **once in six attempts** and reported success all
six times, while a reconnect worked every time it was tried. So this does the
reliable thing on a signal that is observable — the route change — rather than
the cheap thing on a signal that is not.

### Tried on air, and revised — 2026-08-22

**Nine repairs fired, reconnects completed in 1.1–1.3 s, and the button worked
after most of them.** Two things were wrong, both reported by the operator:

**1. It felt slow, and it was.** The first version waited 1.5 s for the route to
go quiet *before* repairing, putting that wait on the critical path: press,
nothing, 1.5 s, 1.2 s reconnect, then a button. Now the repair happens on the
**first** change of a burst and further changes are ignored for
`repairCooldown` (4 s). Same coalescing, none of the latency — and simpler, since
the delay and its task are gone.

**2. A reconnect is not reliable either, and pretending otherwise was the real
fault.** One repair completed in full — disconnect, reconnect, `connected`, all
four subscribes — and the button was still dead. So a reconnect is only *better
odds* than a re-subscribe, not a guarantee, and there is no host-side action
known to always restore this link.

> **That is what made the previous behaviour a genuine failure mode rather than
> an annoyance.** The status panel said **"Accessory ready"**, the accessory's LED
> was lit, and there was no working button and nothing to press. The app was
> asserting something it had no evidence for, and leaving the operator with no
> way out.

So the design goal changed: **stop trying to guarantee the link, and never lie
about it.**

* `isButtonVerified` — false from the moment a link comes up or is rebuilt, true
  only when something actually arrives on it. `.connected` is not evidence and a
  successful subscribe is not evidence; arriving data is the only evidence there
  is.
* The status panel says **"Accessory untested"** rather than "Accessory ready"
  until that happens, at `.working` emphasis rather than solid.
* The accessory pane offers a **Reconnect** button in that state, and says in
  words that the on-screen button always works. An operator who cannot key from
  the accessory now has both an explanation and two ways forward.

**What this does not claim.** The repair is aimed at the *observed* trigger. A
link that dies for some other reason will still strand the button until the next
route change or a manual Reconnect, and there is still no liveness check — because there cannot be a
useful one without either a readable characteristic on the seam (`BLECentral` has
no read) or a definition of "too quiet", which a PTT button legitimately is for
minutes at a time.

Seven tests: the repair itself, burst coalescing, refusal while keyed, refusal
during learn mode, refusal with nothing learned, and both sides of the session's
idle gate.

### Candidate fixes considered

* ~~**Re-subscribe on every `.routeChanged`.**~~ **Ruled out 2026-08-22** — a bare
  re-subscribe revived the link once in six attempts, and reported success every
  time. Necessary as a first step, nowhere near sufficient alone.
* **Liveness detection.** Treat "keyed nothing for N seconds while subscribed"
  as suspicious and reconnect. More general, and needs care not to reconnect
  during a legitimate quiet period — which is most of the time on a radio.
* **Stop trusting `.connected` in the UI.** Independent of the repair and worth
  doing regardless: the indicator claiming a live accessory while nothing arrives
  is what made this take two sessions to find. `lastSignal` already exists; the
  pane could show how long ago it was.

## The session is never deactivated, and iOS keeps re-choosing HFP

Also observed 2026-08-22: **disconnecting from a reflector does not put the
route back.** The LED goes out and then comes back on with no channel connected
at all. In the log that is:

```
route changed: reason=override           in=BluetoothHFP     out=BluetoothHFP  16000 Hz
route changed: reason=override           in=MicrophoneBuiltIn out=Speaker      48000 Hz
route changed: reason=newDeviceAvailable in=BluetoothHFP     out=BluetoothHFP  16000 Hz
```

The session is deactivated and reactivated, `.defaultToSpeaker` briefly wins —
which is the `MicrophoneBuiltIn` line, and **that is the app transmitting from
the phone's own microphone if it happens during an over**, the "sounds like a
pocket" fault `BU-13` warns about, seen live — and then HFP is re-offered and
taken again.

So an active `.playAndRecord` + `.allowBluetooth` session does not merely *start*
on HFP, it **keeps returning** to it, because the category demands an input route
and HFP is the only Bluetooth one on offer. Disconnecting is not enough; only
deactivating the session, or changing the category, releases the accessory.

### Third attempt, 2026-08-22 evening — the linger, with the mechanism in hand

Implemented the same evening the root cause was proven (see `BRINGUP.md`
BU-14: the accessory mutes its own BLE notifications while its Classic side
sits in an *idle* HFP call, so handing the route back between overs is what
lets the button live — this stopped being a receive-quality nicety and became
the `BU-14` fix).

The design differs from both reverted attempts in one place: **the hand-back
to listening happens on a 3 s linger, never inline in `stopCapture()`.** That
is what removes the first attempt's loop — SF-3's transient drop-and-resume
completes inside the linger and re-keys into a session still on radio, so no
category change, no fresh cascade, convergence. `AudioPipelineIO` tracks the
applied policy so the resume's escalation is a no-op rather than a redundant
`setCategory`. SF-3 is not suppressed anywhere: every route change still drops
transmit, and the residual cost is one `BU-15`-style drop-and-resume on the
first over after each hand-back — the same dance macOS does on a cold SCO
link, for the same reason. The linger also mirrors macOS's measured ~2.1 s
SCO linger, sized up to outlast the resume cycle (300 ms settle + engine
start + cascade tail).

The "requirements decision" the section below insists on has been taken:
2026-08-22, with the operator, on the cross-transport evidence — and it did
not require the suppression window after all, only the linger.

### Attempted twice and reverted twice, 2026-08-22. The cause is not enough

**Second attempt, on top of `RC-13`.** With the cause on the signal,
`RadioSession` ignored `categoryChange` for SF-3 and kept it as `BU-14`'s repair
trigger. It half worked, and the half that worked is worth recording: the route
genuinely reached `Playback` at **44100 Hz**, and
`route change not treated as SF-3: categoryChange` fired 23 times in one session.
The goal is reachable.

**It still failed, and here is why the cause alone cannot fix it.** One
deliberate policy switch does not produce one route change. It produces a
cascade:

```
route changed: reason=override           in=none out=BluetoothA2DPOutput 44100 Hz
route changed: reason=newDeviceAvailable  in=none out=BluetoothA2DPOutput 44100 Hz
route changed: reason=categoryChange      in=none out=BluetoothA2DPOutput 44100 Hz
signal routeChanged(engineConfigurationChange) isTransmitting=true held=true
endTransmit reason=routeChanged wasTransmitting=true held=true
```

Only `categoryChange` is self-evidently ours. `override`,
`newDeviceAvailable` and `engineConfigurationChange` are **indistinguishable from
an accessory being unplugged**, and SF-3 must drop transmit for those — so it
did, and keying stayed broken.

**What would actually be needed**, and it is a requirements decision rather than
an implementation one: the app saying *"I am about to change the route, expect a
cascade"* and that window being respected. Which is a suppression window on the
transmit path — precisely where SF-3 exists to hold. The trade is real and
arguable (the window is short, the app initiated it, and the alternative is
permanently narrowband receive audio), but it is **not a call to be made by
whoever next opens the file.**

Cheaper options that do not touch SF-3, both partial:

* **Switch on connect/disconnect rather than per-over.** HFP for the whole QSO
  as now, but released when nothing is connected: fixes the accessory being held
  in a call while idle, and the battery, but not receive quality during a QSO.
* **Accept it on iOS** and record the platform difference. macOS already behaves
  correctly, and the honest version of that is a documented difference rather
  than a fix that breaks keying.

`RC-12` and `RC-13` both stay: the policy is right, the cause is right and it
made SF-3 more precise on its own merits.

### The first attempt, and why the plan below is not enough

**The switch was implemented against `v0.5.4`, tried on a phone, and reverted the
same day.** It made transmitting unusable: keying produced a second of audio and
then stopped, with a route-change notice and the transmit banner cycling.

**A category change is a route change.** `SF-3` requires transmit to be dropped
on a route change, so asking for the radio policy at key-down drops the very
transmission it was enabling, and the automatic resume then does it again:

```
key down → activateSession(radio) → route change → SF-3 drops transmit
         → resumeAcrossRouteChange keys back down → route change → …
```

Every component did what it is specified to do. **The missing piece is a library
capability, not an app fix:** `AudioSessionSignal.routeChanged` carries no reason,
so nothing above the library can tell "the category changed because we asked"
from "the accessory went away". The first must not drop transmit; the second must,
unconditionally. That distinction has to exist before this section can be
implemented, and it belongs in `RadioCore` beside the policy it accompanies.

**Not to be worked around by suppressing SF-3 on the key path.** That is exactly
where SF-3 has to hold: it is the requirement that stops a microphone being left
open when the route moves under a live transmission.

`RC-12` stays — the policy is right and additive, and nothing uses it yet.

### The plan as written, still accurate about the goal

#### Harmonised, 2026-08-22 — implemented against `v0.5.4`

**Done, and it is smaller than the plan below feared**, because the release-edge
hazard turned out to be closed and because `configureSession()` already built the
engine under a recording category:

* The library gained `AudioSessionPolicy.listening` and `activateSession(_:)`
  (`RC-12`, swift-hamvoip#48).
* `configureSession()` activates **radio**, builds the engine under it — that
  ordering is `BU-1` and is why this was safe to do at all — then switches to
  **listening**.
* `startCapture` asks for **radio** again before opening the microphone. This is
  now where the SCO link comes up, which is what the accessory's LED should be
  reporting.
* `stopCapture` hands the route back, **best-effort and non-throwing**: failing
  to return to A2DP is a quality regression, while failing to shut the microphone
  is not, and a stop path must not be delayed by the lesser of the two.

Unverified on air at the time of writing. What to watch: the LED out between
overs, receive audio at 44.1 kHz, and whether `BU-14`'s repair and this start
fighting — the route now changes at every key-down and key-up *by design*, and
the quiet period is the only thing keeping them apart.

### The plan as written before it was done

### How to harmonise iOS to the macOS behaviour

The goal is to state it once: **A2DP while listening, HFP only while
transmitting, switched at key-down and key-up.** That is now the *fix for
`BU-14`* and not only a receive-quality improvement — but the finding above
adds a constraint that breaks the obvious implementation.

> ### ✅ The release-edge hazard — RESOLVED 2026-08-22, kept for the reasoning
>
> **Answered: the release survives.** Two held presses, released 13.3 s and
> 11.6 s after the press and more than 10 s after `key-down on air` had put the
> route on HFP, both delivered their `RELEASE edge` (and its duplicate). The
> LED — which does track SCO — was lit until the release in both. So a hold-to-
> talk design that raises SCO at key-down is safe, and the latched-hold
> workaround below is **not needed**.
>
> What follows is the reasoning as it stood before that test, kept because the
> shape of the argument is worth having if another accessory behaves differently.
>
> ### ⚠️ The release-edge hazard as originally feared
>
> If HFP is what starves the button, then a design that raises SCO **at
> key-down** puts the *release* edge on the wrong side of the boundary: the
> press arrives with SCO down and gets through, SCO comes up, and the release
> arrives into exactly the condition under which nothing is delivered.
>
> **That is key-down with no key-up: a transmitter held open by a button the app
> can no longer hear.** It is the precise failure `SF-2` exists to prevent, and
> it would be *caused* by the change meant to fix `BU-14`.
>
> **On the observed evidence this is a real risk, and the evidence is subtler
> than it first looked.** The one cycle that got through after the route became
> HFP delivered its release fine — but it did so *before SCO had finished coming
> up*, because a tap is shorter than the 163 ms setup. That is not reassurance;
> it is the mechanism showing that only *short* releases survive. A held press
> released after SCO settles is the untested case, and it is the normal one.
>
> So the accessory PTT on iOS **must not depend on the release edge arriving
> over a live SCO link.** Options, none chosen:
>
> * **Latch with a bounded hold.** Treat the press as keying until either a
>   release arrives *or* a timeout expires — with the timeout well inside the
>   `SF-1` watchdog, so the watchdog is the backstop and not the mechanism. This
>   turns an undelivered release into a short over rather than a stuck one.
>   Costs the operator hold-to-talk semantics on iOS, which is a real loss.
> * **Do not raise SCO for the accessory path at all.** Transmit from the
>   *phone's* microphone while the accessory stays on A2DP for receive. The
>   button keeps working, the operator keeps hi-fi receive — and speaks into the
>   phone, which for a speaker-mic in the hand is close to absurd. Listed
>   because it is safe, not because it is good.
> * **Establish whether a release survives an established SCO link.** This is
>   the cheap experiment and it comes first, before any of the above is chosen.
>   **It must use a multi-second hold**, for the reason in the box above: a tap
>   releases inside the SCO setup window and will pass whether or not the hazard
>   is real.
>
>   Two ways to run it, in order of cost:
>
>   1. **On iOS, no re-pairing needed.** Background the app so SCO drops and the
>      button is alive; **press and hold**; bring the app to the foreground while
>      still holding, so SCO rises under a held button; keep holding for several
>      seconds; then release. If the `RELEASE edge` line appears, the release
>      survives an established SCO link and the hazard is closed.
>   2. **On macOS**, where SCO already rises on the transmit path: hold the
>      accessory PTT for several seconds and confirm the release unkeys. Costs
>      re-pairing the accessory away from the phone.
>
> Until that experiment is run, **do not implement the switch.**

Sketched in the order the risk sits, because step 1 is cheap and steps 2–3 are
not.

**1. ✅ Done 2026-08-22 — the diagnosis is confirmed.** The idle hardware rate
during a session is **16000 Hz on `BluetoothHFP`**, against 44100 Hz on
`BluetoothA2DPOutput` before the session is configured. iOS holds HFP for the
whole call, exactly as this section predicted, and the operator's independent
report of worse receive audio is that. Kept below because the instrument is how
the next steps get measured too.

**The instrument now exists** — `Diagnostics` (added under `BU-13`) logs `audioStateDescription()` on
every key-down and key-up, and on iOS logs
`AVAudioSession.routeChangeNotification` with its reason code. Read it with:

```sh
log stream --predicate 'subsystem == "au.charlesmartin.currawong"' --style compact --info
``` What settles it is
the *hardware rate while idle*: 16000 Hz between overs means HFP is being held
and this section applies; 44100 Hz means it is not and the LED has another
cause. **Do not skip this.** Three plausible explanations for the LED were
tried and discarded on 2026-08-22 before this one survived.

**2. Move the HFP option out of the standing category and onto the transmit
path.** The shape that matches macOS is to sit in a category that permits A2DP
playback while idle and request HFP only for the duration of a transmission:

* Idle: a category/option set that routes output over A2DP and does not hold an
  input route. `.playback`, or `.playAndRecord` with
  `.allowBluetoothA2DP` and without `.allowBluetooth`, depending on what
  receive-side playback needs.
* Key-down: switch to `.playAndRecord` + `.allowBluetooth` (+ `.voiceChat`),
  which brings SCO up, then start capture.
* Key-up: stop capture, then switch back.

**This is a library change, in `AudioPipeline`'s session policy, and it must be
cited from here and made there** — Currawong reads the library and never writes
to it. The policy is currently a single static value applied once at activation;
harmonising means it becomes at least two, with a transition. RC-11 moved this
policy into the library precisely so the app would not own it, and that stands.

**3. Budget for the costs, and expect them to be the reason this is hard.**

* **A category switch mid-session is audible.** It re-routes, and the app will
  pay something like the 163 ms again at every key-down — plausibly more on iOS,
  where the session has to deactivate and reactivate rather than just open a
  device. Measure it on the phone before committing; if it lands much above
  ~200 ms the trade may not be worth it, and the honest outcome is to document
  the iOS behaviour as a known difference rather than ship a worse one.
* **A route change drops transmit, by requirement.** SF-3 is not negotiable and
  `resumeAcrossRouteChange()` already implements the drop-and-resume. Deliberately
  causing a route change *on the transmit path* therefore means deliberately
  triggering that machinery on every key-down. See `BU-15`, which is this exact
  interaction observed on macOS and visible to the operator. **Solve BU-15
  first.** Harmonising iOS on top of an unresolved BU-15 would put the startup
  dance on every over instead of just the first.
* **`AVAudioEngine` never revisits its input format.** The 0 Hz bootstrap
  deadlock (`BU-1`) came from an engine built before the session was up. An
  engine that survives a 44100 → 16000 switch is the same hazard wearing a new
  hat, and the existing repair — discard the pipeline and build a fresh one — is
  the one to reuse.
* **Interaction with the SF-1 watchdog.** Each key-down starts its own
  watchdog. If a key-down becomes "switch category, wait, then key", the
  watchdog must start from the moment the operator is actually on air, not from
  the button edge.

**Do not begin this as a refactor.** It is one behaviour change with a
measurement in front of it and a requirement (SF-3) crossing it. If step 1 shows
the hardware rate is already 44100 while idle, none of the rest applies.

## Instruments, for next time

Everything above was measured with tools kept in
`../experiment-data/q2l-ble-probe/` (workspace, unversioned):

* `bleprobe.swift` — connects to the BLE peripheral, subscribes to every
  notifying characteristic, prints timestamped hex. This is how the button map
  was established.
* `scotime.swift` — times capture-start → first audio sample over N cold
  cycles. This is where the 163 ms comes from.
* `sco-timing.log` — correlated `bluetoothd` + `coreaudiod` output.

Two traps in probing, both paid for already:

* **Do not `readValue` characteristics while probing.** A read on
  `894C8042-…B08E` (the one `[read,NOTIFY]` characteristic) returns an empty
  value through `didUpdateValueFor`, which is indistinguishable from an
  unsolicited empty notification and invites a false diagnosis of learn mode —
  which latches the first signal it sees unconditionally. The device volunteers
  no such signal. Currawong only subscribes, so it never sees one.
* **A BLE peripheral takes one central.** A probe left connected will silently
  prevent the app from connecting at all. Kill it before testing the app.

To watch the classic side, `log stream` on subsystem `com.apple.bluetooth` and
grep `Server.Remote` (AVRCP commands, by name, with source address) or
`Server.Handsfree` (SCO setup and teardown).
