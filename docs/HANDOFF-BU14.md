# Handoff — `BU-14`, the accessory button that stops working

> ## ✅ RESOLVED the same evening — read this first
>
> The fresh pair of eyes this document asked for ran §4's experiments instead of
> writing more machinery, and the cause is proven: **the Q2L suppresses its own
> BLE notifications while its Classic side sits in an idle HFP call, and resumes
> them on the same subscription the moment call mode ends.** Established by a
> cross-transport test — Mac holding the BLE link, phone holding the call — so
> no iOS component is implicated. §3's mystery fact (reads work, notifications
> don't) is a property of the accessory, not the stack. macOS "not showing the
> fault" was macOS dropping SCO ~2.1 s after capture: the accessory self-healed
> before anyone pressed. iOS holds the session forever (`BU-17`), so the button
> stayed dead forever. **The fix is `BU-17`'s harmonisation, not link repair.**
>
> Two deterministic bugs in §6's machinery were also found on-device and fixed
> (probe answers swallowed on verified links; probe echoes setting
> `isButtonVerified`) — see the BU-14 section of `BRINGUP.md`, which now leads
> with the full evidence, and `experiment-data/q2l-ble-probe/ios-session12-*` /
> `mac-crosstest-1.log`. The rest of this document is preserved as written, as
> the record of how not to get here.

Written 2026-08-22, at the end of a long single session, for someone picking this
up cold. It exists because that session produced **a new bug after each old one**,
which is a signal that the approach needs a different pair of eyes rather than one
more iteration.

Read this before `BLUETOOTH-AUDIO.md`, which is longer, partly superseded by its
own later sections, and organised by discovery rather than by conclusion.

---

## 1. The fault, in one paragraph

A TIDRADIO Q2L Bluetooth speaker-mic keys Currawong over BLE. On **iOS** the
button works for a few overs and then stops: no notifications arrive, the app
still reports the link connected, and no disconnection is delivered. On **macOS**
the same accessory and the same app code do not show the fault. Everything in
this session was about detecting and recovering from that, and **the cause is
still unknown.**

## 2. Hardware facts — established, reproduced, trust these

The Q2L is **two Bluetooth devices** sharing a name and the `DC:C8:15` OUI:

| | Address | Carries |
|---|---|---|
| Classic | `DC:C8:15:5A:3B:9A` | HFP + A2DP + AVRCP — mic, speaker, CH+/CH-, volume |
| BLE | `DC:C8:15:DD:46:58` | GATT, advertising `0xFFE0` — the PTT, and only that |

| Button | Transport | Signal |
|---|---|---|
| **PTT** | BLE GATT | `FF00/FF01` notify: `0x01` press, `0x00` release |
| CH+ / CH- | Classic AVRCP | Next / Previous Track |
| Vol +/- | Classic AVRCP | absolute-volume notification, `0x00`–`0x7f` |

Other BLE characteristics: `AE30/AE02` (Telink OTA), `FF00/FF21`, `FFE0/FFE1`
(Telink serial), and `89A8591D-…3E24/894C8042-…B08E` — the **only readable one**,
which matters because the liveness probe reads it.

Measured properties:

* **Real press/release edges.** 3.088 s hold and 0.090 s tap. Not a latching
  button.
* **The release `0x00` is sent twice**, ~1 ms apart. Handlers must be idempotent.
* **SCO setup costs 163 ms** median (macOS, n=9), and the handshake completes
  *inside* CoreAudio's fixed startup window rather than adding to it.
* **macOS lingers SCO ~2.1 s** after capture stops.
* **The device sends `.subscribed` eight times per reconnect** — once per service,
  twice over. The readable characteristic is absent from the first round.
* **The handset's beep is transmitted** — heard at the far end via ECHOTEST. The
  over begins before the beep, so the beep is useless as a "mic is live" cue.

## 3. What is established about the fault

* It kills **notification delivery only**. Reads still work — the liveness probe
  answered in ~205 ms on a link whose notifications were dead (§5, attempts
  10-11). **This is the single most surprising fact here**, and it is why a probe
  is not a proxy for the button working: they travel different paths.
* **Nothing reports it.** `linkState` stays `.connected`, no `.disconnected`
  event arrives, and a re-subscribe *reports success* while delivering nothing —
  five in a row did.
* **Only arriving data is evidence.** Neither `.connected` nor a successful
  subscribe means anything. This is the one hard-won rule; do not build on either.
* It is associated with the **end of an over** — the unkey — not with HFP being
  up. Release edges arrive mid-over with SCO established, so SCO does not gate
  delivery.
* A **reconnect** recovers it, usually. A bare **re-subscribe** recovered it once
  in six attempts.
* The accessory **does reach a backgrounded app**: ~25 press/release pairs
  delivered with Currawong in the background.

## 4. What is NOT established — the actual gap

**Why does notification delivery stop?** Never answered. Three candidate
mechanisms, none discriminated:

1. **The accessory renegotiates or drops its BLE link** when entering/leaving
   hands-free call mode, and iOS never surfaces it.
2. **Radio coexistence** between SCO and BLE on one 2.4 GHz controller.
3. **Something iOS-specific in CoreBluetooth** — because macOS, same code, does
   not show the fault.

Cheap experiments that would discriminate, none of them run:

* **Does the vendor's own app suffer it?** If yes, the accessory or the OS is at
  fault and no amount of app code fixes it.
* **Does a different BLE PTT accessory suffer it?** Isolates device from stack.
* **Does macOS suffer it if HFP is forced to stay up** (e.g. keep a capture
  running)? macOS working is the biggest clue available and has never been used
  as a control.
* **Capture the BLE link** with PacketLogger (Apple's Additional Tools) to see
  whether the peripheral stops sending or iOS stops delivering. This is the one
  that would actually answer it.

**Strong recommendation: establish the cause before building more recovery
machinery.** Everything in §5 is recovery built on an unknown, which is why it
kept producing new failure modes.

## 5. Chronology of attempts, and why each failed

The value of this section is negative knowledge. Every one of these looked right.

| # | Attempt | Why it failed |
|---|---|---|
| 1 | Assume the duplicate release toggles transmit | Code already idempotent. Not the fault. |
| 2 | Assume a permanently-installed mic tap | `stopCapture()` already tears it down. |
| 3 | Assume an empty notification poisons learn mode | The empty value was **my own probe's read** coming back. |
| 4 | `BU-17` v1 — hold HFP only while transmitting | A category change **is** a route change, so SF-3 dropped the very over it enabled, then resumed into a loop. Reverted. |
| 5 | `RC-13` — put a *cause* on `routeChanged`, retry `BU-17` | Necessary but insufficient: one switch emits a **cascade** (`categoryChange`, `override`, `newDeviceAvailable`, `engineConfigurationChange`) and only the first is identifiably ours. Reverted. |
| 6 | Repair: rebuild the link on an idle route change | Fired after *every* over, rebuilding links that had just worked. |
| 7 | 3 s quiet period after an over | Suppressed the repair for **exactly the event that kills the link** — bursts at +1.26 s and +2.51 s were swallowed and the button stayed dead 113 s. Withdrawn. |
| 8 | Escalation: retry if no data within 3 s | Measured *operator silence*, not link health. Both "verified"s coincided with a `PRESS edge`. |
| 9 | Liveness probe (read a characteristic) | Reported "no readable characteristic" — a **discovery-progress** fact — as link failure, 24 ms before the readable one appeared. Self-inflicted rebuild loop. |
| 10 | Probe-first: probe, rebuild only on failure | A read on a dead link produces **no callback at all**, so the negative answer needed a deadline; the 10 s backstop became the recovery time. |
| 11 | Shorten the deadline to 1 s | Exposed that the deadline was armed at **rebuild start**, before any probe existed — expired 2 ms after reconnect, three rebuilds in four seconds. Fixed in `613c5ef`; **untested on device.** |

**The pattern in my own errors, stated plainly:** I repeatedly inferred a
mechanism from a correlation, built machinery on it, and only discovered the
mechanism was wrong when the machinery misbehaved. Four times the "fix" was the
new fault. A fresh session should distrust §5 conclusions that are not backed by
a measurement in §2 or §3.

## 6. Where the code stands now

Branch `task/bu-13-key-instrumentation`, PR **currawong#38**. Head `613c5ef`.
651 tests green. Latest build installed on the phone but **the last fix has not
been tried on device.**

* **`Diagnostics`** (`Sources/Currawong/Diagnostics.swift`) — the instrument.
  `os.Logger` plus a **stdout mirror in DEBUG**, because `log stream` cannot reach
  a device (its `--device` flag is gone) and `os_log` does not appear in
  `devicectl`'s console. Read it with:
  ```sh
  xcrun devicectl device process launch --console --device melchior au.charlesmartin.currawong
  ```
  Detaching that console **kills the app**, and locking the phone drops the tunnel.
* **`BLEPTTController`** — the repair. On an idle route change it *probes*; a
  failed or unanswered probe (1 s deadline) buys a rebuild; a rebuilt link is
  probed again; bounded at 3 attempts; coalesced by in-flight **state**, not by a
  clock. `isButtonVerified` is false until data actually arrives and drives an
  honest "Accessory untested" plus a **Reconnect** button.
* **`RadioSession.isIdleForAccessoryRepair`** — the SF-2 gate, asked before every
  rebuild including ones the controller schedules itself. **Do not move this
  decision into the controller:** it cannot see the on-screen PTT.
* **`BLECentral.probeForLiveness` / `.probeFailed`** — the probe. Contract:
  nothing readable *yet* says nothing; only an attempted-and-failed read is
  evidence.

Library, both merged and released in **v0.5.4** / pending: `RC-12`
(`AudioSessionPolicy.listening`) and `RC-13` (`routeChanged` carries a cause,
swift-hamvoip#49). Neither is used by the app right now — `BU-17` is reverted —
but both are correct and additive. The app-side `BU-17` diff is saved at
`experiment-data/q2l-ble-probe/bu17-rc13-app-side.patch`.

## 7. Data

All under `experiment-data/q2l-ble-probe/` (workspace, unversioned):

| File | What it shows |
|---|---|
| `bleprobe.swift`, `hidprobe.swift` | the original transport-map probes |
| `scotime.swift`, `sco-timing.log` | the 163 ms SCO measurement |
| `ios-bu14-session-*.log` | first phone session: the fault, and HFP correlation |
| `ios-session2-*.log` | forget-and-retrain recovering it; the `.subscribed` behaviour |
| `ios-session3/4-repair-*.log` | repair v1 and v2 |
| `ios-session5-bu17-v2-*.log` | the SF-3 cascade that killed `BU-17` |
| `ios-session6-escalation-v1-*.log` | escalation measuring operator silence |
| `ios-session7-probe-*.log` | the "no readable characteristic" loop |
| `ios-session8-eventdriven-*.log` | event-driven repair, still looping |
| `ios-session9-workingish-*.log` | **the best session** — 8 repairs, all verified first attempt, and the 1.6–2.6 s rebuild cost measured |
| `ios-session10-probefirst-*.log` | probe-first, and the 10 s backstop regression |
| `ios-session11-deadline-1s-*.log` | the 1 s deadline, and the evidence for attempt #11: the deadline armed at rebuild start expiring 2 ms after reconnect |

## 8. Deliberate design constraints — do not undo these

* **SF-2 is unconditional.** A disconnection unkeys. Any repair that disconnects
  must be gated on the session being idle, and the gate belongs in
  `RadioSession`. Attempt #4 failed by putting a route change on the transmit
  path; do not "fix" that by suppressing SF-3 there.
* **Only arriving data proves a link works.** Not `.connected`, not a successful
  subscribe.
* **Never probe during learn mode** — a read's value arrives as a notification and
  the learner latches the first signal it sees.
* **`CoreBluetoothCentral` has no tests by construction** (it needs a radio). Its
  contract is prose on the `BLECentral` protocol, and `FakeBLECentral` must mirror
  it. Attempt #9 lived precisely in the gap between them; the fake's probe always
  worked while the device's could not run yet.
* **The dependency is versioned.** For iteration, pin an exact library revision in
  `project.yml` (`revision: <sha>`) and do not commit it. The documented `path:`
  swap does not work: xcodegen rejects a local package outside the project tree,
  and the relative path is wrong from inside a worktree. A `branch:` pin resolves
  to a stale head.

## 9. If I were picking this up

1. **Do not write code first.** Run one of the §4 experiments. The vendor-app
   comparison and the PacketLogger capture are both an hour's work and either
   would tell you whether this is fixable in the app at all.
2. If the cause turns out to be the accessory, the honest outcome is the honest
   indicator plus **Reconnect** — which already exists — and a documented device
   limitation, not more machinery.
3. If it is fixable, note that **session 9 was close**: probe-first with the
   deadline correctly placed (`613c5ef`, untested) may already be adequate. Try
   the existing build before changing anything.
