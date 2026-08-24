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

# Because this script has already failed once by exiting silently mid-way, and a
# script that handles a private key is the wrong place to guess what happened.
trap 'rc=$?; [[ ${rc} -eq 0 ]] || printf "\033[1;31mFAILED\033[0m at line %s (exit %s). Nothing was uploaded unless it says so above.\n" "${LINENO}" "${rc}" >&2' ERR

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
#
# One command, no pipe, deliberately. This was `tr -dc … </dev/urandom | head -c
# 40`, which is worse than it looks under `set -euo pipefail`: `head` exits at 40
# bytes, `tr` takes SIGPIPE, the pipeline reports 141, and because that is a
# command substitution `set -e` kills the script — after the identity line and
# before the export, with nothing printed. Which is exactly how it failed the
# first time it was run.
EXPORT_PASSWORD="$(openssl rand -hex 20)"
[[ ${#EXPORT_PASSWORD} -ge 32 ]] || die "could not generate an export password"

info "exporting the Developer ID certificate and key"
printf '  macOS will ask you to authorise this. Click Allow.\n'
# `-t identities` takes the certificate *and* its private key, which is what a
# runner needs and the whole reason this cannot be fetched with an Apple ID.
security export -t identities -f pkcs12 -P "${EXPORT_PASSWORD}" -o "${P12}" \
    || die "the export was refused or cancelled — nothing was uploaded"
[[ -s "${P12}" ]] || die "the export produced nothing"
note "exported $(du -h "${P12}" | cut -f1)"

# `security export -t identities` takes *every* codesigning identity in the
# keychain, not only the one we want, and there is no flag to narrow it. Usually
# that means an Apple Development key travels along with the Developer ID one.
# Signing still picks the right one by name, but it is more key material in a
# secret than the job needs, so at least say so rather than let it pass unseen.
# `-legacy` is an OpenSSL 3 flag and macOS has shipped LibreSSL as `openssl`,
# which rejects it — so this is allowed to come back empty, and an empty string
# in the integer test below would itself fail the script. Both tries are
# best-effort: this is a courtesy warning, not a gate.
certs="$(openssl pkcs12 -in "${P12}" -passin "pass:${EXPORT_PASSWORD}" \
    -nokeys -legacy 2>/dev/null | grep -c 'BEGIN CERTIFICATE' || true)"
if [[ ! "${certs}" =~ ^[0-9]+$ ]]; then
    certs="$(openssl pkcs12 -in "${P12}" -passin "pass:${EXPORT_PASSWORD}" \
        -nokeys 2>/dev/null | grep -c 'BEGIN CERTIFICATE' || true)"
fi
[[ "${certs}" =~ ^[0-9]+$ ]] || certs=0

if [[ "${certs}" -gt 1 ]]; then
    printf '\033[1;33m  note\033[0m the export contains %s certificates, not just the Developer ID one.
' "${certs}"
    printf '       Signing picks the right one by name, so this works. To upload only the
'
    printf '       one identity, export it from Keychain Access instead — select just
'
    printf '       "Developer ID Application", File > Export Items — and set the secret with:
'
    printf '         base64 -i <file>.p12 | gh secret set MACOS_CERTIFICATE_P12
'
    printf '         printf <its password> | gh secret set MACOS_CERTIFICATE_PASSWORD
'
fi

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
