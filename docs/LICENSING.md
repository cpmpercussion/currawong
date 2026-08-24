# Licensing the macOS download

**APP-26.** What Currawong ships that is not Currawong, what each licence
requires of us, and how the Mac build distributed outside the App Store
satisfies the one licence that constrains anything.

Short version: **it is fine, and it was the App Store that was ever the
problem.** Codec2's LGPL-2.1 wants the recipient to be able to replace the
library. On a download that is true and was measured to be true. Inside a signed
App Store bundle it is not, which is what `OQ-6` is about — and `OQ-6` stays open
for iOS regardless of anything here.

## What the app ships

| Component | Version | Licence | How it is linked | Obligation |
|---|---|---|---|---|
| Currawong | 0.1.0 | Apache-2.0 | ours | notice, licence text |
| `swift-hamvoip` | 0.5.4 | Apache-2.0 | compiled in | notice, licence text |
| Codec2 | 1.2.0 (`06d4c11e`) | **LGPL-2.1** | dynamic framework | notice, licence text, source, **substitution** |
| libgsm (GSM 06.10) | 1.0.22 | TU-Berlin permissive | compiled in (vendored in `CGSM`) | notice, verbatim, not removed |

`swift-argument-parser` is deliberately absent: it is a dependency of the
library's `hamvoip-cli` executable target, and the app links `RadioCore`,
`IAX2Kit`, `M17Kit` and `EchoLinkKit`. Acknowledging code we do not ship would
be its own small dishonesty. `AcknowledgementsTests` asserts it stays absent.

The list lives in `Sources/Currawong/Acknowledgements.swift` as data rather than
prose, because two of these four obligations are conditions on the right to
distribute rather than courtesies. `scripts/check-licence-notices.sh` checks the
claims against the artefacts, and CI runs it on every push.

## Where the user is told

`Settings → About` (`AboutPane`), which lists every component, its licence, how
it is linked, and its notice. LGPL-2.1 §6 asks for a *prominent* notice that the
library is used and is covered by that licence; a line in a README is not a
notice given to the person running the application. The Codec2 entry is expanded
by default for that reason.

The download carries the same thing again as files: `LICENSES/` at the top level
of the zip, and `README-FIRST.txt` with the substitution procedure. The licence
text also travels inside the app bundle — `COPYING` is inside
`Codec2.framework` — but "inside a framework inside a bundle" is not where
anybody looks.

## Codec2 and LGPL-2.1 §6

§6 lets us distribute a work that uses the library, provided the recipient may
modify the library and relink. Four things discharge it:

1. **Dynamic linking only** (`LP-4`). Codec2 is its own framework inside the
   bundle and is never statically linked into the app binary. This is §6(b)'s
   own suggested route. `project.yml` declares it Embed & Sign; adding
   `-force_load` or `-all_load` would undo it, and the check script fails if
   either appears.
2. **The licence text accompanies the executable.** `COPYING` inside every
   framework slice, and again in `LICENSES/` in the download.
3. **The notice.** In the About screen and in `README-FIRST.txt`, naming the
   licence and its version, and saying plainly that Currawong itself is not
   covered by it.
4. **The corresponding source.** Every release carries
   `codec2-<commit>-source.tar.gz`, fetched by commit rather than by tag —
   §6 wants the source that corresponds to the binary, and a tag is a name that
   can be moved. Offered from the same place as the binary, which is §6's own
   "equivalent access from the same place".

### The substitution works, and that was measured

Documented procedure, in `README-FIRST.txt`: replace
`Currawong.app/Contents/Frameworks/Codec2.framework`, re-sign the application
(`codesign --force --deep --sign -`), launch.

Run end to end on 2026-08-24 against a Developer ID-signed, hardened build:

| What was done | Result |
|---|---|
| Replace the framework, re-sign the whole application | **Verifies and launches**, using the replacement |
| Replace the framework, keep our signature | Killed on launch |

The second row is not a licensing problem, it is what a code signature is: an
application's signature seals the files nested inside it. Which is exactly why
the instructions say to re-sign, rather than stopping at "replace the
framework" and leaving the user to discover a SIGKILL.

### What `disable-library-validation` does and does not do

The macOS build carries `com.apple.security.cs.disable-library-validation`
(`Sources/Currawong/Currawong-macOS.entitlements`, applied for `sdk=macosx*`
only). Under the hardened runtime that notarisation requires, macOS refuses to
load nested code signed by another team; this turns that off for this app.

Being accurate about how much that matters: **the documented procedure does not
need it.** Re-signing the application ad-hoc makes the app and the framework the
same signer and drops the hardened runtime with it, so library validation never
applies. What the entitlement adds is the case where the two signers differ — a
Codec2.framework signed by somebody else, inside an application re-signed
without it. That is a real way to relink and would otherwise fail.

So dynamic linking is the basis on which this build is distributable, and the
entitlement is one more route left open at the cost of this app's own library
validation. Taken deliberately, and it does not close `OQ-6`: no entitlement
helps inside an App Store bundle, which cannot be modified at all.

## Signing: the trap, written down

The app carries `keychain-access-groups` — see `Currawong.entitlements`, it is
what makes the secret store work on macOS. It is a **restricted** entitlement
and must be authorised by a provisioning profile embedded in the bundle. Sign
without one and nothing complains: `codesign --verify --deep --strict` reports
*valid on disk* and *satisfies its Designated Requirement*, and then the kernel
kills the process on launch with SIGKILL and no message anywhere.

Measured the same day, signing one bundle four ways:

| Entitlements | Embedded profile | Result |
|---|---|---|
| none | no | launches |
| `disable-library-validation` only | no | launches |
| `keychain-access-groups` | no | **killed (SIGKILL)** |
| `keychain-access-groups` | yes | launches |

`com.apple.security.cs.*` needs no profile; the keychain group does. An earlier
version of `package-macos-release.sh` signed the bundle directly with `codesign`
to avoid provisioning profiles altogether, and produced an app that passed every
check and died on launch. It now uses `xcodebuild archive` plus `-exportArchive`
with `method: developer-id`, which fetches or creates the profile and embeds it,
and then **asserts the profile is there** so this cannot be silent again.

The ad-hoc fallback build therefore ships with *no* entitlements at all: an
ad-hoc signature has no team, so the keychain group would name a group the app
cannot be in, and per the table that is not a degraded keychain but a bundle the
kernel refuses to start. It launches, and the secret store does not work. That
is why it is labelled as a build to test the packaging rather than one to operate
a station with — in the packaged read-me and in the job summary.

## Releasing

```sh
make release-macos                      # your Developer ID, or ad-hoc
make release-macos NOTARISE=--notarise  # ...and notarise
```

`.github/workflows/release-macos.yml` runs the same script when a release is
published and attaches `dist/*` to it. `PD-5` wants Developer ID plus
notarisation for macOS and Xcode Cloud distributes only to TestFlight and the
App Store, so this is the other half of `PD-5` — `APP-25` is the iOS half. Both
are triggered by the same release.

### Secrets

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12` | Developer ID Application certificate and key, `base64`-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | the password the `.p12` was exported with |
| `ASC_KEY_P8` | App Store Connect API key (`.p8`), `base64`-encoded |
| `ASC_KEY_ID` | that key's ID |
| `ASC_ISSUER_ID` | the issuer ID from App Store Connect |

The API key does two jobs — it authenticates the provisioning-profile fetch and
it notarises — which is why there is no app-specific password in the list.
`NOTARY_APPLE_ID`/`NOTARY_TEAM_ID`/`NOTARY_PASSWORD` still work as an
alternative for notarisation if that is easier.

With no secrets at all the workflow still runs and attaches an ad-hoc build,
with the warning above. That exercises the pipeline; it does not produce
something to give anybody.

### Local export failing with "No Accounts"

The identity is in the keychain but nothing can fetch a profile. Open Xcode →
Settings → Accounts and sign in again — a stale Apple ID token reports exactly
this (`Invalid credentials in keychain … missing Xcode-Token`), which is how it
presented here on 2026-08-24.

## Redistributing the framework at all

`.gitignore` excludes `*.xcframework` with the note that redistributing a
third-party LGPL binary *from this repository* is a decision nobody had taken.
Attaching it to a release is redistribution too, and that decision has now been
taken: it is what a downloadable Mac build is. The obligations that come with it
are the four above, and they are why they are checked rather than remembered.
