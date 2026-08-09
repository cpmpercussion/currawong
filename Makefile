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
#   make clean        remove generated project and build output
#
# Overrides:
#   make test SIMULATOR='iPhone 16'
#   make build DEVELOPMENT_TEAM=XXXXXXXXXX
#   make build SIGNING='CODE_SIGNING_ALLOWED=NO'   # unsigned CI build

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

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) $(SIGNING)

.PHONY: all generate build build-macos test test-macos clean simulator

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

# Prints the simulator `make test` would pick, for when it picks a surprising one.
simulator:
	@echo '$(SIMULATOR)'

clean:
	rm -rf $(PROJECT) $(DERIVED_DATA) build
