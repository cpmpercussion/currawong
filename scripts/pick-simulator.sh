#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Prints the name of an available iPhone simulator, for
# `xcodebuild -destination 'platform=iOS Simulator,name=…'`.
#
# The Makefile calls this rather than hard-coding a device, because the device
# set changes with every Xcode release and a hard-coded name turns `make test`
# into a puzzle on someone else's machine. Override it instead if you care which
# one runs:  make test SIMULATOR='iPhone 16'
#
# Prints nothing and exits 1 if no iPhone simulator is installed.

set -eu

name=$(xcrun simctl list devices available 2>/dev/null |
	sed -n 's/^[[:space:]]*\(iPhone[^(]*\) (.*/\1/p' |
	sed 's/[[:space:]]*$//' |
	head -n 1)

if [ -z "$name" ]; then
	echo "no available iPhone simulator found" >&2
	exit 1
fi

printf '%s\n' "$name"
