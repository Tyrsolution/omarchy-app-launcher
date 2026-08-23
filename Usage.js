// Frecency scoring and "recently added" bookkeeping for the app launcher.
// Pure functions over plain objects: the QML side owns file IO and layout,
// this file owns the arithmetic so it stays readable and testable.

// A launch's weight halves every two weeks. Long enough that a daily driver
// stays on top through a quiet weekend, short enough that last month's
// one-off install drifts back down into the alphabetical tail.
var HALF_LIFE_MS = 14 * 24 * 60 * 60 * 1000

function decay(ageMs) {
  if (!isFinite(ageMs) || ageMs <= 0) return 1
  return Math.pow(0.5, ageMs / HALF_LIFE_MS)
}

// The stored score is always "score as of `last`", so reading it back means
// decaying it forward to now. Never mutates the stored value.
function effectiveScore(stat, now) {
  if (!stat) return 0
  var score = Number(stat.score)
  if (!isFinite(score) || score <= 0) return 0
  var last = Number(stat.last)
  if (!isFinite(last) || last <= 0) return score
  return score * decay(now - last)
}

// One launch adds 1 to a score that has already decayed to `now`. A burst of
// launches today outranks a long-idle favorite without ever zeroing it out.
// Returns a new map so QML property assignment sees a change.
function record(usage, id, now) {
  var next = clone(usage)
  var prev = next[id]
  next[id] = {
    score: effectiveScore(prev, now) + 1,
    last: now,
    launches: ((prev && Number(prev.launches)) || 0) + 1
  }
  return next
}

function forget(usage, id) {
  var next = clone(usage)
  delete next[id]
  return next
}

// Drop entries for apps that no longer exist, so an uninstall/reinstall cycle
// doesn't resurrect a stale score and the file doesn't grow forever.
function prune(usage, liveIds) {
  var next = ({})
  for (var id in usage)
    if (liveIds[id] === true) next[id] = usage[id]
  return next
}

function clone(usage) {
  var next = ({})
  for (var k in usage) next[k] = usage[k]
  return next
}

// Highest frecency first, then alphabetical. The name tiebreak is explicit
// because QML's JS engine does not guarantee a stable sort, so relying on the
// alphabetical order the shell handed us would scramble the unlaunched tail.
function sortByScore(rows) {
  rows.sort(function(a, b) {
    if (a.score !== b.score) return b.score - a.score
    var an = String(a.name || "").toLowerCase()
    var bn = String(b.name || "").toLowerCase()
    if (an < bn) return -1
    if (an > bn) return 1
    return 0
  })
  return rows
}

function parseUsage(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return ({}) }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return ({})
  var entries = parsed.entries
  if (!entries || typeof entries !== "object" || Array.isArray(entries)) return ({})
  var out = ({})
  for (var id in entries) {
    var stat = entries[id]
    if (!stat || typeof stat !== "object") continue
    out[String(id)] = {
      score: Number(stat.score) || 0,
      last: Number(stat.last) || 0,
      launches: Number(stat.launches) || 0
    }
  }
  return out
}

function serializeUsage(usage) {
  return JSON.stringify({ version: 1, entries: usage }, null, 2) + "\n"
}

function parseSeen(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null
  if (!Array.isArray(parsed.ids)) return null
  var out = ({})
  for (var i = 0; i < parsed.ids.length; i++) out[String(parsed.ids[i])] = true
  return out
}

function serializeSeen(idMap) {
  var ids = []
  for (var id in idMap) ids.push(id)
  ids.sort()
  return JSON.stringify({ version: 1, ids: ids }, null, 2) + "\n"
}
