# Contributing

Bug reports and focused pull requests are welcome.

Before submitting a change:

1. Build on an Apple Silicon Mac running macOS 26 or later.
2. Confirm independent video loading and playback.
3. Confirm Audacity connection with `mod-script-pipe` enabled.
4. Confirm cursor repositioning followed by `Space` in Audacity starts both at the new position.
5. Confirm `P` pauses and resumes both, and that typing Space or P while editing label text does not trigger transport following.
6. Confirm the one-time Accessibility flow opens the correct System Settings pane and does not request Input Monitoring.
7. Confirm stopping returns both to the run's starting point and highlighted selections stop and return correctly.
8. Confirm the ±1 ms and ±10 ms offset controls work during playback without altering either source file.
9. Confirm `codesign --verify --deep --strict` succeeds for the built app.

Contributions are accepted under the repository's GPL-3.0-or-later licence.
