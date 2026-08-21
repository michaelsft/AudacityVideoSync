#!/bin/bash
set -euo pipefail

VERSION="${1:-2.1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO_ROOT/dist/Audacity Video Sync.app"
DMG="$REPO_ROOT/dist/Audacity-Video-Sync-$VERSION.dmg"
SOURCE="$REPO_ROOT/dist/Audacity-Video-Sync-$VERSION-Third-Party-Source.tar.gz"
CHECKSUMS="$REPO_ROOT/dist/SHA256SUMS-$VERSION.txt"

for path in "$APP" "$DMG" "$SOURCE" "$CHECKSUMS"; do
    if [ ! -e "$path" ]; then echo "Missing release item: $path"; exit 1; fi
done

codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/AudacityVideoSync" | grep -q 'arm64'
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Unexpected CFBundleVersion would create a bracketed version number."
    exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION"
test -f "$APP/Contents/Resources/COPYING"
test -d "$APP/Contents/Resources/Open Source Licences/Licenses"
hdiutil verify "$DMG" >/dev/null
(cd "$REPO_ROOT/dist" && shasum -a 256 -c "$(basename "$CHECKSUMS")")

echo "Release $VERSION verified."
