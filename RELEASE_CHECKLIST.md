# Public release checklist

## One-time GitHub setup

1. Create an empty public repository in your GitHub account.
2. Upload the complete contents of this folder, including files whose names begin with a dot.
3. Keep the repository licence set to **GNU GPLv3**.
4. Add the repository description: `Native Apple Silicon video synchronisation companion for Audacity.`
5. Add topics such as `audacity`, `mpv`, `macos`, `swiftui`, `video`, and `audio`.

## Before each release

1. Update the version in `Source/Info.plist` and `CHANGELOG.md`.
2. Check that `ThirdParty/DEPENDENCIES.md` matches the installed libraries.
3. Run `bash Scripts/collect_licenses.sh`.
4. Commit and tag the exact release source, for example `v2.0`.
5. Run the public release builder:

   ```bash
   bash Scripts/build_release.sh 2.0
   ```

6. Verify the release:

   ```bash
   bash Scripts/verify_release.sh 2.0
   ```

## Upload to the GitHub Release

Upload all of these from `dist/` to the same release:

- `Audacity-Video-Sync-2.0.dmg`
- `Audacity-Video-Sync-2.0-Third-Party-Source.tar.gz`
- `SHA256SUMS-2.0.txt`

Do not upload a DMG without its corresponding source archive and checksums.

GitHub will also generate source archives from the tag. Those cover this application's repository source; the separately generated third-party archive contains the exact upstream archives and Homebrew patches recorded for the bundled playback stack.

## Gatekeeper warning

The current build is ad-hoc signed rather than Developer ID signed and notarised. Public downloads may be blocked by Gatekeeper. Until notarisation is added, explain that users may need to use **System Settings > Privacy & Security > Open Anyway** after the first blocked launch.

## Final checks

- Test the DMG on a different Apple Silicon Mac or a clean macOS account.
- Confirm the app is version `2.0`, with no bracketed build number.
- Confirm both user guides match the released interface.
- Confirm the app's `Contents/Resources/Open Source Licences` folder is present.
- Confirm the release description includes the independent-project trademark disclaimer.
- Confirm the release description states Apple Silicon, macOS 26 or later, and the current Gatekeeper/notarisation status.
- Confirm the release tag points to the exact commit used for the release build.
- Download the three assets and run `shasum -a 256 -c SHA256SUMS-X.Y.txt` without renaming them.
