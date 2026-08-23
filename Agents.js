// The coding agents Omarchy knows how to launch, surfaced in the launcher as
// tiles alongside applications.
//
// Omarchy models agents as "one default, launched by omarchy-agent", so there
// is no command for "launch agent X without changing the default". The argv
// below therefore mirrors the per-agent flags in `omarchy-agent` (each agent's
// own spelling of "don't stop to ask"), which is the source of truth: if that
// script gains an agent or changes a flag, update this table to match.
var ROSTER = [
  { id: "claude",   name: "Claude Code",    asset: "claude", monogram: "",   argv: ["claude", "--permission-mode", "bypassPermissions"] },
  { id: "codex",    name: "Codex",          asset: "codex",  monogram: "",   argv: ["codex", "--dangerously-bypass-approvals-and-sandbox"] },
  { id: "copilot",  name: "GitHub Copilot", asset: "",       monogram: "Co", argv: ["copilot", "--allow-all"] },
  { id: "crush",    name: "Crush",          asset: "",       monogram: "Cr", argv: ["crush", "--yolo"] },
  { id: "gemini",   name: "Gemini",         asset: "",       monogram: "Ge", argv: ["gemini", "--yolo"] },
  { id: "grok",     name: "Grok",           asset: "",       monogram: "Gr", argv: ["grok", "--permission-mode", "bypassPermissions"] },
  { id: "omp",      name: "Oh My Pi",       asset: "",       monogram: "Om", argv: ["omp", "--auto-approve"] },
  { id: "opencode", name: "OpenCode",       asset: "",       monogram: "Op", argv: ["opencode", "--auto"] },
  { id: "pi",       name: "Pi",             asset: "",       monogram: "Pi", argv: ["pi"] }
]

// Namespaced so an agent's frecency and "seen" state can never collide with a
// desktop id.
function rowId(agentId) {
  return "agent:" + String(agentId || "")
}

function agentIdOf(rowIdValue) {
  var value = String(rowIdValue || "")
  return value.indexOf("agent:") === 0 ? value.slice(6) : ""
}

// Which agents are actually on this machine: one `command -v` per definition,
// echoing the id when its binary resolves. A non-login shell is deliberate —
// the shell's PATH already carries the mise shims, and sourcing the profile
// would touch ~/.local/share, which the desktop-entry watcher monitors.
function probeCommand(roster) {
  var lines = []
  for (var i = 0; i < roster.length; i++) {
    var definition = roster[i]
    var binary = definition.argv && definition.argv.length > 0 ? definition.argv[0] : definition.id
    lines.push('command -v ' + shellQuote(binary) + ' >/dev/null 2>&1 && echo ' + shellQuote(definition.id))
  }
  return lines.join('; ')
}

function definitionFor(roster, agentId) {
  for (var i = 0; i < roster.length; i++)
    if (roster[i].id === agentId) return roster[i]
  return null
}

function matches(row, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return true
  return String(row.name || "").toLowerCase().indexOf(q) !== -1
    || String(row.agentId || "").toLowerCase().indexOf(q) !== -1
}

// Ranked for a query: names that start with what was typed come first, then
// alphabetical. Agents are few, so this stays predictable without scoring.
function sortMatches(rows, query) {
  var q = String(query || "").trim().toLowerCase()
  rows.sort(function(a, b) {
    var an = String(a.name || "").toLowerCase()
    var bn = String(b.name || "").toLowerCase()
    if (q) {
      var ap = an.indexOf(q) === 0 ? 0 : 1
      var bp = bn.indexOf(q) === 0 ? 0 : 1
      if (ap !== bp) return ap - bp
    }
    if (an < bn) return -1
    if (an > bn) return 1
    return 0
  })
  return rows
}

// ---------------------------------------------------------------- custom

// Omarchy's roster is a fixed list, but any CLI agent can be added here:
//
//   ~/.config/omarchy/app-launcher/agents.json
//   { "version": 1, "agents": [
//       { "id": "antigravity", "name": "Antigravity",
//         "command": ["agy", "--dangerously-skip-permissions"] } ] }
//
// An entry whose id matches a built-in replaces it, so the shipped flags can be
// overridden without editing this file.

function shellQuote(value) {
  return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
}

// Ids name state keys and are interpolated into the probe, so keep them plain.
function isValidId(id) {
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(String(id || ""))
}

// "Antigravity" -> "An". Two letters, because five agents here start with C.
function defaultMonogram(text) {
  var value = String(text || "").replace(/[^A-Za-z0-9]/g, "")
  if (value.length === 0) return "?"
  return value.charAt(0).toUpperCase() + (value.length > 1 ? value.charAt(1).toLowerCase() : "")
}

function normalizeCustom(entry) {
  if (!entry || typeof entry !== "object") return null
  var id = String(entry.id || "").trim()
  if (!isValidId(id)) return null

  var argv = []
  if (Array.isArray(entry.command)) {
    for (var i = 0; i < entry.command.length; i++) {
      var part = entry.command[i]
      if (typeof part !== "string" || part.length === 0) continue
      argv.push(part)
    }
  }
  if (argv.length === 0) argv = [id]

  var name = String(entry.name || "").trim() || id
  return {
    id: id,
    name: name,
    asset: "",
    icon: String(entry.icon || "").trim(),
    monogram: String(entry.monogram || "").trim() || defaultMonogram(name),
    argv: argv,
    custom: true
  }
}

function parseCustom(rawText) {
  var parsed = null
  try { parsed = JSON.parse(String(rawText || "")) } catch (e) { return [] }
  if (!parsed || typeof parsed !== "object") return []
  var list = Array.isArray(parsed) ? parsed : parsed.agents
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var entry = normalizeCustom(list[i])
    if (entry) out.push(entry)
  }
  return out
}

// Built-ins first, then customs; a custom id wins over the built-in it shadows.
function mergeRoster(customs) {
  var byId = ({})
  var order = []
  function put(definition) {
    if (byId[definition.id] === undefined) order.push(definition.id)
    byId[definition.id] = definition
  }
  for (var i = 0; i < ROSTER.length; i++) put(ROSTER[i])
  for (var j = 0; j < (customs || []).length; j++) put(customs[j])

  var out = []
  for (var k = 0; k < order.length; k++) out.push(byId[order[k]])
  return out
}
