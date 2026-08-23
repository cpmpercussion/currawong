# Handoff — `BU-15`, the dance at the start of every over

Written 2026-08-23, for someone picking this up cold to **fix** it. The
diagnosis is done and the instrument is built; what is left is a design
decision and the change that follows from it.

Read `BRINGUP.md`'s `BU-15` and `BU-17` rows first — they are short. Read
`BLUETOOTH-AUDIO.md` only if you touch the macOS side; it is long, organised by
discovery rather than conclusion, and mostly about the accessory.

---

## 1. The fault, in one paragraph

Press PTT for the first over after a pause. Nothing happens for about
eight-tenths of a second, the strip goes red, goes back to not-red, and then
goes red again and actually transmits. The operator has held the button down
the whole time. Nothing is broken — SF-3 is doing exactly what it is specified
to do — but the first second and a half of every over is lost and the app looks
like it is malfunctioning.

## 2. The measured trace — trust this

One 6.4 s hold, melchior (iPhone 13 Pro, iOS 26.5), M17-CBR module A,
**no Bluetooth accessory attached**, 2026-08-23. Times are relative to the
press. Produced by `scripts/bu15-measure.sh`.

| t | event |
|---|---|
| +0.63 s | `audio session escalated to radio for capture` |
| +0.82 s | `key-down on air` |
| +0.92 s | `routeChanged` `isTransmitting=true held=true resumes=0` |
| +1.01 s | `routeChanged` `resumes=1` |
| **+1.09 s** | **`key-up`** — the drop the operator sees |
| +1.15 s | `routeChanged` `isTransmitting=false held=true resumes=2` |
| +1.23 s | `routeChanged` `resumes=3` — the cap |
| +1.36 s | `routeChanged` `resumes=3` |
| **+1.47 s** | **`key-down on air`** — back on air, stable from here |
| +6.31 s | `key-up` — the release |

**Two key-downs in one hold. One interruption. 385 ms of dead air. 1.47 s
before transmit is stable.** That is the ~1 s `BU-17` charged to this row, and
it is a floor rather than a typical case: this run had no accessory, so it paid
only the category-change cost and none of the SCO cost.

**`resumes=N` counts scheduled resume *attempts*, not re-keys.** Read the
`key-down on air` lines for the real count. An earlier note in `BRINGUP.md` got
this wrong and has been corrected; do not re-derive the mistake.

## 3. Why the simulator cannot test this, and what that means for your loop

`BU15SessionProbeTests` (in the ordinary test target, runs under `make test`)
measured this on 2026-08-23: the simulator **performs** the category change —
the built-in mic enters and leaves `currentRoute.inputs` on cue — but
`AVAudioSession` posts **no `routeChangeNotification`** for it, nor for
`overrideOutputAudioPort`, nor for `setActive`. Zero across a whole run, with
controls in the same run to prove the detector works.

So SF-3 never fires in the simulator, the first over looks perfectly clean, and
**a simulator run reports a false pass on any fix you write.** That probe is
kept as a tripwire asserting the zero; if it ever fails, the simulator gained
notifications and this got easier.

Your loop is therefore:

1. **Develop against the injected signal.** `harness.audio.emit(.routeChanged)`
   in `Tests/CurrawongTests` — the seam sixteen-odd existing tests already use.
   This is where a fix gets its unit tests, on either platform, headlessly.
2. **Confirm on the device.** §7. There is no substitute.

## 4. The mechanism, precisely

`escalateForCapture()` (`AudioIO.swift`) switches the session from
`AudioSessionPolicy.listening` (`.playback`) to `.radio`
(`.playAndRecord`/`.voiceChat`) before opening the microphone. That category
change is a route change. iOS posts it. `RadioSession.handle(_:)` receives
`.routeChanged`, and `resumeAcrossRouteChange()` drops transmit and schedules a
re-key.

**This is correct behaviour, not a bug in SF-3.** A route change during
transmit really can mean the accessory was unplugged, and dropping the
transmitter is the required response. The problem is that the app cannot tell
its *own* deliberate switch from a real one.

Why the switch exists at all: `BU-17`. Holding `.playAndRecord` for the whole
session pins a Bluetooth accessory into HFP, which gives 16 kHz receive audio
for the entire QSO, a permanently lit "in call" light, and — the reason it is
not merely a quality nicety — **a Q2L that mutes its own BLE PTT notifications
for as long as that idle call is up.** So the session drops back to `.listening`
after every over (on a 3 s linger, `listeningLingerNanoseconds`), and the next
over has to escalate again. The dance is the price of the button working.

`escalateForCapture()` already skips the change when `appliedPolicy` is already
`.radio` — which is why back-to-back overs inside the linger are clean, and why
this is specifically the *first* over after a pause.

## 5. Three things that make this worse than it looks

These came out of the trace and are the most useful part of this document.

1. **It is a cascade, not an event.** One deliberate switch produced **five**
   `routeChanged` signals in 440 ms. A fix that suppresses only the first
   notification will not work. This was already known — the second attempt at
   `BU-17` failed on exactly this, and its comment in `AudioIO.swift` lists the
   cascade as `categoryChange`, `override`, `newDeviceAvailable`,
   `engineConfigurationChange` — but the trace is the first time it has been
   counted.

2. **The cascade exhausts the resume budget in 440 ms.**
   `maximumAutomaticResumes` is 3. It exists to stop a genuinely flapping route
   producing an unbounded series of key-downs. Here it is spent entirely on one
   self-inflicted switch, so a *real* route change arriving later in the same
   hold has no budget left.

3. **The operator is shown a warning that is already untrue.** Past the cap,
   `resumeAcrossRouteChange()` takes `explain: true`, which raises the
   `.routeChanged` `SafetyNotice` — "press and hold to transmit again". Then the
   app re-keys itself **115 ms later**, off a resume scheduled before the cap
   was hit. (`resumeWork` is reassigned at `RadioSession.swift:1840` without
   cancelling the previous task, so all three scheduled resumes run; only the
   first gets past `beginTransmit`'s `guard !transmitDesired`, and the rest are
   no-ops.) Whether that un-cancelled task is a latent bug or load-bearing
   accident is worth deciding deliberately.

## 6. Constraints — do not violate these

- **SF-3 must still drop transmit on a real route change.** It is a safety
  requirement and it is not suppressible. Any fix must distinguish, not
  disable. Note the existing `BU-17` comment's warning: of the cascade, only
  the first signal is self-evidently ours, and the rest are indistinguishable
  from an accessory being unplugged *by inspection of the notification alone*.
- **Do not stop handing the route back.** The per-over switch is what keeps the
  Q2L's PTT alive (`BU-14`, proven by cross-transport test). Reverting to a
  held `.playAndRecord` session trades this bug for a dead button.
- **Do not "harmonise" macOS.** `BLUETOOTH-AUDIO.md` is explicit: macOS holding
  SCO only while transmitting is the reference behaviour, and making it match
  iOS would cost hi-fi receive audio and a usable TX indicator.
- **`NetworkClient` is the seam.** If a fix wants a protocol-specific type
  outside `CompositionRoot.swift`, stop — the fix belongs in the library.
- The usual: SPDX line 1, `make test` and `make test-macos` green before a PR,
  one task per branch.

## 7. The tooling that exists now

Built 2026-08-23. All of it is on `task/bu-15-simulator-probe`.

**The on-air UI target runs on an iOS device.** It was macOS-only, and was
built against `click()` / `typeKey()` / `rightClick()`, which do not exist off
macOS. `Tests/CurrawongOnAirUITests/Interaction.swift` now holds the operations
that genuinely differ; the `BU-9` delete tests stay macOS-only behind
`#if os(macOS)` because they are about the macOS context menu.

```sh
scripts/bu15-measure.sh VK1CPM          # from the repo root, in a real terminal
```

That drives one over and collects the device log immediately. Both halves
matter — see §8.

Four device-only traps are already paid for, and are documented at their call
sites:

| Trap | Symptom |
|---|---|
| The keyboard covers `Save` and the tab bar | Taps land on a key; `exists=true hittable=false`; nothing appears to happen |
| The panes are **tabs** on iPhone, not a split view | `no link button naming this channel` |
| `Add channel` **pushes** a form *inside* the Channels tab | `the test's channel vanished before it could be deleted`, after a perfect over |
| The callsign cannot come from the app's defaults on iOS | Runner and app are separate sandboxes; use `TEST_RUNNER_CURRAWONG_ONAIR_CALLSIGN`, and note it must be in `xcodebuild`'s **environment**, not a trailing build-setting override |

**A test cannot watch the app during its own gesture.** `press(forDuration:)`
blocks the main thread, and every route off it is refused: a backgrounded press
throws `Must be called on the main thread`; backgrounded sampling throws
`Activity cannot be used after its scope has completed`, or `Current context
must not be nil` if you wrap it in an activity of its own. All three were
tried. That is why the count comes from the log rather than from the UI.

## 8. Reading the phone's log — the part that will waste your morning

- `log stream --device` **no longer exists**.
- `log collect --device-name` works but **needs root**, and sudo needs a real
  TTY — it cannot prompt from inside a Claude Code `!` command.
- `Diagnostics` logs at `.info`, which os_log keeps in a **memory ring buffer
  rather than persisting**. A collect three minutes after a run kept 4 lines of
  a whole session; one six minutes after kept nothing of the run it was aimed
  at. **Collect immediately or there is nothing to collect** — which is why
  `bu15-measure.sh` does the run and the collect together.
- If you want the fuller trace persisted, raising those calls from `.info` to
  `.default` would do it. Not done, because nothing needed it yet.

## 9. Where the code is

| What | Where |
|---|---|
| The escalation, the hand-back, the linger | `Sources/Currawong/AudioIO.swift` — `escalateForCapture()`, `handRouteBack(afterLinger:)`, `completeHandback(_:attempt:playbackBaseline:)` |
| SF-3 and the resume | `Sources/Currawong/RadioSession.swift` — `handle(_:)`, `resumeAcrossRouteChange()`, `maximumAutomaticResumes` (550), `routeSettleNanoseconds` (555), `resumeWork` (516, 1840) |
| The policies | library, `RadioCore/AudioPipeline.swift` — `AudioSessionPolicy.radio` / `.listening` |
| Injected-signal tests | `Tests/CurrawongTests/RadioSessionTransmitTests.swift`, `RadioSessionActivityTests.swift` |
| The simulator probe | `Tests/CurrawongTests/BU15SessionProbeTests.swift` |
| The on-air tests | `Tests/CurrawongOnAirUITests/BU15FirstOverUITests.swift`, `M17EndOfOverUITests.swift` |

## 10. What would count as fixed

One continuous hold produces **one** `key-down on air` and no `SafetyNotice`,
on a device, with and without the Q2L attached — and the injected-signal tests
still show that a route change the app did *not* cause still drops transmit.

The reviewer's question will be "how do you know this is your own switch and
not an unplugged accessory?", so whatever distinguishes them should be the
first thing the change explains.

## 11. Open questions, offered rather than prescribed

Not researched, and deliberately not implemented — the design decision is the
next person's.

- Is there a signal that identifies the app's own switch? A window around the
  `setCategory` call is the obvious candidate and is the crudest; the previous
  attempt's failure was assuming *only* the first signal is ours, so any window
  has to cover the whole cascade without swallowing a real change that lands
  inside it.
- Should the escalation happen **before** the key-down rather than as part of
  it, so the cascade lands while idle and SF-3 has nothing to drop? That is
  precisely the trick `configureSession()` already uses
  (`handRouteBack(afterLinger: false)`, "the route-change cascade this causes
  lands while idle"). The cost is deciding when to escalate — on connect? on
  touch-down before key-down? — and what re-escalates after a hand-back.
- Should the resume budget exclude self-inflicted changes rather than the
  changes being suppressed? That fixes §5.2 and §5.3 without touching SF-3's
  drop at all, but leaves the 385 ms of dead air.
- Is the un-cancelled `resumeWork` (§5.3) wanted? Cancelling it is a one-line
  change with its own test, and is separable from this fault.
