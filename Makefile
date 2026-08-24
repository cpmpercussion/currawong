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
#   make resolved     refresh the committed Package.resolved pin (Xcode Cloud)
#   make licences     check the licence notices against what is shipped (APP-26)
#   make release-macos  build, sign and package the Mac download (APP-26)
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

# The dependency pin Xcode Cloud reads; see the `resolved` target.
PINNED_RESOLVED := ci_scripts/Package.resolved

.PHONY: all generate codec2 build build-macos test test-macos resolved licences release-macos clean distclean simulator

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

# Xcode Cloud resolves with automatic resolution disabled, so it needs a
# Package.resolved and will not compute one. That file lives inside the
# generated .xcodeproj, which is never committed, so the pin is committed here
# instead and `ci_scripts/ci_post_clone.sh` copies it into place.
#
# Run this whenever project.yml's package versions change, and commit the
# result with that change: the pin, not `from:`, is what the cloud build
# builds, and a stale pin fails the build exactly as a missing one does.
# The guard is for the path-dependency swap in project.yml: a path dependency
# is not pinned at all, so refreshing while swapped would commit a pin with no
# swift-hamvoip in it — which fails the cloud build in the same place a missing
# file does, one push later.
resolved: $(PROJECT)
	$(XCB) -resolvePackageDependencies
	@grep -q 'swift-hamvoip' $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
	  || { echo "Resolved file has no swift-hamvoip pin — is the path dependency swapped in?"; exit 1; }
	cp $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
	   $(PINNED_RESOLVED)
	@echo "Refreshed $(PINNED_RESOLVED) — commit it."

# **APP-26.** The licence claims, checked against the artefacts they describe.
# Most of it needs no build; the Codec2 checks are skipped rather than failed
# when the framework is absent, so this is safe on a fresh clone. CI runs the
# same script on every push, and so does `release-macos` before it packages
# anything — those checks are conditions on the right to distribute, so the
# moment to fail is before an artefact exists to attach. See docs/LICENSING.md.
licences:
	scripts/check-licence-notices.sh

# **APP-26.** The macOS download: builds, signs, notarises and packages the app
# together with the licence texts and the corresponding Codec2 source.
# `--identity auto` uses whatever Developer ID is in your keychain; with none it
# produces an ad-hoc build, which tests the packaging and must not be handed to
# anybody. `.github/workflows/release-macos.yml` calls this same script, so a
# release is reproducible on your own machine.
#
#   make release-macos                      # ad-hoc, or your Developer ID
#   make release-macos NOTARISE=--notarise  # ...and notarise (needs NOTARY_*)
NOTARISE ?=
release-macos:
	scripts/package-macos-release.sh --identity auto $(NOTARISE)

# Prints the simulator `make test` would pick, for when it picks a surprising one.
simulator:
	@echo '$(SIMULATOR)'

clean:
	rm -rf $(PROJECT) $(DERIVED_DATA) build dist

# Separate from `clean` because rebuilding the framework costs about four
# minutes and a codec2 checkout, and almost nothing you would run `clean` for
# is fixed by discarding it.
distclean: clean
	rm -rf $(CODEC2) .build
