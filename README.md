# App Launcher

A centered grid of clickable application icons for [Omarchy](https://omarchy.org/) 4.x.

It runs as an `overlay` plugin inside `omarchy-shell` (Quickshell), so summoning
it is an IPC call into a process that is already running — not a cold start. The
app list comes from the shell's shared `AppLibrary`, so installing or removing an
application updates the grid live, with no polling and no restart.

Coding agents (Claude Code, Codex, Gemini, …) appear alongside applications and
launch into a terminal.

**Requirements:** Omarchy 4.x with `omarchy-shell` (Quickshell 0.3+). The
configuration wizards additionally need `gum` and `python3`, both of which ship
with Omarchy.

---

## Install

The plugin itself is a directory drop-in; the keybinding and menu rows are
separate because a plugin cannot write to those files on your behalf.

```bash
# 1. the plugin
omarchy plugin add https://github.com/Tyrsolution/omarchy-app-launcher.git --enable --yes

# (or by hand)
# git clone https://github.com/Tyrsolution/omarchy-app-launcher.git \
#     ~/.config/omarchy/plugins/tyrsolution.app-launcher
# omarchy-shell shell rescanPlugins
# omarchy plugin enable tyrsolution.app-launcher left

# 2. a keybinding — add to ~/.config/hypr/bindings.lua
#    o.bind("SUPER + A", "App Launcher", "omarchy-shell shell toggle tyrsolution.app-launcher '{}'")

# 3. the Setup menu rows — copy the setup.applauncher.* block from
#    docs/omarchy-menu.jsonc into ~/.config/omarchy/extensions/omarchy-menu.jsonc

# 4. check it
omarchy plugin list | grep app-launcher
omarchy-shell shell toggle tyrsolution.app-launcher '{}'
```

Step 3 is optional: everything it exposes can also be done from a shell. Without
it you simply lose the guided wizards under Setup.

---

## Using it

| Open it with | What it runs |
|---|---|
| `SUPER + A` | `omarchy-shell shell toggle tyrsolution.app-launcher '{}'` |
| The ▦ button in the bar | the same IPC toggle — click to open, click again to close |
| Any script | `omarchy-shell shell toggle tyrsolution.app-launcher '{}'` |

### Keyboard

| Key | Action |
|---|---|
| any character | filter as you type (name, generic name, comment, keywords, acronym) |
| `↑` `↓` `←` `→` | move the selection; up/down crosses the section divider, keeping your column |
| `Home` / `End` | first tile / last tile |
| `Enter` | launch the selection |
| `Menu` | context menu for the selection |
| `Esc` | clear the filter, or close if the filter is empty |
| `Backspace` | edit the filter |

### Mouse

Click a tile to launch it. Hovering moves the selection. Right-click opens the
context menu: an app offers its `.desktop` actions (Chrome's *New Incognito
Window*, a terminal's *New Window*, …), *Reset usage ranking*, and *Remove from
launcher…* (the stock `omarchy-remove-launcher-entry` flow); an agent offers
*Set as default agent* instead. Clicking outside the card closes it.

### Payload options

```bash
omarchy-shell shell toggle tyrsolution.app-launcher '{"query":"chr"}'     # open pre-filtered
omarchy-shell shell toggle tyrsolution.app-launcher '{"iconScale":1.4}'   # bigger icons
omarchy-shell shell toggle tyrsolution.app-launcher '{"fontFamily":"Inter"}'
```

---

## What you see

**Frequently used** — one row, most-launched first, containing only things you
have actually launched. Each launch adds 1 to a score that halves every two
weeks, so a daily driver holds its place without pinning while last month's
one-off drifts out. On a fresh install the section is absent entirely rather
than filled with a guess.

**All apps** — everything else alphabetically, in a scrolling grid with a
draggable scroll bar. The viewport snaps to whole rows, so the bottom row is
never sliced in half.

Typing collapses both into a single relevance-ranked grid; matching agents lead,
since typing three letters of an agent's name should not put it three rows down.

**Badges.** A tile whose desktop entry appeared since the last time you closed
the launcher carries an accent dot, and the footer counts them. Closing the
launcher marks everything on screen as seen.

**Theme.** Colors, fonts, corner radius, and border style come from the shared
`qs.Commons` tokens, so it re-themes with `omarchy theme set`.

---

## Configuring it

Everything lives under **Omarchy menu › Setup › App Launcher**, also reachable as
`omarchy menu summon applauncher`:

| Row | What it does |
|---|---|
| Open Launcher | Same toggle as `SUPER+A` |
| Add Application | Guided prompts that write a real desktop entry |
| Add Coding Agent | Guided prompts that add a CLI agent to `agents.json` |
| Remove Coding Agent | Picks from the agents you added; built-ins are not editable here |
| Edit Agents File | Opens `agents.json` in `$EDITOR` for hand-tuning flags |
| Reset Usage Ranking | Deletes `usage.json`, emptying *Frequently used* |

The wizards live in this plugin's `bin/` and run fine on their own:

```bash
bin/app-launcher-add-app        # write a desktop entry
bin/app-launcher-add-agent      # add a CLI agent
bin/app-launcher-remove-agent   # remove one you added
```

### Adding an application

*Add Application* writes `~/.local/share/applications/<name>.desktop` rather than
a launcher-private entry, on purpose: a desktop entry is the system's own
registry, so the app appears in this launcher, Omarchy's Apps menu, and anything
else that reads XDG entries. This launcher watches those directories, so the tile
shows up immediately — no restart, no rescan.

Use it for AppImages, hand-installed binaries, and scripts. Anything installed by
a package manager already ships its own desktop entry.

### Adding a coding agent

Omarchy's agent roster is a fixed list, so anything else goes in:

```
~/.config/omarchy/app-launcher/agents.json
```

```json
{
  "version": 1,
  "agents": [
    {
      "id": "antigravity",
      "name": "Antigravity CLI",
      "command": ["agy", "--dangerously-skip-permissions"],
      "monogram": "Ag"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Required. Names the frecency key (`agent:<id>`). Letters, digits, `.`, `_`, `-`. |
| `name` | Shown on the tile. Defaults to the id. |
| `command` | argv to run. `command[0]` is the binary probed with `command -v` — an agent that isn't installed simply doesn't appear. Defaults to `[id]`. |
| `monogram` | One or two characters for the tile. Derived from the name if omitted. |
| `icon` | Optional. An absolute path / `file://` URL, or an icon-theme name. Wins over the monogram. |

An entry whose `id` matches a built-in **replaces** it, so you can override the
shipped flags for `claude` or `codex` without editing plugin code.

The file is watched: saving it updates the launcher immediately, even while it is
open. Invalid JSON is ignored rather than clearing your agents.

---

## How agents are launched

Omarchy models agents as *one default, launched by `omarchy-agent`* — there is no
command for "launch agent X without changing the default". So an agent tile runs
the agent's own argv through Omarchy's terminal launcher:

```
[[ -d "$HOME/Work" ]] && cd "$HOME/Work"
exec omarchy-launch-tui --app-id=org.omarchy.agent <agent> <flags…>
```

That matches what Omarchy's own agent keybinding produces: the shared
`org.omarchy.agent` app-id (so existing window rules and themes still apply),
each agent's own spelling of "don't stop to ask", and `~/Work` as the working
directory because agents refuse to remember trust for `$HOME`.

Clicking a tile **does not change your default agent**. To change it, right-click
and pick *Set as default agent*, which runs `omarchy default agent <name>` — that
sets it and opens it, which is what the omarchy command does.

The built-in flag table lives in `Agents.js` and mirrors
`/usr/share/omarchy/bin/omarchy-agent`, which is the source of truth: if that
script gains an agent or changes a flag, update the roster to match. The roster
is re-probed on every summon (`command -v` in a non-login shell), so an agent
installed since the last open just shows up.

---

## State

Two files, both safe to delete — deleting `seen.json` re-baselines the badges,
deleting `usage.json` empties *Frequently used*:

```
~/.local/state/omarchy/app-launcher/usage.json   # frecency scores (agents keyed "agent:<id>")
~/.local/state/omarchy/app-launcher/seen.json    # desktop ids seen at last close
```

Both survive reboots and logout/login: scores are written on every launch, not on
exit, and atomically (temp file + rename), so an interrupted write cannot corrupt
them. Scores for apps that no longer exist are pruned when the launcher closes.

To reset by hand, **close the launcher first** — a live instance rewrites
`usage.json` from memory when it closes.

---

## Troubleshooting

**Nothing opens.** `omarchy plugin list | grep app-launcher` should show `enabled`.
If not: `omarchy-shell shell rescanPlugins && omarchy plugin enable tyrsolution.app-launcher left`.

**`SUPER+A` does nothing.** `hyprctl binds -j | grep -i "App Launcher"` should
find it, and `hyprctl configerrors` should be empty.

**An agent tile is missing.** Its binary must resolve in a non-login shell:
`bash -c 'command -v <binary>'`. Agents installed through mise are on the shell's
PATH already; something installed only by a shell profile will not be found.

**A newly installed app has a generic icon.** The launcher re-indexes icons each
time it opens, so reopen it. If it persists, the package shipped no themed icon.

**Edits to the QML do nothing.** See below — plugin code needs a shell restart.

---

## Hacking on it

```
manifest.json   plugin id, kinds (overlay + bar-widget), entry points
AppGrid.qml     the overlay: state, IO, layout, keyboard, context menu
Usage.js        frecency arithmetic and state (de)serialization
Agents.js       the coding-agent roster, launch argv, custom roster parsing
BarWidget.qml   the bar button
bin/            the gum wizards the Setup menu rows call
```

**After editing the QML, run `omarchy restart shell`.** Omarchy watches
`~/.config/omarchy/plugins/` and logs `Local plugin changed, reloading`, but in
practice the engine keeps serving the already-compiled component, so edits do not
take effect until the shell restarts. `manifest.json` changes are picked up by
`omarchy-shell shell rescanPlugins`.

```bash
journalctl --user -f | grep 'qml:'      # console.log/warn from the plugin
omarchy plugin validate ~/.config/omarchy/plugins/tyrsolution.app-launcher
omarchy plugin list | grep app-launcher
```

The overlay deliberately does **not** set `keepLoaded`, so it is built fresh on
each summon and reads its state files each time.

---

## Forking it

Fork freely — but if you publish a fork, rename the plugin id so the two cannot
collide in someone's `~/.config/omarchy/plugins/`. Every reference:

| File | Reference |
|---|---|
| `manifest.json` | `"id"` |
| `BarWidget.qml` | `moduleName`, and the id inside the IPC string |
| `AppGrid.qml` | the `pluginId` fallback; optionally `stateDir` and `agentConfigPath` |
| `~/.config/hypr/bindings.lua` | the `SUPER+A` action |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | the toggle action and the three `bin/` paths |
| `~/.config/omarchy/shell.json` | the bar layout entry (or re-enable the plugin) |
| `AppGrid.qml` | `WlrLayershell.namespace`, if you write layer rules against it |

Changing `stateDir` or `agentConfigPath` moves your frecency data and custom
agents; leaving them alone keeps both across a rename.

## License

MIT — see [LICENSE](LICENSE).
