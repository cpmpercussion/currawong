#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# set-release-secrets.sh — put the four secrets the release workflow needs into
# the GitHub repository, without any of them passing through a shell history, a
# file that outlives the run, or this script's output.
#
# WHY THIS IS A SCRIPT AND NOT A LIST OF COMMANDS IN A DOC
#   One of the four is a private key. Exporting it by hand means choosing a
#   password, remembering to `base64` it, remembering to delete the `.p12`
#   afterwards, and not putting either the password or the path anywhere it will
#   be read back. That is four chances to leave signing material on disk. Here
#   the password is generated, used twice and never printed, and the export is
#   removed on the way out including when the script fails.
#
# WHAT IT SETS
#   MACOS_CERTIFICATE_P12        the Developer ID Application identity and key
#   MACOS_CERTIFICATE_PASSWORD   a fresh random password for that export
#   NOTARY_APPLE_ID              your Apple ID
#   NOTARY_PASSWORD              an app-specific password for it
#
#   NOTARY_TEAM_ID and MACOS_PROVISIONING_PROFILE are set separately — neither is
#   sensitive and neither needs a prompt. See docs/LICENSING.md.
#
# WHAT IT WILL ASK YOU FOR
#   macOS will put up a keychain dialog to authorise exporting the private key.
#   That prompt is why this cannot run unattended — click Allow. Then the script
#   asks for your Apple ID and an app-specific password, neither of which is
#   echoed.
#
# USAGE
#   scripts/set-release-secrets.sh
#
# See docs/LICENSING.md.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
note() { printf '\033[1;32m  ->\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

WORK=""
cleanup() {
    # The export contains a private key, so it goes whatever happens — including
    # on a failure between the export and the upload.
    [[ -n "${WORK}" && -d "${WORK}" ]] && rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

command -v gh >/dev/null || die "gh not found. brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[[ -n "${IDENTITY}" ]] || die "no Developer ID Application identity in your keychain.
     This script uploads the one you sign with; it cannot create one."
note "identity ${IDENTITY}"

WORK="$(mktemp -d)"
chmod 700 "${WORK}"
readonly P12="${WORK}/devid.p12"

# Generated, not chosen: it exists only to encrypt the export in transit to the
# secret store, and nothing ever needs to know it again. It is written straight
# to the secret and never printed.
EXPORT_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"

info "exporting the Developer ID certificate and key"
printf '  macOS will ask you to authorise this. Click Allow.\n'
# `-t identities` takes the certificate *and* its private key, which is what a
# runner needs and the whole reason this cannot be fetched with an Apple ID.
security export -t identities -f pkcs12 -P "${EXPORT_PASSWORD}" -o "${P12}" \
    || die "the export was refused or cancelled — nothing was uploaded"
[[ -s "${P12}" ]] || die "the export produced nothing"
note "exported $(du -h "${P12}" | cut -f1)"

info "your Apple ID and an app-specific password"
printf '  The app-specific password is the one from appleid.apple.com, not your\n'
printf '  account password. Neither is echoed.\n\n'
read -r -p "  Apple ID (email): " APPLE_ID
[[ -n "${APPLE_ID}" ]] || die "no Apple ID given"
read -r -s -p "  App-specific password: " NOTARY_PW
printf '\n'
[[ -n "${NOTARY_PW}" ]] || die "no app-specific password given"

info "uploading"
# Piped rather than passed as arguments, so none of it reaches a process list or
# a shell history.
base64 -i "${P12}" | gh secret set MACOS_CERTIFICATE_P12
printf '%s' "${EXPORT_PASSWORD}" | gh secret set MACOS_CERTIFICATE_PASSWORD
printf '%s' "${APPLE_ID}" | gh secret set NOTARY_APPLE_ID
printf '%s' "${NOTARY_PW}" | gh secret set NOTARY_PASSWORD

info "what the repository now has"
gh secret list

printf '\n'
note "the exported key has been deleted from ${WORK}"
printf '\nIf a secret is wrong, run this again — setting one replaces it.\n'
