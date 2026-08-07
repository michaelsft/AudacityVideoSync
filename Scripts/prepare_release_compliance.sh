#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
DMG_PATH="${2:-}"
if [ -z "$VERSION" ] || [ -z "$DMG_PATH" ]; then
    echo "Usage: bash Scripts/prepare_release_compliance.sh VERSION PATH_TO_DMG [OUTPUT_DIRECTORY]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${3:-$REPO_ROOT/dist}"
RELEASE_NAME="Audacity-Video-Sync"
SOURCE_ARCHIVE="$DIST_DIR/$RELEASE_NAME-$VERSION-Third-Party-Source.tar.gz"
CHECKSUM_FILE="$DIST_DIR/SHA256SUMS-$VERSION.txt"
WORK_DIR="$(mktemp -d "/tmp/avs-release-source-${VERSION//[^A-Za-z0-9]/_}.XXXXXX")"
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/Library/Caches}"
CACHE_DIR="$CACHE_BASE/AudacityVideoSyncSources"

FORMULAE=(
    mpv ffmpeg dav1d lame libvmaf libvpx openssl@3 opus svt-av1 x264 x265
    jpeg-turbo libarchive libb2 lz4 xz zstd libass libpng freetype fribidi
    gettext fontconfig pcre2 glib graphite2 harfbuzz libunibreak libbluray
    libudfread little-cms2 shaderc vulkan-loader libplacebo luajit mujs
    libsamplerate mpg123 rubberband uchardet zimg
)

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

if [ ! -f "$DMG_PATH" ]; then
    echo "DMG not found: $DMG_PATH"
    exit 1
fi

mkdir -p "$WORK_DIR/Audacity-Video-Sync-$VERSION" "$WORK_DIR/Third-Party-Sources"
mkdir -p "$DIST_DIR" "$CACHE_DIR"
ditto "$REPO_ROOT/Source" "$WORK_DIR/Audacity-Video-Sync-$VERSION/Source"
ditto "$REPO_ROOT/Scripts" "$WORK_DIR/Audacity-Video-Sync-$VERSION/Scripts"
ditto "$REPO_ROOT/Resources" "$WORK_DIR/Audacity-Video-Sync-$VERSION/Resources"
ditto "$REPO_ROOT/ThirdParty" "$WORK_DIR/Audacity-Video-Sync-$VERSION/ThirdParty"
for file in LICENSE README.md RELEASE_CHECKLIST.md TRADEMARKS.md; do
    if [ -f "$REPO_ROOT/$file" ]; then cp "$REPO_ROOT/$file" "$WORK_DIR/Audacity-Video-Sync-$VERSION/"; fi
done

for tool in jq curl git shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool"
        exit 1
    fi
done

echo "Collecting exact sources and patches recorded in the installed SPDX SBOMs."
echo "Downloads are cached for later releases."
for formula in "${FORMULAE[@]}"; do
    echo "  $formula"
    safe_formula="${formula//@/_}"
    metadata_dir="$REPO_ROOT/ThirdParty/Licenses/$safe_formula"
    sbom="$metadata_dir/sbom.spdx.json"
    formula_file="$metadata_dir/Homebrew-formula.rb"
    target_dir="$WORK_DIR/Third-Party-Sources/$safe_formula"
    mkdir -p "$target_dir"

    if [ ! -f "$sbom" ]; then
        echo "Missing SPDX source record: $sbom"
        exit 1
    fi

    while IFS=$'\t' read -r package_id url expected_sha; do
        [ -n "$url" ] || continue
        clean_url="${url%%\?*}"
        base_name="$(basename "$clean_url")"
        safe_id="$(echo "$package_id" | tr '@/:' '____')"

        if [[ "$url" == *.git ]]; then
            if [ ! -f "$formula_file" ]; then
                echo "Missing formula metadata needed for Git revision: $formula_file"
                exit 1
            fi
            revision="$(sed -nE 's/.*revision: "([0-9a-f]+)".*/\1/p' "$formula_file" | head -n 1)"
            if [ -z "$revision" ]; then
                echo "Could not determine pinned Git revision for $formula"
                exit 1
            fi
            cached_file="$CACHE_DIR/$safe_formula-$revision.tar.gz"
            if [ ! -f "$cached_file" ]; then
                clone_dir="$WORK_DIR/git-$safe_formula"
                git clone --quiet --no-checkout "$url" "$clone_dir"
                git -C "$clone_dir" archive \
                    --format=tar.gz \
                    --prefix="$safe_formula-$revision/" \
                    --output="$cached_file" \
                    "$revision"
            fi
        else
            cached_file="$CACHE_DIR/$safe_id--$base_name"
            needs_download=1
            if [ -f "$cached_file" ] && [ -n "$expected_sha" ]; then
                actual_sha="$(shasum -a 256 "$cached_file" | awk '{print $1}')"
                if [ "$actual_sha" = "$expected_sha" ]; then needs_download=0; fi
            fi
            if [ "$needs_download" = "1" ]; then
                curl --fail --location --retry 3 --output "$cached_file.part" "$url"
                mv "$cached_file.part" "$cached_file"
            fi
            if [ -n "$expected_sha" ]; then
                actual_sha="$(shasum -a 256 "$cached_file" | awk '{print $1}')"
                if [ "$actual_sha" != "$expected_sha" ]; then
                    echo "Checksum mismatch for $url"
                    exit 1
                fi
            fi
        fi

        cp "$cached_file" "$target_dir/$(basename "$cached_file")"
    done < <(
        jq -r '.packages[]
            | select(.SPDXID | test("^SPDXRef-(Archive|Patch)"))
            | [.SPDXID, .downloadLocation, (.checksums[]? | select(.algorithm == "SHA256") | .checksumValue) // ""]
            | @tsv' "$sbom"
    )
done

tar -C "$WORK_DIR" -czf "$SOURCE_ARCHIVE" \
    "Audacity-Video-Sync-$VERSION" \
    "Third-Party-Sources"

(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$SOURCE_ARCHIVE")" > "$(basename "$CHECKSUM_FILE")"
)

echo "Source archive: $SOURCE_ARCHIVE"
echo "Checksums: $CHECKSUM_FILE"
