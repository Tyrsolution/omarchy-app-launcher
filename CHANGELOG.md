# Changelog

All notable changes to App Launcher are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The
version below tracks `version` in [`manifest.json`](manifest.json) and the `v*` git
tag — bump all three together. Omarchy itself never shows that number: `omarchy
plugin validate` requires the field to exist but ignores its value, and `omarchy
plugin list` reports no version in either its table or `--json`. It is for people
reading the repo and for matching a checkout to a release, which is what makes the
tag the part that actually reaches anyone.

Changes are grouped under `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, and
`Security`. Merged pull requests are credited inline with their number and author.

## [Unreleased]

### Changed

- The project description now says what the launcher became rather than what it
  shipped as. The old wording — an icon grid with frecency and agents — predated
  the System section and the toggles, and read as a feature list. Updated in all
  three places it lives: the GitHub About, `manifest.json` (which is what the
  plugin marketplace lists you by), and the README's opening line.

## [0.4.0] - 2026-09-03

### Added

- Two toggle rows above the search field. **Session** — Do Not Disturb, Stay
  Awake, Nightlight, Screensaver, Window Gaps — acts on the machine; the second
  row acts on the window behind the launcher and is labelled with it, since a
  switch that changes something you cannot see should say what it is aimed at.
  On is shown by a filled pill as well as colour, so it does not depend on hue.
  Both rows are keyboard reachable and flipping one leaves the launcher open.
- The window row is shown only when the launcher is summoned by keybinding. With
  `input:follow_mouse` on, reaching for the bar button refocuses every window the
  pointer crosses, so on that path the row would describe — and act on — a window
  the user never chose. The bar button now marks its payload `{"source":"bar"}`;
  anything unmarked is treated as keyboard, so existing keybindings need no
  change.

### Removed

- The overlay's `toggle()`. The shell decides open-vs-hide itself and calls
  `open(payload)` directly, so it was never on the path `omarchy-shell shell
  toggle` takes. It hardcoded `open("{}")`, which would have discarded the
  `source` marker and quietly restored the window toggles on the pointer path.

## [0.3.0] - 2026-09-03

### Added

- `when:` and `checked:` guards are now evaluated, so System rows reflect the
  machine they are on: Hibernate is hidden where it is unavailable, "Stop
  Screenrecording" only appears while recording, and the current default agent,
  browser, terminal and editor carry a ✓. On this machine that hides 70 of 269
  leaves. Folders whose every descendant is hidden disappear rather than opening
  onto an empty grid.
- Guards are answered by one batched `bash` process per evaluation (~0.3s for
  185 of them) rather than a process per row, and re-run on each summon so a row
  cannot contradict state that changed since the shell started. The open path
  never waits on it — the grid draws on the previous answers and takes the new
  ones when they land.

### Changed

- The card sizes itself to a whole number of application rows. The grid snaps to
  whole rows so the last is never sliced, and the fixed card height left 63px
  over — a half-row of dead space above the System divider that read as the grid
  running out. Removing it also recovers the application row the System strip had
  cost, so the grid is back to the density it had before the section existed.
- Folder tiles in the main grid carry the same `›` marker the System strip uses.
  Inside a folder some tiles open and some run, and nothing distinguished them:
  `Install` listed Development beside Windows identically.
- Search results in the strip name the folder a command sits in rather than its
  whole trail. At tile width "Setup › Defaults › Agent" rendered as
  "…aults › Agent", spending the space on an elision marker; it now reads
  "Agent".

## [0.2.0] - 2026-09-03

### Added

- A **System** section, pinned below the applications, that browses Omarchy's own
  menu as folders. Nine tiles (Learn, Trigger, Style, Setup, Install, Remove,
  Update, About, Power) drill into their submenus in place, with a breadcrumb and
  a clickable Back target; leaves run the same shell command the menu would run.
  It is pinned rather than scrolled in with the apps because reaching it by
  scrolling past every application would be worse than the menu it complements.
- Menu commands are searchable. Typing turns the strip into ranked results drawn
  from all 269 leaves, flattened with their breadcrumb — folders are for
  browsing, search is for finding — and the selection follows the results, so a
  query matching no applications still runs on Enter.
- Menu commands earn frecency like applications, so one you run often can climb
  into the Frequently used row.
- `Menu.js`: parses the shipped menu and the user's `omarchy-menu.jsonc`
  extensions, merges them, and flattens the tree. Both files are watched, so a
  row added to the menu appears in the launcher without a shell restart.

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

[Unreleased]: https://github.com/Tyrsolution/omarchy-app-launcher/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Tyrsolution/omarchy-app-launcher/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Tyrsolution/omarchy-app-launcher/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Tyrsolution/omarchy-app-launcher/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Tyrsolution/omarchy-app-launcher/releases/tag/v0.1.0
