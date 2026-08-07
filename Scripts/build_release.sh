#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo 'Usage: bash "Resources/DMG Files/build_audacity_video_sync_native.sh" 2.0'
    exit 1
fi
if [[ "$VERSION" == *"/"* || "$VERSION" == *":"* ]]; then
    echo "Version cannot contain / or :."
    exit 1
fi

APP_NAME="Audacity Video Sync"
RELEASE_NAME="Audacity-Video-Sync"
EXECUTABLE_NAME="AudacityVideoSync"
MACOS_DEPLOYMENT_TARGET="26.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$APP_ROOT/Source"
INSTALLER_DIR="$APP_ROOT/dist"
RESOURCE_DIR="$APP_ROOT/Resources/DMG"
THIRD_PARTY_DIR="$APP_ROOT/ThirdParty"
ICON_FILE="$RESOURCE_DIR/Audacity Video Sync.icns"
VOLUME_ICON_FILE="$RESOURCE_DIR/VolumeIcon.icns"
BACKGROUND_FILE="$RESOURCE_DIR/dmg-background.png"
PUBLISHED_APP="$INSTALLER_DIR/$APP_NAME.app"
FINAL_DMG="$INSTALLER_DIR/$RELEASE_NAME-$VERSION.dmg"
MPV_PREFIX="$(/opt/homebrew/bin/brew --prefix mpv 2>/dev/null || true)"
WORK_ROOT="$(mktemp -d "/tmp/audacity-video-sync-native-${VERSION//[^A-Za-z0-9]/_}.XXXXXX")"
BUILD_DIR="$WORK_ROOT/build"
MODULE_CACHE="$WORK_ROOT/module-cache"
APP_BUNDLE="$WORK_ROOT/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
RESOURCES_DIR="$CONTENTS/Resources"
DMG_SOURCE="$WORK_ROOT/dmg-source"
VERIFY_MOUNT=""

cleanup() {
    if [ -n "$VERIFY_MOUNT" ] && mount | grep -Fq " on $VERIFY_MOUNT "; then
        hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
    fi
    if [ "${KEEP_AUDACITY_VIDEO_SYNC_NATIVE_WORK:-0}" != "1" ]; then
        rm -rf "$WORK_ROOT"
    else
        echo "Keeping build work folder: $WORK_ROOT"
    fi
}
trap cleanup EXIT

require_file() { if [ ! -f "$1" ]; then echo "Missing required file: $1"; exit 1; fi; }
require_tool() { if ! command -v "$1" >/dev/null 2>&1; then echo "Missing required tool: $1"; exit 1; fi; }

require_tool clang
require_tool swiftc
require_tool codesign
require_tool hdiutil
require_tool create-dmg
require_tool install_name_tool
require_tool otool
require_tool vtool
require_tool ditto
require_file "/opt/homebrew/bin/brew"
require_file "$SOURCE_DIR/AudacityVideoSync.swift"
require_file "$SOURCE_DIR/MPVPlayerView.h"
require_file "$SOURCE_DIR/MPVPlayerView.m"
require_file "$SOURCE_DIR/AudacityVideoSync-Bridging-Header.h"
require_file "$SOURCE_DIR/Info.plist"
require_file "$ICON_FILE"
require_file "$VOLUME_ICON_FILE"
require_file "$BACKGROUND_FILE"
require_file "$APP_ROOT/LICENSE"
require_file "$THIRD_PARTY_DIR/THIRD_PARTY_NOTICES.md"
require_file "$THIRD_PARTY_DIR/DEPENDENCIES.md"
require_file "$MPV_PREFIX/include/mpv/client.h"
require_file "$MPV_PREFIX/lib/libmpv.2.dylib"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE" "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR" "$DMG_SOURCE" "$INSTALLER_DIR"

echo "Compiling native arm64 app..."
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" clang \
    -fobjc-arc \
    -fmodules \
    -Wno-deprecated-declarations \
    -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" \
    -I"$MPV_PREFIX/include" \
    -c "$SOURCE_DIR/MPVPlayerView.m" \
    -o "$BUILD_DIR/MPVPlayerView.o"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swiftc \
    -module-cache-path "$MODULE_CACHE" \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -target "arm64-apple-macos$MACOS_DEPLOYMENT_TARGET" \
    -import-objc-header "$SOURCE_DIR/AudacityVideoSync-Bridging-Header.h" \
    -Xcc -I"$SOURCE_DIR" \
    -Xcc -Wno-deprecated-declarations \
    "$SOURCE_DIR/AudacityVideoSync.swift" \
    "$BUILD_DIR/MPVPlayerView.o" \
    -L"$MPV_PREFIX/lib" \
    -lmpv \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework OpenGL \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks' \
    -o "$MACOS_DIR/$EXECUTABLE_NAME"

cp "$SOURCE_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$ICON_FILE" "$RESOURCES_DIR/Audacity Video Sync.icns"
mkdir -p "$RESOURCES_DIR/Open Source Licences"
cp "$APP_ROOT/LICENSE" "$RESOURCES_DIR/COPYING"
cp "$THIRD_PARTY_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/Open Source Licences/"
cp "$THIRD_PARTY_DIR/DEPENDENCIES.md" "$RESOURCES_DIR/Open Source Licences/"
if [ -d "$THIRD_PARTY_DIR/Licenses" ]; then
    ditto "$THIRD_PARTY_DIR/Licenses" "$RESOURCES_DIR/Open Source Licences/Licenses"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MACOS_DEPLOYMENT_TARGET" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleVersion" "$CONTENTS/Info.plist" 2>/dev/null || true

echo "Bundling libmpv and its Apple-silicon runtime libraries..."
QUEUE_FILE="$WORK_ROOT/dylib-queue.txt"
SEEN_FILE="$WORK_ROOT/dylib-seen.txt"
: > "$QUEUE_FILE"
: > "$SEEN_FILE"
echo "$MPV_PREFIX/lib/libmpv.2.dylib" >> "$QUEUE_FILE"

QUEUE_LINE=1
while true; do
    SOURCE_LIB="$(sed -n "${QUEUE_LINE}p" "$QUEUE_FILE")"
    if [ -z "$SOURCE_LIB" ]; then break; fi
    QUEUE_LINE=$((QUEUE_LINE + 1))
    LIB_NAME="$(basename "$SOURCE_LIB")"
    if grep -Fqx "$LIB_NAME" "$SEEN_FILE"; then continue; fi
    echo "$LIB_NAME" >> "$SEEN_FILE"
    cp -L "$SOURCE_LIB" "$FRAMEWORKS_DIR/$LIB_NAME"

    otool -L "$SOURCE_LIB" | tail -n +2 | awk '{print $1}' | while IFS= read -r DEPENDENCY; do
        case "$DEPENDENCY" in
            /opt/homebrew/*)
                if [ -f "$DEPENDENCY" ]; then echo "$DEPENDENCY" >> "$QUEUE_FILE"; fi
                ;;
        esac
    done
done

for LIBRARY in "$FRAMEWORKS_DIR"/*.dylib; do
    LIB_NAME="$(basename "$LIBRARY")"
    install_name_tool -id "@rpath/$LIB_NAME" "$LIBRARY" 2>/dev/null
    otool -L "$LIBRARY" | tail -n +2 | awk '{print $1}' | while IFS= read -r DEPENDENCY; do
        case "$DEPENDENCY" in
            /opt/homebrew/*)
                install_name_tool -change "$DEPENDENCY" "@rpath/$(basename "$DEPENDENCY")" "$LIBRARY" 2>/dev/null
                ;;
        esac
    done
done

install_name_tool -change "$MPV_PREFIX/lib/libmpv.2.dylib" '@rpath/libmpv.2.dylib' "$MACOS_DIR/$EXECUTABLE_NAME" 2>/dev/null \
    || install_name_tool -change '/opt/homebrew/opt/mpv/lib/libmpv.2.dylib' '@rpath/libmpv.2.dylib' "$MACOS_DIR/$EXECUTABLE_NAME"

if find "$FRAMEWORKS_DIR" -type f -maxdepth 1 -exec file {} \; | grep -v 'arm64' | grep -q 'Mach-O'; then
    echo "Verification failed: a non-arm64 Mach-O library was bundled."
    exit 1
fi
if ! file "$MACOS_DIR/$EXECUTABLE_NAME" | grep -q 'arm64'; then
    echo "Verification failed: native executable is not arm64."
    exit 1
fi
if otool -L "$MACOS_DIR/$EXECUTABLE_NAME" "$FRAMEWORKS_DIR"/*.dylib | grep -E '^\s+/opt/homebrew/' >/dev/null; then
    echo "Verification failed: Homebrew library paths remain in the app."
    otool -L "$MACOS_DIR/$EXECUTABLE_NAME" "$FRAMEWORKS_DIR"/*.dylib | grep -E '^\s+/opt/homebrew/'
    exit 1
fi
for MACH_O in "$MACOS_DIR/$EXECUTABLE_NAME" "$FRAMEWORKS_DIR"/*.dylib; do
    BINARY_MINIMUM="$(vtool -show-build "$MACH_O" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    if [ -n "$BINARY_MINIMUM" ] && [ "$(printf '%s\n%s\n' "$MACOS_DEPLOYMENT_TARGET" "$BINARY_MINIMUM" | sort -V | tail -n 1)" != "$MACOS_DEPLOYMENT_TARGET" ]; then
        echo "Verification failed: $(basename "$MACH_O") requires macOS $BINARY_MINIMUM, above declared minimum $MACOS_DEPLOYMENT_TARGET."
        exit 1
    fi
done

echo "Signing app and bundled libraries..."
for LIBRARY in "$FRAMEWORKS_DIR"/*.dylib; do codesign --force --sign - "$LIBRARY" >/dev/null 2>&1; done
codesign --force --sign - "$MACOS_DIR/$EXECUTABLE_NAME" >/dev/null 2>&1
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1
codesign --verify --deep --strict "$APP_BUNDLE"

ditto "$APP_BUNDLE" "$DMG_SOURCE/$APP_NAME.app"
echo "Creating DMG..."
create-dmg \
    --volname "$APP_NAME $VERSION" \
    --volicon "$VOLUME_ICON_FILE" \
    --background "$BACKGROUND_FILE" \
    --window-pos 200 120 \
    --window-size 660 420 \
    --icon-size 112 \
    --text-size 13 \
    --icon "$APP_NAME.app" 155 230 \
    --app-drop-link 505 230 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    --disk-image-size 500 \
    "$WORK_ROOT/$RELEASE_NAME-$VERSION.dmg" \
    "$DMG_SOURCE"

BUILT_DMG="$WORK_ROOT/$RELEASE_NAME-$VERSION.dmg"
hdiutil verify "$BUILT_DMG" >/dev/null
VERIFY_MOUNT="$(mktemp -d "/tmp/audacity-video-sync-native-verify-${VERSION//[^A-Za-z0-9]/_}.XXXXXX")"
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$BUILT_DMG" >/dev/null
MOUNTED_APP="$VERIFY_MOUNT/$APP_NAME.app"
require_file "$MOUNTED_APP/Contents/MacOS/$EXECUTABLE_NAME"
if [ ! -e "$VERIFY_MOUNT/Applications" ]; then echo "Verification failed: Applications link is missing."; exit 1; fi
require_file "$VERIFY_MOUNT/.VolumeIcon.icns"
MOUNTED_VOLUME_ICON_ALPHA="$(sips -g hasAlpha "$VERIFY_MOUNT/.VolumeIcon.icns" 2>/dev/null | awk '/hasAlpha:/ {print $2; exit}')"
if [ "$MOUNTED_VOLUME_ICON_ALPHA" != "yes" ]; then
    echo "Verification failed: mounted-volume icon does not contain transparency."
    exit 1
fi
codesign --verify --deep --strict "$MOUNTED_APP"
if ! file "$MOUNTED_APP/Contents/MacOS/$EXECUTABLE_NAME" | grep -q 'arm64'; then
    echo "Verification failed: mounted app is not arm64."
    exit 1
fi
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
if [ "$MOUNTED_VERSION" != "$VERSION" ]; then
    echo "Verification failed: packaged version is $MOUNTED_VERSION, expected $VERSION."
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MOUNTED_APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Verification failed: CFBundleVersion would create a bracketed version number."
    exit 1
fi
hdiutil detach "$VERIFY_MOUNT" >/dev/null
rmdir "$VERIFY_MOUNT" 2>/dev/null || true
VERIFY_MOUNT=""

if [ -d "$PUBLISHED_APP" ]; then rm -rf "$PUBLISHED_APP"; fi
if [ -f "$FINAL_DMG" ]; then rm -f "$FINAL_DMG"; fi
ditto "$APP_BUNDLE" "$PUBLISHED_APP"
mv "$BUILT_DMG" "$FINAL_DMG"

echo "Preparing public-release compliance assets..."
bash "$SCRIPT_DIR/prepare_release_compliance.sh" "$VERSION" "$FINAL_DMG"

echo
echo "Done."
echo "App: $PUBLISHED_APP"
echo "DMG: $FINAL_DMG"
echo "Third-party source: $INSTALLER_DIR/$RELEASE_NAME-$VERSION-Third-Party-Source.tar.gz"
echo "Checksums: $INSTALLER_DIR/SHA256SUMS-$VERSION.txt"
echo -n "SHA-256: "
shasum -a 256 "$FINAL_DMG" | awk '{print $1}'
