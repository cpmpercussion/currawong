#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# BU-15: drive one on-air over from an iPhone, then read the phone's own log for
# the timing of it.
#
# **This is no longer how the key-downs are counted.** The app carries its own
# trace out on the transmit strip's accessibility value in DEBUG builds, and
# `BU15FirstOverUITests` asserts the count directly — no root, no TTY, no ring
# buffer, and it runs unattended. Use this when you want os_log's account of a
# run rather than the app's.
#
# **Why two steps.** The dance BU-15 is about happens inside a single continuous
# PTT hold, and XCUITest cannot look at the app during its own gesture —
# `press(forDuration:)` blocks the main thread and every route off it is refused
# (see BU15FirstOverUITests). The app is already instrumented for exactly this:
# `RadioSession` logs every key-down, key-up and SF-3 signal, and `resumes=` is
# incremented by the `resumeAcrossRouteChange()` that *is* the dance. So the UI
# test produces one clean over and prints its window; this reads the log back.
#
# **This transmits.** It keys a live reflector under the callsign you give it.
#
# Usage:
#   scripts/bu15-measure.sh <callsign> [device-name]
#
# `log collect` needs root to reach an attached device, so this prompts for a
# sudo password once, after the on-air part is over. It needs a real terminal:
# sudo cannot prompt without a TTY.
#
# **Collect immediately, or there is nothing to collect.** `Diagnostics` logs at
# `.info`, and os_log keeps info-level messages in a memory ring buffer rather
# than persisting them — so they are evicted within minutes and a `log collect`
# run even five minutes late returns almost nothing. Measured 2026-08-23: a
# collect about three minutes after a run kept 4 lines out of a whole session,
# and one about six minutes after it kept none of that run at all. That is why
# this script does the run and the collect together rather than leaving the
# collect to the operator. If the fuller trace is wanted, raising those calls
# from `.info` to `.default` would persist them.

set -euo pipefail

CALLSIGN="${1:-}"
DEVICE_NAME="${2:-melchior}"

if [ -z "$CALLSIGN" ]; then
    echo "usage: $0 <callsign> [device-name]" >&2
    echo "This transmits. It will not invent a callsign for you." >&2
    exit 2
fi

DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | awk -v name="$DEVICE_NAME" '$1 == name { print $3 }' | head -1)

if [ -z "$DEVICE_ID" ]; then
    echo "no device named '$DEVICE_NAME' — xcrun devicectl list devices" >&2
    exit 1
fi

echo "==> device $DEVICE_NAME ($DEVICE_ID), transmitting as $CALLSIGN"

RUN_LOG=$(mktemp -t bu15run)
trap 'rm -f "$RUN_LOG"' EXIT

# A moment before the run, so the collection window certainly contains it.
STARTED_AT=$(date +%s)

set +e
TEST_RUNNER_CURRAWONG_ONAIR_CALLSIGN="$CALLSIGN" \
    xcodebuild -project Currawong.xcodeproj -scheme CurrawongOnAir \
    -derivedDataPath DerivedData -allowProvisioningUpdates \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -only-testing:CurrawongOnAirUITests/BU15FirstOverUITests \
    test > "$RUN_LOG" 2>&1
TEST_STATUS=$?
set -e

grep -E '^=== BU-15' "$RUN_LOG" || true

if [ "$TEST_STATUS" -ne 0 ]; then
    # A locked phone makes xcodebuild report failure *after* a run whose tests
    # all passed, so say what actually happened rather than trusting the status.
    if grep -q "Test Case .* passed" "$RUN_LOG"; then
        echo "==> the test passed; xcodebuild's exit status is post-run noise"
    else
        echo "==> the on-air run failed — not collecting a log for it" >&2
        grep -E "error: -\[|XCTAssert|Timed out while enabling automation" "$RUN_LOG" \
            | head -10 >&2
        exit "$TEST_STATUS"
    fi
fi

ELAPSED=$(( $(date +%s) - STARTED_AT + 30 ))
ARCHIVE=$(mktemp -d -t bu15log)/melchior.logarchive

echo "==> collecting the last ${ELAPSED}s from $DEVICE_NAME (needs sudo)"
sudo /usr/bin/log collect --device-name "$DEVICE_NAME" \
    --last "${ELAPSED}s" --output "$ARCHIVE"

echo
echo "==> the app's own account of the over"
/usr/bin/log show "$ARCHIVE" \
    --predicate 'subsystem == "au.charlesmartin.currawong"' \
    --style compact --info \
    | grep -iE "key-down|key-up|signal |escalated|hand-back" || {
        echo "nothing from the app in that window. Check that the build on the"
        echo "phone is a DEBUG build — Diagnostics' stdout mirror and its most"
        echo "verbose lines are DEBUG-only."
    }

echo
echo "==> key-downs inside the hold (more than one is BU-15)"
/usr/bin/log show "$ARCHIVE" \
    --predicate 'subsystem == "au.charlesmartin.currawong"' \
    --style compact --info \
    | grep -ci "key-down" || true

echo "log archive kept at $ARCHIVE"
