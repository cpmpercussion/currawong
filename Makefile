# Currawong — terminal workflow.
#
# Everything here runs from a shell. Opening Xcode is optional and, for build
# and test, unnecessary. The .xcodeproj is generated (see project.yml) and is
# not in version control, so `generate` is the first step after a fresh clone.
#
#   make generate     regenerate Currawong.xcodeproj from project.yml
#   make codec2       build Codec2.xcframework (needs cmake; ~4 min, once)
#   make build        build for a generic iOS device
#   make build-macos  build for macOS
#   make test         run the unit tests on an iOS simulator
#   make test-macos   run the unit tests on macOS
#   make clean        remove generated project and build output
#   make distclean    ...and the Codec2 framework and its build tree
#
# Codec2.xcframework is a build prerequisite: the app embeds it (LP-4, dynamic
# only) and M17 audio does not exist without it. It is not in version control,
# so the first build after a fresh clone builds it — needing `brew install
# cmake` — and every build after that finds it already there. See docs/CODEC2.md.
#
# Overrides:
#   make test SIMULATOR='iPhone 16'
#   make build DEVELOPMENT_TEAM=XXXXXXXXXX
#   make build SIGNING='CODE_SIGNING_ALLOWED=NO'   # unsigned CI build
#   make build PROVISIONING=''                     # never touch the network

SCHEME       := Currawong
PROJECT      := Currawong.xcodeproj
DERIVED_DATA := DerivedData

# First available iPhone simulator on this machine, so the command in the
# README does not go stale every time Xcode ships a new device set.
SIMULATOR ?= $(shell scripts/pick-simulator.sh)

IOS_DEVICE_DEST := generic/platform=iOS
IOS_SIM_DEST    := platform=iOS Simulator,name=$(SIMULATOR)
MACOS_DEST      := platform=macOS

# Passed through to xcodebuild; empty by default. See the header.
SIGNING ?=

# The app carries one entitlement — the Keychain access group, without which
# macOS refuses every write to the data protection keychain with "a required
# entitlement isn't present". An entitlement means a provisioning profile, and
# a profile that does not exist yet means Xcode has to fetch or create one,
# which it will only do when asked. Without this flag a first build on a fresh
# machine fails with "No profiles for 'au.charlesmartin.currawong' were found".
#
# It needs an Apple ID with the team in Xcode's accounts, and the network. A CI
# build has neither and does not need either: `SIGNING='CODE_SIGNING_ALLOWED=NO'`
# skips signing, and the flag is then inert.
PROVISIONING ?= -allowProvisioningUpdates

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) $(PROVISIONING) $(SIGNING)

CODEC2 := Codec2.xcframework

.PHONY: all generate codec2 build build-macos test test-macos clean distclean simulator

all: build test

# The framework is a real file, so make rebuilds it only when it is missing.
# Deleting it (or `make distclean`) is how you force a rebuild.
$(CODEC2):
	scripts/build-codec2-xcframework.sh

codec2: $(CODEC2)

# Generation depends on the framework because project.yml references it: an
# xcodeproj generated against a missing framework builds, then fails at link
# time with a message that does not mention codec2 at all.
$(PROJECT): project.yml $(CODEC2)
	xcodegen generate

generate: $(CODEC2)
	xcodegen generate

build: $(PROJECT)
	$(XCB) -destination '$(IOS_DEVICE_DEST)' build

build-macos: $(PROJECT)
	$(XCB) -destination '$(MACOS_DEST)' build

test: $(PROJECT)
	@test -n "$(SIMULATOR)" || { echo "No iOS simulator found. Install one, or pass SIMULATOR='iPhone 16'."; exit 1; }
	@echo "Testing on simulator: $(SIMULATOR)"
	$(XCB) -destination '$(IOS_SIM_DEST)' test

test-macos: $(PROJECT)
	$(XCB) -destination '$(MACOS_DEST)' test

# Prints the simulator `make test` would pick, for when it picks a surprising one.
simulator:
	@echo '$(SIMULATOR)'

clean:
	rm -rf $(PROJECT) $(DERIVED_DATA) build

# Separate from `clean` because rebuilding the framework costs about four
# minutes and a codec2 checkout, and almost nothing you would run `clean` for
# is fixed by discarding it.
distclean: clean
	rm -rf $(CODEC2) .build
