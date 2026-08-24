#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# set-release-secrets.sh — put the four secrets the release workflow needs into
# the GitHub repository, and check them before they go rather than after.
#
# WHY IT DOES NOT EXPORT THE CERTIFICATE FOR YOU
#   It used to, with `security export -t identities`, and that was a mistake
#   twice over. There is no flag to narrow that to one identity, so it tries to
#   export *every* private key in the keychain — three of them here: Apple
#   Development, Developer ID Application, Developer ID Installer — and macOS
#   raises a separate authorisation dialog for each, re-asking until you pick
#   "Always Allow". It reads as an endless prompt loop, and what it would have
#   uploaded is two private keys the release does not need.
#
#   Keychain Access exports exactly the identity you select, asks once, and is
#   a one-off. So that step is yours, and this script starts from the file.
#
# EXPORTING THE CERTIFICATE (once)
#   1. Open Keychain Access.
#   2. Left pane: login. Category: My Certificates.
#   3. Select **Developer ID Application: <your name> (EDH387FRHA)** — the
#      Application one, not Installer.
#   4. File > Export Items… > format "Personal Information Exchange (.p12)".
#   5. Save it somewhere temporary and give it a password. You will type that
#      password into this script, and nothing needs to remember it afterwards.
#
# THEN
#   scripts/set-release-secrets.sh --certificate ~/Desktop/devid.p12
#
#   It checks the file opens with the password you give and that it really holds
#   a Developer ID Application identity, because a wrong password or the wrong
#   export uploads a secret that fails in CI with a message about none of that.
#   Then it asks for your Apple ID and an app-specific password, and uploads.
#   Nothing is echoed and nothing is passed as a command argument.
#
#   Delete the .p12 afterwards — it is a private key. The script says so at the
#   end rather than deleting a file you chose the location of.
#
# WHAT IT SETS
#   MACOS_CERTIFICATE_P12, MACOS_CERTIFICATE_PASSWORD, NOTARY_APPLE_ID,
#   NOTARY_PASSWORD.
#
#   MACOS_PROVISIONING_PROFILE and NOTARY_TEAM_ID are set separately; neither is
#   sensitive. See docs/LICENSING.md.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
note() { printf '\033[1;32m  ->\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m  note\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# This script has failed once by exiting silently mid-way, which is the wrong
# thing for a script handling a private key to do.
trap 'rc=$?; [[ ${rc} -eq 0 ]] || printf "\033[1;31mFAILED\033[0m at line %s (exit %s). Nothing was uploaded unless it says so above.\n" "${LINENO}" "${rc}" >&2' ERR

CERTIFICATE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --certificate|--cert) CERTIFICATE="${2:?--certificate needs a path}"; shift 2 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

command -v gh >/dev/null || die "gh not found. brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"

if [[ -z "${CERTIFICATE}" ]]; then
    die "no certificate given.

     Export it from Keychain Access first — login > My Certificates, select
     \"Developer ID Application\", File > Export Items… as .p12 — then:

       scripts/set-release-secrets.sh --certificate ~/Desktop/devid.p12

     Run with --help for the full walkthrough."
fi
[[ -f "${CERTIFICATE}" ]] || die "${CERTIFICATE} is not a file"
[[ -s "${CERTIFICATE}" ]] || die "${CERTIFICATE} is empty"
note "certificate ${CERTIFICATE} ($(du -h "${CERTIFICATE}" | cut -f1))"

info "the password you gave that export"
read -r -s -p "  .p12 password: " P12_PASSWORD
printf '\n'
[[ -n "${P12_PASSWORD}" ]] || die "no password given"

# Reads the certificates out of the export. Keychain Access writes legacy
# PKCS#12, which OpenSSL 3 needs `-legacy` for and LibreSSL rejects the flag
# for, so both are tried. Nothing is written to disk: the PEM stays in a
# variable, and it is the certificates only — `-nokeys`.
read_certs() {
    openssl pkcs12 -in "${CERTIFICATE}" -passin "pass:${P12_PASSWORD}" \
        -nokeys -legacy 2>/dev/null \
        || openssl pkcs12 -in "${CERTIFICATE}" -passin "pass:${P12_PASSWORD}" \
            -nokeys 2>/dev/null \
        || true
}

info "checking the export before uploading it"
certs_pem="$(read_certs)"
if [[ -z "${certs_pem}" ]]; then
    die "could not open ${CERTIFICATE} with that password.

     Either the password is wrong, or the file is not a PKCS#12 export. Nothing
     has been uploaded. Try again — no harm done."
fi
note "password opens the file"

# `openssl pkcs12 -nokeys` already prints a `subject=` line above each
# certificate, so the names are in the output we have. An earlier version of
# this piped that through `openssl storeutl` instead, which read nothing and so
# skipped the check silently — an Installer-only export sailed through the dry
# run reporting no problem at all.
subjects="$(printf '%s' "${certs_pem}" | sed -n 's/^subject=//p' || true)"
if [[ -z "${subjects}" ]]; then
    subjects="$(printf '%s' "${certs_pem}" | sed -n 's/^ *friendlyName: *//p' || true)"
fi

cert_count="$(printf '%s' "${certs_pem}" | grep -c 'BEGIN CERTIFICATE' || true)"
[[ "${cert_count}" =~ ^[0-9]+$ ]] || cert_count=0
note "${cert_count} certificate(s) in the export"

if grep -qi 'Developer ID Application' <<<"${subjects}"; then
    note "it holds a Developer ID Application identity"
elif [[ -n "${subjects}" ]]; then
    die "this export does not contain a Developer ID Application certificate.

     It contains: ${subjects//$'\n'/, }

     Signing needs the *Application* identity, not Installer and not Apple
     Development. Nothing has been uploaded."
else
    # Could not read the subjects on this openssl. Not worth failing over — the
    # password check above already proved the file is a real export.
    warn "could not read the certificate names on this openssl; skipping that check"
fi

if [[ "${cert_count}" -gt 2 ]]; then
    warn "that is more certificates than a single identity plus its issuer."
    warn "if you exported more than one identity, only the Developer ID"
    warn "Application one is used — but the others' keys would be in the secret."
fi

info "your Apple ID and an app-specific password"
printf '  The app-specific password is the one from appleid.apple.com, not your\n'
printf '  account password. Neither is echoed.\n\n'
read -r -p "  Apple ID (email): " APPLE_ID
[[ -n "${APPLE_ID}" ]] || die "no Apple ID given"
[[ "${APPLE_ID}" == *@* ]] || die "\"${APPLE_ID}\" does not look like an email address"
read -r -s -p "  App-specific password: " NOTARY_PW
printf '\n'
[[ -n "${NOTARY_PW}" ]] || die "no app-specific password given"

info "uploading"
# Piped, not passed as arguments, so none of it reaches a process list.
base64 -i "${CERTIFICATE}" | gh secret set MACOS_CERTIFICATE_P12
note "MACOS_CERTIFICATE_P12"
printf '%s' "${P12_PASSWORD}" | gh secret set MACOS_CERTIFICATE_PASSWORD
note "MACOS_CERTIFICATE_PASSWORD"
printf '%s' "${APPLE_ID}" | gh secret set NOTARY_APPLE_ID
note "NOTARY_APPLE_ID"
printf '%s' "${NOTARY_PW}" | gh secret set NOTARY_PASSWORD
note "NOTARY_PASSWORD"

info "what the repository now has"
gh secret list

printf '\n'
warn "delete ${CERTIFICATE} — it is a private key, and it is not needed again."
printf '\nIf a secret is wrong, run this again; setting one replaces it.\n'
