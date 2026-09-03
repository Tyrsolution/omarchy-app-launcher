// Toggles: the two rows above the search field.
//
// Session toggles act on the machine, window toggles on whatever was focused
// before the launcher opened. They are kept apart on purpose — "Do Not Disturb"
// and "Float" are not the same kind of switch, and the window row names its
// target so it is never a mystery which window is about to change.
//
// Omarchy's own menu carries these as plain rows with no `checked:`, so none of
// them declare their state. Every value below is therefore read by us, and the
// four mechanisms it takes are the reason this is a table rather than a loop:
// a flag file, a hypr flag file, a status script, and a shell IPC call.
//
// Two of the flags are NEGATIVE — `screensaver-off`, `window-no-gaps` — so the
// file existing means the feature is off. Reading those the obvious way renders
// every one of them backwards.

var TOGGLES_DIR = "/.local/state/omarchy/toggles/"

// `read` is bash evaluated inside the batch below; it must print 1 for on and 0
// for off, and must never change the state it is reporting.
var SESSION = [
  { id: "dnd", label: "Do Not Disturb", icon: "󰂛",
    action: "omarchy-toggle-notification-silencing",
    read: '[[ $(omarchy-shell notifications dndState 2>/dev/null) == on ]] && echo 1 || echo 0' },

  { id: "awake", label: "Stay Awake", icon: "󰅶",
    action: "omarchy-toggle-idle",
    read: 'omarchy-toggle-idle status 2>/dev/null | grep -q \'"enabled":true\' && echo 1 || echo 0' },

  { id: "nightlight", label: "Nightlight", icon: "󰔎",
    action: "omarchy-toggle-nightlight",
    // Reports off when hyprsunset is not running, which is the truth: the
    // filter is not applied. It cannot tell that apart from "switched off".
    read: 'omarchy-toggle-nightlight --status 2>/dev/null | grep -q \'"enabled":true\' && echo 1 || echo 0' },

  { id: "screensaver", label: "Screensaver", icon: "󱄄",
    action: "omarchy-toggle-screensaver",
    read: '[[ -f "$HOME' + TOGGLES_DIR + 'screensaver-off" ]] && echo 0 || echo 1' },

  { id: "gaps", label: "Window Gaps", icon: "",
    action: "omarchy-hyprland-window-gaps-toggle",
    read: '[[ -f "$HOME' + TOGGLES_DIR + 'hypr/window-no-gaps.lua" ]] && echo 0 || echo 1' }
]

// `needsFloating` marks a toggle Hyprland refuses on a tiled window — it warns
// "Window does not qualify to be pinned" rather than doing anything, so the tile
// is shown disabled instead of lying about what a click will do.
var WINDOW = [
  { id: "float", label: "Float", icon: "",
    action: "hyprctl dispatch \'hl.dsp.window.float({ action = \"toggle\" })\'", field: "float" },

  { id: "fullscreen", label: "Fullscreen", icon: "",
    action: "hyprctl dispatch \'hl.dsp.window.fullscreen({ mode = \"fullscreen\" })\'", field: "fullscreen" },

  { id: "pin", label: "Pin", icon: "",
    action: "hyprctl dispatch \'hl.dsp.window.pin()\'", field: "pinned", needsFloating: true },

  { id: "group", label: "Group", icon: "",
    action: "hyprctl dispatch \'hl.dsp.group.toggle()\'", field: "grouped" }
]

// --------------------------------------------------------------- state

// One bash pass for every toggle plus the focused window, the same shape as the
// menu's guard batch: asking nine questions one at a time would be nine forks
// on every summon. Prints `key=value` lines.
//
// The window block is what makes the second row possible at all: a layer shell
// takes keyboard focus without becoming the active window, so `hyprctl
// activewindow` still resolves to whatever sits behind the launcher — the same
// window SUPER+T would act on.
function stateScript() {
  var lines = []
  for (var i = 0; i < SESSION.length; i++)
    lines.push("printf '" + SESSION[i].id + "=%s\\n' \"$(" + SESSION[i].read + ")\"")

  lines.push('W=$(hyprctl activewindow -j 2>/dev/null)')
  lines.push('if [[ -n $W && $W != "{}" ]]; then')
  // The class names the row; the title changes constantly and would only make
  // the label jitter.
  lines.push('  printf "win.class=%s\\n" "$(jq -r \'.class // ""\' <<<"$W")"')
  lines.push('  printf "win.float=%s\\n" "$(jq -r \'if .floating then 1 else 0 end\' <<<"$W")"')
  lines.push('  printf "win.fullscreen=%s\\n" "$(jq -r \'if (.fullscreen // 0) > 0 then 1 else 0 end\' <<<"$W")"')
  lines.push('  printf "win.pinned=%s\\n" "$(jq -r \'if .pinned then 1 else 0 end\' <<<"$W")"')
  lines.push('  printf "win.grouped=%s\\n" "$(jq -r \'if ((.grouped // []) | length) > 0 then 1 else 0 end\' <<<"$W")"')
  lines.push('fi')
  return lines.join("\n") + "\n"
}

function parseState(text) {
  var out = ({})
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var eq = line.indexOf("=")
    if (eq < 0) continue
    out[line.substring(0, eq)] = line.substring(eq + 1)
  }
  return out
}

// ---------------------------------------------------------------- rows

function rowId(id) {
  return "toggle:" + String(id || "")
}

function makeRow(def, on, available, subtext) {
  return {
    id: rowId(def.id),
    kind: "toggle",
    name: def.label,
    subtext: subtext || "",
    icon: "",
    iconUrl: "",
    monogram: def.icon,
    iconFont: "",
    glyphScale: 0.52,
    action: def.action,
    on: on,
    available: available,
    score: 0,
    isNew: false
  }
}

function sessionRows(state) {
  var out = []
  for (var i = 0; i < SESSION.length; i++)
    out.push(makeRow(SESSION[i], state[SESSION[i].id] === "1", true))
  return out
}

// A capitalised window class is a better label than a title that changes with
// every tab. Empty when nothing is focused, which hides the row entirely.
function windowTitle(state) {
  var cls = String(state["win.class"] || "")
  if (!cls) return ""
  return cls.charAt(0).toUpperCase() + cls.slice(1)
}

function windowRows(state) {
  if (!windowTitle(state)) return []

  var floating = state["win.float"] === "1"
  var out = []
  for (var i = 0; i < WINDOW.length; i++) {
    var def = WINDOW[i]
    var on = state["win." + def.field] === "1"
    var available = !def.needsFloating || floating
    out.push(makeRow(def, on, available, available ? "" : "needs floating"))
  }
  return out
}
