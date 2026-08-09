# Currawong

A SwiftUI client for internet-linked amateur radio voice modes, on iOS and
macOS. Named for a bird with a distinctive, far-carrying call, locally notable
in VK1.

Currawong is the app half of the project. The protocols live next door in
[`swift-hamvoip`](../swift-hamvoip) — AllStarLink/IAX2 today, M17 and possibly
EchoLink later — and **no protocol code lives in this repository**. The app
talks to the libraries through `RadioCore.NetworkClient` and knows nothing about
RFC 5456. The one place a concrete client is named is
`Sources/Currawong/CompositionRoot.swift`.

## Status

**Scaffold (APP-1).** It builds, it launches, it runs its tests, and that is
all it does. There is no connect screen, no PTT button, no audio and no
settings; the root view is a placeholder that displays transmit state and says
so. On-screen PTT and the connect screen are APP-2, Bluetooth PTT is Phase 5.

Nothing here has been on the air.

## Building and testing from the terminal

You need Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a checkout of `swift-hamvoip` as a sibling
directory:

```
ham-voip-project/
├── swift-hamvoip
└── currawong
```

The `.xcodeproj` is generated from `project.yml` and is not in version control,
so generate it first:

```sh
make generate      # xcodegen generate
make build         # build for a generic iOS device
make build-macos   # build for macOS
make test          # run the unit tests on an iOS simulator
make test-macos    # run the unit tests on macOS
make clean         # remove the generated project and all build output
```

`make test` picks an installed iPhone simulator for you
(`scripts/pick-simulator.sh`); override it with `make test SIMULATOR='iPhone 16'`.

Or without make:

```sh
xcodegen generate
xcodebuild build -scheme Currawong -destination 'generic/platform=iOS'
xcodebuild test  -scheme Currawong -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Signing is set to the maintainer's team. Building under a different account
wants `DEVELOPMENT_TEAM=XXXXXXXXXX` on the command line, or
`CODE_SIGNING_ALLOWED=NO` for an unsigned CI build.

## Dependency on the library

`project.yml` declares `swift-hamvoip` as a **local path dependency**
(`../swift-hamvoip`), because the library is not published yet and the two are
developed together. At the library's first tagged release this becomes an
ordinary versioned git dependency; the comment in `project.yml` says so too.

## What the app is allowed to know

- Views and view models use `RadioCore` vocabulary only — `NetworkClient`,
  `TransmitState`. If something up here needs an IAX2-shaped type, the fix
  belongs in the library's protocol, not in a cast.
- Background modes are `audio` and `bluetooth-central`, and nothing else.
- No CallKit, no volume-button PTT, no multicast entitlement.

## Licence

Apache-2.0, the same as the library. See [LICENSE](LICENSE).
