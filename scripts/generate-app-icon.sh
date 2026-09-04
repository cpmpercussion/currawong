#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Regenerate the app icon PNGs in Assets.xcassets from the SVG sources in
# Design/. Run after editing either SVG. Requires librsvg and ImageMagick:
#
#   brew install librsvg imagemagick
#
# Design/AppIcon.svg is the master (full-bleed, iOS). Design/AppIcon-macOS.svg
# wraps the same artwork in the pre-Tahoe macOS treatment: an 824x824 rounded
# rectangle (r=185) centred on a transparent 1024 canvas. Both are written by
# Design/icon-explore/trace/trace.py --install; edit that, not the SVGs.
set -eu
cd "$(dirname "$0")/.."

SET=Sources/Currawong/Assets.xcassets/AppIcon.appiconset

# iOS marketing icon: App Store validation rejects an alpha channel, so strip it.
rsvg-convert -w 1024 -h 1024 Design/AppIcon.svg | magick - -alpha off "$SET/AppIcon-iOS-1024.png"

# macOS slots, each rendered from the SVG at its native size.
for entry in 16:16 16@2x:32 32:32 32@2x:64 128:128 128@2x:256 256:256 256@2x:512 512:512 512@2x:1024; do
    name=${entry%%:*}
    px=${entry##*:}
    rsvg-convert -w "$px" -h "$px" Design/AppIcon-macOS.svg -o "$SET/AppIcon-macOS-$name.png"
done

echo "regenerated $(ls "$SET" | grep -c '\.png$') PNGs in $SET"
