# Contributing

Bug reports and focused pull requests are welcome.

Before submitting a change:

1. Build on an Apple Silicon Mac running macOS 26 or later.
2. Confirm independent video loading and playback.
3. Confirm Audacity connection with `mod-script-pipe` enabled.
4. Confirm cursor repositioning followed by `Control + Option + Space` starts both at the new position.
5. Confirm stopping returns both to the run's starting point.
6. Confirm `codesign --verify --deep --strict` succeeds for the built app.

Contributions are accepted under the repository's GPL-3.0-or-later licence.
