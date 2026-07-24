#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
OUTPUT_ICON="$ROOT_DIR/.build/AppIcon.icns"

fail() {
    print -u2 -- "make_icon: $*"
    exit 1
}

for tool in sips iconutil; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
[[ -f "$SOURCE_ICON" ]] || fail "source icon not found: $SOURCE_ICON"
[[ "$(sips -g pixelWidth "$SOURCE_ICON" | awk '/pixelWidth/ {print $2}')" == "1024" ]] \
    || fail "source icon must be 1024 pixels wide"
[[ "$(sips -g pixelHeight "$SOURCE_ICON" | awk '/pixelHeight/ {print $2}')" == "1024" ]] \
    || fail "source icon must be 1024 pixels high"
[[ "$(sips -g hasAlpha "$SOURCE_ICON" | awk '/hasAlpha/ {print $2}')" == "yes" ]] \
    || fail "source icon must include transparency"

rm -rf -- "$ICONSET_DIR"
mkdir -p -- "$ICONSET_DIR"

sips -z 16 16 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICON"
print -- "$OUTPUT_ICON"
