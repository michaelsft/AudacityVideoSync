# Changelog

## 2.1 — 2026-08-21

- Added a temporary live video-offset control for manually aligning unsynchronised source material during Audacity-controlled playback.
- Added visible ±1 ms and ±10 ms offset buttons, millisecond precision and a one-click reset without modifying the audio, video or Audacity project.
- Synced playback now honours highlighted Audacity selections, stopping at the selection end and returning the video to its start.
- Added a translucent Audacity selection indicator and slim playhead to the AVS scrubber.
- Replaced the dedicated Control-Option-Space shortcut with context-sensitive following of Audacity's normal Space and P transport shortcuts.
- Keyboard following ignores label text fields and other interactive controls and requires macOS Accessibility permission.
- Fixed Space playback starting the video only after Audacity was paused by handling transport keys before Audacity begins playback.
- Accessibility requests now open and foreground the correct System Settings pane.
- Label typing context is tracked independently of Audacity's unreliable accessibility role so Space and P remain label text while editing.
- Return, Escape, Tab or clicking away from a label now restores Space/P synchronisation immediately without reconnecting.
- Removed the stale post-label accessibility focus gate and prevented transport keys reaching Audacity alone while a shared command is still settling.
- Sandboxed, read-only access is limited to videos explicitly opened or dropped by the user, avoiding broad Desktop-folder access requests.
- Replaced the synced Play/Stop button with the primary Disconnect Sync button and removed the duplicate disconnect control.
- Added clearer connected/disconnected status, a visual drift gauge and green/orange offset state.
- Increased the default window size and refreshed the app and volume icons.

## 2.0 — 2026-08-06

- Rebuilt as a native Apple Silicon SwiftUI/AppKit application.
- Embedded MPV playback with video controls and paused loading.
- Added permanent drag-and-drop video area.
- Made independent video playback available without Audacity.
- Added one-button Audacity cursor synchronisation.
- Added global `Control + Option + Space` synchronised playback.
- Added frontmost-Audacity shortcut restriction, enabled by default.
- Added startup compensation and drift correction.
- Added remembered Open Video start-folder settings.
