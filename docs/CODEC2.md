# Codec 2 in Currawong

**Currawong ships no `Codec2.xcframework`, and no LGPL code at all.** Codec 2
3200 (FR-2.4) is still the voice codec an M17 stream frame carries; it is
`M17Kit.WeebillVoiceCodec` that encodes and decodes it — the library's own
pure-Swift implementation (M17-7), Apache-2.0 like everything else, arriving
over SPM with the rest of `swift-hamvoip`.

There is one codec on the M17 path and one place it is constructed:
`CompositionRoot.makeVoiceCodec()`.

## What was removed, and when

The app embedded a 7.6 MB `Codec2.xcframework` built from
[drowe67/codec2](https://github.com/drowe67/codec2) at 1.2.0, with its own
conformance in `Sources/Currawong/Codec2Codec.swift`, from the first M17 work
until **APP-31 (2026-08-29)**.

It was there for a good reason. The library has a `Codec2VoiceCodec` of its own,
but it sits behind `#if CODEC2` — a flag defined only when the XCFramework is
present in the library's *own* checkout. The framework is committed to neither
repository, and nothing can run a build script inside the checkout SPM makes of
a resolved dependency, so for every downstream consumer that conformance simply
did not exist:

```
error: cannot find 'Codec2VoiceCodec' in scope
```

`M17Client` takes an injected `any VoiceCodec`, so the app built the framework
and supplied its own conformance.

**Weebill removed the reason.** Being Swift rather than a C library behind an
XCFramework, it survives being consumed over SPM, so the app stopped needing to
carry a codec to have one. APP-27 switched `makeVoiceCodec()` to Weebill on
2026-08-28 and both directions were proven on air the same day. The framework
stayed in the build for a while after that — nothing called it, but keeping it
meant the two implementations could still be compared by swapping one line.
APP-31 took the maintainer's decision that Weebill works and removed it.

## What went with it

| Gone | Was |
|---|---|
| `Codec2.xcframework` | 7.6 MB of LGPL-2.1 binary, embedded and signed in every build |
| `Sources/Currawong/Codec2Codec.swift` | the app's `VoiceCodec` conformance, behind `#if canImport(Codec2)` |
| `Tests/CurrawongTests/Codec2CodecTests.swift` | its unit tests, and the availability test that failed loudly when the framework was missing |
| `scripts/build-codec2-xcframework.sh` | a ~100-line locator for the library's ~500-line build |
| `make codec2`, and the framework prerequisite on `generate` | four minutes and a `brew install cmake` before a fresh clone could build |
| `cmake` in `ci_scripts/ci_post_clone.sh`, and the framework build | roughly four minutes on *every* Xcode Cloud build, uncacheable |
| `M17LinkError.codecUnavailable` | unreachable since APP-27 |

`Tests/CurrawongTests/M17CodecIntegrationTests.swift` is **kept**, and now runs
against `CompositionRoot.makeVoiceCodec()` rather than a named type. Weebill's
own encode/decode correctness is the library's to test; what stayed the app's to
prove is the fit — that two of the injected codec's frames are exactly one
16-byte `M17StreamPacket` payload, that an over round-trips through
`M17StreamTransmitter` and `M17StreamReceiver` as recognisable audio, and that
`M17Client` accepts what the composition root hands it. Get that wrong and
everything still compiles while every over goes out misaligned.

## Two obligations this discharges

Both applied to the framework and to nothing else, so both lapse with it. Both
are the **library's** requirements, and this note records only the app's side of
them — amending either is a change to
`swift-hamvoip/docs/DESIGN-REQUIREMENTS.md`, not something the app can do.

- **LP-4** — Codec 2 is LGPL-2.1, so it could ship only as a dynamically linked
  framework carrying its own `COPYING`, never statically linked. That is why
  `project.yml` declared it `embed: true, codeSign: true`. With no LGPL code in
  the app, LP-4 has nothing here to constrain.
- **OQ-6** — the open question of whether shipping an LGPL library inside a
  signed iOS app really satisfies LGPL §6, given that a user cannot substitute
  the framework. It wanted deciding *before* App Store submission. It is now
  **avoidable rather than answered**: the app no longer does the thing the
  question was about. Reopening it means reintroducing an LGPL dependency.

The acknowledgements screen that was outstanding for Codec 2's licence is no
longer required for that reason.

## If it ever needs to come back

Nothing here is one-way. The framework build lives in `swift-hamvoip`
(`scripts/`, the OQ-2 spike result) and was only ever *located* by the app's
deleted script — that is still the right place for it, and it is still there.
Reintroducing the framework would mean restoring the app-side conformance and
the embed, and reopening both LP-4 and OQ-6 with it. Do not do it casually; the
point of APP-31 is that there is now one Codec 2 in this app, and it is Swift.
