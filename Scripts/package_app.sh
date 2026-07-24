#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="CodexRemote"
DISPLAY_NAME="Codex Remote"
EXPECTED_ARCH="arm64"
EXPECTED_BUNDLE_IDENTIFIER="com.ulisses.codexremote"
DEFAULT_APP_PATH="$ROOT_DIR/.build/$APP_NAME.app"

fail() {
    print -u2 -- "package_app: $*"
    exit 1
}

for tool in swift ditto plutil codesign lipo; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
[[ -x /usr/libexec/PlistBuddy ]] \
    || fail "required tool is unavailable: /usr/libexec/PlistBuddy"

INFO_PLIST_SOURCE="$ROOT_DIR/Resources/Info.plist"
ICON_SOURCE="$ROOT_DIR/.build/AppIcon.icns"
[[ -f "$INFO_PLIST_SOURCE" ]] || fail "Info.plist not found: $INFO_PLIST_SOURCE"

APP_PATH="${APP_PATH:-$DEFAULT_APP_PATH}"
if [[ "$APP_PATH" != /* ]]; then
    APP_PATH="$ROOT_DIR/$APP_PATH"
fi
[[ "${APP_PATH:t}" == "$APP_NAME.app" ]] \
    || fail "APP_PATH must end in $APP_NAME.app: $APP_PATH"

APP_PARENT="${APP_PATH:h}"
mkdir -p -- "$APP_PARENT"
[[ -d "$APP_PARENT" ]] || fail "application output parent is not a directory: $APP_PARENT"
APP_PARENT="$(cd "$APP_PARENT" && pwd -P)"
APP_PATH="$APP_PARENT/$APP_NAME.app"
[[ "$APP_PARENT" != "/" ]] || fail "unsafe application output parent"

plutil -lint "$INFO_PLIST_SOURCE" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_SOURCE")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST_SOURCE")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST_SOURCE")"
PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST_SOURCE")"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST_SOURCE")"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST_SOURCE")"
LSUI_ELEMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO_PLIST_SOURCE")"

[[ "$VERSION" == [A-Za-z0-9]* && "$VERSION" != *[^A-Za-z0-9._-]* ]] \
    || fail "unsupported application version: $VERSION"
[[ "$BUILD" == <-> ]] || fail "application build must be numeric: $BUILD"
[[ "$EXECUTABLE_NAME" == "$APP_NAME" ]] \
    || fail "expected executable $APP_NAME, found $EXECUTABLE_NAME"
[[ "$PACKAGE_TYPE" == "APPL" ]] || fail "Info.plist does not describe an application bundle"
[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
    || fail "expected bundle identifier $EXPECTED_BUNDLE_IDENTIFIER, found $BUNDLE_IDENTIFIER"
[[ "$MINIMUM_SYSTEM_VERSION" == "14.0" ]] \
    || fail "expected macOS minimum version 14.0, found $MINIMUM_SYSTEM_VERSION"
[[ "$LSUI_ELEMENT" == "true" ]] || fail "LSUIElement must be true for the menu-bar app"

print -- "Building $DISPLAY_NAME $VERSION ($BUILD) for $EXPECTED_ARCH..."
swift build \
    --package-path "$ROOT_DIR" \
    -c release \
    --arch "$EXPECTED_ARCH"
"$ROOT_DIR/Scripts/make_icon.sh" >/dev/null
[[ -f "$ICON_SOURCE" ]] || fail "application icon not found: $ICON_SOURCE"

BIN_DIR="$(swift build \
    --package-path "$ROOT_DIR" \
    -c release \
    --arch "$EXPECTED_ARCH" \
    --show-bin-path)"
EXECUTABLE_SOURCE="$BIN_DIR/$APP_NAME"
[[ -f "$EXECUTABLE_SOURCE" && -x "$EXECUTABLE_SOURCE" ]] \
    || fail "release executable not found: $EXECUTABLE_SOURCE"
[[ "$(lipo -archs "$EXECUTABLE_SOURCE")" == "$EXPECTED_ARCH" ]] \
    || fail "release executable is not exclusively $EXPECTED_ARCH"

TEMP_DIR="$(mktemp -d "$APP_PARENT/.codex-remote-app.XXXXXX")"
[[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$TEMP_DIR" != "/" ]] \
    || fail "could not create a safe temporary directory"

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" && "$TEMP_DIR" != "/" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
on_interrupt() {
    cleanup
    trap - EXIT
    exit 130
}
on_terminate() {
    cleanup
    trap - EXIT
    exit 143
}
trap cleanup EXIT
trap on_interrupt INT
trap on_terminate TERM

TEMP_APP="$TEMP_DIR/$APP_NAME.app"
CONTENTS="$TEMP_APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p -- "$MACOS" "$RESOURCES"

ditto --noqtn "$EXECUTABLE_SOURCE" "$MACOS/$APP_NAME"
chmod 0755 "$MACOS/$APP_NAME"
ditto --noqtn "$INFO_PLIST_SOURCE" "$CONTENTS/Info.plist"
ditto --noqtn "$ICON_SOURCE" "$RESOURCES/AppIcon.icns"

plutil -lint "$CONTENTS/Info.plist" >/dev/null
codesign --force --deep --sign - "$TEMP_APP"
codesign --verify --deep --strict "$TEMP_APP"

[[ "$(lipo -archs "$MACOS/$APP_NAME")" == "$EXPECTED_ARCH" ]] \
    || fail "packaged executable is not exclusively $EXPECTED_ARCH"

if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    [[ -d "$APP_PATH" && ! -L "$APP_PATH" ]] \
        || fail "refusing to replace non-directory application output: $APP_PATH"
    rm -rf -- "$APP_PATH"
fi
ditto --noqtn "$TEMP_APP" "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
print -- "$APP_PATH"
