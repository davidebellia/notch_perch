#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Export the app artwork at standard macOS icon resolutions.
ICON_SOURCE="assets/AppIcon.png"
ICON_OUTPUT="build/AppIcon.icns"
ICON_WORK="$(mktemp -d /private/tmp/notchperch-icon.XXXXXX)"
trap 'rm -rf "$ICON_WORK"' EXIT HUP INT TERM
ICON_SET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICON_SET" build
for ICON_SIZE in 16 32 128 256 512; do
  sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  ICON_DOUBLE=$((ICON_SIZE * 2))
  sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$ICON_SOURCE" --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o "$ICON_OUTPUT"
