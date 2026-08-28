#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# check-licence-notices.sh — verify the app's licence claims against the
# artefacts they are claims about.
#
# WHY THIS EXISTS
#   `Sources/Currawong/Acknowledgements.swift` names versions and a commit, and
#   `docs/LICENSING.md` explains why Codec2 may ship at all. Both are strings.
#   Two of the obligations they discharge are *conditions on the right to
#   distribute*, so a notice that has quietly gone stale — a bumped dependency,
#   a licence file dropped from the framework, a static link introduced by a
#   linker flag — is a distribution problem rather than a documentation one.
#   Everything here is cheap and mechanical, so it runs in CI on every push and
#   again before a release is packaged.
#
# USAGE
#   scripts/check-licence-notices.sh                  # source-level checks only
#   scripts/check-licence-notices.sh path/to/App.app  # ...and the built bundle
#
#   Exits non-zero on the first failure, listing all of them first.
#
# See docs/LICENSING.md.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACK="${REPO_ROOT}/Sources/Currawong/Acknowledgements.swift"
readonly PROJECT_YML="${REPO_ROOT}/project.yml"
readonly XCFRAMEWORK="${REPO_ROOT}/Codec2.xcframework"

APP_BUNDLE="${1:-}"

failures=0
pass() { printf '\033[1;32m  ok\033[0m   %s\n' "$1"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$1" >&2; failures=$((failures + 1)); }
skip() { printf '\033[1;33m  skip\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

# Pulls a `static let <name> = "<value>"` out of the acknowledgements file.
swift_constant() {
    sed -n "s/.*static let $1 = \"\\([^\"]*\\)\".*/\\1/p" "${ACK}" | head -1
}

head_ "The versions the About screen claims"

# swift-hamvoip: Acknowledgements.libraryVersion against project.yml's `from:`.
# There is no runtime way to read an SPM pin out of a built app, so the constant
# is hand-kept and this is the thing that keeps it honest.
claimed_library="$(swift_constant libraryVersion)"
pinned_library="$(sed -n 's/^ *from: *\([0-9][0-9.]*\) *$/\1/p' "${PROJECT_YML}" | head -1)"
if [[ -z "${claimed_library}" || -z "${pinned_library}" ]]; then
    fail "could not read the swift-hamvoip version from both sides (claimed='${claimed_library}' pinned='${pinned_library}')"
elif [[ "${claimed_library}" == "${pinned_library}" ]]; then
    pass "swift-hamvoip ${claimed_library} matches project.yml"
else
    fail "About screen says swift-hamvoip ${claimed_library}; project.yml pins ${pinned_library}.
       Update Acknowledgements.libraryVersion in the same commit as the bump."
fi

# Codec2: the claimed version and commit against the notice the library's build
# script wrote into the framework that is actually embedded.
claimed_codec2="$(swift_constant codec2Version)"
claimed_commit="$(swift_constant codec2Commit)"
notice="${XCFRAMEWORK}/LICENCE-NOTICE.txt"
if [[ ! -f "${notice}" ]]; then
    skip "Codec2.xcframework not built — run \`make codec2\` to check its version and licence"
else
    if grep -q "Codec2 ${claimed_codec2}\$" "${notice}"; then
        pass "Codec2 ${claimed_codec2} matches the embedded framework"
    else
        fail "About screen says Codec2 ${claimed_codec2}; $(grep -m1 'contains Codec2' "${notice}" || true)"
    fi
    if grep -q "${claimed_commit}" "${notice}"; then
        pass "Codec2 commit ${claimed_commit:0:12} matches the embedded framework"
    else
        fail "About screen names codec2 commit ${claimed_commit}, which the framework notice does not.
       The LGPL wants the *corresponding* source, so this one is not cosmetic."
    fi
fi

head_ "LP-4 — Codec2 is dynamically linked and carries its licence"

# The COPYING file, per slice. LGPL-2.1 §6 requires the licence text travel with
# the executable; the framework bundle is where it travels.
if [[ ! -d "${XCFRAMEWORK}" ]]; then
    skip "Codec2.xcframework not built — licence text and linkage unchecked"
else
    if [[ -f "${XCFRAMEWORK}/COPYING" ]]; then
        pass "COPYING at the XCFramework root"
    else
        fail "no COPYING at the XCFramework root"
    fi

    slices=0
    while IFS= read -r fw; do
        slices=$((slices + 1))
        name="$(basename "$(dirname "${fw}")")"

        # Versions/A/Resources on macOS, the bundle root on iOS.
        if [[ -f "${fw}/COPYING" || -f "${fw}/Versions/A/Resources/COPYING" ]]; then
            pass "${name}: COPYING present"
        else
            fail "${name}: no COPYING inside the framework bundle"
        fi

        binary="${fw}/Codec2"
        [[ -f "${binary}" ]] || binary="${fw}/Versions/A/Codec2"
        if [[ ! -f "${binary}" ]]; then
            fail "${name}: no Codec2 binary found"
        elif file "${binary}" | grep -q 'dynamically linked shared library'; then
            pass "${name}: dynamically linked shared library"
        else
            fail "${name}: not a dynamic library — $(file -b "${binary}").
       LP-4 forbids static linking of Codec2 and LGPL-2.1 is why."
        fi
        # `-L` so a symlinked framework — how a local checkout often gets one —
        # is walked rather than silently reported as having no slices.
    done < <(find -L "${XCFRAMEWORK}" -maxdepth 2 -type d -name '*.framework')
    [[ ${slices} -gt 0 ]] || fail "no framework slices found inside ${XCFRAMEWORK}"
fi

# The linker flags that would silently undo all of the above. `project.yml` is
# where they would be added, and the whole point is that nobody would notice.
if grep -qE -- '-force_load|-all_load' "${PROJECT_YML}"; then
    if grep -B2 -E -- '-force_load|-all_load' "${PROJECT_YML}" | grep -qi 'do not add'; then
        pass "no -force_load/-all_load (only the comment forbidding them)"
    else
        fail "project.yml contains -force_load or -all_load, which would pull LGPL objects into the app binary (LP-4)"
    fi
else
    pass "no -force_load/-all_load in project.yml"
fi

head_ "The entitlement the LGPL substitution depends on"

# Not a licensing detail dressed up as a build check. Under the hardened runtime
# a notarised app refuses to load a framework signed by anybody else, so without
# this entitlement the Codec2 the user builds cannot load and §6's substitution
# right is documented rather than available. And the file has to *parse*:
# codesign uses AMFI's XML reader, which rejected this file over a double hyphen
# inside a comment and said only "syntax error near line 48".
readonly MACOS_ENTITLEMENTS="${REPO_ROOT}/Sources/Currawong/Currawong-macOS.entitlements"
if [[ ! -f "${MACOS_ENTITLEMENTS}" ]]; then
    fail "no Sources/Currawong/Currawong-macOS.entitlements — the Mac build cannot be signed for distribution"
else
    if plutil -lint "${MACOS_ENTITLEMENTS}" >/dev/null 2>&1; then
        pass "Currawong-macOS.entitlements parses"
    else
        fail "Currawong-macOS.entitlements is not a valid plist: $(plutil -lint "${MACOS_ENTITLEMENTS}" 2>&1)"
    fi

    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' \
        "${MACOS_ENTITLEMENTS}" 2>/dev/null | grep -q true; then
        pass "com.apple.security.cs.disable-library-validation is set"
    else
        fail "com.apple.security.cs.disable-library-validation is not set in the macOS entitlements.
       Without it a notarised build refuses a user-built Codec2 and LGPL-2.1 §6's
       substitution right becomes unavailable. See docs/LICENSING.md."
    fi

    # Both platforms must be in the same keychain group or the secret store
    # works on one of them.
    ios_group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' \
        "${REPO_ROOT}/Sources/Currawong/Currawong.entitlements" 2>/dev/null || true)"
    macos_group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' \
        "${MACOS_ENTITLEMENTS}" 2>/dev/null || true)"
    if [[ -n "${ios_group}" && "${ios_group}" == "${macos_group}" ]]; then
        pass "both platforms name the same keychain access group"
    else
        fail "keychain access groups differ: iOS '${ios_group}' vs macOS '${macos_group}'"
    fi
fi

head_ "The About screen says what the licences require"

# Not a test of prose. Each of these is a phrase a licence asks for by name, and
# the tests in AcknowledgementsTests assert the structure; this asserts the
# words survive an edit.
require_phrase() {
    if grep -qF "$1" "${ACK}"; then
        pass "$2"
    else
        fail "$2 — the phrase \"$1\" is no longer in Acknowledgements.swift"
    fi
}
require_phrase "covered by the GNU Lesser General Public License" \
    "LGPL-2.1 §6: the notice that the library is used and is covered by the licence"
require_phrase "linked dynamically and is never statically linked" \
    "LP-4 stated where a user can read it"
require_phrase "this notice is not removed" \
    "libgsm: the notice its terms forbid removing"
require_phrase "you may replace it with your own build of Codec2" \
    "LGPL-2.1 §6: the substitution right, stated to the user"

if [[ -n "${APP_BUNDLE}" ]]; then
    head_ "The built bundle: $(basename "${APP_BUNDLE}")"

    if [[ ! -d "${APP_BUNDLE}" ]]; then
        fail "${APP_BUNDLE} is not a bundle"
    else
        # macOS layout; the iOS one is Frameworks/ at the bundle root.
        embedded="${APP_BUNDLE}/Contents/Frameworks/Codec2.framework"
        [[ -d "${embedded}" ]] || embedded="${APP_BUNDLE}/Frameworks/Codec2.framework"

        if [[ ! -d "${embedded}" ]]; then
            fail "no Codec2.framework embedded in the bundle — either M17 audio is gone or it was linked statically"
        else
            pass "Codec2.framework is embedded as a separate framework"

            if [[ -f "${embedded}/Versions/A/Resources/COPYING" || -f "${embedded}/COPYING" ]]; then
                pass "the LGPL text ships inside the bundle the user receives"
            else
                fail "the embedded framework has no COPYING — §6 requires the licence accompany the executable"
            fi

            main="${APP_BUNDLE}/Contents/MacOS/Currawong"
            [[ -f "${main}" ]] || main="${APP_BUNDLE}/Currawong"
            # The two platforms spell the load command differently — macOS uses
            # the versioned framework layout, `Codec2.framework/Versions/A/Codec2`,
            # and iOS the flat one, `Codec2.framework/Codec2`. Matching only the
            # flat form failed on a perfectly good Mac build. What matters is
            # that the framework is named at `@rpath` at all: that is a dynamic
            # link, which is what LP-4 requires and a static link could not
            # produce.
            if [[ -f "${main}" ]] \
                && otool -L "${main}" 2>/dev/null | grep -q '@rpath/Codec2.framework/'; then
                pass "the app links Codec2 at @rpath, not statically"
            else
                fail "the app binary does not name Codec2.framework at @rpath in its load commands"
            fi
        fi
    fi
fi

printf '\n'
if [[ ${failures} -eq 0 ]]; then
    printf '\033[1;32mAll licence checks passed.\033[0m\n'
else
    printf '\033[1;31m%d licence check(s) failed.\033[0m See docs/LICENSING.md.\n' "${failures}" >&2
    exit 1
fi
