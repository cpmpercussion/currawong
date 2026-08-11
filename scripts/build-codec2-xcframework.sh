#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# build-codec2-xcframework.sh — produce Codec2.xcframework for this app.
#
# WHY THE APP BUILDS ITS OWN
#   swift-hamvoip knows how to build this framework and has its own copy of it
#   during development, but that copy never reaches us. The XCFramework is 7.6
#   MB of LGPL-2.1 binary and is not committed to either repository, so the
#   checkout SPM makes of a resolved dependency does not contain one — and
#   there is nowhere to run a build script inside that checkout. The library's
#   own `Codec2VoiceCodec` is therefore compiled out for every downstream
#   consumer, this app included.
#
#   So Currawong embeds the framework (project.yml, Embed & Sign, LP-4) and
#   supplies its own conformance in Sources/Currawong/Codec2Codec.swift.
#
# WHY THIS SCRIPT IS SHORT
#   The real build — three slices, the cross-compilation handling, the licence
#   and dynamic-linking assertions — is 500-odd lines and lives in the library,
#   which is the right place for it: it is the library's dependency and the
#   library's OQ-2 spike result. Duplicating it here would give us two copies
#   to keep in step. Instead this locates the library's script and runs it.
#
#   SPM has already checked the library out to build the app, at exactly the
#   version project.yml pins, so that checkout is the preferred source and
#   needs no network. Failing that, a sibling ../swift-hamvoip is used, and
#   failing that the pinned tag is cloned into the build directory.
#
# USAGE
#   scripts/build-codec2-xcframework.sh [--clean]
#   make codec2
#
#   Arguments are passed through to the library's script; run it with --help
#   for the full set.
#
# REQUIREMENTS
#   cmake (brew install cmake) and Xcode with the iOS SDKs.
#
# See docs/CODEC2.md, and the library's docs/reference/CODEC2-XCFRAMEWORK.md
# for what the artefact contains and how it was verified.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OUTPUT="${REPO_ROOT}/Codec2.xcframework"
readonly SCRIPT_RELATIVE_PATH="scripts/build-codec2-xcframework.sh"

# Kept in step with project.yml's `from:` by hand. Only used for the clone
# fallback, which is the path taken when neither checkout is available.
readonly LIBRARY_URL="https://github.com/cpmpercussion/swift-hamvoip"
readonly LIBRARY_REF="v0.2.0"

readonly SPM_CHECKOUT="${REPO_ROOT}/DerivedData/SourcePackages/checkouts/swift-hamvoip"
readonly SIBLING_CHECKOUT="${REPO_ROOT}/../swift-hamvoip"
readonly CLONE_DIR="${REPO_ROOT}/.build/swift-hamvoip-codec2"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
note() { printf '\033[1;32m  ->\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

find_library_script() {
    if [[ -x "${SPM_CHECKOUT}/${SCRIPT_RELATIVE_PATH}" ]]; then
        note "using the SPM checkout (resolved by xcodebuild)" >&2
        printf '%s' "${SPM_CHECKOUT}/${SCRIPT_RELATIVE_PATH}"
        return
    fi
    if [[ -x "${SIBLING_CHECKOUT}/${SCRIPT_RELATIVE_PATH}" ]]; then
        note "using the sibling checkout at ../swift-hamvoip" >&2
        printf '%s' "${SIBLING_CHECKOUT}/${SCRIPT_RELATIVE_PATH}"
        return
    fi

    note "no local checkout; cloning ${LIBRARY_REF}" >&2
    if [[ -d "${CLONE_DIR}/.git" ]]; then
        git -C "${CLONE_DIR}" fetch --tags --quiet origin
    else
        mkdir -p "$(dirname "${CLONE_DIR}")"
        git clone --quiet "${LIBRARY_URL}" "${CLONE_DIR}"
    fi
    git -C "${CLONE_DIR}" checkout --quiet "${LIBRARY_REF}"
    [[ -x "${CLONE_DIR}/${SCRIPT_RELATIVE_PATH}" ]] \
        || fail "the clone has no ${SCRIPT_RELATIVE_PATH}"
    printf '%s' "${CLONE_DIR}/${SCRIPT_RELATIVE_PATH}"
}

command -v cmake >/dev/null 2>&1 \
    || fail "cmake is required and not installed. brew install cmake"

info "Codec2.xcframework for Currawong"
LIBRARY_SCRIPT="$(find_library_script)"
note "recipe: ${LIBRARY_SCRIPT}"

# OUTPUT_DIR puts the product here rather than in the library's own tree; the
# work tree stays beside the recipe so repeat builds stay incremental.
OUTPUT_DIR="${REPO_ROOT}" "${LIBRARY_SCRIPT}" "$@"

[[ -d "${OUTPUT}" ]] || fail "the build reported success but ${OUTPUT} is missing"
info "Done: ${OUTPUT}"
note "it is gitignored; 'Embed & Sign' is wired up in project.yml"
