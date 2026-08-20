# Currawong — agent instructions

The SwiftUI client for the `swift-hamvoip` protocol libraries. Apache-2.0.

**The plan lives in the library repo, not here:**
`../swift-hamvoip/docs/DEVELOPMENT-PLAN.md` — §1 "How to work" applies to this
repo too, and **Phase 4 (APP-1 … APP-4)** is the task list for this app.
Requirements background: `../swift-hamvoip/docs/DESIGN-REQUIREMENTS.md`.
Read the library repo; **never write to it.** It is a separate repo with its own
history and its own agents.

## Decisions already made — do not revisit

- App name **Currawong**; bundle identifier **`au.charlesmartin.currawong`**.
  Extensions extend it (`au.charlesmartin.currawong.liveactivity`); the Keychain
  access group is `$(TeamID).au.charlesmartin.currawong`.
- Separate repo from the library, depending on it via SPM. **Versioned git
  dependency** (`from: 0.1.0`) as of the library's first release — the build no
  longer needs a sibling checkout, and the path dependency must not be
  committed back. A sibling checkout is still how you *read* the plan and the
  requirements, below.
- **xcodegen** with `project.yml`. **The `.xcodeproj` is generated and never
  committed** — change `project.yml`, then `make generate`. So is
  `Sources/Currawong/Info.plist`; edit the `info.properties` block in
  `project.yml` instead.
- Deployment targets **iOS 16.2** / macOS 13. The iOS floor was 16.0, matching
  the library; APP-3 raised it for ActivityKit — 16.1 for the framework, 16.2
  for `ActivityContent`, `update(_:)` and `end(_:dismissalPolicy:)`, which are
  the three that stop the Live Activity from lying. **The library's floor stays
  at iOS 16.0** and must not be bumped from here.

## Hard rules (violations get the PR closed)

- Line 1 of every Swift file: `// SPDX-License-Identifier: Apache-2.0`.
- **PD-4: CallKit MUST NOT be used.** Wrong semantics, regionally restricted.
- **PT-6: volume-button interception MUST NOT be used.** Fails App Store review.
- **PT-5: do not rely on `GCKeyboard`** — foreground-only.
- Background modes are **`audio` and `bluetooth-central` only** (PD-2). Do not
  add `voip`. Do not request `com.apple.developer.networking.multicast` (PD-3).
- **The app talks to the library through `RadioCore.NetworkClient`.** Views and
  view models use `NetworkClient` and `TransmitState` and know nothing about
  IAX2, M17 or EchoLink. The one exception is the composition root
  (`Sources/Currawong/CompositionRoot.swift`), which constructs the concrete
  `IAX2Client` and its `IAX2Destination`. If you find yourself wanting a
  protocol-specific type anywhere else, **stop and report it** — the fix is a
  missing piece of `NetworkClient` in the library, not a cast up here.
- No third-party dependencies unless a plan task names one.
- Everything must build and test from the terminal. Do not add a workflow that
  requires opening Xcode.

## Safety requirements that shape the UI

- **SF-1** transmit watchdog: enforced by the library's client, 180 s default.
- **SF-2** BLE link loss during transmit must drop transmit.
- **SF-3** audio interruption or route change must drop transmit. Whoever wires
  `RadioCore.AudioPipeline` **must** consume its `signals` stream — the pipeline
  deliberately does not act on interruptions itself. Note also that
  `configureSession()` and `startCapture(onFrame:)` both `throw`.
- **SF-4** transmit state must be visible without unlocking the device (APP-3,
  Live Activity).

A stuck open microphone into a repeater is the failure mode all of this exists
to prevent.

## Working here

```sh
make generate && make build && make test
```

Both must be green before you open a PR. One task per branch (`task/app-2`),
one PR per task.
