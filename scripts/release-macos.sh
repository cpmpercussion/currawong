#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
#
# The Mac direct download (APP-40, PD-5's Developer ID half): a signed,
# notarised, stapled Currawong.app in a DMG, for attaching to a GitHub release.
# Xcode Cloud covers TestFlight and the App Store; this covers everyone else,
# and it runs here rather than in CI so the signing identity never leaves this
# machine.
#
# Pipeline:
#   xcodegen      regenerate the project from project.yml
#   xcodebuild    archive the Currawong scheme for macOS (Release)
#   xcodebuild    export with method=developer-id. This embeds a Developer ID
#                 provisioning profile, which the app cannot launch without:
#                 keychain-access-groups is a restricted entitlement, and a
#                 bundle that claims one with no profile passes
#                 `codesign --verify` and is then killed by the kernel on
#                 launch, with no message (found under APP-26, 2026-08-24).
#   codesign      verify; check the Hardened Runtime and the embedded profile
#   notarytool    notarise the .app, then staple it
#   hdiutil       wrap the stapled .app in a DMG with an /Applications link
#   notarytool    sign, notarise and staple the DMG too
#
# Prereqs (once per machine):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. Xcode signed in to the team's Apple ID (Settings → Accounts), so
#      -allowProvisioningUpdates can create the Developer ID profile.
#   3. notarytool credentials in the keychain. A profile is an Apple ID and a
#      team, not an app, so the one made for IMPSY is the default here:
#        xcrun notarytool store-credentials IMPSY_NOTARY \
#          --apple-id <apple-id> --team-id EDH387FRHA \
#          --password <app-specific-password>
#
# Usage:
#   scripts/release-macos.sh                  full pipeline → DMG
#   scripts/release-macos.sh --skip-notarize  archive, export, verify only
#   scripts/release-macos.sh --no-dmg         stop after stapling the .app
#
# The version is project.yml's CFBundleShortVersionString. Bump it in a commit
# before running this; the artefact is named for it.
#
# Env:
#   NOTARY_PROFILE   notarytool keychain profile (default: IMPSY_NOTARY)
#   BUILD_DIR        artefact root (default: build/release-macos)

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR}/.."

PROJECT="Currawong.xcodeproj"
SCHEME="Currawong"
BUILD_DIR="${BUILD_DIR:-build/release-macos}"
ARCHIVE_PATH="${BUILD_DIR}/Currawong.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${SCRIPT_DIR}/ExportOptions-macOS.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-IMPSY_NOTARY}"
TEAM_ID="EDH387FRHA"

SKIP_NOTARIZE=0
MAKE_DMG=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --no-dmg)        MAKE_DMG=0 ;;
    -h|--help)       sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log()  { print -P "%F{cyan}==>%f $*"; }
ok()   { print -P "%F{green}==>%f $*"; }
fail() { print -P "%F{red}==> FAIL:%f $*" >&2; exit 1; }

if command -v xcbeautify >/dev/null; then
  XCFORMAT=(xcbeautify --quiet)
else
  XCFORMAT=(tail -5)
fi

# `notarytool submit --wait` exits 0 when the verdict is Invalid, so the
# verdict is read from its output instead.
notarise() {
  local file="$1" submit_log="$2"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait \
    | tee "$submit_log"
  if ! grep -q "status: Accepted" "$submit_log"; then
    local id
    id=$(awk '/^  id:/ {print $2; exit}' "$submit_log")
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "Notarisation of $file rejected; Apple's log is above."
  fi
}

# ── preflight ────────────────────────────────────────────────────────────────

command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || fail "No 'Developer ID Application' certificate in the login keychain"

if (( ! SKIP_NOTARIZE )); then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool profile '$NOTARY_PROFILE' missing; see the prereqs at the top of $0"
fi

# The path dependency is for working on both repos at once, and a release
# built against an uncommitted library is one nobody can reproduce.
grep -qE '^[[:space:]]*path:[[:space:]]*\.\./swift-hamvoip' project.yml \
  && fail "project.yml has the swift-hamvoip path dependency swapped in"

VERSION=$(awk -F'"' '/CFBundleShortVersionString:/ {print $2; exit}' project.yml)
[[ -n "$VERSION" ]] || fail "No CFBundleShortVersionString in project.yml"
log "Currawong $VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
  print -P "%F{yellow}==> warning:%f the working tree has uncommitted changes"
fi

# ── archive and export ───────────────────────────────────────────────────────

log "xcodegen generate"
xcodegen generate >/dev/null

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Archiving $SCHEME for macOS"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  | "${XCFORMAT[@]}"
[[ -d "$ARCHIVE_PATH" ]] || fail "No archive at $ARCHIVE_PATH"

log "Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  | "${XCFORMAT[@]}"

APP_PATH="${EXPORT_DIR}/Currawong.app"
[[ -d "$APP_PATH" ]] || fail "No exported app at $APP_PATH"

# ── verify ───────────────────────────────────────────────────────────────────

log "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Captured whole: piping codesign into `grep -q` lets grep exit early,
# codesign takes SIGPIPE, and pipefail reports that as a failure.
sig=$(codesign -dvv "$APP_PATH" 2>&1)
print -r -- "$sig" | grep -E "Authority|TeamIdentifier|flags" | sed 's/^/    /'
[[ "$sig" == *"Developer ID Application"* ]] || fail "Not signed with a Developer ID certificate"
[[ "$sig" == *"(runtime)"* ]] || fail "Hardened Runtime is off; see ENABLE_HARDENED_RUNTIME in project.yml"

# See the header: without this the app verifies and then dies on launch.
[[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]] \
  || fail "No embedded provisioning profile; keychain-access-groups will get the app killed on launch"

ents=$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)
[[ "$ents" == *"keychain-access-groups"* ]] || fail "The keychain access group is missing from the signed entitlements"
[[ "$ents" == *"com.apple.security.app-sandbox"* ]] || fail "App Sandbox is missing from the signed entitlements"

ok "Built and signed: $APP_PATH"

if (( SKIP_NOTARIZE )); then
  ok "Stopped before notarisation (--skip-notarize)"
  exit 0
fi

# ── notarise the app ─────────────────────────────────────────────────────────

APP_ZIP="${BUILD_DIR}/Currawong-${VERSION}.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

log "Notarising the app (a few minutes)"
notarise "$APP_ZIP" "${BUILD_DIR}/notary-app.log"

log "Stapling the app"
xcrun stapler staple "$APP_PATH"
spctl -a -vv -t exec "$APP_PATH" 2>&1 | sed 's/^/    /'

# Re-zip so the zip carries the stapled ticket.
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
ok "Notarised and stapled: $APP_ZIP"

(( MAKE_DMG )) || exit 0

# ── DMG ──────────────────────────────────────────────────────────────────────

DMG_PATH="${BUILD_DIR}/Currawong-${VERSION}.dmg"
STAGE="${BUILD_DIR}/dmg"
mkdir -p "$STAGE"
ditto "$APP_PATH" "$STAGE/Currawong.app"
ln -s /Applications "$STAGE/Applications"

log "Building the DMG"
hdiutil create -volname "Currawong ${VERSION}" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"

IDENTITY=$(security find-identity -v -p codesigning \
  | awk -F'"' "/Developer ID Application: .*\\(${TEAM_ID}\\)/ {print \$2; exit}")
[[ -n "$IDENTITY" ]] || fail "No Developer ID Application identity for team $TEAM_ID"
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

log "Notarising the DMG"
notarise "$DMG_PATH" "${BUILD_DIR}/notary-dmg.log"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH" | sed 's/^/    /'

shasum -a 256 "$DMG_PATH" | sed "s|${BUILD_DIR}/||" > "${DMG_PATH}.sha256"
ok "Distributable: $DMG_PATH"
ok "Checksum:      ${DMG_PATH}.sha256"
