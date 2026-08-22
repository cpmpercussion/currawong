# Bluetooth accessories, HFP, and why the two platforms differ

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
costs nothing real, and the operator gets hi-fi receive audio for free. The
handset's beep and red LED land ~100 ms into the key-up — about 60 ms *before*
audio actually flows — which is better PTT feedback than anything the app could
draw.

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
2. **Received audio is 16 kHz mono for the entire QSO**, not just while
   transmitting. This is a real quality regression against macOS, and it is
   invisible in testing because it sounds like the far end rather than like a
   fault.

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

### How to harmonise iOS to the macOS behaviour

The goal is to state it once: **A2DP while listening, HFP only while
transmitting, switched at key-down and key-up.** Sketched in the order the
risk sits, because step 1 is cheap and steps 2–3 are not.

**1. Confirm the diagnosis before changing anything. The instrument now
exists** — `Diagnostics` (added under `BU-13`) logs `audioStateDescription()` on
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
