# Bundled dependency manifest

This manifest describes the Homebrew packages responsible for the 49 dynamic libraries bundled in the Audacity Video Sync 2.0 development build audited on 7 August 2026. Formula definitions, upstream licence files and SPDX SBOM records are retained under `Licenses/<formula>/`.

| Formula | Installed version | Licence expression |
|---|---:|---|
| mpv | 0.41.0_7 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| ffmpeg | 8.1.2_1 | GPL-3.0-or-later |
| dav1d | 1.5.4 | BSD-2-Clause |
| lame | 4.0 | LGPL-2.0-or-later |
| libvmaf | 3.2.0 | BSD-2-Clause-Patent |
| libvpx | 1.16.0 | BSD-3-Clause |
| openssl@3 | 3.6.3_1 | Apache-2.0 |
| opus | 1.6.1 | BSD-3-Clause |
| svt-av1 | 4.2.0 | BSD-3-Clause |
| x264 | r3222 | GPL-2.0-or-later |
| x265 | 4.2 | GPL-2.0-or-later |
| jpeg-turbo | 3.2.0 | IJG AND Zlib AND BSD-3-Clause |
| libarchive | 3.8.9 | BSD-2-Clause |
| libb2 | 0.98.1 | CC0-1.0 |
| lz4 | 1.10.0_1 | BSD-2-Clause |
| xz | 5.8.3 | 0BSD AND GPL-2.0-or-later |
| zstd | 1.5.7_1 | (BSD-3-Clause OR GPL-2.0-only) AND BSD-2-Clause AND MIT |
| libass | 0.17.5 | ISC |
| libpng | 1.6.58 | libpng-2.0 |
| freetype | 2.14.3 | FTL |
| fribidi | 1.0.16 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| gettext | 1.0_1 | GPL-3.0-or-later AND LGPL-2.1-or-later |
| fontconfig | 2.18.2 | HPND-sell-variant AND Unicode-3.0 AND MIT-Modern-Variant AND MIT AND public-domain portions |
| pcre2 | 10.47_1 | BSD-3-Clause |
| glib | 2.88.3 | LGPL-2.1-or-later |
| graphite2 | 1.3.15 | MIT OR MPL-2.0 OR LGPL-2.1-or-later OR GPL-2.0-or-later |
| harfbuzz | 14.3.0 | MIT |
| libunibreak | 7.0 | Zlib |
| libbluray | 1.5.0 | LGPL-2.1-or-later |
| libudfread | 1.2.0 | LGPL-2.1-or-later |
| little-cms2 | 2.19 | MIT |
| shaderc | 2026.3 | Apache-2.0 |
| vulkan-loader | 1.4.357.0 | Apache-2.0 |
| libplacebo | 7.360.1 | LGPL-2.1-or-later |
| luajit | 2.1.1785763465 | MIT |
| mujs | 1.3.9 | ISC |
| libsamplerate | 0.2.2_1 | BSD-2-Clause |
| mpg123 | 1.33.7 | LGPL-2.1-only |
| rubberband | 4.0.0 | GPL-2.0-or-later |
| uchardet | 0.0.8 | MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later |
| zimg | 3.0.6 | WTFPL |

## FFmpeg build configuration

The audited Homebrew FFmpeg build reports the material configuration flags below:

```text
--enable-shared
--enable-version3
--enable-gpl
--enable-libsvtav1
--enable-libopus
--enable-libx264
--enable-libmp3lame
--enable-libdav1d
--enable-libvmaf
--enable-libvpx
--enable-libx265
--enable-openssl
--enable-videotoolbox
--enable-audiotoolbox
```

The build does **not** report `--enable-nonfree`.

## Apple system frameworks

AppKit, SwiftUI, Carbon, OpenGL, VideoToolbox, AudioToolbox and other `/System/Library` frameworks are supplied by macOS and are not copied into the application bundle.
