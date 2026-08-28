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

> 📄 **Handing over: read `HANDOFF-BU14.md` first.** Written at the end of the
> 2026-08-22 session, which produced a new bug after each old one and is being
> handed to a fresh pair of eyes. It carries the established hardware facts, what
> is and is not proven about the fault, a table of eleven attempts and why each
> failed, and the cheap experiments that would establish the cause — which is
> still unknown. Everything built so far is *recovery* on top of an unknown cause,
> which is why it kept producing new failure modes.

> 📄 **Fixing `BU-15`: read `HANDOFF-BU15.md` first.** Unlike the one above, the
> diagnosis there is *done* — the fault is traced on a device, second by second,
> and the instrument to re-measure it is built (`scripts/bu15-measure.sh`). What
> is left is a design decision. It also carries the two things that will
> otherwise cost a morning each: the simulator cannot reproduce this fault at all
> and will pass a broken fix, and reading an iPhone's log has a sudo and a
> stopwatch in the way.

**Inflection point, 2026-08-22.** After two failed attempts at `BU-17`, the
operator settled the priority: a permanently lit accessory LED is acceptable if
the button works. **The LED is not what blocks the button** — after a fresh
reconnect the button works with the LED lit and the route on HFP, and it stayed
dead after the LED went out. So `BU-17` is deprioritised rather than solved, its
receive-quality cost becomes an accepted iOS limitation — **and it is a smaller
cost than earlier entries here claimed**: all three modes are 8 kHz at source
(µ-law, GSM 06.10, Codec2 3200), so A2DP's extra bandwidth buys nothing, and what
HFP actually costs is a second lossy codec generation plus `.voiceChat`
processing. `BU-14` — making the
accessory link survive the HFP transition or recover from it unnoticed — is the
work. See `BLUETOOTH-AUDIO.md`, which now leads with this.

**Added 2026-08-21: the first accessory.** A TIDRADIO Q2L speaker-mic with a PTT
button is in hand, and neither half of it works for long — `BU-13` (the audio
stops after keying) and `BU-14` (the button stops keying). **Probed properly on
2026-08-22**, which answered the question both items were waiting on — the
device attaches as *two* Bluetooth devices, and the PTT is BLE rather than a
media key — and turned up `BU-15` on the way. **Then, on the phone the same day,
`BU-14`'s root cause: the button's BLE notifications are not delivered while the
audio session holds HFP up, which on iOS is always.** `BU-16` and `BU-17` came
out of that session too, and `BU-10` got its first evidence — the accessory does
reach a backgrounded app. The transport map, the measured
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
| BU-10 | The Live Activity (SF-4, APP-3) has never been seen on a locked iPhone, and the case it exists for — an accessory keying a backgrounded app — has never been staged | **First data 2026-08-22 (evening), staged live:** the accessory's press and release edges **do reach the locked app** — the BU-17 listening policy is what makes that possible, since a held HFP call would have muted them at the accessory. What fails is the next layer: escalating the parked session (`Playback`, `route=none`) to `.playAndRecord` from the locked state is refused with `'!int'` (OSStatus 560557684, cannot-interrupt-others) on both the attempt and the retry, so the key-down fails and the `CaptureUnavailable` alert — correctly carrying the whole audio state — waits for the unlock. The next unlocked over worked; nothing wedged. So locked-phone PTT now fails at **session activation**, one layer later than before (silently muted button), and that is the question this item now owns: whether an `audio`-background-mode app can activate a recording session from the lock screen at all without the excluded frameworks (PD-4), or whether the session must be kept warm across the lock. Evidence in `experiment-data/q2l-ble-probe/ios-session13-*.log` at t=636.7 |
| BU-8 | Nobody has watched an M17 over *end* at the far end — the last-frame flag is sent and read, but the pair has never been observed working together | ✅ **Closed 2026-08-20** — four overs from the app, four `ended — end of over` at an independent observer on `m17-cbr.charlesmartin.au` A. Closes `BU-4` check 5 with it |
| BU-11 | An empty rounded panel hangs under the Channel name field on launch, with no interaction | **Diagnosed 2026-08-21, and it is not ours.** It is AppKit's *one-time-code* AutoFill panel — `NSAutoFillHeuristicController` → `SPSafariPlatformSupport`, remote content from `com.apple.SafariPlatformSupport.Helper` — shown with nothing to offer. It goes when the app is re-signed with no entitlements. No public API turns it off; **no app-side fix, and nothing to do but decide whether to report it** |
| BU-12 | **On a short display, the whole app is taller than its window and macOS centres the overflow** — the status panel ends up above the top edge and the sidebar's contents halfway down. Reproduced with an empty channel list, which is a first launch | ✅ **Fixed 2026-08-21.** It was the **sidebar**, not the connect form: a wrapping caption with `.fixedSize(horizontal: false, vertical: true)`, which a `NavigationSplitView` measures at an *unspecified width* — one word per line — and which `fixedSize` then makes a minimum. `ChannelListView` is 67 points tall on its own and demanded 1237.5 in the sidebar. Both `fixedSize` calls are gone, nothing is truncated by their absence, and the sidebar's held-back top alignment shipped with it |
| BU-13 | **A Bluetooth speaker-mic works for a while and then stops carrying audio, and keying is what stops it** — TIDRADIO Q2L, first accessory of any kind this app has met | Open, **not yet reproduced under instrumentation**, 2026-08-21. First suspect is `stopCapture()` stopping the whole engine on every unkey (see the `AudioIO` type note) against a route that goes away with it |
| BU-14 | **The accessory's PTT button keys the app for a while and then stops** — same device, and possibly the same root cause or possibly nothing to do with BU-13 | **ROOT CAUSE PROVEN 2026-08-22 (evening): the accessory itself suppresses its BLE notifications while its Classic side sits in an idle HFP call.** Cross-tested with the Mac holding the BLE link while the phone held the call: zero notifications with the LED red, the same subscription delivering again the moment call mode ended — no reconnect, no re-subscribe. Reads answered throughout, which is how every probe lied. iOS shows it and macOS never did because iOS holds the session forever (`BU-17`) while macOS drops SCO ~2.1 s after capture — so `BU-14` **is** `BU-17`, and the fix is releasing the session when idle. Not fixable by link repair; the day's two probe-machinery bugs are fixed regardless. **Fix verified on air the same evening** (see BU-17): ten-plus consecutive overs, every press after a completed hand-back delivered — the press that always died. Still open for the closure criteria only: an over with the app backgrounded and the phone locked (stage with `BU-10`) |
| BU-16 | **A tap outruns the key-down, so the radio keys *after* the button is released** — the press begins an async key-down that costs ~163 ms on a Bluetooth accessory, and the button's edges are 90 ms apart | **Diagnosed 2026-08-22, ✅ fixed the same day.** Safe — the release had already cleared `transmitDesired` and the next apply unkeyed — but the operator transmitted after letting go. A latency fault, not a race. Fixed by reversing the key-down: `link.startTransmit()` first (milliseconds, so the carrier is up with the press), then `startCapture`; and a release that lands at the new suspension point abandons the key-down, unkeying without ever opening the microphone, so a tap now produces nothing at all. Three tests, one delivering the release from inside the awaited call. **Not yet confirmed on air** — what wants watching is the first over's audio against an already-keyed link. ⚠️ **The ordering was reversed again by `BU-15` on 2026-08-23**, and this fix's *purpose* survives it: opening the microphone is itself a route change, so keying the link first guaranteed the SF-3 drop `BU-15` is about. Audio bring-up now comes first and the carrier follows it, which costs the far end nothing — those 163 ms were a keyed-but-silent carrier either way — and improves this item's own case, since a tap this short now never keys at all. `testTheMicrophoneOpensBeforeTheLinkKeys` is the renamed test |
| BU-17 | **The audio session is never released, so the accessory is held in an HFP call whenever the app is foregrounded** — LED lit with nothing connected, receive audio 16 kHz throughout | **Diagnosed 2026-08-22.** `.playAndRecord` + `.allowBluetooth` keeps *returning* to HFP because the category demands an input route. **Promoted the same evening from "blocks BU-14" to *being* BU-14**: the accessory mutes its own BLE notifications for as long as the call is up, so holding the session is what kills the button. **Third attempt implemented and ✅ VERIFIED ON AIR the same evening** — radio only while capturing, listening otherwise, hand-back on a 3 s linger so SF-3's drop-and-resume converges instead of looping (the first attempt's fault). Two more on-air rounds found and fixed: received audio restarting an input-bearing engine re-raised HFP (the hand-back now discards the engine a capture was attempted on), and the redundant `setActive(true)` was refused with `'!pri'` (the downgrade is category-only, and retries). Ten-plus consecutive overs then cycled cleanly: every press delivered, every hand-back completed, LED red only while keyed. Residual: the escalation dance costs ~1 s of the first over's audio after each hand-back — that is `BU-15`/`BU-16` territory and the RC-13 causes are the tool |
| BU-18 | **On macOS the route stays on HFP for the rest of the session after the first over, and the Q2L's red LED never lights at all** — so receive audio is 16 kHz from the first transmit onwards, and the operator has no TX indicator on the handset | **Measured 2026-08-23** while confirming `BU-15`, by polling CoreAudio through an over (`kAudioDevicePropertyNominalSampleRate` and `…IsRunningSomewhere` on the default devices, 50 ms). SCO **does** come up: the default output swaps 44100 → 16000 Hz **1.065 s after the press**, matching the app's own `sigPrep@957`/`carrier@1229`, and the input starts running 63 ms later. So the LED is **not** tracking SCO on this accessory, and `BLUETOOTH-AUDIO.md`'s claim that it therefore makes a usable TX indicator on macOS is wrong — the operator reported the LED dark while transmitting, and the mic demonstrably working (tapped it, saw signal). ⚠️ **The second finding is the bigger one:** the output stayed at 16000 Hz for **69 s** — across the release, across a second over, and through the idle between them — returning to 44100 only at teardown. macOS is *not* holding SCO only while transmitting, which is the premise the whole iOS-versus-macOS asymmetry rests on (`BLUETOOTH-AUDIO.md`: "a feature, not an inconsistency to be fixed"). Likely cause: `discardsEngineOnHandback` is false on macOS, so the engine keeps its instantiated input unit and CoreAudio keeps the HFP route — i.e. macOS has `BU-17`'s fault too, just without the muted button that made it urgent on iOS. Not investigated further; found while confirming something else. Data: `experiment-data/bu15-2026-08-23/13-macos-coreaudio-poll.log` |
| BU-15 | **The first transmit of an over does a visible dance** — press PTT, a pause, the UI flashes red, goes back to not-red, then red and actually transmitting (macOS with the Q2L, where the handset also beeps; and iOS with no accessory at all) | **Diagnosed 2026-08-22, ✅ fixed and confirmed on air 2026-08-23. Three triggers, one mechanism:** keying causes a route change, SF-3 correctly treats it as real, `resumeAcrossRouteChange()` drops transmit and keys back down. On macOS the trigger is the SCO bring-up swapping the A2DP device for the HFP device (44100 → 16000 Hz) and posting `AVAudioEngineConfigurationChange`; on iOS it is `escalateForCapture()`'s `listening` → `radio` category change (BU-17), which needs no Bluetooth. The machinery is working as specified; the operator should not have to watch it. **Not reproducible in the simulator, measured 2026-08-23** (`BU15SessionProbeTests`, iPhone 17 Pro / iOS 26.5, Xcode 26.6): the category change moves the route there — the built-in mic enters and leaves `currentRoute.inputs` on cue — but `AVAudioSession` posts no `routeChangeNotification` for it, nor for `overrideOutputAudioPort` or `setActive`. SF-3 is therefore never triggered, the simulator shows a clean first transmit, and it would report a **false pass on any fix**. Develop the fix against the injected `.routeChanged` signal (`harness.audio.emit`), confirm it on the device. **Traced on air 2026-08-23** (melchior, iPhone 13 Pro / iOS 26.5, M17-CBR module A, **no accessory** — so this is the iOS category-change trigger on its own, as the row above says it should be). One 6.4 s hold, `scripts/bu15-measure.sh`, times relative to the press: `escalateForCapture` at **+0.63 s**, first `key-down on air` at **+0.82 s**, then five `routeChanged` signals in 440 ms, `key-up` at **+1.09 s**, and the second `key-down on air` at **+1.47 s**, steady from there to the release. So: **two key-downs in one hold, one interruption, 385 ms of dead air, and 1.47 s before transmit is stable** — which is the operator-visible dance exactly as described, and the ~1 s BU-17 charged to this row. ⚠️ **`resumes=N` counts scheduled resume *attempts*, not re-keys** — an earlier note here read `resumes=3` as three re-key cycles, which is wrong. Each route change in the cascade schedules its own resume and increments the counter, but `resumeWork` is reassigned without cancelling the previous task, so all three ran and only the first got past `beginTransmit`'s `guard !transmitDesired`; the rest were no-ops. **The cap makes it worse, not safer:** `maximumAutomaticResumes` is 3, the last two signals of the cascade were therefore not resumable, and those take `explain: true` — so the operator gets the "press and hold to transmit again" safety notice **and then the app re-keys itself 115 ms later** off a resume scheduled before the cap was hit. ⚠️ **And the diagnosis was a trigger short.** Opening the microphone instantiates the engine's input audio unit, which posts a route change of its own ~63 ms later — measured 2026-08-23, after a first fix caught the category cascade and the dance survived it. **Fixed by ordering, not by suppression:** escalate, open the microphone, wait for what they disturbed to go quiet, *then* key the far end — nothing is on air for any of it, so SF-3 has nothing to drop and is narrowed nowhere. This reverses `BU-16`'s link-first ordering and loses nothing by it; see the detail section. Data in `experiment-data/bu15-2026-08-23/` (outside the repo, sixteen runs, manifest separated from interpretation). Confirmed on air: one key-down per hold, cold and warm, no notice — on the bare phone (`route=MicrophoneBuiltIn`, 1.03–1.09 s press → carrier cold, 23–31 ms warm) **and with the Q2L as the audio route** (`route=BluetoothHFP`, 0.81 s cold, 23 ms warm), so BU-16's fast path is intact on both. `lastKeyDownRoute` exists because the first Q2L run carried no route field and so could not be checked; see the detail section for what that did and did not establish, and for what was **not** tested — which includes ordinary Bluetooth headphones and the accessory's own button as the PTT source. Residual: the cold over's ~440–500 ms microphone open, which route-conditional policy should remove rather than a shorter wait. ✅ **macOS with the Q2L confirmed 2026-08-23 too**, and it needed one more change: the wait was switched off there by a platform flag, but `startCapture` blocked **798 ms** raising SCO and the configuration change landed **1 ms after the carrier**. The flag is gone — how long the microphone took to open is the evidence that something was raised (cold 421–798 ms, warm 1–35 ms across both platforms), which covers macOS without pretending its policy bookkeeping means anything and stops a Mac on its built-in microphone waiting for a notification nobody will send |
| BU-19 | **On an iPad, connecting takes the top of the status panel off the screen, and an M17 link lands the operator on the reflector directory** — the detail column's fixed 620-point floor is taller than an iPad mini in landscape has once the transmit controls arrive, and APP-18's fallback picked the first pane left rather than the radio | ✅ **Fixed 2026-08-26.** Two faults, one report. (1) `.frame(minHeight: 620)` on the detail column: a demand larger than the window is neither scrolled nor clipped at the bottom — the parent **centres** it, which is `BU-12`'s mechanism, and the edge the status panel is on is the top. The floor is gone; the column takes what it is given and what compresses is the pane *under* the session pane, which is a directory or a settings list and scrolls. (2) A `session` pane, complementing `connect` the way `SessionPaneLayout`'s two halves already do: connected, the radio has the column to itself and Reflectors is a tap away rather than the default. The pane set moved out of `RootView` into `DetailPaneSet`, which is where the landing is now decided and tested |
| BU-20 | **`main` has been red since 2026-08-23 and no PR could see it** — four tests in the iOS-simulator step fail intermittently, and that step is skipped on pull requests (`ci.yml`: `if: github.event_name != 'pull_request'`), so every PR was green while the merge that followed it was not | ✅ **Fixed 2026-08-26.** None of the four was a product fault. Three were observation races in the tests — a cascade whose delivery was assumed rather than waited for, and two waits on *transient* state (the 300 ms gap between an SF-3 drop and its repair) that a poll arriving late misses entirely, then spends its whole timeout on. The fourth was a **fourteen-second scheduling stall**: injected linger, no timer involved, and the hand-back logged 3 ms after the test had given up. Fixed by waiting on monotonic instruments instead of transient ones, by making the cascade wait for the session to *handle* each signal, and by a 20 s default timeout with the measurement written next to it. `AudioPipelineIOTests` also stopped taking the real `AVAudioSession` and the real 3 s linger by default, which is where the `!pri` retry chains in every CI log came from |
| BU-21 | **The `BU-15` preparation gate closes one step before the carrier is up** — a route change handled between `routePreparationInFlight = false` and `isTransmitting = true` is treated as an SF-3 event on a hold with nothing on air, which drops the hold and schedules a repair while the original key-down is still in flight | Open, **found by analysis on 2026-08-26, never observed.** Narrow and self-healing — the transmit work chain serialises, so the carrier comes up and goes down again and the repair keys it back — but the operator-visible result is `BU-15`'s dance, from the one window the `BU-15` fix does not cover. The fix is not obviously "extend the gate": that would swallow a real route change in the window where the carrier is coming up, which is SF-3's business. Wants a decision, not a patch |

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

#### On an iOS device, since 2026-08-23

The target gained an iOS destination so `BU-15` could be reached at all: its
iOS trigger is a route change the **simulator does not report**
(`BU15SessionProbeTests`), so a real iPhone is the only place that fault is
visible. `M17EndOfOverUITests` and the new `BU15FirstOverUITests` both drive
either platform; the `BU-9` delete tests stay macOS-only behind `#if
os(macOS)`, being about the macOS context menu.

**The callsign now comes from the environment.** The old route read it from the
app's real defaults, which works only on macOS — on iOS the runner and the app
are separate sandboxes. Nothing is committed, and a run with no callsign
**skips instead of transmitting**:

```sh
xcrun devicectl list devices          # find the device's identifier
xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
    -derivedDataPath DerivedData -allowProvisioningUpdates \
    -destination 'platform=iOS,id=<device-id>' \
    -only-testing:CurrawongOnAirUITests/BU15FirstOverUITests \
    TEST_RUNNER_CURRAWONG_ONAIR_CALLSIGN=<yours> test
```

`xcodebuild` strips the `TEST_RUNNER_` prefix and passes the rest into the
runner's environment, which is the only way into a UI test process on a device.

**Two device-side grants, neither scriptable**, and both produce the same
`Timed out while enabling automation mode` the macOS Accessibility grant does:

- **Settings → Developer → Enable UI Automation** must be on.
- **The device must be unlocked for the whole run.** A locked phone also fills
  the log with `The device is passcode protected` and makes `xcodebuild` report
  `** TEST FAILED **` *after* a run whose tests all passed — check the result
  bundle before believing the exit status. Set Auto-Lock to Never.

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

### BU-14 — the accessory's PTT button keys for a while and then stops 🔬 ROOT CAUSE PROVEN 2026-08-22

**What the operator sees.** The button can be got working — "starts working a
bit" — and then stops. Whether this is BU-13's fault wearing a second face, or
independent, is unknown.

> ### ✅ ROOT CAUSE PROVEN 2026-08-22 (evening, cross-transport test): the
> ### accessory suppresses its own BLE notifications while in HFP call mode
>
> The decisive experiment split the Q2L's two halves across two machines: the
> **Mac** held the BLE link (subscribed to `FF00/FF01`, receiving clean
> press/release edges), while the **phone** ran Currawong and brought the HFP
> call up on the Classic side via an on-screen over. Result:
>
> * LED red (call up, over ended): PTT presses produced **zero notifications at
>   the Mac** — a different central, OS, and Bluetooth stack from the one that
>   ever showed the fault. The BLE link never dropped.
> * Currawong quit, SCO down, LED cleared: the **same** Mac connection and
>   **same** subscription delivered the next presses immediately. No reconnect,
>   no re-subscribe, nothing repaired.
>
> So the suppression is in the accessory (firmware or its single 2.4 GHz
> radio's scheduling), it is gated on the Classic side being in an **idle**
> call — notifications flow fine *during* an over with SCO streaming, which is
> why release edges always arrived mid-over — and it is fully reversible the
> moment call mode ends. Reads are answered throughout, which is why a liveness
> probe can never see it (§3's "different paths", now explained).
>
> **This resolves the whole contradiction pile below.** The first session's
> "root cause: the audio session" was *right*; its retraction was reasonable on
> the evidence then available but wrong. Why macOS never showed it: macOS drops
> SCO ~2.1 s after capture stops, so the accessory exits call mode and
> self-heals before the next press. iOS never releases the session — `BU-17` —
> so call mode persists indefinitely and the button stays dead indefinitely.
> **`BU-14` and `BU-17` are one fault**, and the fix is `BU-17`'s: release or
> downgrade the audio session when idle (the RC-12 `.listening` policy and
> RC-13 route-change causes exist for exactly this). Why a reconnect "usually"
> recovered it: a fresh subscribe pokes the accessory into pushing again even
> in call mode — a workaround that explains the repair machinery's partial
> successes, not a fix.
>
> The same evening's instrumented run also found and fixed **two deterministic
> bugs in the repair machinery itself** (`BLEPTTController`): a probe's answer
> on an already-verified link was swallowed — the deadline-cancel lived inside
> the unverified→verified transition — so every post-over route change tore
> down a healthy link one second after it had answered; and `isButtonVerified`
> was set by *any* arriving data including the probe's own read echo, which is
> how a dead button was labelled "Accessory ready". Verification now requires
> the button's own signals; a probe answer only ends the repair ladder. Every
> apparent "death" in that run was the first bug, not the underlying fault.
>
> Evidence: `experiment-data/q2l-ble-probe/ios-session12-*.log` (the app side,
> console attached from t=0) and `mac-crosstest-1.log` (the Mac side), with the
> advert witness in `witness-session1.log`.

> ### ⛔ Corrected 2026-08-22 (second session): it is **not** the audio session
> *(superseded in turn by the cross-transport proof above: the observations
> here are all real, but "the subscription dies" was the wrong reading of a
> muted accessory — the subscription was alive the whole time)*
>
> **The BLE subscription dies silently and never recovers.** Notifications stop,
> `linkState` stays `.connected`, and **no `.disconnected` event is delivered** —
> logging added specifically to check that stayed silent through both dead
> periods. The button was dead with SCO up *and* dead after SCO dropped and the
> route returned to A2DP. **Forget-and-retrain fixed it twice, and immediately
> afterwards notifications flowed with the route on `BluetoothHFP`** — the state
> that supposedly starved them.
>
> So the HFP *transition* is the trigger (the button died right after
> `categoryChange` in both sessions, plausibly the accessory renegotiating its
> BLE link on entering call mode) but the HFP *state* is not the mechanism. The
> fault is that **the app trusts `.connected` and cannot notice that a
> subscription has stopped delivering.**
>
> **The iOS harmonisation is therefore not this item's fix.** It stays the fix
> for `BU-17` and receive quality. And the release-edge hazard that gated it is
> **closed**: releases arrive fine over an established SCO link. See
> `BLUETOOTH-AUDIO.md`.
>
> 🔧 **Tried on air 2026-08-22 and revised.** Nine repairs fired and reconnects
> completed in 1.1–1.3 s, but two things were wrong. It **felt slow** — the 1.5 s
> settle was on the critical path — so the repair is now leading-edge with a 4 s
> cooldown. And **a reconnect is not reliable either**: one completed in full and
> the button was still dead. So the goal changed from guaranteeing the link to
> never lying about it: `isButtonVerified` is false until data actually arrives,
> the panel says **"Accessory untested"** instead of "Accessory ready", and the
> pane offers a **Reconnect** button and points at the on-screen PTT. The old
> behaviour — panel claiming ready, LED lit, no possible way to key — was the
> real defect. **Still open: no host-side action reliably restores this link.**
>
> 🔧 **First attempt, superseded by the above.** On an audio route
> change that finds the session **idle**, the accessory link is rebuilt: the
> session decides idleness (`!isTransmitting`, no hold, no resume in flight) so
> SF-2 stays unconditional, and the controller waits 1.5 s for the route to go
> quiet — coalescing `BU-17`'s once-a-second flapping into one repair — then
> disconnects, letting the existing reconnect path do the rest. Refused during
> learn mode and while the accessory holds the key. Seven tests. **What remains
> is watching it work on the phone against the real fault.**
>
> **Answered 2026-08-22: a bare re-subscribe revives it, but only sometimes.**
> One clean success with no reconnect (`categoryChange` at 1237.4 killed it,
> "Teach it again" re-subscribed at 1251.2, notifications at 1253.4), then five
> further bare re-subscribes that revived nothing — **every one of them reported
> as successful.** So neither `.connected` nor a successful subscribe is a
> liveness signal; only arriving data is. The fix is therefore
> **re-subscribe, verify, then escalate to a reconnect** — and the escalation
> must not be able to fire while transmitting, because `SF-2` makes a disconnect
> unkey unconditionally. Details in `BLUETOOTH-AUDIO.md`.

> ~~**ROOT CAUSE FOUND 2026-08-22 — `BU-14` is the iOS audio session.**~~
> *(superseded by the correction above; the observations were right, the
> conclusion was not — with no `.subscribed` logging at the time, a dead
> subscription and a starved link looked identical)*
> The button's notifications are delivered while the route is A2DP and **not
> delivered at all** while it is HFP. Observed across four transitions on the
> phone with `Diagnostics` streaming: ~25 consecutive presses all delivered with
> the session deactivated, zero delivered once `categoryChange` put the route on
> `BluetoothHFP` at 16 kHz, and the link reporting `.connected` throughout.
> "Keys for a while and then stops" is *keys until the audio session comes up*.
> **Refined the same day:** the discriminator is not the route being HFP but the
> **SCO link being established**. One complete cycle — press, release *and*
> duplicate — was delivered with the route already `BluetoothHFP`, because a tap
> outruns the ~163 ms SCO setup. Starvation begins once SCO settles, so the
> danger is worst for a *held* press released seconds later, which is normal
> operating practice. **Any test must use a multi-second hold; a tap proves
> nothing.**
>
> Mechanism — radio coexistence starvation versus the handset changing mode —
> is not yet distinguished, and which it is decides whether the fix is safe:
> see the release-edge hazard in `BLUETOOTH-AUDIO.md`, which must be read before
> anything is implemented. **The fix is the iOS harmonisation, and it is not
> the cosmetic change it looked like.**
>
> Two things follow immediately. **The link-state indicator cannot be trusted**
> — this item's own advice was to look at it when the button stops, and it says
> `connected` while nothing arrives. And **the accessory does reach a
> backgrounded app**: the ~25 delivered presses were all with Currawong in the
> background, which is the first evidence on that question and belongs to
> `BU-10`.

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

### BU-15 — the first transmit of an over does a visible dance ✅ FIXED AND CONFIRMED ON AIR 2026-08-23

**What the operator sees**, first transmit of an over: press PTT → a pause →
the UI flashes red → back to not-red → then red, and actually transmitting. On
macOS with the Q2L the handset also beeps at the start of it. Subsequent
transmits do not do it, or do it less. Nothing is broken at the end of it; it
just looks like the app changed its mind.

**One mechanism, two triggers.** In both cases the act of keying causes a route
change, SF-3 correctly treats that route change as real, and the resume is the
flash. Every step is a component behaving as specified.

The shared tail, from the route change onwards:

* `RadioSession.handle(_:)` routes `.routeChanged` to
  `resumeAcrossRouteChange()`, which does exactly what SF-3 and its own doc
  comment promise: **stop transmitting** (red off), wait
  `routeSettleNanoseconds` for the graph to settle, then key back down (red on).

**Trigger A — the SCO bring-up (macOS, and any Bluetooth accessory).** This is
what the item was first written from, on 2026-08-22:

1. Key-down. `beginTransmit` → `audio.startCapture(...)` opens the input.
2. Opening the accessory's input brings the HFP SCO link up. The handset beeps
   at that moment — ~100 ms in, and about 60 ms *before* audio actually flows.
3. Bringing SCO up **changes the engine's configuration**: CoreAudio swaps the
   A2DP device for the HFP device and the rate goes 44100 → 16000 Hz.
4. `AVAudioEngine` posts `.AVAudioEngineConfigurationChange`. The library's
   observer for that is **not** inside `#if os(iOS)`
   (`RadioCore/AudioPipeline.swift:1158`), so it yields `.routeChanged` on macOS
   too — correctly, since the graph really was rebuilt.

**Trigger B — the category escalation (iOS, no Bluetooth required).** Added by
`BU-17` later the same day, and the reason this item is no longer a
Bluetooth story:

1. Key-down. `AudioIO.escalateForCapture()`
   (`Sources/Currawong/AudioIO.swift:458`) switches the session from
   `AudioSessionPolicy.listening` to `.radio` before opening the microphone —
   `.playback`/`.default`/no options → `.playAndRecord`/`.voiceChat`/
   `[allowBluetooth, defaultToSpeaker]`.
2. **A category change is a route change**, with no accessory involved at all.
   It produces the cascade the `BU-17` comment in that same file enumerates:
   `categoryChange`, `override`, `newDeviceAvailable`,
   `engineConfigurationChange` — and only the first is self-evidently ours.
3. Same tail, same flash. The comment at `AudioIO.swift:441` already says so:
   "one `BU-15`-style drop-and-resume on the first over after each hand-back …
   the same dance macOS does on a cold SCO link."

So the flash is SF-3 firing on a route change that the act of keying caused.
**Nothing here is a bug in isolation** — which is why it needs writing down
rather than fixing in passing.

> ⚠️ **On iOS a flash has three possible causes; diagnose which is in play.**
> Trigger B above (this item). `BU-16` — a tap outruns the key-down path, so the
> transmitter keys after the button is already released; that needs the ~163 ms
> SCO bring-up to outrun, so it does not apply with no accessory connected.
> Or trigger A, if an accessory is connected. An earlier version of this section
> said the iOS flash was *always* `BU-16`; that was written before `BU-17`
> introduced trigger B, and it is no longer true.

**Why the first one of an over, not the first of a session.** The dance needs
the route change to land *while the engine is already running*. For trigger A
that means a cold SCO link: on a warm one — inside the ~2.1 s SCO linger, or
when SCO comes up before the engine finishes starting — there is no change to
observe, so no drop. For trigger B, `escalateForCapture()` skips the category
change when the session is already `radio`, so back-to-back overs are clean and
an over that starts after the `listeningLingerNanoseconds` hand-back (3 s,
`AudioIO.swift:236`) re-escalates and dances again. Both make it
timing-dependent rather than once-per-launch — the original "first transmit
after launch" framing was the macOS symptom, not the rule. **Not measured;
inferred.** If this item is picked up, measure before designing: log every
`.routeChanged` with its cause against key-down timestamps for a dozen presses,
on both platforms.

**Why it matters beyond cosmetics.**

* Each resume is a **real key-down** and starts its own SF-1 watchdog. The
  transmission the operator thinks they started is not the one being timed.
* `automaticResumes` is capped at `maximumAutomaticResumes` per hold. Spending
  one of those on the first key-down of every over spends a safety budget on a
  self-inflicted route change — and with trigger B that is *every* over that
  follows an idle gap, not an occasional cold link.
* It puts a red/not-red flicker in front of the operator at exactly the moment
  they are deciding whether they are on air. The `TransmitActivityRequest` for
  a route-change resume already says "keep holding" rather than blinking the
  banner — the same care has not been taken for the main UI.
* **It blocks the iOS harmonisation** in `BLUETOOTH-AUDIO.md`, which would
  deliberately cause a route change on every key-down. On top of an unresolved
  BU-15 that would move the dance from the first over to all of them — and
  trigger B has already taken the first step down that road, so the "solve
  BU-15 first" instruction there is now overdue rather than precautionary.

**The fix, 2026-08-23 — and a correction to everything above it.**

The diagnosis had one trigger too few. Escalating the category is a route
change, as this item says; **so is opening the microphone**, and that second one
is what survived the first attempt at the fix. From the device (times in ms from
the press, read out of the app's own instrument — see below):

```
attempt 1:  press@0  prep@19  sigPrep@553,559,569  prepped@797     ← category cascade: caught
            carrier@801  mic@801  onair@1179
            sigTx@1242,1261                                        ← the microphone's own, 63 ms
            resume@1722 ... onair@1764                             ← still two key-downs
```

The first capture on an engine instantiates its input audio unit, and that posts
a route change of its own about 63 ms later. The original trace could not
separate the two, because both landed after a single key-down.

So the fix is an **ordering, and it covers both**: escalate, open the
microphone, wait for the cascade *they* caused to go quiet, and only then key
the far end. Nothing is on air for any of it, so there is no transmission for
SF-3 to drop, nothing has to be told apart from an unplugged accessory, and SF-3
is not narrowed by a single line. `AudioIO.prepareForCapture()` escalates,
`AudioIO.settleRoute()` waits, and `RadioSession.routePreparationInFlight` is
the window in which a route change means nothing because nothing is keyed.

```
fixed:      press@0  prep@16  mic@518  sigPrep@851,859,861  prepped@1083  carrier@1089
            keyDowns=1  tx=0  — one key-down, no notice, steady to the release
warm over:  press@0  prep@12  mic@13   prepped@14  carrier@23
            keyDowns=1 — nothing was disturbed, so nothing was waited for
```

**Three things that make this cheaper than it looks.**

* **`BU-16`'s fast path is intact.** `settleRoute()` returns immediately unless
  something really moved the route — a category change that was applied, or a
  first capture on this engine. An over inside the 3 s hand-back linger does
  neither, and keys the far end **23 ms** after the press, measured. It is the
  first over after a pause, and only that, which pays the wait.
* **`BU-16`'s ordering is reversed, deliberately, and it loses nothing.** The
  163 ms it bought was a keyed-but-silent carrier either way, so the same audio
  reaches the far end — it now starts *with* the carrier instead of 163 ms in.
  And `BU-16`'s own case comes out better: a 90 ms tap now never keys at all,
  rather than keying after the finger has lifted. `OnAirGate` drops anything the
  microphone captures before the carrier, so the transmit meter still reports
  only what actually left.
* **The safety budget is no longer spent on ourselves.** `automaticResumes` is
  untouched by a cold over now, so a *real* route change later in the same hold
  has its full allowance. Separately, `resumeWork` is cancelled rather than
  merely reassigned — which is what stopped the app re-keying 115 ms after
  telling the operator it had stopped, and stops a resume already in the air
  from undoing an SF-1 watchdog unkey.

**The residual cost is 1.07 s from press to carrier on a cold over**, and the
microphone is ~500 ms of it. That is the number to attack next, and the way to
attack it is not a shorter wait: it is to stop making every over cold. The
per-over hand-back exists for `BU-14`, which is a *Bluetooth* problem — with no
Bluetooth device in the route there is nothing to hand back, so the session
could hold `.radio` and keep its engine, and a cold over would stop existing for
the majority of operators. Route-conditional policy is the follow-up; this item
does not need it.

**The instrument, which is the other thing this task leaves behind.**
`sudo log collect` cannot be driven by an unattended test — root, a TTY, and an
`.info` ring buffer that evicts the run within minutes (§8 of
`docs/HANDOFF-BU15.md`). So the app carries the trace out itself:
`RadioSession.keyDownsInCurrentHold`, `routeSignalsDuringPreparation`,
`routeSignalsWhileTransmitting` and `holdTrace` are reset only by a press the
*operator* makes, so they survive the release — which is the whole trick, since
XCUITest cannot look at the app during its own gesture. The transmit strip
carries them as its accessibility value in DEBUG builds, and
`BU15FirstOverUITests` asserts one key-down per hold, cold and warm, on a
device. `scripts/bu15-measure.sh` is still the way to see the phone's own log;
it is no longer the way to count.

**Closed:** confirmed on air 2026-08-23 (melchior, M17-CBR module A), one
key-down per hold in every run, cold and warm, no safety notice.

| platform / route | press → carrier, cold | signals absorbed | warm over |
|---|---|---|---|
| iOS, `route=MicrophoneBuiltIn` | 1.03–1.09 s | 3–5 | 23–31 ms |
| iOS, `route=BluetoothHFP` (Q2L) | 0.81 s | 1–2 | 21–23 ms |
| macOS, Q2L as default in *and* out | 0.96–1.23 s | 0–1 | 145–168 ms |

**The data is outside this repo, and it is separated from this write-up on
purpose:** `experiment-data/bu15-2026-08-23/` holds all sixteen `xcodebuild`
runs whole, a mechanical extract of every `=== BU-15` line in run order, and a
manifest recording the conditions of each run and **drawing no conclusions**.
Everything below is interpretation; if the two disagree, the logs are right.

**Tested, and not tested.** Every row above is the on-screen PTT button, one
6.4 s hold plus one 2 s hold, on one phone (melchior, iPhone 13 Pro / iOS 26.5)
and one Mac, with one accessory. What that leaves untested is worth naming
because some of it is the *common* case:

* **Ordinary Bluetooth headphones** — AirPods, a car, a speaker. The interesting
  one, and the configuration most operators who own no PTT accessory but are not
  on the built-in microphone will actually be in.
* **Wired earbuds**, and an iPad.
* **The accessory's own button as the PTT source.** Every on-air run keyed from
  the screen. The BLE press path reaches the same `beginTransmit`, so the
  ordering is the same code, but it has not been run on air through this fix.
* **macOS on its built-in microphone.** Unit-tested (a capture that raises
  nothing waits for nothing), not run on air.

**And one cost, measured rather than predicted.** A macOS run opened the
microphone in **111 ms** — 11 ms past the threshold, because SCO was still up
from an earlier session — and then saw **no signals at all**, so it spent the
whole onset budget: ~850 ms of wall clock waiting for a cascade that was never
coming. One key-down, no dance, 850 ms of latency for nothing. That is the
onset margin doing exactly what it is set up to do, in the one case where it buys
nothing, and it is the number to revisit first if the cold over is being made
faster. `APP-24` makes the question rarer by making cold overs rare.

**The accessory case is cheaper than the bare phone**, which is worth not
misreading: the Q2L was already the route, so the HFP link did not have to be
brought up from cold inside the over — fewer signals, and the wait leaves by its
quiet window sooner. It does not mean SCO is free.

⚠️ **Insist on the `route=` field before believing an accessory run** — and note
what that suspicion did and did not establish, because the first telling of this
overstated it. The first Q2L run carried no route field, so it *could not be
checked*; it was doubted because it came out faster than the bare-phone runs,
which is backwards for an SCO bring-up. `RadioSession.lastKeyDownRoute` was added
and the next run said `BluetoothHFP`.

**But the two runs' numbers are near-identical** — `mic@441 carrier@818` against
`mic@436 carrier@808` — so the first one almost certainly *was* the accessory
case as well. **An earlier version of this row, and commit `6e9aa3d`, said it was
not. That is not supported by the numbers, and is withdrawn.** What survives is
the instrumentation lesson: a Q2L can be connected for BLE — its PTT button —
while its Classic side is not the audio route, the triggers are fixed
independently, and a run that does not say which route it measured does not say
which trigger it tested. That is a reason to record the route, not grounds for
deciding a particular run was fake.

**The macOS trigger needed one more change, and it replaced a bad idea with a
measurement.** The wait was switched off on macOS by a platform flag, on the
reasoning that `applyPolicy` does nothing there so there is no cascade to wait
for. Wrong: `startCapture` blocked **798 ms** bringing SCO up and the
configuration change landed **1 ms after the carrier**.

```
before:  press@0  prep@53  mic@71  prepped@869  carrier@903  onair@903  sigTx@904
after:   press@0  prep@50  mic@81  sigPrep@914  prepped@1160  carrier@1190
```

What the flag was really trying to ask is **whether the audio stack had to bring
something up**, and how long opening the microphone took answers that without
asking the platform anything. ⚠️ **An earlier version of this section put figures
of 421–494 ms in this table for iOS. They were wrong** — they were read off gaps
in `holdTrace`, which bracket the escalation, not the capture. The capture
duration had to be instrumented (`micMs`) to be known at all:

| | cold over | warm over |
|---|---|---|
| iOS, built-in mic | 16 ms | 0 ms |
| macOS, Q2L as the route | 798 ms, and 111 ms with SCO already up | 1 ms |

**So the threshold carries macOS and does not carry iOS**, and finding that out
is what makes the pair of conditions in `settleRoute()` legible rather than
belt-and-braces:

* **macOS** — `startCapture` blocks on the SCO link and the configuration change
  follows it, so the duration is the whole signal.
* **iOS** — capture is fast either way, so the threshold never fires. What fires
  is *signals having already arrived*: the escalation blocks the main actor for
  ~480 ms, while the forwarder (a detached task, so not blocked) counts the
  cascade coming in. The `sigPrep` lines appear later than the signals did,
  which is worth knowing before reading a trace too literally.

Both conditions are load-bearing, one per platform, and neither is redundant.
`captureSlowThresholdNanoseconds` is 100 ms — an order of magnitude above every
warm figure, comfortably below the cold ones, and 11 ms below the awkward case
below. Two platform flags went away with it, including one that had macOS's
fictional policy bookkeeping standing in for a real route.

### BU-16 — a tap outruns the key-down, so the radio keys after you let go ✅ FIXED 2026-08-22

**Observed on iOS**, accessory PTT, one quick tap, in this order:

```
accessory notify FF00/FF01 = 01  → PRESS edge
accessory notify FF00/FF01 = 00  → RELEASE edge (wasKeyed=true)
key-down on air                            ← keys AFTER the release
accessory notify FF00/FF01 = 00  → RELEASE edge (wasKeyed=false)
key-up
```

The press begins an asynchronous key-down — `audio.startCapture(...)` and then
`await link.startTransmit()` — and on a Bluetooth accessory `startCapture` alone
costs ~163 ms while the SCO link comes up (`BLUETOOTH-AUDIO.md`). A tap shorter
than that completes before the key-down does, so the transmitter goes on air
*after* the operator has let go and comes off a moment later.

**It is safe and it is still wrong.** Safe because the release set
`transmitDesired = false` and the following apply unkeyed it — no stuck
microphone, and the existing flag ordering is what saved it. Wrong because the
operator transmitted something they did not ask to transmit, after releasing,
and because on screen it is indistinguishable from `BU-15`'s route-change flash
while having nothing to do with it.

**Not a race in the ordinary sense.** Nothing here is unsynchronised — every
step is on the main actor, in the documented order. It is a *latency* fault: the
button's edges are 90 ms apart (measured on this device) and the key-down path
is longer than that.

**The fix, implemented 2026-08-22.** Two changes in `applyTransmit()`, and they
are separate answers to separate halves of the fault:

* **The link keys first, and capture catches up.** `link.startTransmit()` is
  milliseconds of network; `startCapture` is the ~163 ms. Paying the network
  first puts the far end's carrier up with the press instead of a sixth of a
  second after it, which is the whole of the latency complaint. The cost is a
  moment of keyed-but-silent carrier while the microphone comes up — the pause
  a handheld's operator makes after keying anyway — and it is bounded, because
  a capture that then fails goes down the existing fail-closed path and unkeys
  the link it just raised. `testAMicrophoneFailureAfterKeyingUnkeysTheLink`
  pins that.
* **A key-down whose release already arrived is abandoned.** The re-check this
  section proposed, moved to after `startTransmit` because that is where the
  suspension now is: `transmitDesired` is re-read on return, and a false answer
  unkeys the link and returns without ever opening the microphone. The re-check
  and the decision sit in one main-actor region with no `await` between them,
  per the reentrancy rule. A tap now produces **nothing at all** rather than an
  over that begins after the release.

The two options not taken are still the right ones to refuse: a **minimum hold**
adds latency to every deliberate press to fix an accidental one, and **letting
the UI stop lying** would leave the unwanted transmission happening.

`FakeNetworkClient.duringStartTransmit` is what makes the abandonment testable —
it delivers the release from *inside* the awaited call, the ordering the
workspace `CLAUDE.md` says a common-ordering test cannot reach.
`testAReleaseDuringTheKeyDownLeavesTheRadioOffAir` asserts the radio stays off
air, the microphone is never opened, and the link is told to unkey.

**Not yet seen on air.** The tests cover the ordering; what wants confirming
with the Q2L is that the first over's audio is not clipped by the reversed
order, since the microphone now opens against an already-keyed link.

**Closed when** a tap shorter than the key-down path produces either a complete
short over or nothing at all, and never a transmission that starts after the
release.

### BU-17 — the audio session is never released, so the accessory is held in a call forever 🔬 DIAGNOSED 2026-08-22

**What the operator sees.** The accessory's LED stays lit whenever Currawong is
in the foreground, whether or not a channel is connected. Disconnecting from a
reflector puts it out for a moment and then it comes back **with nothing
connected at all**.

**What the log says.** On disconnect:

```
route changed: reason=override           in=BluetoothHFP      out=BluetoothHFP  16000 Hz
route changed: reason=override           in=MicrophoneBuiltIn out=Speaker       48000 Hz
route changed: reason=newDeviceAvailable in=BluetoothHFP      out=BluetoothHFP  16000 Hz
```

The session is deactivated and reactivated; `.defaultToSpeaker` briefly wins;
then HFP is re-offered and taken again. An active `.playAndRecord` +
`.allowBluetooth` session does not merely *start* on HFP, it **keeps returning**
to it, because the category demands an input route and HFP is the only Bluetooth
one available.

**Three costs, and the third is the one that matters.**

1. The accessory is held in a hands-free call indefinitely — battery, and an LED
   that reports nothing useful.
2. Receive audio is 16 kHz mono the whole time (`BLUETOOTH-AUDIO.md`).
3. **It keeps `BU-14` unfixable by any means short of releasing the session.**
   The button is starved for exactly as long as HFP is up, and on iOS today that
   is "always". Disconnecting is not enough.

**Note the `MicrophoneBuiltIn` line.** For the moment `.defaultToSpeaker` wins,
the input route is the *phone's own microphone*. Harmless here because nothing
was keyed — but the same flap during an over is the app transmitting from the
phone's mic with the accessory at the operator's mouth, which is the "sounds
like a pocket" fault `BU-13` warns about, and this is the first sight of the
mechanism that would cause it.

> ### ⛔ Tried twice, reverted twice, 2026-08-22. **The cause is not enough.**
>
> The second attempt used `RC-13`'s cause: ignore `categoryChange` for SF-3, keep
> it as `BU-14`'s repair trigger. It **half worked** — the route reached
> `Playback` at 44100 Hz and the ignore fired 23 times — and still broke keying,
> because **one policy switch produces a cascade**: `categoryChange`, `override`,
> `newDeviceAvailable`, `engineConfigurationChange`. Only the first is
> self-evidently ours; the others are indistinguishable from an accessory being
> unplugged, and SF-3 must drop transmit for those.
>
> **So this needs a requirements decision, not another attempt.** Either a
> suppression window on the transmit path — where SF-3 exists to hold — or one of
> two partial options that leave SF-3 alone: switch on connect/disconnect (fixes
> the idle case and the battery, not receive quality during a QSO), or accept the
> platform difference and document it. `RC-12` and `RC-13` both stay; the cause
> made SF-3 more precise on its own merits.
>
> ### ⛔ First attempt, 2026-08-22.
>
> Switching policy on the transmit path made the app unusable for transmitting:
> "tx just doesn't work, like it switches for a second and then turns off", an
> "audio route changed" notice over and over, the transmit banner and the layout
> reflowing repeatedly, and sometimes a state where the operator could not even
> disconnect.
>
> **The mechanism, and it is structural rather than a tuning problem.** A
> category change *is* a route change. `SF-3` requires transmit to be dropped on
> a route change, and `RadioSession` correctly does exactly that. So:
>
> ```
> key down -> activateSession(radio) -> route change -> SF-3 drops transmit
>          -> resumeAcrossRouteChange keys back down -> route change -> ...
> ```
>
> Every component behaved as specified, and the loop is the consequence. **No
> amount of tuning fixes it**: the quiet period guards `BU-14`'s repair, not
> SF-3, and widening it would not help because SF-3 must not be widened.
>
> **What is actually missing, and it is a library capability.**
> `AudioSessionSignal.routeChanged` carries no reason, so nothing above the
> library can tell *"the category changed because we just asked for it"* from
> *"the accessory went away"*. The first must not drop transmit; the second must,
> unconditionally. Until the library can distinguish them — a new task there,
> not a workaround here — the switch cannot be made from the app.
>
> `RC-12` and the `v0.5.4` bump stay: the policy is correct and additive, and
> nothing uses it yet. The app-side switch is reverted; `BU-17` is **open**.
>
> **Do not** attempt this again by suppressing SF-3 around the key path. SF-3 is
> the requirement that stops a microphone being left open by a route that moved,
> and a suppression window on the transmit path is precisely where it must hold.
>
> ~~🔧 Implemented 2026-08-22, not yet verified on air.~~ Against `v0.5.4`:
> `configureSession()` still activates the **radio** policy and builds the engine
> under it — that ordering is `BU-1` and must not change — and then switches to
> **listening**. `startCapture` asks for the radio policy again before opening
> the microphone, which is where SCO now comes up; `stopCapture` hands the route
> back, best-effort and without throwing, because shutting the microphone is the
> safety-relevant half of that call and nothing may delay it.
>
> **What to look for on air:** the accessory's LED out between overs and lit only
> while transmitting, and receive audio back at 44.1 kHz on A2DP. Then re-check
> `BU-14`'s repair, because the route now changes at every key-down and key-up by
> design — the quiet period is what should keep them apart.
>
> 🔧 **The library half: `RC-12`, swift-hamvoip#48, merged as `v0.5.4`.** It adds
> `AudioSessionPolicy.listening` (`.playback`, `.default`, no options) and
> `activateSession(_:)` taking a policy. **The category differs from `radio`, not
> just the options** — that is the whole point, because this item showed a
> `.playAndRecord` session keeps *returning* to HFP: the category requires an
> input and HFP is the only Bluetooth one on offer. Adding `allowBluetoothA2DP`
> to a recording category does not help, and RC-12 pins that option as unused so
> nobody tries.
>
> **What is left here is deciding when to switch**, and it waits on a released
> tag — the dependency is versioned, and the commented-out path dependency in
> `project.yml` must not be committed swapped.
>
> **The hazard to respect when doing it.** `AVAudioEngine` never revisits its
> input format, so an engine built while idling under `listening` reports 0 Hz
> for the life of the process — `BU-1` again. `AudioPipelineIO` already rebuilds
> once on a failed `startCapture`, and that is the machinery this must lean on:
> switch to `radio` *before* building, and treat the first press after any
> receive as a case that may need the rebuild. Do not add a second rebuild path.
>
> Note also that this makes the audio route change at every key-down and key-up
> **by design**, which is exactly the signal `BU-14`'s repair watches. The quiet
> period added for `BU-16`'s sibling defect is what keeps the two from fighting;
> check it still holds once this lands.

**Closed when** the accessory's LED is out whenever the app is not transmitting,
and the route is A2DP between overs. That is the same change as the iOS
harmonisation in `BLUETOOTH-AUDIO.md` — **and it is gated on the release-edge
hazard recorded there.** Do not close this one by making the session shorter
without reading it.

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

> ✅ **Half of this is done: the SF-1 watchdog has been observed, 2026-08-22.**
> With the timeout set to 10 s and the accessory's button held down, on an iPhone
> against `m17-cbr`:
>
> ```
> [214.772] key-down on air
> [224.827] endTransmit reason=watchdogExpired wasTransmitting=true held=true
> [297.434] key-down on air
> [307.440] endTransmit reason=watchdogExpired wasTransmitting=true held=true
> ```
>
> 10.055 s and 10.006 s after key-down, twice, unkeying a button that was still
> physically held (`held=true`) — which is precisely the case this item exists
> for and which had never been seen. It also arrived *before* the release edge in
> both instances, so the watchdog, not the operator, ended both transmissions.
>
> **Still unobserved: a phone call dropping transmit** (SF-3 by interruption).
> That is the remaining half, and it needs someone to ring the phone mid-over.

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

> ✅ **First evidence, 2026-08-22, from the `BU-14` session.** "An accessory keys
> a backgrounded app" is no longer unobserved: ~25 accessory press/release pairs
> were delivered to Currawong **while it was in the background**, logged edge by
> edge. That answers the delivery half of this item. The Live Activity itself
> still has not been watched on a locked phone.
>
> ⚠️ **And the obvious instrument does not reach that case.** Locking the phone
> drops the `devicectl ... --console` tunnel — observed the same day as
> `CoreDeviceError 3`, "the connection was invalidated" — and that also kills the
> app it launched. So the log cannot be read across the very transition this item
> is about. Either the diagnostics become readable *on the device*, or this item
> is observed by eye rather than by log.

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

### BU-18 — macOS holds HFP for the whole session, and the Q2L's LED never lights 🔬 MEASURED 2026-08-23

Found while confirming `BU-15` on macOS, from an operator observation: **the
Q2L's red light does not come on while Currawong transmits**, though the Q2L is
demonstrably the microphone (tapped it, saw signal on the meter).

That contradicts `BLUETOOTH-AUDIO.md`, which says the LED tracks the SCO link
and that this makes it a usable TX indicator on macOS. So rather than argue
about the LED, the link itself was measured.

**Data:** `experiment-data/bu15-2026-08-23/13-macos-coreaudio-poll.log`, recorded
concurrently with run 13 (`13-macos-q2l-onair.log`). Both timestamp in UTC, so
they correlate without adjustment. The manifest there records the conditions and
nothing else.

**Method.** A 30-line CoreAudio poller — `kAudioHardwarePropertyDefaultInput`/
`OutputDevice`, then `kAudioDevicePropertyNominalSampleRate` and
`kAudioDevicePropertyDeviceIsRunningSomewhere` — sampling every 50 ms and
printing only transitions, run across one `BU15FirstOverUITests` session with
the Q2L as the Mac's default input *and* output. Cheap, needs no root, and needs
nothing from the app; worth keeping in mind as the way to answer "what is the
route actually doing" on macOS, where there is no `AVAudioSession` to ask.

```
hold began   03:16:12.165                                       (app's own log)
      +1.065s  out: 44100 → 16000 Hz, running=true              ← SCO comes up
      +1.128s  in:  running=true                                ← capture starts
hold ended   03:16:24.682
      ...      out: still 16000 Hz, across a second over and the idle between
03:17:33.879   out: 16000 → 44100 Hz                            ← 69 s later, teardown
```

**Two findings.**

1. **SCO is up, and the LED is dark.** The 44100 → 16000 output swap is
   unambiguous, it lands 1.065 s after the press — within 40 ms of the app's own
   `carrier@1229` — and the input runs from 63 ms later. Whatever the LED tracks,
   it is not this. `BLUETOOTH-AUDIO.md:102` needs correcting, and the macOS
   operator has no handset TX indicator: the app's own strip is all there is.
   Worth knowing before anything is designed on the assumption that the handset
   reports transmit.

2. **macOS does not hold SCO only while transmitting.** It held it for 69 s —
   through the release, a whole second over, and the idle in between — and gave
   it up only at teardown. So macOS receive audio is **narrowband from the first
   transmit onwards**, which is exactly `BU-17`'s fault on the platform whose
   behaviour `BU-17` was written to imitate. The likely cause is one line:
   `discardsEngineOnHandback` is false on macOS, so the engine keeps its
   instantiated input unit and CoreAudio has no reason to drop the route. The
   reason it never surfaced is that macOS has no `BU-14` — the button keeps
   working, so nothing forced the question.

**Why this is not folded into `BU-17`.** That item is about iOS, is fixed, and is
confirmed on air. This is the same shape on a different platform with a
different consequence — quality, not a dead button — and it invalidates a
premise `BLUETOOTH-AUDIO.md` leans on in several places ("a feature, not an
inconsistency to be fixed"). It wants deciding, not appending.

**Not investigated further.** One session, one accessory, found while confirming
something else. Before fixing: confirm with a second session, and check whether
a Mac on its built-in microphone shows the same hold (it should not — nothing to
hold). The obvious experiment is flipping `discardsEngineOnHandback` on for
macOS and re-running the poller.

### BU-19 — the iPad column: a clipped status panel and the wrong landing pane ✅ FIXED 2026-08-26

**What an operator sees**, on an iPad mini: connect, and the top of the status
panel — the LCD — goes off the top of the screen. On M17 the same press also
leaves them looking at the *reflector directory*, with the radio squeezed into
the top of the detail column, having just linked to a reflector.

Two faults in one report, and they compound: the second is what makes the column
tall enough for the first to bite.

**The clipping is `BU-12`'s mechanism on a smaller display.** A view that demands
more height than its parent has is not clipped at the bottom and does not
scroll — the parent centres it, and the overflow is split between both edges. The
demand was `.frame(minHeight: 620)` on the detail column. That number was
*examined* during BU-12 and cleared on the arithmetic of the display it was found
on:

> **`.frame(minHeight: 620)`** on the detail column: 620 is less than 866, so it
> cannot be the demand. It stays as documentation of what the fixed region needs.

Which was true there and is false on an iPad mini in landscape, where 744 points
of screen become something in the mid-600s once the status bar, the home
indicator, the transmit strip and the detail column's navigation bar are out —
and where connecting adds the level meters, the PTT button (a 190-point floor on
iOS against 120 on macOS) and the link button at once. The overrun is small, a
couple of dozen points, which is why it reads as the panel having *scrolled* a
little rather than as a layout fault.

A number cannot be right for both a Mac window and an iPad mini, so there is no
new number. The column takes what it is given, top-aligned; the session pane is
rigid and keeps its height; what compresses is whichever pane is below it, and
those are directories and settings lists, which scroll. Nothing load-bearing is
in the part that gives.

**The landing pane is APP-18 finishing half a thought.** APP-18 takes the connect
form out of the picker once there is a link — correctly: connected it is a
read-only wall of fields. But it gave the connected state no pane of its own, so
the selection fell to `visibleDetailPanes.first`, which is whatever the mode's
first *optional* pane happens to be — the reflector directory in M17, the station
directory in EchoLink, the keypad in AllStarLink.

The fix is the complement APP-18 already had one half of: `connect` is the
disconnected state's pane, `session` is the connected state's, exactly one of the
two is ever offered, and `session` sorts ahead of every optional pane so it is
also what a connect falls back *to*. Selecting it draws the session pane with the
whole column and nothing under it — which is the iPhone's Session tab, arrived at
from the other direction.

**Where it lives now.** `RootView`'s three inline computed properties
(`visibleDetailPanes`, `effectiveDetailPane`, `showsConnectForm`) are one value
type, `DetailPaneSet`, next to `SessionPaneLayout` and for the same reason: the
part worth testing is not which panes exist but which one the operator lands on
when the set changes underneath them, and that was not visible from any one of
the three. `DetailPaneSetTests` covers the landing in every mode and every
connection state.

**The regression test, and its limit.** `DetailColumnSizingTests` hosts the real
`RootView` at 1024×560 — shorter than any iPad, deliberately, because
reproducing the device would mean guessing at a navigation bar and two safe-area
insets and the real overrun was small enough to pass by accident. It asserts the
*demand*: 660 points against a 560-point window with the floor in place, 416.5
connected and 220.5 disconnected without it.

**It is macOS-only, and the fault was on an iPad.** That is not an oversight:
`UIHostingController.sizeThatFits(in:)`, for a controller attached to the test
host's window scene, answers with the scene's geometry rather than the view's. On
an iPad Pro simulator every case returned the identical 716.5 — every mode, both
connection states, and both sides of a fix that moves the number by 240 points
under AppKit. A test that cannot tell the fault from its fix is worse than none,
so the number is measured where it means something. What it measures — a
`minHeight` in points — is platform-independent, and iOS is the tighter budget of
the two by the PTT button's 70 points, so a column that fits on macOS has less
margin on the device, not more.

**One hazard found while fixing it, before it shipped.** The natural way to
write "the radio gets the whole column" is a branch around the session pane —
`if .session { pane } else { pane; Divider(); content }` — and that puts
`SessionPane` in two arms of a conditional, which is two view identities.
Changing pane would tear the pane down and rebuild it, `PushToTalkButton`'s
`onDisappear { onRelease(.viewDisappeared) }` would fire on the way past, and
**changing pane while keyed would unkey the radio** with the button visible
throughout. The tab layout unkeys on a tab change for a good reason — the button
really does leave — and this would have looked like the same rule while being a
different thing. Written as one conditional *below* the pane instead, so the
pane holds one position in the stack and one identity.

**Not verified on the device.** There is no iPad mini simulator installed here
and the tests above cannot see the device's chrome. What is confirmed is the
suite green on macOS, an iPhone simulator and an iPad Pro simulator, and the
demand measured on both sides of the change.

### BU-20 — `main` is red, and the failures are in the tests ✅ FIXED 2026-08-26

**Four tests, three causes, no product fault** — and a fifth thing worth as
much as the fixes: **a pull request cannot see any of this.** `ci.yml` carries
`if: github.event_name != 'pull_request'` on the `Test (iOS Simulator)` step, by
a deliberate trade written out above it (four times the cost to gate every PR
with a run that is mostly view modifiers). The consequence is that the iOS suite
is only ever exercised on merge, nightly and on demand, so a green PR check and
a red `main` are the *expected* pair when a fault lives in that step. Four
nightly runs said so before anyone read them:

| Run | Trigger | Failed |
|---|---|---|
| 32651299165 | nightly, 23 Aug | `testTheCascadeDuringPreparationCostsNeitherAKeyDownNorANotice` |
| 32751300742 | nightly, 24 Aug | `testARouteChangeAfterPreparationStillDropsTransmit` |
| 32872444133 | nightly, 25 Aug | the above, plus `testReplyAudioArrivingDuringTheLingerDefersTheHandback` |
| 32959937776 | push (`BU-19` merge) | all of the above, plus `testAWatchdogUnkeyCancelsAResumeAlreadyScheduled` |

A different subset each time, from the same small family. That shape is the
diagnosis: not a break, a race.

#### 1. The cascade was assumed to have been delivered

`BU15FirstOverTests.cascade(_:on:)` emitted a route change, slept 20 ms, and
emitted the next. But `emit` yields into an `AsyncStream` and returns — the
session handles the signal later, on the main actor, when its consumer task is
scheduled. With a core to spare that is well inside 20 ms. On a loaded runner it
is not, and the tail of the cascade was handled *after* `settleRoute()` returned
and `routePreparationInFlight` had been cleared. SF-3 then did what SF-3 does
with a signal outside preparation: dropped the hold and scheduled a repair. The
test observed two key-downs, seven unkeys and a safety notice — `BU-15`'s exact
symptom, produced by the test itself.

It now waits, after each signal, until the session's own
`routeSignalsDuringPreparation` has counted it. That is what the file's own
doc comment always claimed ("delivered *and handled* inside the awaited call")
and what the sleep only hoped for; a signal that never lands during preparation
is now a named failure rather than a confusing one.

#### 2. Two waits were watching a state that is only briefly true

An SF-3 drop under a held button is followed by a repair 300 ms later, so
`!client.isTransmitting` is true only inside that gap. A poll that does not land
in it sees a transmitting client before and after — and then waits out its whole
timeout reporting that SF-3 never fired, which is what
`testAWatchdogUnkeyCancelsAResumeAlreadyScheduled` did for five seconds. Both
waits now use instruments that only ever grow: the client's call log for the
stop, and `routeSignalsWhileTransmitting` for "the signal was handled, the hold
dropped and the repair scheduled", which is the precondition that test actually
needs.

The third, in the same test file, was subtler and reproduced **locally on an
idle machine**: `waitUntil { client.isTransmitting }` followed by
`XCTAssertEqual(session.keyDownsInCurrentHold, 2)`. The client is keyed inside
`link.startTransmit()`; the session counts the key-down when that call *resumes*.
Waiting on one and asserting the other is a race across a resumption, and it
lost — 1 instead of 2. It now waits on the counter it asserts.

#### 3. Fourteen seconds in which nothing was scheduled

`testReplyAudioArrivingDuringTheLingerDefersTheHandback` injects its linger, so
no timer is involved: after `gate.open()` the hand-back is one `Task.detached`
away. On run 32959937776 the test's own escalation logged at **t=17.812** and
the deferred hand-back at **t=32.060** — fourteen seconds later, and **3 ms
after the test had given up**. The work was not stuck. It was not run.

On a runner where the host app alone took 7 seconds to launch, a five-second
budget is not measuring the product. `waitUntil`'s default is now 20 s, with
those numbers written next to it: a longer timeout costs a passing test nothing,
because every predicate is polled, and costs a failing one fifteen more seconds
before it says so.

**And the likeliest source of the stall got fixed while we were there.** Seven
tests in `AudioPipelineIOTests` are about engine lifetime and said nothing about
policy, so they took the initialiser's defaults — the real `AVAudioSession` and
a real three-second linger. On the simulator the hand-back's `setCategory` is
refused with `'!pri'`, so each of them left a retry chain of up to five attempts,
three seconds apart, running past the end of the test that started it: fifteen
seconds of blocking audio calls on the cooperative thread pool, from tests that
never wanted a session. That is the `!pri` noise in every CI log, and blocking
calls on the cooperative pool are exactly what stops detached work being
scheduled on a machine with few cores. They now inject a no-op policy and a
linger that never elapses — which is what the real three seconds was doing there
by accident, since these tests assume the hand-back does not complete while they
run.

**What was checked before calling it fixed.** The rewritten tests were run
against a deliberately broken product — the `BU-15` preparation gate removed —
and they fail. A test that cannot fail is not a fix.

### BU-21 — the preparation gate closes one step early 🔧 OPEN 2026-08-26

**Found by reading, not by watching.** `applyTransmit` clears
`routePreparationInFlight` as soon as `settleRoute()` returns, and then awaits
`link.startTransmit()` before setting `isTransmitting = true`. A `.routeChanged`
handled in between passes both halves of the gate's condition — preparation is
over, nothing is on air — so `handle(_:)` falls through to
`resumeAcrossRouteChange()`: the hold is dropped and a repair is scheduled while
the key-down that caused the route change is *still in flight*. The key-down
then completes and sets `isTransmitting = true` against a `transmitDesired` that
the stop has already cleared, and 300 ms later the repair keys down again.

It is narrow — the window is one `await` on a live link — and self-healing,
because the transmit work chain serialises: the stop's `applyTransmit` waits for
the key-down's, then unkeys, and the repair follows. What the operator sees
while it heals is `BU-15`'s dance, from the one window `BU-15`'s fix does not
cover.

**Not fixed here, deliberately.** The obvious change — hold the gate until the
carrier is up — swallows a *real* route change in the window where the carrier
is coming up, and that is SF-3's business, not a test's. The alternative is to
defer rather than swallow: record that a route change arrived, let the key-down
finish or abandon, then act on it once. That is a design decision about SF-3's
behaviour and wants the maintainer's call, on evidence, rather than a patch
attached to a test fix. Never observed on air; `holdTrace` would show it as
`sigIdle` between `prepped` and `carrier`.

### BU-22 — the first over after the input spins up is silent ✅ FIXED 2026-08-28

**Watched on air, twice, on macOS.** Connect, key down, speak: no transmit
meter and nothing at the far end. Release, key down again: normal audio,
normal meter, and every subsequent over is fine. Observed 2026-08-28 against
M17-CBR module A, and again in the session that produced `BU-23`.

**The log says which over is different, and why.** The silent one is always
the one preceded by these two lines; overs 2..n have neither:

```
audio session escalated to radio for capture
audio route settled before key-down: 0 route changes in 12 x 60ms
```

Overs 2..n land inside the 3 s hand-back linger, so `BU-16`'s fast path skips
escalation and reuses an input that is already running. **The silent over is
exactly the one where the input device had just been spun up** — and about a
second elapsed between the escalation and the key-down, so this is not a race
the existing wait is losing. `settleRoute()` waits for the *route* to stop
changing, which it had; it does not wait for the device to produce signal.

**Corroborated off the app entirely.** A 30-line scratch tool driving
`RadioCore.AudioPipeline.startCapture` directly returned 4 full seconds of
**exact zeros** on its first run, and normal room noise on the next run moments
later, in a *different process*. So the warm-up is the device's, not the app's
state, and no amount of app-side bookkeeping will see it as anything but
silence.

**This is `BU-2`'s shape, one layer down.** That one was the macOS permission
prompt: nothing had asked, so the first capture attempt raised the dialog and
that press put no audio on air; the fix moved the ask to connect time, "where
the operator is already waiting and no over is at stake". The same sentence
applies here with *device warm-up* in place of *permission*, and the same fix
applies — this is a second cause of one symptom, and the 2026-08-20 fix could
not have covered it.

**Fix: warm the input on connect** (the maintainer's call, 2026-08-28). Open
capture briefly when the session connects, so the device is awake before the
first key-down, and let the existing linger keep it awake between overs.

Rejected alternative: hold `OnAirGate` closed until the tap delivers a
non-silent buffer. It fixes the symptom and breaks something real — a
legitimately quiet start to an over would be swallowed, and an operator whose
first word is soft would key up into nothing. Silence is not the same thing as
a dead device, and the gate must not be taught to confuse them.

**Where it goes.** `RadioSession`'s connect path, beside the
`requestRecordPermission()` call that `BU-2` put there; `AudioIO`
`prepareForCapture()` is the piece to reuse. Note that `AudioPipeline` reports
nothing about signal presence, so if the warm-up needs to *verify* rather than
merely wait, that is a library-side addition (see `RC-14` in the library's
plan, which touches the same code for a different reason).

**Fixed 2026-08-28.** `AudioIO.warmUpInput()` is new: it makes the transmit
path's own three calls — escalate, open the microphone, wait out what that
disturbed — and then *holds the input open*, which is the part a key-down does
not do and the whole reason the first over was silent. Frames are dropped on the
floor; nothing is keyed, so there is nowhere for them to go, and the transmit
meter goes on reporting only what left. Closing through `stopCapture()` puts it
on the ordinary hand-back path, so an operator who keys up straight afterwards
still takes `BU-16`'s fast path into a device that is now awake.

`connect()` **starts it before the node is dialled and awaits it before
`connection` becomes `.connected`.** Both halves are load-bearing. Starting
early means the warm-up runs alongside the DNS lookup, the link, the call and
the answer, so it normally costs the connect nothing at all. Awaiting before
`.connected` is what keeps it from becoming the fault it fixes: `beginTransmit`
refuses a press that is not connected, so the operator cannot key into a running
warm-up and find the microphone already taken. Every failure exit awaits it too
— a connect that could not be made must not leave the microphone open behind an
alert nobody has read yet.

The verification question above did **not** need answering, and no library
change was needed: the maintainer's fix was to warm the device, not to prove the
warming worked. `RC-14` landed separately, for its own reasons.

**It reproduces on Bluetooth, and not on a USB webcam — which is why it would
not reproduce on demand.** Measurements in `experiment-data/bu22-input-warmup.txt`,
melchior, 2026-08-28. A cold probe at 20:39 on the Logitech StreamCam, after the
machine had been left alone, delivered its first buffer at 283 ms with room noise
already in it: no fault at all. A webcam is permanently powered. When a pair of
AirPods became the default input three hours later, the fault was immediate and
repeatable.

**The fault, reproduced on the app's own code path** — `RadioCore.AudioPipeline`,
cold AirPods, the exact sequence the fix creates:

```
warm-up (1.6 s):              80 frames, 7 with audio, first frame 178 ms, first audio 1574 ms
first over after a 1.5 s gap: 80 frames, 78 with audio, first frame 151 ms, first audio 151 ms
```

Read that pair carefully, because it is the whole case for the fix. Cold, the
device delivered frames from 178 ms and **audio only from 1574 ms** — nearly a
second and a half of zeros, *with frames arriving the whole time*, which is
exactly why nothing above the device can tell it from silence. After the warm-up,
the next open carried audio in its **first frame**. Not sooner: immediately.

A second finding from the same evening, not the one being fixed and recorded
because it is a trap for anything built on a short close/reopen: a fresh engine
opened **one second after** the previous one closed delivered **no buffers at
all** for three seconds. Reopening a Bluetooth input immediately after closing it
is its own hazard.

**The hold — `AudioPipelineIO.warmUpHoldTicks`, 17 ticks, 1020 ms past the
settle — is still argued rather than derived, and here is exactly what is
unproven.** The 1.6 s warm-up measured above *outlasted* the 1574 ms of silence,
so it does not separate "opening the device wakes it" from "holding it open until
audio appears wakes it". If it is the latter, 1020 ms past the settle may be
short on a cold Bluetooth link — though in the app the settle itself spends up to
1.2 s on a cold SCO open, so the real total is closer to 2.2 s than to 1.0 s.

The argument for the shorter number: a device opened once delivers immediately on
the next open **in a different process**, so it is the opening that wakes the
hardware and the zeros are what that costs whoever pays first. A trial with a
deliberately short (1.0 s) warm-up on a cold device is the measurement that would
settle it.

**If a silent first over is ever seen again, do not simply raise that number.**
Establish first whether the warm-up ran at all — `input warmed for …` in the route
log — and whether the device was still cold when it did. A warm-up that ran and
did not work is a different fault from one that was too short.

### BU-23 — a segfault 400 ms after an engine reconfiguration mid-over 🔬 UNEXPLAINED 2026-08-28

**One crash, not reproduced.** `Currawong-2026-08-28-191119.ips`, macOS 26.5.1,
Debug build against library v0.6.0. `EXC_BAD_ACCESS (SIGSEGV)` at
`0xffffd3f627b90040`, flagged *possible pointer authentication failure*.

**No frame of ours is in the fault path.** Thread 0, top to bottom:

```
SerialExecutor._isSameExecutor<A>(_:)          ← crash
SerialExecutor.isMainExecutor.getter
swift_task_isCurrentExecutorWithFlagsImpl
DesignLibrary
HStack.init(alignment:spacing:content:)
... SystemSegmentedControl._overrideSizeThatFits ...
```

A SwiftUI layout pass over a segmented control, asking Swift concurrency
whether it is on the main executor, dereferencing a pointer with garbage high
bits. `Currawong.debug.dylib` appears only as the app entry point at the
bottom. Codec2 and Weebill are nowhere near it.

**What makes it worth a task rather than a shrug** is the 1.5 s before it:

```
19:11:12.667  key-down on air                                    (third over)
19:11:13.940  signal routeChanged(engineConfigurationChange) isTransmitting=true
19:11:13.947  endTransmit reason=routeChanged
19:11:14.44   SIGSEGV
```

An `AVAudioEngineConfigurationChange` arrived **mid-transmit** — the operator
had just changed the default input device, which is what produces one — and the
process died 400 ms later. `RC-14` in the library's plan records the defect that
window exposes: the capture chain is never rebuilt on that notification, so for
the ~7 ms until `endTransmit` removed the tap, a live tap was running against a
reconfigured engine with a converter and a `channelStride` snapshotted from the
old format. The stale-stride path is an out-of-bounds *read*.

**Stated honestly: that does not explain this crash.** An out-of-bounds read
explains a segfault at the read; it does not obviously explain a corrupted
executor pointer 400 ms later in an unrelated subsystem. And
`swift_task_isCurrentExecutor` crashes are a known pattern on recent macOS
SwiftUI. Two candidates, no evidence separating them:

1. Heap corruption originating in the capture path (`RC-14`), surfacing wherever
   the allocator next handed out the damaged memory.
2. An OS/toolchain bug in SwiftUI's segmented-control layout, and the timing is
   a coincidence.

**One more thing in the report, unexplained and possibly unrelated:** thread 12,
on the `com.apple.root.user-initiated-qos.cooperative` pool, was parked in
`_pthread_mutex_firstfit_lock_wait` inside `AudioPipeline.enqueuePlayback`
(`AudioPipeline.swift:1230`), called from `startReceivePump`. Blocking a
cooperative-pool thread on a mutex is its own hazard, and this repository has
paid for that class of mistake before — but starvation causes hangs, not
segfaults, so it is recorded here as an observation rather than a cause.

**How to settle it: an AddressSanitizer build.** `-enableAddressSanitizer YES`,
then reproduce by switching the default input device mid-over. ASan traps an
out-of-bounds access at the instant it happens, naming the line, instead of
leaving us to infer it from a crash in someone else's framework 400 ms later.
If ASan is silent through several device swaps, candidate 1 is dead and this
becomes a bug report for Apple.

**Do not fix `RC-14` and close this.** `RC-14` is worth fixing on its own merits
and should be; whether it caused this crash is a separate question that only the
ASan run answers. Closing this on the strength of the fix would be assuming the
thing to be proven.
---

**2026-08-28 — `RC-14` is fixed, this is still open, and candidate 1 is now the
weaker of the two.** Three things came out of doing that work, none of which is
the ASan run this entry asks for, and none of which closes it.

**1. The out-of-bounds read is not reachable on this Mac.** The library gained
`hamvoip-cli experiment capture-swap`, which changes the default input device
under a live capture — the same action that produced this crash — and reports
what the pipeline saw. Eight swaps, twice, both under AddressSanitizer, both
silent: 550 frames and 0 rebuilds as shipped, 530 frames and 8 rebuilds with the
staleness check forced on (`experiment-data/rc14-capture-swap.txt`, and
`swift-hamvoip/docs/CLI.md` §12). Zero rebuilds is not the probe failing to fire;
it is the finding. A third run, after a Bluetooth headset joined the machine,
established why — and corrected a wrong reading of the first two, which had
suggested the input node simply reports 44100 Hz for everything:

> `AVAudioEngine` fixes its input rate when the input audio unit is
> instantiated, and a device change afterwards does not move it — CoreAudio
> resamples into the rate the engine already chose. Only the **channel count**
> follows the device.

A *fresh* engine on the AirPods reports 24000 Hz mono, against 44100 Hz stereo
for the StreamCam; swapping to those same AirPods *under a running capture*
reports 44100 Hz mono. So under a live capture on macOS the rate cannot go
stale, and neither can the stride — every device here is de-interleaved, and
de-interleaved buffers stride by 1 whatever the channel count. **The stale
stride, the only unbounded read in that path, cannot have occurred here.**
Candidate 1 needs an interleaved input format, and macOS did not hand one to an
`AVAudioEngine` tap in any configuration tried.

That is evidence, not proof. It does not cover the app's own build, which is
where the crash happened, and it does not rule out heap corruption from
somewhere else in that path. But candidate 1's stated mechanism is gone, so the
weight has shifted to candidate 2.

**2. A crash of exactly this shape came out of an ordinary use-after-free.**
While writing the probe, `AVAudioEngine().inputNode.outputFormat(forBus: 0)` —
as one expression, so the engine is released before the format is read —
segfaulted inside `AVAudioIONodeImpl::GetOutputFormat` with a **bad pointer
dereference at garbage high bits, reported as a possible pointer authentication
failure**. That is this crash's signature, from nothing more exotic than an
object outliving its owner. It says the signature is not diagnostic of anything
in particular; it is what a dangling Objective-C pointer looks like on arm64e.
Worth keeping in mind for candidate 2, where the dangling thing would be
SwiftUI's, not ours.

**3. The ASan run is now one command:** `make asan-macos` builds the sanitized
macOS app and launches it, with the reproduction (change the default input
device mid-over) still manual, because it has to be. Below the app, and needing
nobody on air, is the `capture-swap` probe above — try that first.

**Still open, and still on the same question.** If ASan is silent through
several device swaps *in the app*, candidate 1 is dead and this becomes a bug
report for Apple.

