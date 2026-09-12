// The pinned rows: which ids are favorited, and in what order. Pure functions
// over a plain array, the same division of labour Usage.js keeps — the QML side
// owns file IO and layout, this file owns the list.
//
// An array rather than a map because the order *is* the state. A pin sits where
// you put it for as long as it is pinned, and a JSON object promises nothing
// about the order its keys come back in.

// Only the kinds that could reach the old frecency row can be pinned. A folder
// is navigation and a toggle is a switch; neither is a thing you launch, and
// neither has ever appeared in this section.
function pinnable(kind) {
  var k = String(kind || "")
  return k === "app" || k === "agent" || k === "command"
}

function contains(ids, id) {
  return indexOf(ids, id) >= 0
}

function indexOf(ids, id) {
  var wanted = String(id || "")
  if (!wanted) return -1
  for (var i = 0; i < ids.length; i++)
    if (String(ids[i]) === wanted) return i
  return -1
}

// New pins go on the end, so nothing already placed moves. Returns a new array
// so QML property assignment sees a change.
function add(ids, id) {
  if (contains(ids, id)) return ids.slice()
  var next = ids.slice()
  next.push(String(id))
  return next
}

function remove(ids, id) {
  var at = indexOf(ids, id)
  if (at < 0) return ids.slice()
  var next = ids.slice()
  next.splice(at, 1)
  return next
}

function toggle(ids, id) {
  return contains(ids, id) ? remove(ids, id) : add(ids, id)
}

// Resolve pinned ids into rows, in pin order, against whichever pools are live
// right now. An id nothing matches is skipped rather than drawn as a dead tile:
// the app was uninstalled, or the menu entry is hidden behind a `when:`. It is
// only dropped from the file by prune(), so a `when:` that goes false and true
// again does not cost you the pin.
function resolve(ids, pools) {
  var index = Object.create(null)
  for (var p = 0; p < pools.length; p++) {
    var pool = pools[p] || []
    for (var i = 0; i < pool.length; i++) {
      var rowId = String((pool[i] && pool[i].id) || "")
      if (rowId && index[rowId] === undefined) index[rowId] = pool[i]
    }
  }
  var out = []
  for (var k = 0; k < ids.length; k++) {
    var row = index[String(ids[k])]
    if (row) out.push(row)
  }
  return out
}

// Drop pins for things that no longer exist, so an uninstall does not leave an
// id in the file forever. Same domain as the usage prune: apps, agents, and
// menu commands.
function prune(ids, liveIds) {
  var out = []
  for (var i = 0; i < ids.length; i++)
    if (liveIds[String(ids[i])] === true) out.push(String(ids[i]))
  return out
}

// null, not [], when there is nothing usable to read — an unreadable file and
// an empty one are different answers, and only the second one is the user
// saying they unpinned everything.
function parse(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null
  if (!Array.isArray(parsed.ids)) return null
  var out = []
  var seen = Object.create(null)
  for (var i = 0; i < parsed.ids.length; i++) {
    var id = String(parsed.ids[i] || "")
    if (!id || seen[id] === true) continue
    seen[id] = true
    out.push(id)
  }
  return out
}

// Unsorted on purpose, unlike seen.json: this order is the feature.
function serialize(ids) {
  return JSON.stringify({ version: 1, ids: ids }, null, 2) + "\n"
}

// ----------------------------------------------------------------- view

// Which tab the section is showing. Persisted separately from the pins: this
// is a preference about the launcher, not part of the list, and keeping it out
// of favorites.json means that file stays hand-editable as what it looks like.
//
// The collapsed state is deliberately NOT here. Collapsing is a momentary
// "give me more applications right now" gesture, not something to carry across
// a reboot.
var TABS = ["favorites", "frequent"]

function validTab(tab) {
  var wanted = String(tab || "")
  for (var i = 0; i < TABS.length; i++)
    if (TABS[i] === wanted) return wanted
  return ""
}

function otherTab(tab) {
  return validTab(tab) === "frequent" ? "favorites" : "frequent"
}

// "" when there is nothing usable, so the caller keeps its own default rather
// than being handed one twice.
function parseView(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return "" }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return ""
  return validTab(parsed.tab)
}

function serializeView(tab) {
  return JSON.stringify({ version: 1, tab: validTab(tab) || "favorites" }, null, 2) + "\n"
}
