#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/ThirdParty/Licenses"

FORMULAE=(
    mpv ffmpeg dav1d lame libvmaf libvpx openssl@3 opus svt-av1 x264 x265
    jpeg-turbo libarchive libb2 lz4 xz zstd libass libpng freetype fribidi
    gettext fontconfig pcre2 glib graphite2 harfbuzz libunibreak libbluray
    libudfread little-cms2 shaderc vulkan-loader libplacebo luajit mujs
    libsamplerate mpg123 rubberband uchardet zimg
)

mkdir -p "$OUTPUT_DIR"

for formula in "${FORMULAE[@]}"; do
    prefix="$(/opt/homebrew/bin/brew --prefix "$formula")"
    cellar_path="$(cd "$prefix" && pwd -P)"
    safe_name="${formula//@/_}"
    target="$OUTPUT_DIR/$safe_name"
    mkdir -p "$target"

    while IFS= read -r file; do
        cp "$file" "$target/$(basename "$file")"
    done < <(find -L "$cellar_path" -maxdepth 2 -type f \( \
        -iname 'license*' -o -iname 'copying*' -o -iname 'copyright*' -o -iname 'notice*' \
    \) | sort)

    for metadata in sbom.spdx.json; do
        if [ -f "$cellar_path/$metadata" ]; then cp "$cellar_path/$metadata" "$target/"; fi
    done
    if [ -d "$cellar_path/.brew" ]; then
        formula_file="$(find "$cellar_path/.brew" -maxdepth 1 -type f -name '*.rb' | head -n 1)"
        if [ -n "$formula_file" ]; then cp "$formula_file" "$target/Homebrew-formula.rb"; fi
    fi
done

echo "Collected installed licence and build metadata in: $OUTPUT_DIR"
