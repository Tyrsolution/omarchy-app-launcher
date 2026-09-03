// The Omarchy menu, surfaced in the launcher as a browsable "System" section.
//
// Omarchy's menu is a flat map of dotted ids in JSONC — "style.theme.set" sits
// under "style.theme", which sits under "style". The shell's own MenuModel.js
// parses this, but QML's JS imports take static paths only, so a plugin cannot
// import it out of $OMARCHY_PATH. The parsing below is therefore a deliberate
// copy of that format's rules, and has to track them: id-implied parents, an
// explicit `parent` override, and "an item with an `action` is a leaf".
//
// What this module does NOT do is evaluate `when:`/`checked:`. Those are bash
// expressions, and answering them well means batching every one into a single
// subprocess with pacman/command lookups shadowed — see MenuModel.guardScript.
// Until that lands, `visibleIds` accepts a guard map and simply allows every
// row when it has none, so the seam is here and the callers already pass it.

// The apps node is provider-driven: it is a live mirror of the same AppLibrary
// the grid already renders, so showing it would list every application twice.
var SKIP_ROOTS = { apps: true }

// "System" is our section name, and upstream also has a top-level group called
// "system" — nesting one inside the other reads as a bug. Its seven rows are
// Screensaver/Lock/Suspend/Hibernate/Logout/Reboot/Shutdown, so Power is both
// unambiguous and a better description than the name it replaces.
var RELABEL = { system: "Power" }

var SEPARATOR = " › "

// ------------------------------------------------------------------ parsing

// The menu files are JSONC: line comments and trailing commas. Mirrors the
// shell's own stripper rather than pulling in a real parser.
function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function normalizeAliases(value) {
  if (Array.isArray(value)) {
    var out = []
    for (var i = 0; i < value.length; i++) if (value[i]) out.push(String(value[i]))
    return out
  }
  if (typeof value === "string" && value) return [value]
  return []
}

// A row is an action if it carries a command, a link if it points at another
// submenu, and a container otherwise. Same three-way split the shell makes.
function normalizeItem(id, raw) {
  var value = raw || {}
  var parent = value.parent
  if (parent === undefined)
    parent = id.indexOf(".") >= 0 ? id.split(".").slice(0, -1).join(".") : "root"
  if (id === "root") parent = ""

  return {
    id: id,
    parent: parent,
    kind: value.action ? "action" : (value.target ? "link" : "menu"),
    icon: String(value.icon || ""),
    iconFont: String(value.iconFont || ""),
    label: String(value.label || id),
    description: String(value.description || ""),
    action: String(value.action || ""),
    target: String(value.target || ""),
    provider: String(value.provider || ""),
    aliases: normalizeAliases(value.aliases),
    when: String(value.when || ""),
    checked: String(value.checked || "")
  }
}

function parse(rawText) {
  var stripped = stripJsonc(rawText)
  if (!stripped.trim()) return []

  var parsed
  try {
    parsed = JSON.parse(stripped)
  } catch (e) {
    console.warn("app-grid: menu parse failed:", e)
    return []
  }
  if (typeof parsed !== "object" || parsed === null) return []

  var source = (parsed.items && typeof parsed.items === "object" && !Array.isArray(parsed.items))
    ? parsed.items
    : parsed

  var out = []
  for (var id in source) {
    var entry = source[id]
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
    out.push(normalizeItem(id, entry))
  }
  return out
}

// User entries override the shipped ones field by field, keyed on id — that is
// how ~/.config/omarchy/extensions/omarchy-menu.jsonc extends the menu rather
// than replacing it. First appearance fixes the order, so an override does not
// move a row.
function merge(defaultItems, userItems) {
  var items = ({})
  var order = []
  var sources = [defaultItems || [], userItems || []]

  for (var s = 0; s < sources.length; s++) {
    var src = sources[s]
    for (var i = 0; i < src.length; i++) {
      var entry = src[i]
      if (!entry || !entry.id) continue
      if (!items[entry.id]) order.push(entry.id)

      var prior = items[entry.id] || {}
      var merged = ({})
      for (var k in prior) merged[k] = prior[k]
      for (var k2 in entry) merged[k2] = entry[k2]
      merged.id = entry.id
      items[entry.id] = merged
    }
  }

  return { items: items, order: order }
}

// ------------------------------------------------------------------- shape

function isLeaf(item) {
  return !!item && item.kind === "action"
}

function childIds(items, order, parentId) {
  var out = []
  for (var i = 0; i < order.length; i++) {
    var entry = items[order[i]]
    if (entry && entry.parent === parentId) out.push(entry.id)
  }
  return out
}

// The tiles the System strip shows: every top-level group except the ones we
// deliberately drop. Provider-driven roots are dynamic and have no static
// children to browse, so they are skipped too.
function rootIds(items, order) {
  var out = []
  for (var i = 0; i < order.length; i++) {
    var entry = items[order[i]]
    if (!entry || entry.id === "root") continue
    if (entry.parent !== "root") continue
    if (SKIP_ROOTS[entry.id]) continue
    if (entry.provider) continue
    out.push(entry.id)
  }
  return out
}

function labelFor(item) {
  if (!item) return ""
  return RELABEL[item.id] || item.label
}

// "Setup › Default › Agent" for the row's parent chain, so a flattened search
// result still says where it came from. Guarded against a cycle in `parent`.
function breadcrumb(items, id) {
  var parts = []
  var cursor = items[id] ? items[id].parent : ""
  var guard = 0

  while (cursor && cursor !== "root" && guard < 32) {
    var entry = items[cursor]
    if (!entry) break
    parts.unshift(labelFor(entry))
    cursor = entry.parent
    guard++
  }
  return parts.join(SEPARATOR)
}

// Leaves anywhere beneath `id`, used both for a folder's "12 items" subtext and
// to decide whether a folder is worth showing at all.
function leafCountUnder(items, order, id, whenResults, depth) {
  var guard = depth || 0
  if (guard >= 32) return 0

  var total = 0
  var kids = childIds(items, order, id)
  for (var i = 0; i < kids.length; i++) {
    var entry = items[kids[i]]
    if (!entry || !allowed(entry, whenResults)) continue
    if (isLeaf(entry)) total++
    else total += leafCountUnder(items, order, entry.id, whenResults, guard + 1)
  }
  return total
}

// A `when:` only hides on an explicit false, so an unevaluated guard shows the
// row. That is the shell's rule and the safe direction: a row that should have
// been hidden is a papercut, one wrongly hidden is a missing feature.
function allowed(item, whenResults) {
  if (!item) return false
  if (!item.when) return true
  if (!whenResults) return true
  return whenResults[item.id] !== false
}

// ------------------------------------------------------------------- rows

// Namespaced so a menu row's frecency and "seen" state can never collide with
// a desktop id or an agent row.
function rowId(menuId) {
  return "cmd:" + String(menuId || "")
}

function menuIdOf(value) {
  var text = String(value || "")
  return text.indexOf("cmd:") === 0 ? text.slice(4) : ""
}

// Menu rows carry a Nerd Font glyph rather than an icon file, and the launcher
// already has a tile that draws text in a rounded square for agent monograms.
// Reusing it costs one font override and a size bump: glyphs are drawn to fill
// their em box, so they need less headroom than two capital letters.
function rowFor(items, order, item, whenResults, checkedResults, subtextOverride) {
  var leaf = isLeaf(item)
  var count = leaf ? 0 : leafCountUnder(items, order, item.id, whenResults)
  var subtext = subtextOverride !== undefined && subtextOverride !== null
    ? subtextOverride
    : (leaf ? (item.description || breadcrumb(items, item.id))
            : (count === 1 ? "1 item" : count + " items"))

  var parent = item.parent && item.parent !== "root" ? items[item.parent] : null

  return {
    id: rowId(item.id),
    menuId: item.id,
    // The immediate parent's label, for surfaces too narrow for the full
    // breadcrumb. `subtext` keeps the whole trail for those that fit.
    parentLabel: parent ? labelFor(parent) : "",
    kind: leaf ? "command" : "folder",
    name: labelWithCheck(item, checkedResults),
    subtext: subtext,
    icon: "",
    iconUrl: "",
    monogram: item.icon,
    iconFont: item.iconFont,
    glyphScale: 0.52,
    action: item.action,
    childCount: count,
    score: 0,
    isNew: false
  }
}

// The tiles for one folder, in menu order: what a click drills into. Folders
// with nothing visible under them are dropped rather than opening onto an
// empty grid.
function browseRows(items, order, parentId, whenResults, checkedResults) {
  var out = []
  var kids = childIds(items, order, parentId)

  for (var i = 0; i < kids.length; i++) {
    var entry = items[kids[i]]
    if (!entry || !allowed(entry, whenResults)) continue
    if (entry.kind === "link") continue
    if (entry.provider) continue
    if (!isLeaf(entry) && leafCountUnder(items, order, entry.id, whenResults) === 0) continue
    // The breadcrumb is already in the header while browsing, so a leaf shows
    // its description or nothing rather than repeating where it lives.
    out.push(rowFor(items, order, entry, whenResults, checkedResults,
                    isLeaf(entry) ? entry.description : undefined))
  }
  return out
}

// The System strip itself. A root that is its own action (upstream's "about")
// has no children and becomes an ordinary command tile, which is why this goes
// through the same rowFor as everything else.
function sectionRows(items, order, whenResults, checkedResults) {
  var out = []
  var roots = rootIds(items, order)

  for (var i = 0; i < roots.length; i++) {
    var entry = items[roots[i]]
    if (!entry || !allowed(entry, whenResults)) continue
    if (!isLeaf(entry) && leafCountUnder(items, order, entry.id, whenResults) === 0) continue
    out.push(rowFor(items, order, entry, whenResults, checkedResults))
  }
  return out
}

// Every action leaf, flattened with its breadcrumb — folders are for browsing,
// search is for finding, so a query collapses the tree instead of walking it.
function leafRows(items, order, whenResults, checkedResults) {
  var out = []

  for (var i = 0; i < order.length; i++) {
    var entry = items[order[i]]
    if (!entry || !isLeaf(entry)) continue
    if (entry.provider) continue
    if (!allowed(entry, whenResults)) continue

    var root = rootOf(items, entry.id)
    if (SKIP_ROOTS[root]) continue

    out.push(rowFor(items, order, entry, whenResults, checkedResults, breadcrumb(items, entry.id)))
  }
  return out
}

function rootOf(items, id) {
  var cursor = items[id]
  var guard = 0
  while (cursor && cursor.parent && cursor.parent !== "root" && guard < 32) {
    cursor = items[cursor.parent]
    guard++
  }
  return cursor ? cursor.id : ""
}

// ---------------------------------------------------------------- matching

// Menu rows are verbs the user half-remembers ("night light", "screen record"),
// so the breadcrumb and description are searched alongside the label, and every
// query word has to land somewhere. Ranking puts a label prefix first: typing
// "the" should reach Theme before "Set as default *the*me" fallbacks.
function matches(row, query) {
  var text = String(query || "").trim().toLowerCase()
  if (!text) return true

  var haystack = (String(row.name || "") + " " + String(row.subtext || "")).toLowerCase()
  var words = text.split(/\s+/)

  for (var i = 0; i < words.length; i++)
    if (haystack.indexOf(words[i]) < 0) return false

  return true
}

function matchScore(row, query) {
  var text = String(query || "").trim().toLowerCase()
  var name = String(row.name || "").toLowerCase()
  if (!text) return 0
  if (name === text) return 3
  if (name.indexOf(text) === 0) return 2
  if (name.indexOf(text) >= 0) return 1
  return 0
}

function sortMatches(rows, query) {
  var out = []
  for (var i = 0; i < rows.length; i++)
    if (matches(rows[i], query)) out.push(rows[i])

  out.sort(function(a, b) {
    var d = matchScore(b, query) - matchScore(a, query)
    if (d !== 0) return d
    return String(a.name || "").toLowerCase() < String(b.name || "").toLowerCase() ? -1 : 1
  })
  return out
}

// --------------------------------------------------------------- guards

// `when:` decides whether a row shows, `checked:` whether it gets a ✓. Both
// are bash, and 144 of the menu's leaves carry one here, so asking them one at
// a time would fork 144 processes every time the menu is read. Everything from
// here to parseGuards is vendored VERBATIM from the shell's MenuModel.js —
// extracted rather than retyped, because the prelude's quoting is unforgiving
// and a transcription slip would answer guards wrong rather than fail loudly.
//
// It must track upstream. If a guard starts coming back wrong, diff these
// against $OMARCHY_PATH/shell/plugins/menu/MenuModel.js before looking here.

var GUARD_READERS = [
  "omarchy-channel-current",
  "omarchy-default-agent",
  "omarchy-default-browser",
  "omarchy-default-editor",
  "omarchy-default-terminal",
  "omarchy-dns"
]

function guardHelpers() {
  return 'declare -A __omarchy_pkgs=()\n'
    + 'mapfile -t __omarchy_pkg_names < <({ pacman -Qq; LC_ALL=C pacman -Qi'
    + " | awk '/^[A-Za-z]/ { provides = ($0 ~ /^Provides/); sub(/^[^:]*: /, \"\") }"
    + ' provides && $0 != "None" { n = split($0, p, " ");'
    + ' for (i = 1; i <= n; i++) { sub(/[<>=].*/, "", p[i]); print p[i] } }\'; } 2>/dev/null)\n'
    + 'for __omarchy_pkg in "${__omarchy_pkg_names[@]}"; do __omarchy_pkgs[$__omarchy_pkg]=1; done\n'
    + '__omarchy_pkg_has() { [[ -n ${__omarchy_pkgs[$1]-} ]] && return 0; '
    + '[[ $1 == *[\\<\\>=]* ]] && { pacman -Q "$1" &>/dev/null; return; }; return 1; }\n'
    + 'omarchy-pkg-present() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 1; done; return 0; }\n'
    + 'omarchy-pkg-missing() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 0; done; return 1; }\n'
    + 'omarchy-cmd-present() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 1; done; return 0; }\n'
    + 'omarchy-cmd-missing() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 0; done; return 1; }\n'
}

function guardPrelude(guards) {
  var prelude = guardHelpers()

  for (var i = 0; i < GUARD_READERS.length; i++) {
    // The guards arrive already substituted, so what marks a reader as wanted
    // is the slot standing in for it, not the call it replaced.
    if (guards.indexOf(guardReaderSlot(i)) < 0) continue
    // `|| :` so a reader that exits nonzero cannot take the batch down with
    // it under a login shell that turned on errexit.
    prelude += "__omarchy_read_" + i + "=$(" + GUARD_READERS[i] + " 2>/dev/null) || :\n"
  }

  return prelude
}

function guardReaderSlot(index) {
  return "${__omarchy_read_" + index + "}"
}

function substituteGuardReaders(expression) {
  for (var i = 0; i < GUARD_READERS.length; i++)
    expression = expression.split("$(" + GUARD_READERS[i] + ")").join(guardReaderSlot(i))

  return expression
}

function guardLine(id, tag, expression) {
  return "if { " + substituteGuardReaders(expression) + "; } >/dev/null 2>&1; then echo "
    + id + ":" + tag + ":1; else echo " + id + ":" + tag + ":0; fi\n"
}

function guardScript(items) {
  var guards = ""
  var ids = Object.keys(items || {})

  for (var i = 0; i < ids.length; i++) {
    var entry = items[ids[i]]
    if (!entry) continue
    if (entry.when) guards += guardLine(ids[i], "w", entry.when)
    if (entry.checked) guards += guardLine(ids[i], "c", entry.checked)
  }

  return guards ? guardPrelude(guards) + guards : ""
}

// `<id>:<w|c>:<0|1>` per line, split from the right: an id may contain a colon
// in principle, the tag and value never do.
function parseGuards(text) {
  var when = ({})
  var checked = ({})
  var lines = String(text || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue

    var colon = line.lastIndexOf(":")
    if (colon < 0) continue
    var value = line.substring(colon + 1) === "1"

    var rest = line.substring(0, colon)
    var tagAt = rest.lastIndexOf(":")
    if (tagAt < 0) continue

    var id = rest.substring(0, tagAt)
    var tag = rest.substring(tagAt + 1)
    if (tag === "w") when[id] = value
    else if (tag === "c") checked[id] = value
  }
  return { when: when, checked: checked }
}

// A ✓ on a row whose `checked:` came back true — the menu's own convention for
// "this is the setting you are already on".
function labelWithCheck(item, checkedResults) {
  var label = labelFor(item)
  if (!item || !item.checked) return label
  return (checkedResults && checkedResults[item.id]) ? label + " ✓" : label
}
