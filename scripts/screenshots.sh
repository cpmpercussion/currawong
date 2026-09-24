#!/bin/sh
# App Store screenshots (APP-39): every ScreenshotStage scene, light and dark,
# on each iOS simulator named below and on macOS. PNGs land in
# build/screenshots/<destination>/, named <n>-<scene>-<appearance>.png.
#
#   scripts/screenshots.sh                  # iOS devices and macOS
#   scripts/screenshots.sh macos            # one platform
#   IOS_DEVICES='iPhone 17 Pro Max' scripts/screenshots.sh ios
#
# The defaults are the sizes App Store Connect requires: the 6.9" iPhone and
# the 13" iPad. The Mac window is sized by the stage to 1280x800 points, which
# is 2560x1600 on a Retina display.
set -eu
failed=0

cd "$(dirname "$0")/.."
PLATFORMS=${1:-ios macos}
IOS_DEVICES=${IOS_DEVICES:-"iPhone 17 Pro Max|iPad Pro 13-inch (M5)"}
OUT=build/screenshots
XCB="xcodebuild -project Currawong.xcodeproj -scheme CurrawongScreenshots -derivedDataPath DerivedData"

run() { # destination-spec, output-dir-name
    bundle="build/screenshots-$2.xcresult"
    rm -rf "$bundle" "$OUT/$2"
    mkdir -p "$OUT/$2"
    # Exported even when a scene fails, so the failure can be seen.
    $XCB -destination "$1" -resultBundlePath "$bundle" test || failed=1
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$OUT/$2"
    # The manifest maps exported file names to the attachment names.
    /usr/bin/python3 - "$OUT/$2" <<'PY'
import json, os, sys
d = sys.argv[1]
for test in json.load(open(os.path.join(d, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        stem = name.split("_")[0] if name else a["exportedFileName"]
        os.replace(os.path.join(d, a["exportedFileName"]), os.path.join(d, stem + ".png"))
os.remove(os.path.join(d, "manifest.json"))
PY
    ls "$OUT/$2"
}

[ -d Currawong.xcodeproj ] || xcodegen generate

for platform in $PLATFORMS; do
    case $platform in
    ios)
        echo "$IOS_DEVICES" | tr '|' '\n' | while read -r device; do
            # Booted and left to settle first, so a first-boot system
            # notification has come and gone before anything is captured.
            xcrun simctl bootstatus "$device" -b >/dev/null
            sleep 20
            xcrun simctl status_bar "$device" override --time 9:41 \
                --dataNetwork wifi --wifiMode active --wifiBars 3 \
                --cellularMode active --cellularBars 4 \
                --batteryState charged --batteryLevel 100
            run "platform=iOS Simulator,name=$device" "$(echo "$device" | tr ' ' '-' | tr -d '()"')"
        done ;;
    macos)
        run "platform=macOS" macos ;;
    *)
        echo "unknown platform: $platform (ios or macos)"; exit 1 ;;
    esac
done

exit $failed
