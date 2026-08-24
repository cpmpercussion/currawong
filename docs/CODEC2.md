# Codec2 in Currawong

Currawong embeds `Codec2.xcframework` — Codec2 3200 (FR-2.4), the voice codec an
M17 stream frame carries. The framework is built from source on your machine,
never committed, and linked dynamically for licensing reasons.

| | |
|---|---|
| Upstream | https://github.com/drowe67/codec2 |
| Version | 1.2.0, pinned to commit `06d4c11e699b0351765f10398abb4f663a984f36` |
| Slices | `ios-arm64`, `ios-arm64_x86_64-simulator`, `macos-arm64_x86_64` |
| Size | about 7.6 MB |
| Licence | LGPL-2.1 — see **The licence constraint** below |
| Built by | `make codec2` / `scripts/build-codec2-xcframework.sh` |
| In version control | No. `*.xcframework` is gitignored |

## Why the app builds it rather than getting it from the library

`swift-hamvoip` has its own `Codec2VoiceCodec`, but it sits behind `#if CODEC2`,
a flag the library only defines when `Codec2.xcframework` is present in its own
checkout. The framework is 7.6 MB of LGPL binary and is committed to neither
repository, so the checkout SPM makes of a resolved dependency never contains
one — and there is nowhere to run a build script inside that checkout. The net
effect is that for every downstream consumer, this app included, the library's
codec conformance does not exist.

That was verified against the published v0.2.0 by building a throwaway package
against it:

```
error: cannot find 'Codec2VoiceCodec' in scope
```

Everything else in `M17Kit` — `M17StreamPacket`, `M17CRC16`,
`M17StreamTransmitter`, `M17Client` — *is* available downstream; only the codec
conformance is missing. `M17Client` takes an injected `any VoiceCodec`, so the
app embeds the framework, supplies `Codec2Codec`
(`Sources/Currawong/Codec2Codec.swift`) and injects it. The library keeps its
own conformance for its tests and CLI.

## The licence constraint (LP-4)

Codec2 is LGPL-2.1. It may ship **only** as a dynamically linked framework
carrying its own licence text, and must never be statically linked into the app
binary. That is why `project.yml` declares it `embed: true, codeSign: true`
(Embed & Sign). `COPYING` travels inside every slice of the framework.

Do not add `-force_load` or `-all_load` for it, and do not convert it to a
static link: either would pull LGPL objects into the app binary.

The acknowledgements screen naming Codec2 and its licence exists as of
**APP-26**: `Settings → About`, from `Sources/Currawong/Acknowledgements.swift`.
The macOS build distributed outside the App Store additionally makes the
substitution §6 exists to permit performable, and that was measured rather than
asserted. See [`LICENSING.md`](LICENSING.md), which is now the place for all of
this; what stays here is the mechanics of building the framework.

### OQ-6 is open — for the App Store, and only there

Shipping Codec2 as a dynamic framework satisfies the letter of LP-4, but a
signed iOS app cannot have its framework substituted by the user, which is
precisely what LGPL §6 relinking exists to permit. That remains a licensing
judgement the maintainer owns, unresolved, and wanting a decision *before* App
Store submission rather than after.

**APP-26 narrowed it rather than answering it.** On the directly distributed Mac
build the substitution is genuinely performable — replace the framework,
re-sign, launch, all three confirmed working — so for that channel §6 is
satisfied rather than argued about. Nothing about it helps inside an App Store
bundle, which cannot be modified at all. `LICENSING.md` has the measurements.

## Building it

```sh
make codec2                              # or scripts/build-codec2-xcframework.sh
```

Requires `brew install cmake` (and Xcode with the iOS SDKs). Roughly four
minutes from cold; incremental afterwards.

`make generate`, `make build` and `make test` all depend on the framework and
build it automatically when it is missing, so a fresh clone needs no extra step
beyond having cmake installed.

`make distclean` removes it. That is deliberately separate from `make clean`,
because rebuilding costs four minutes and almost nothing you would run `clean`
for is fixed by discarding it.

## Where the recipe lives

The app's script is a thin locator of about 100 lines. The real 500-line build —
three slices, cross-compilation, the licence and dynamic-linking assertions —
lives in `swift-hamvoip`, which is the right place for it: codec2 is the
library's dependency and the build is the library's OQ-2 spike result.
Duplicating it here would leave two copies to keep in step.

The locator looks for the library's script in this order:

| Order | Location | Notes |
|---|---|---|
| 1 | `DerivedData/SourcePackages/checkouts/swift-hamvoip` | The SPM checkout xcodebuild already resolved, at exactly the pinned version. No network needed |
| 2 | `../swift-hamvoip` | A sibling working checkout |
| 3 | Clone of the pinned tag (`v0.2.0`) into `.build/` | Last resort |

The pinned tag in the script is kept in step with `project.yml`'s `from:` **by
hand**. It only matters for the clone fallback, but it is a manual coupling and
worth remembering when the dependency is bumped.

## Why it is gitignored

`.gitignore` excludes `*.xcframework`. Redistributing a third-party LGPL binary
from this repository is a decision nobody has taken.

## Testing

`Tests/CurrawongTests/Codec2CodecTests.swift` covers the app's conformance:
frame geometry (160 samples / 8 bytes / 20 ms), buffer sizes, a tone
round-tripping with its RMS energy roughly intact, silence staying silent,
distinct tones encoding differently, and input validation.

It deliberately does **not** pin bit-exact codec output. That would assert
things about an upstream build rather than about our code, and would break on
any codec2 bump.

Those tests are guarded by `#if canImport(Codec2)`, so they would compile to
nothing if the framework were missing — a suite that passes having tested no
codec at all. A separate, always-compiled `Codec2AvailabilityTests` in the same
file fails loudly in that case.

`Tests/CurrawongTests/M17CodecIntegrationTests.swift` covers the claim the
arrangement actually exists to support: that the app's codec can drive the
library's M17 path. A codec that encodes and decodes correctly is necessary and
not sufficient — if the geometry the app produced did not match what an
`M17StreamPacket` expects, every test in the file above would still pass. So it
asserts that two of our frames are exactly one 16-byte stream payload, runs a
one-second over through `M17StreamTransmitter` and back through
`M17StreamReceiver` requiring recognisable audio out the far end, and confirms
`M17Client` accepts the codec — which is the injection point
`CompositionRoot` will use when M17 becomes selectable. No socket is opened
(AU-5).

The dynamic-linking requirement is checked on the built artefact rather than
assumed. On an iOS device build the embedded binary reports *Mach-O 64-bit
dynamically linked shared library arm64*, the app links it as
`@rpath/Codec2.framework/Codec2`, and `COPYING` is present inside the embedded
bundle.

## State of M17 in the app

The codec is wired and tested. **M17 is not selectable in the UI**, and getting
there is an architecture task rather than a picker.

`CompositionRoot` builds a `RadioSession<IAX2Client>`, hard-wired to one client
type, and `RadioLink` is generic over `Client: NetworkClient`. Adding M17 as a
second mode means the session has to be able to hold either client — that is the
work, and it has not been done.

Nor has the M17 audio path ever been run against a real reflector by anyone.
Library-side transmit has never been sent to one, and decoded audio has never
been listened to. Treat M17 as believed-working, not working. **IAX2 is the
validated path** — see [`BRINGUP.md`](BRINGUP.md).
