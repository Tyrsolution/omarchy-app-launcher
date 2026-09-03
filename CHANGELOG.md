# Changelog

All notable changes to App Launcher are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The
version below tracks `version` in [`manifest.json`](manifest.json) — bump the two
together, since that is the number `omarchy plugin list` reports to users.

Changes are grouped under `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, and
`Security`. Merged pull requests are credited inline with their number and author.

## [Unreleased]

### Fixed

- The bar button uses `BarIconButton` rather than `WidgetButton`, so the launcher glyph
  is optically centered within its bar slot instead of sitting off to one side.
  `BarIconButton` derives from `WidgetButton` and sizes itself to the shell's shared icon
  slot (`Style.bar.iconSlot`), which also makes the previous `horizontalMargin: 7.5`
  override redundant, so it is removed. Vertical bars render identically to before — that
  margin only ever fed the horizontal width calculation.
  ([#1](https://github.com/Tyrsolution/omarchy-app-launcher/pull/1), thanks to
  [@nsyntych](https://github.com/nsyntych))

## [0.1.0] - 2026-08-23

Initial release.

### Added

- Overlay plugin for `omarchy-shell` presenting applications as a centered grid of
  clickable icons. Summoning it is an IPC call into the already-running shell rather than
  a cold process start.
- Live install and remove tracking via the shell's shared `AppLibrary`, so the grid
  follows package changes with no polling and no restart.
- Frecency ordering, which surfaces a "Frequently used" row above the alphabetical grid.
- Coding agents (Claude Code, Codex, Gemini, …) listed alongside applications and launched
  into a terminal.
- Bar widget entry point for opening the launcher by click. It shares the single IPC
  toggle path with the `SUPER + A` keybinding, so the button and the binding cannot drift
  out of sync.
- Setup wizards for the keybinding and menu rows, plus documentation covering install,
  uninstall, the safety surface, and what "Remove from launcher" does.

[Unreleased]: https://github.com/Tyrsolution/omarchy-app-launcher/compare/ebf72cb...HEAD
[0.1.0]: https://github.com/Tyrsolution/omarchy-app-launcher/tree/ebf72cb
