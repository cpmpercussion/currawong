# Currawong — terminal workflow.
#
# Everything here runs from a shell. Opening Xcode is optional and, for build
# and test, unnecessary. The .xcodeproj is generated (see project.yml) and is
# not in version control, so `generate` is the first step after a fresh clone.
#
#   make generate     regenerate Currawong.xcodeproj from project.yml
#   make build        build for a generic iOS device
#   make build-macos  build for macOS
#   make test         run the unit tests on an iOS simulator
#   make test-macos   run the unit tests on macOS
#   make resolved     refresh the committed Package.resolved pin (Xcode Cloud)
#   make clean        remove generated project and build output
#   make distclean    ...and any local build tree
#
# **A fresh clone needs nothing but xcodegen and Xcode.** Until APP-31 the app
# also had to build Codec2.xcframework here — four minutes and a cmake
# install — before it could build at all. Codec 2 3200 now comes from the
# library as `M17Kit.WeebillVoiceCodec`, in pure Swift over SPM. See
# docs/CODEC2.md.
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

# The dependency pin Xcode Cloud reads; see the `resolved` target.
PINNED_RESOLVED := ci_scripts/Package.resolved

.PHONY: all generate build build-macos test test-macos asan-macos resolved clean distclean simulator

all: build test

$(PROJECT): project.yml
	xcodegen generate

generate:
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

# An AddressSanitizer build of the macOS app, launched (BU-23). ASan traps an
# out-of-bounds access at the instant it happens, naming the line, instead of
# leaving a crash in somebody else's framework 400 ms later to be reasoned
# about — which is the whole difficulty of BU-23.
#
# It builds and runs the app; the reproduction is manual and has to be, because
# it is "change the default input device in the middle of an over". Connect,
# key down, and switch the input device in System Settings → Sound while
# transmitting. ASan output goes to the terminal this was launched from.
#
# The capture path *below* the app can be exercised without going on air, and
# should be tried first because it needs nobody's cooperation:
#
#     cd ../swift-hamvoip && swift build -Xswiftc -sanitize=address
#     ASAN_OPTIONS=detect_leaks=0 .build/debug/hamvoip-cli experiment capture-swap --swaps 8
asan-macos: $(PROJECT)
	$(XCB) -destination '$(MACOS_DEST)' -enableAddressSanitizer YES build
	@echo
	@echo "Launching the sanitized app. Reproduce by changing the default input"
	@echo "device mid-over; ASan reports land here."
	@ASAN_OPTIONS=detect_leaks=0 \
	  "$$($(XCB) -destination '$(MACOS_DEST)' -showBuildSettings 2>/dev/null \
	    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2}' | head -1)/Currawong.app/Contents/MacOS/Currawong"

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

# Prints the simulator `make test` would pick, for when it picks a surprising one.
simulator:
	@echo '$(SIMULATOR)'

clean:
	rm -rf $(PROJECT) $(DERIVED_DATA) build

# Kept separate from `clean` although the difference is now small: since APP-31
# there is no Codec2.xcframework to discard, and `.build` is only the scratch
# directory the old framework build used. It stays because a stale `.build` is
# still worth a way to remove, and because `distclean` is in muscle memory.
distclean: clean
	rm -rf .build
