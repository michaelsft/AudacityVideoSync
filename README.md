# Audacity Video Sync

Audacity Video Sync is a native Apple Silicon macOS companion for synchronising video playback with the editing cursor and playback state in Audacity.

It embeds libmpv for accurate video playback while using Audacity's `mod-script-pipe` interface for cursor and transport control. Video can also be opened and played independently without Audacity.

> This is an independent, unofficial project. It is not affiliated with, endorsed by, or sponsored by the Audacity project, Muse Group, MPV, FFmpeg, or their contributors.

## Features

- Native SwiftUI/AppKit interface.
- Embedded MPV video playback.
- Drag-and-drop or Open Video file selection.
- Videos load paused and remain usable independently.
- One-button synchronisation to Audacity's editing cursor.
- Global `Control + Option + Space` shortcut to start and stop both applications.
- Each start reads the current Audacity cursor before playback.
- Each stop returns to that run's starting point.
- Configurable startup compensation.
- Apple Silicon only.

## Requirements

- Apple Silicon Mac.
- macOS 26 or later. The current bundled Homebrew MPV/FFmpeg libraries were built for macOS 26; supporting earlier releases requires a separately built and tested dependency stack.
- Audacity with `mod-script-pipe` enabled for synchronised operation.

Audacity is not required for independent video playback.

## First-time Audacity setup

1. Open **Audacity > Settings > Modules**.
2. Set **mod-script-pipe** to **Enabled**.
3. Completely quit and reopen Audacity.
4. Give Audacity Video Sync Accessibility permission if macOS requests it.

See the illustrated [First-Time Setup Guide](Documentation/User%20Guides/Audacity%20Video%20Sync%202.0%20-%20First-Time%20Setup.png).

## Everyday use

1. Open Audacity and Audacity Video Sync in either order.
2. Load the audio into Audacity and the matching video into AVS.
3. Click **Sync Video to Audacity Cursor** once.
4. Place Audacity's cursor inside the waveform.
5. Press `Control + Option + Space` to start or stop both.

See the illustrated [Quick User Guide](Documentation/User%20Guides/Audacity%20Video%20Sync%202.0%20-%20Quick%20User%20Guide.png).

## Building from source

The build requires an Apple Silicon Mac, Xcode command-line tools, Homebrew MPV, and `create-dmg`:

```bash
xcode-select --install
brew install mpv create-dmg
bash Scripts/build_release.sh 2.0
```

Finished release files are written to `dist/`. The release build also creates a corresponding third-party source archive and SHA-256 checksums. The first compliance build may take some time because Homebrew source archives must be downloaded; they are cached afterwards.

## Public binary releases

Do not upload a DMG by itself. Upload all three generated files from `dist/` to the same GitHub Release:

- `Audacity-Video-Sync-X.Y.dmg`
- `Audacity-Video-Sync-X.Y-Third-Party-Source.tar.gz`
- `SHA256SUMS-X.Y.txt`

Follow [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

### macOS Gatekeeper

The current public build is ad-hoc signed rather than Developer ID signed and notarised. On first launch, macOS may block the app as being from an unidentified developer. After attempting to open it once, go to **System Settings > Privacy & Security** and choose **Open Anyway** only if you downloaded the files from this repository and their SHA-256 checksums match the published checksum file.

## Security note

Audacity documents `mod-script-pipe` as a developer-oriented interface which allows external programs to send commands to Audacity. Only enable it on a trusted personal Mac and do not use it in an untrusted multi-user or server environment.

## Licence

Audacity Video Sync is copyright © 2026 Audacity Video Sync contributors and is distributed under the GNU General Public License version 3 or, at your option, any later version. See [LICENSE](LICENSE).

Bundled releases include GPL, LGPL, BSD, MIT, Apache, ISC, MPL and other open-source components. See [ThirdParty/THIRD_PARTY_NOTICES.md](ThirdParty/THIRD_PARTY_NOTICES.md) and [ThirdParty/DEPENDENCIES.md](ThirdParty/DEPENDENCIES.md).
