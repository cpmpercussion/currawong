#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# package-macos-release.sh — build the Mac app and everything that must travel
# with it, ready to attach to a GitHub release.
#
# WHAT COMES OUT
#   dist/Currawong-<version>-macOS.zip     the .app, its licences, and a read-me
#   dist/codec2-<commit>-source.tar.gz     the corresponding Codec2 source
#   dist/SHA256SUMS.txt
#
# WHY THE SOURCE TARBALL IS NOT OPTIONAL
#   Codec2 is LGPL-2.1 and this is the one route by which Currawong is
#   distributed as a binary somebody else runs. §6 lets us ship a work that uses
#   the library provided the recipient can modify the library and relink; the
#   dynamic framework and the library-validation entitlement make that
#   performable, and this tarball is the "complete corresponding source" half of
#   the same clause, offered from the same place as the binary. Attaching one
#   without the other is not a smaller compliance story, it is a different one.
#   See docs/LICENSING.md.
#
# SIGNING
#   Developer ID plus notarisation is what PD-5 asks for and what makes a
#   download somebody can open. It needs an identity in the keychain:
#
#     scripts/package-macos-release.sh --identity "Developer ID Application: Name (TEAMID)"
#     scripts/package-macos-release.sh --identity auto --notarise
#
#   With no identity the build is signed ad-hoc, which is enough to run locally
#   and NOT enough to hand to anybody — Gatekeeper will refuse it and the
#   Keychain access group does not resolve, so stored secrets may fail. The
#   script says so in the read-me it packages, rather than pretending otherwise.
#
#   Signing needs a provisioning profile too, and that is not optional: the app
#   carries the restricted `keychain-access-groups` entitlement, and macOS
#   SIGKILLs a bundle that claims it without an embedded profile — after
#   codesign has called the signature valid. The export step fetches and embeds
#   one, which needs an Apple ID signed in to Xcode locally, or in CI:
#     ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID   (an App Store Connect API key)
#
#   --notarise uses the same API key, or an Apple ID and app-specific password:
#     NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#
# USAGE
#   scripts/package-macos-release.sh [--identity auto|<name>] [--notarise]
#                                    [--version X.Y.Z] [--output dist]
#
# See docs/LICENSING.md and docs/DEVELOPMENT-PLAN.md (APP-26).

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

IDENTITY=""
NOTARISE=0
VERSION=""
OUTPUT="dist"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
        --notarise|--notarize) NOTARISE=1; shift ;;
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --output) OUTPUT="${2:?--output needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

readonly DERIVED="${REPO_ROOT}/build/release-macos"
readonly ARCHIVE="${REPO_ROOT}/build/Currawong"
readonly EXPORT_DIR="${REPO_ROOT}/build/export-macos"
# Set once the version is known: the staging directory is the folder name the
# recipient sees when they unzip, so it is named for the release rather than for
# the build step that made it.
STAGE=""

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
note() { printf '\033[1;32m  ->\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preconditions

command -v xcodegen >/dev/null || die "xcodegen not found. brew install xcodegen"
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode."

if [[ -z "${VERSION}" ]]; then
    VERSION="$(sed -n 's/^ *CFBundleShortVersionString: *"\([^"]*\)".*/\1/p' project.yml | head -1)"
    [[ -n "${VERSION}" ]] || die "could not read CFBundleShortVersionString from project.yml"
fi
note "version ${VERSION}"
STAGE="${REPO_ROOT}/build/Currawong-${VERSION}"

# `auto` picks the first Developer ID Application identity in the keychain, so
# CI (which imports exactly one) needs no name and a human need not paste theirs.
if [[ "${IDENTITY}" == "auto" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    if [[ -n "${IDENTITY}" ]]; then
        note "identity ${IDENTITY}"
    else
        warn "no Developer ID Application identity in the keychain; falling back to ad-hoc"
    fi
fi

if [[ ${NOTARISE} -eq 1 ]]; then
    [[ -n "${IDENTITY}" ]] || die "--notarise needs a Developer ID identity; an ad-hoc build cannot be notarised"
    # Either credential works. The API key is preferred because the same key
    # also authenticates the provisioning-profile fetch, so CI holds one secret
    # for both instead of an Apple ID and an app-specific password as well.
    if [[ -n "${ASC_KEY_PATH:-}" ]]; then
        : "${ASC_KEY_ID:?ASC_KEY_PATH needs ASC_KEY_ID}"
        : "${ASC_ISSUER_ID:?ASC_KEY_PATH needs ASC_ISSUER_ID}"
    elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
        : "${NOTARY_TEAM_ID:?NOTARY_APPLE_ID needs NOTARY_TEAM_ID}"
        : "${NOTARY_PASSWORD:?NOTARY_APPLE_ID needs NOTARY_PASSWORD (an app-specific password)}"
    else
        die "--notarise needs either ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD"
    fi
fi

# ------------------------------------------------------------------------ build

info "Codec2.xcframework"
if [[ -d Codec2.xcframework ]]; then
    note "already built"
else
    note "building (about four minutes)"
    scripts/build-codec2-xcframework.sh
fi

info "generating the project"
xcodegen generate

info "building Currawong for macOS"
rm -rf "${DERIVED}" "${ARCHIVE}.xcarchive" "${EXPORT_DIR}"

# **A distribution build needs an embedded provisioning profile, and this was
# established the hard way.**
#
# The app carries `keychain-access-groups` (Sources/Currawong/Currawong.entitlements
# — it is what makes the secret store work on macOS). That entitlement is
# *restricted*: it has to be authorised by a provisioning profile embedded in the
# bundle. Sign it without one and nothing complains — `codesign --verify --deep
# --strict` reports "valid on disk" and "satisfies its Designated Requirement" —
# and then the kernel kills the process on launch with SIGKILL and no message.
#
# Measured, on 2026-08-24, by signing the same bundle four ways:
#
#   entitlements                        embedded profile   result
#   ----------------------------------  -----------------  -----------------
#   none                                no                 launches
#   disable-library-validation only     no                 launches
#   keychain-access-groups              no                 killed (SIGKILL)
#   keychain-access-groups              yes                launches
#
# So `com.apple.security.cs.*` needs no profile and the keychain group does. An
# earlier version of this script signed the bundle directly with codesign to
# avoid profiles altogether; it produced an app that passed every check here and
# died on launch. Hence `archive` plus `-exportArchive`, which is Apple's own
# path for this and which fetches, or creates, the Developer ID profile and
# embeds it. The static check after the export is there so that this specific
# failure can never be silent again.

if [[ -n "${IDENTITY}" ]]; then
    TEAM_ID="$(sed -n 's/^ *DEVELOPMENT_TEAM: *\([A-Z0-9]*\).*/\1/p' project.yml | head -1)"
    [[ -n "${TEAM_ID}" ]] || die "could not read DEVELOPMENT_TEAM from project.yml"
    note "team ${TEAM_ID}"

    # A fresh CI runner has no Apple ID signed in, so an App Store Connect API
    # key is how `-allowProvisioningUpdates` authenticates. Locally, Xcode's own
    # accounts cover it and these are unset.
    auth_args=()
    if [[ -n "${ASC_KEY_PATH:-}" ]]; then
        : "${ASC_KEY_ID:?ASC_KEY_PATH needs ASC_KEY_ID}"
        : "${ASC_ISSUER_ID:?ASC_KEY_PATH needs ASC_ISSUER_ID}"
        auth_args=(
            -authenticationKeyPath "${ASC_KEY_PATH}"
            -authenticationKeyID "${ASC_KEY_ID}"
            -authenticationKeyIssuerID "${ASC_ISSUER_ID}"
        )
        note "authenticating with the App Store Connect API key"
    fi

    info "archiving"
    archive_args=(
        archive
        -project Currawong.xcodeproj
        -scheme Currawong
        -configuration Release
        -destination 'generic/platform=macOS'
        -archivePath "${ARCHIVE}"
        -derivedDataPath "${DERIVED}"
        -allowProvisioningUpdates
    )
    # `${#a[@]}` is the only safe thing to ask about a possibly-empty array in
    # the bash macOS ships (3.2) under `set -u`.
    [[ ${#auth_args[@]} -eq 0 ]] || archive_args+=("${auth_args[@]}")
    archive_args+=(
        DEVELOPMENT_TEAM="${TEAM_ID}"
        ENABLE_HARDENED_RUNTIME=YES
    )
    xcodebuild "${archive_args[@]}"

    # `signingCertificate` is named rather than left to chance: a machine with
    # both an Apple Development and a Developer ID certificate will otherwise
    # pick the wrong one, and the result fails Gatekeeper in a way that looks
    # like notarisation having gone wrong.
    cat > "${REPO_ROOT}/build/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

    info "exporting"
    export_args=(
        -exportArchive
        -archivePath "${ARCHIVE}.xcarchive"
        -exportPath "${EXPORT_DIR}"
        -exportOptionsPlist "${REPO_ROOT}/build/ExportOptions.plist"
        -allowProvisioningUpdates
    )
    [[ ${#auth_args[@]} -eq 0 ]] || export_args+=("${auth_args[@]}")
    if ! xcodebuild "${export_args[@]}"; then
        die "export failed.

     If it says \"No Accounts\" or \"No profiles for 'au.charlesmartin.currawong'\",
     the signing identity is present but nothing can fetch a provisioning
     profile. Locally: open Xcode > Settings > Accounts and sign in again — a
     stale Apple ID token reports exactly this. In CI: set ASC_KEY_PATH,
     ASC_KEY_ID and ASC_ISSUER_ID to an App Store Connect API key. The profile
     is not optional; see the table above."
    fi

    APP="${EXPORT_DIR}/Currawong.app"
else
    # No identity: build unsigned and sign ad-hoc, with **no entitlements**. An
    # ad-hoc signature carries no team, so the keychain access group would name
    # a group this app cannot be in — and per the table above that is not a
    # degraded keychain but a bundle the kernel refuses to start. Without the
    # entitlement it launches and the secret store does not work. That is the
    # honest shape of a build nobody should be handed, and the read-me this
    # packages says so.
    info "building unsigned (no Developer ID identity)"
    xcodebuild build \
        -project Currawong.xcodeproj \
        -scheme Currawong \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "${DERIVED}" \
        CODE_SIGNING_ALLOWED=NO

    mkdir -p "${EXPORT_DIR}"
    APP="${EXPORT_DIR}/Currawong.app"
    rm -rf "${APP}"
    ditto "${DERIVED}/Build/Products/Release/Currawong.app" "${APP}"

    info "signing ad-hoc"
    # Inside out: a bundle's signature seals its nested code, so the framework
    # is signed first or the outer signature is stale the moment it is made.
    while IFS= read -r nested; do
        codesign --force --sign - "${nested}"
    done < <(find "${APP}/Contents/Frameworks" -maxdepth 1 -mindepth 1 \
        \( -name '*.framework' -o -name '*.dylib' \) 2>/dev/null || true)
    codesign --force --sign - "${APP}"
fi

[[ -d "${APP}" ]] || die "no app at ${APP}"

# ---------------------------------------------- the check that would have saved
#
# Static, because it has to work on a headless runner, and because the dynamic
# version of this question is "does the kernel kill it", which is not a thing to
# find out from a user.
if [[ -n "${IDENTITY}" ]]; then
    profile="${APP}/Contents/embedded.provisionprofile"
    if [[ ! -f "${profile}" ]]; then
        die "the exported app has no embedded.provisionprofile.

     It carries the restricted \`keychain-access-groups\` entitlement, so macOS
     will SIGKILL it on launch — silently, and after codesign has pronounced it
     valid. Do not ship this. The export step is what embeds the profile."
    fi
    if security cms -D -i "${profile}" 2>/dev/null \
        | grep -q 'keychain-access-groups'; then
        note "embedded profile authorises the keychain access group"
    else
        die "the embedded profile does not authorise keychain-access-groups, so the app will be killed on launch"
    fi

    entitled="$(codesign -d --entitlements - --xml "${APP}" 2>/dev/null || true)"
    grep -q 'disable-library-validation' <<<"${entitled}" \
        || die "the signed app does not carry com.apple.security.cs.disable-library-validation — see docs/LICENSING.md"
    note "library-validation entitlement present in the signature"
fi

note "built $(du -sh "${APP}" | cut -f1)"

# ------------------------------------------------------------------- compliance

# Before packaging, not after: the checks are conditions on the right to
# distribute, so the moment to fail is before an artefact exists to attach.
info "licence checks"
scripts/check-licence-notices.sh "${APP}"

# -------------------------------------------------------------------- notarise

if [[ ${NOTARISE} -eq 1 ]]; then
    info "notarising"
    submission="${REPO_ROOT}/build/notarise.zip"
    rm -f "${submission}"
    ditto -c -k --keepParent --sequesterRsrc "${APP}" "${submission}"

    notary_args=(submit "${submission}" --wait)
    if [[ -n "${ASC_KEY_PATH:-}" ]]; then
        notary_args+=(--key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}")
    else
        notary_args+=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_PASSWORD}")
    fi
    xcrun notarytool "${notary_args[@]}"
    # Stapling is what lets the app open on a machine that is offline or that
    # has never asked Apple about it.
    xcrun stapler staple "${APP}"
    note "stapled"
    rm -f "${submission}"
fi

# --------------------------------------------------------------------- assemble

info "assembling ${OUTPUT}/"
rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${OUTPUT}"
cp -R "${APP}" "${STAGE}/Currawong.app"

# The licence texts, at the top level of the download. They are also inside the
# app bundle — the framework carries its own COPYING — but "inside a framework
# inside a bundle" is not where somebody looks, and §6 asks for the licence to
# accompany the executable in a way the recipient actually receives.
mkdir -p "${STAGE}/LICENSES"
cp LICENSE "${STAGE}/LICENSES/Currawong-Apache-2.0.txt"
codec2_copying="$(find -L Codec2.xcframework -maxdepth 1 -name COPYING | head -1)"
[[ -n "${codec2_copying}" ]] || die "no COPYING in Codec2.xcframework"
cp "${codec2_copying}" "${STAGE}/LICENSES/Codec2-LGPL-2.1.txt"
cp Codec2.xcframework/LICENCE-NOTICE.txt "${STAGE}/LICENSES/Codec2-NOTICE.txt"

# libgsm's terms travel with the library's source, which we do not ship here, so
# the notice is extracted from the acknowledgements the app displays — the same
# text, from the one place it is maintained.
gsm_src="${DERIVED}/SourcePackages/checkouts/swift-hamvoip/Sources/CGSM/LICENCE-libgsm.txt"
if [[ -f "${gsm_src}" ]]; then
    cp "${gsm_src}" "${STAGE}/LICENSES/libgsm.txt"
    note "libgsm licence from the resolved checkout"
else
    warn "libgsm licence not found at ${gsm_src}; it is still shown in the app's About screen"
fi

CODEC2_COMMIT="$(sed -n 's/.*static let codec2Commit = "\([^"]*\)".*/\1/p' \
    Sources/Currawong/Acknowledgements.swift | head -1)"
[[ -n "${CODEC2_COMMIT}" ]] || die "could not read codec2Commit from Acknowledgements.swift"

cat > "${STAGE}/README-FIRST.txt" <<EOF
Currawong ${VERSION} for macOS
$(printf '=%.0s' $(seq 1 $((${#VERSION} + 20))))

A client for amateur radio VoIP networks — AllStarLink (IAX2), M17 and
EchoLink. You need an amateur licence and a callsign to use it on air.

INSTALLING
  Drag Currawong.app to /Applications and open it.
$(if [[ -z "${IDENTITY}" ]]; then cat <<'ADHOC'

  THIS BUILD IS NOT SIGNED OR NOTARISED, so macOS will refuse to open it. It
  also ships with no entitlements at all, which means no Keychain access group
  and no saved passwords — not "may fail", will not work. It is a build to test
  the packaging, not one to operate a station with. Use a release built with a
  Developer ID.
ADHOC
else cat <<'SIGNED'

  The app is signed with a Developer ID and notarised by Apple, so it opens
  without any right-click-to-open dance.
SIGNED
fi)

WHAT IT WILL ASK FOR
  The microphone, so it can transmit. Local network access, to reach a node on
  your own LAN. Bluetooth, only if you use a Bluetooth PTT accessory.

LICENSING
  Currawong is free software under the Apache License 2.0. The full text of
  every licence involved is in LICENSES/, and the app's Settings screen has an
  About section listing the same thing.

  Currawong uses Codec2 for M17 digital voice. Codec2 and its use are covered
  by the GNU Lesser General Public License, version 2.1 (LICENSES/Codec2-LGPL-2.1.txt).
  Codec2 is a separate dynamic framework inside the application bundle and is
  never statically linked into Currawong, so you may replace it with your own
  build:

    1. Build Codec2 ${CODEC2_COMMIT} — or your own modified version — as a
       framework. The recipe is scripts/build-codec2-xcframework.sh in the
       Currawong repository, and the exact source this build used is attached
       to the same release as codec2-*-source.tar.gz.
    2. Replace Currawong.app/Contents/Frameworks/Codec2.framework with yours.
    3. Re-sign the app:  codesign --force --deep --sign - Currawong.app
    4. Open it. Currawong will use your Codec2.

  Step 3 is not a formality: an application's signature seals the files nested
  inside it, so replacing the framework and *not* re-signing gives you a bundle
  macOS refuses to start. Re-signing makes it yours, and it works — the
  procedure above was run end to end on 2026-08-24.
$(if [[ -n "${IDENTITY}" ]]; then cat <<'LV'

  This build also carries com.apple.security.cs.disable-library-validation,
  which additionally lets it load a Codec2.framework signed by somebody else if
  you re-sign the application without re-signing the framework.
LV
fi)

  Currawong's own source is at https://github.com/cpmpercussion/currawong.

  Currawong itself is not covered by the LGPL.
EOF

info "fetching the corresponding Codec2 source"
source_tarball="${OUTPUT}/codec2-${CODEC2_COMMIT:0:12}-source.tar.gz"
if [[ -f "${source_tarball}" ]]; then
    note "already present"
else
    # By commit rather than tag: §6 wants the source that corresponds to the
    # binary, and a tag is a name that can be moved.
    curl -fsSL -o "${source_tarball}" \
        "https://codeload.github.com/drowe67/codec2/tar.gz/${CODEC2_COMMIT}" \
        || die "could not download the codec2 source for ${CODEC2_COMMIT}"
    note "$(du -h "${source_tarball}" | cut -f1)"
fi

zip_name="Currawong-${VERSION}-macOS.zip"
[[ -n "${IDENTITY}" ]] || zip_name="Currawong-${VERSION}-macOS-unsigned.zip"
rm -f "${OUTPUT}/${zip_name}"
# `ditto`, not `zip`: it is the only one that preserves the signature and the
# symlink layout of a macOS framework bundle. A `zip -r` of a signed .app
# produces something that fails Gatekeeper on the far side.
ditto -c -k --sequesterRsrc --keepParent "${STAGE}" "${OUTPUT}/${zip_name}"
note "${OUTPUT}/${zip_name} ($(du -h "${OUTPUT}/${zip_name}" | cut -f1))"

( cd "${OUTPUT}" && shasum -a 256 ./*.zip ./*.tar.gz > SHA256SUMS.txt )

info "verifying the packaged app"
if [[ -n "${IDENTITY}" ]]; then
    codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | sed 's/^/  /'
    if [[ ${NOTARISE} -eq 1 ]]; then
        # The question a user's Mac will ask. `spctl` is the thing that answers
        # it, so it is the thing worth asking here.
        spctl --assess --type execute --verbose=2 "${APP}" 2>&1 | sed 's/^/  /'
    fi
else
    note "ad-hoc build; nothing to verify against Gatekeeper"
fi

info "done"
ls -1 "${OUTPUT}"
