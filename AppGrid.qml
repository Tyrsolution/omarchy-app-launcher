import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Usage.js" as Usage
import "Favorites.js" as Favorites
import "SessionState.js" as SessionState
import "Agents.js" as Agents
import "Menu.js" as Menu
import "Toggles.js" as Toggles

// A centered launcher: a two-tab section on top — Favorites you pinned and
// Frequently used the launcher ranked — then every installed application and
// coding agent below, alphabetical and scrollable.
//
// The app list itself is not ours: the shell's AppLibrary already watches
// DesktopEntries, filters hidden/NoDisplay entries, resolves icon names to
// files (re-indexing after an install), and launches under app-graphical.slice.
// This plugin owns presentation, pinned favorites, frecency ordering, and the
// "just added" badge.
Item {
  id: root

  // Injected by the shell's panel loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  readonly property string pluginId: (root.manifest && root.manifest.id) || "tyrsolution.app-launcher"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/app-launcher"

  property bool opened: false
  property string filterText: ""
  property var allRows: []
  // Coding agents (claude, codex, gemini, …) launched into a terminal. Probed
  // on open so an agent installed since last time shows up.
  property var installedAgents: []
  property var pendingAgents: []
  property string defaultAgent: ""
  // User-defined agents from ~/.config/omarchy/app-launcher/agents.json, merged
  // over the built-in roster.
  property var customAgents: []
  property bool agentProbePending: false
  property bool agentsLoaded: false
  readonly property var agentRoster: Agents.mergeRoster(root.customAgents)
  readonly property string agentConfigPath: Quickshell.env("HOME") + "/.config/omarchy/app-launcher/agents.json"
  // The two pools the tabbed section draws from. Favorites is resolved from
  // `favorites` against whatever is installed right now; Frequent is every app
  // with a recorded launch, widest-first. A query collapses both the same way
  // the single section always did.
  //
  // Favorites is uncapped and Frequent is exactly one row — that asymmetry is
  // the point. One is a shelf you arranged, the other is a readout.
  property var favoritePool: []
  readonly property var favoriteRows: root.searching ? [] : root.favoritePool
  property var frequentPool: []
  readonly property var frequentRows: root.searching
    ? []
    : root.frequentPool.slice(0, Math.max(1, panel.columns))

  // --------------------------------------------------------- system menu

  // Omarchy's own menu, browsed as folders in a strip pinned under the apps.
  // It is read straight off disk rather than asked of the menu plugin: there is
  // no IPC for "give me your model", and both files are small and watched.
  property var menuItems: ({})
  property var menuOrder: []
  property var menuDefaults: []
  property var menuCustom: []
  property bool menuDefaultsLoaded: false
  property bool menuCustomLoaded: false

  // "" while the strip shows its top-level folders; a menu id once drilled in.
  property string browsePath: ""
  readonly property bool browsing: root.browsePath.length > 0

  // `when:` (does this row show) and `checked:` (does it get a ✓), answered by
  // one bash batch per menu load rather than a process per row. Empty until the
  // first batch lands, which permits every row — a `when:` only hides on an
  // explicit false, so the launcher opens on stale-but-complete answers instead
  // of waiting, exactly as the menu does.
  property var whenResults: ({})
  property var checkedResults: ({})
  property bool guardsPending: false

  // Flattened once per menu change, not per keystroke — 269 leaves is cheap to
  // filter but not to re-walk on every character.
  readonly property var menuLeaves: Menu.leafRows(root.menuItems, root.menuOrder, root.whenResults, root.checkedResults)

  // The strip is contextual: folders while browsing the launcher normally,
  // matching commands while a search is narrowing things down. Same pinned
  // place either way, so "system things live down there" stays true.
  readonly property var systemRestRows: Menu.sectionRows(root.menuItems, root.menuOrder, root.whenResults, root.checkedResults)
  readonly property var systemRows: root.searching
    ? Menu.sortMatches(root.menuLeaves, root.filterText)
    : root.systemRestRows

  // What the main grid shows: applications, or the folder being browsed.
  readonly property var displayRows: root.browsing
    ? Menu.browseRows(root.menuItems, root.menuOrder, root.browsePath, root.whenResults, root.checkedResults)
    : root.allRows

  // ------------------------------------------------------------- toggles

  // Read by one bash batch per summon, the same way the guards are. Empty until
  // it lands, which draws every toggle off rather than guessing.
  property var toggleState: ({})

  // How this summon was invoked: "bar" for the bar button, empty for the
  // keybinding or a script.
  property string launchSource: ""

  // Focus follows the mouse here (input:follow_mouse = 1, mouse_refocus on),
  // so reaching for the bar button drags focus across every window the cursor
  // crosses on the way. By the time the overlay opens, the "focused window" is
  // whatever the pointer last passed over — not the one being aimed at. The
  // window row would then describe, and act on, the wrong window.
  //
  // A hotkey has no such travel, so its window context is trustworthy. Hiding
  // the row on the pointer path is not tidying: it is declining to offer a
  // control whose target cannot be trusted.
  readonly property bool showWindowToggles: root.launchSource !== "bar"

  readonly property var sessionToggles: Toggles.sessionRows(root.toggleState)
  readonly property var windowToggles: root.showWindowToggles ? Toggles.windowRows(root.toggleState) : []
  // The window behind the launcher. A layer shell takes keyboard focus without
  // becoming the active window, so this is the same window SUPER+T would hit.
  readonly property string windowTarget: Toggles.windowTitle(root.toggleState)

  // Selection spans several grids, so it needs a section as well as an index.
  property string selectedSection: "all"
  property int selectedIndex: 0
  // Pins load from disk after the window is up, so the favorites row can appear
  // a moment after open(). Until the user touches anything, let it take the
  // caret; after that, leave the selection where they put it.
  property bool interacted: false

  // Persisted state. `favorites` drives the top row, `seenIds` drives badges.
  // `usage` still records every launch, but nothing reads it back now that the
  // row is pinned rather than ranked — kept because throwing away scores that
  // took months to earn is not something an update should do quietly.
  property var usage: ({})
  property var seenIds: ({})
  property bool seenLoaded: false
  property var newIds: ({})
  // Ids in the order they were pinned.
  property var favorites: []
  property bool favoritesLoaded: false

  // Which tab the section is showing. Persisted, because which of the two you
  // want is a preference rather than a per-visit choice.
  property string activeTab: "favorites"
  property bool viewInteracted: false
  // ...and the collapsed state deliberately is not. Collapsing is a momentary
  // "give me more applications right now", so it lasts as long as the shell
  // does and no longer. See README.
  property bool stripCollapsed: SessionState.stripCollapsed
  onStripCollapsedChanged: SessionState.stripCollapsed = root.stripCollapsed

  // Tunable per summon: `omarchy-shell shell toggle tyrsolution.app-launcher '{"iconScale":1.4}'`
  property real iconScale: 1.0
  property string fontFamily: Style.font.menuFamily

  // Searching collapses everything into one result grid: a pinned row, a
  // ranked one and a relevance-ranked one on screen at once reads as noise.
  readonly property bool searching: root.filterText.length > 0
  // The strip itself is always there when not searching, even with nothing
  // pinned and nothing launched yet — an empty Favorites tab is where you find
  // out the feature exists. Only its content can be empty.
  readonly property bool showStrip: !root.searching
  readonly property bool stripOpen: root.showStrip && !root.stripCollapsed

  // Follows the active Omarchy theme through the shared menu color tokens.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))

  readonly property int cornerRadius: Style.cornerRadius
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int iconSize: Math.round(Style.space(52) * root.iconScale)
  readonly property int cellWidth: root.iconSize + Style.space(44)
  readonly property int cellHeight: root.iconSize + Style.space(52)
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Style.font.caption + Style.spacing.md * 2
  readonly property int sectionLabelHeight: Style.font.caption + Style.spacing.md * 2
  readonly property int scrollBarWidth: Style.space(4)
  readonly property int ruleHeight: Math.max(1, Style.space(1))

  // The System strip is navigation, not content, so its tiles are smaller than
  // an app tile: it costs one short row instead of a full grid row. The width
  // stays in step with the grid above so the columns line up and the keyboard's
  // column-preserving up/down lands where the eye expects.
  readonly property int compactIconSize: Math.round(root.iconSize * 0.58)
  readonly property int compactCellWidth: root.cellWidth
  readonly property int compactCellHeight: root.compactCellAtRest
    + (root.searching ? Style.font.caption + Style.space(3) : 0)
  readonly property int compactCellAtRest: root.compactIconSize + Style.space(34)

  // The card sizes itself to a whole number of application rows. The grid snaps
  // to whole rows so the last one is never sliced, which means any height the
  // card has beyond an exact multiple shows up as dead space above the System
  // divider — 63px of it before this, enough to read as "the grid ran out".
  //
  // The chrome is summed explicitly rather than measured as `card.height -
  // allArea.height`, because the card's height is derived from it and reading it
  // back would be a binding loop. Every term below is independent of the card's
  // height; if a row or margin is added to the layout it has to be added here
  // too, or the dead space quietly returns.
  //
  // Measured "at rest" — as if not searching — so that typing cannot resize the
  // card under the pointer. A query hides the favorites row, which frees height
  // the grid takes as extra rows; whatever is left over then is a smaller gap in
  // a view that is usually full anyway.
  readonly property bool systemAtRest: root.systemRestRows.length > 0
  readonly property int stripRowsAtRest: Math.min(2, Math.max(1,
    Math.ceil(root.systemRestRows.length / Math.max(1, panel.columns))))

  // The collapse control lives in the gap between the search rule and the tab
  // titles rather than on the title line, because the right-hand end of that
  // line already belongs to "Frequently used". About half a label row: enough
  // to read as its own line, not enough to cost the grid a row of applications.
  readonly property int stripToggleHeight: Math.round(root.sectionLabelHeight * 0.6)

  // One number for the whole section: the tiles, the underline and the height
  // handoff to the applications all ride it, and they only read as a single
  // movement while they share it. The house token is 140ms (Ui/PopupCard);
  // this section is a bigger thing to move than a popup fading in, so it runs
  // slightly longer.
  readonly property int stripSlideMs: 154

  // Split in two, because the strip's grid is the one part of the card whose
  // height is decided by everything else: there is no limit on how many things
  // you can pin, so the rows they get are whatever is left over. Summing the
  // rest first is what keeps that from being a binding loop.
  //
  // The strip's chrome is unconditional now — two titles and a toggle are drawn
  // whether or not either tab has anything in it — so switching tabs moves rows
  // between this sum and the application grid without changing their total.
  // That is what keeps the card exactly the same height either way.
  readonly property int cardChromeSansStrip:
      card.contentTopInset + card.contentBottomInset
    + root.sectionLabelHeight + root.compactCellAtRest
    + (root.showWindowToggles ? root.sectionLabelHeight + root.compactCellAtRest : 0)
    + Style.spacing.xs + root.ruleHeight
    + root.headerHeight + root.ruleHeight
    + root.stripToggleHeight
    + root.sectionLabelHeight + Style.spacing.sm + root.ruleHeight
    + root.sectionLabelHeight
    + Style.spacing.md + Style.spacing.xs
    + (root.systemAtRest ? Style.spacing.xs + root.ruleHeight + root.sectionLabelHeight
                           + root.stripRowsAtRest * root.compactCellAtRest : 0)
    + root.footerHeight

  // Frequently used is one row by definition. Favorites takes as many as it
  // needs, and one row even when empty — that row holds the hint telling you
  // how to fill it, and keeping it a whole row is what stops the card shifting
  // by a remainder when you switch tabs.
  readonly property int favoriteRowsNeeded: Math.max(1,
    Math.ceil(root.favoritePool.length / Math.max(1, panel.columns)))
  readonly property int stripRowsNeeded: root.stripCollapsed
    ? 0
    : (root.activeTab === "frequent" ? 1 : root.favoriteRowsNeeded)
  // One application row is the floor. Pins take every row they need down to
  // that, and scroll past it — growing without limit would push the card off
  // the screen instead of showing you more of it.
  readonly property int stripRowsAffordable: Math.max(1, Math.floor(
    (root.cardMaxHeight - root.cardChromeSansStrip - root.cellHeight) / root.cellHeight))
  readonly property int stripVisibleRows: Math.min(root.stripRowsNeeded, root.stripRowsAffordable)

  readonly property int cardChrome: root.cardChromeSansStrip
    + root.stripVisibleRows * root.cellHeight

  readonly property int cardMaxHeight: Math.min(Style.space(900), panel.height - Style.gapsOut * 2)
  readonly property int cardGridRows: Math.max(1,
    Math.floor((root.cardMaxHeight - root.cardChrome) / root.cellHeight))

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.launchSource = String(payload.source || "")
    if (payload.fontFamily) root.fontFamily = payload.fontFamily
    if (Number(payload.iconScale) > 0) root.iconScale = Number(payload.iconScale)

    root.filterText = String(payload.query || "")
    // A summon always starts at the top: a folder left open from last time is
    // not where anyone expects to land.
    root.browsePath = ""
    contextMenu.hide()
    root.opened = true

    // Icons for packages installed since the shell started may not be in Qt's
    // theme cache yet; AppLibrary rescans on demand.
    if (root.appLibrary) root.appLibrary.refreshIcons()
    // Re-probe the agent roster on every summon, so an agent installed since
    // the last open shows up without a shell restart.
    root.probeAgents()
    // Same for the guards: whether you can hibernate, or are recording right
    // now, changes between summons. The open path does not wait on this — the
    // grid draws on the previous answers and takes the new ones when they land
    // a fraction of a second later. That can reflow a row under the pointer,
    // which is the price of not showing a row that contradicts the system.
    root.evaluateGuards()
    root.readToggles()
    root.interacted = false
    root.refreshNewIds()
    root.rebuild()
    root.resetSelection()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    contextMenu.hide()
    // Everything on screen at close time counts as seen, so badges clear once
    // you've actually had a chance to look at them.
    root.markAllSeen()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // No toggle() here on purpose. The shell decides open-vs-hide itself and
  // calls open(payload) directly (shell.qml summon/deliverIfLoaded), so a
  // toggle on the overlay was never on the path `omarchy-shell shell toggle`
  // takes. The generic `shell call` IPC could still reach one by name, but only
  // while the plugin is loaded — that is, already open — so it could only ever
  // have closed the launcher, which `shell hide` already does.
  //
  // It also hardcoded open("{}"), which now matters: that would discard the
  // `source` marker the bar button sends, and silently bring back the window
  // toggles on the pointer path.

  // ------------------------------------------------------------ app list

  function liveIdMap() {
    var out = Object.create(null)
    for (var a = 0; a < root.installedAgents.length; a++)
      out[Agents.rowId(String(root.installedAgents[a]))] = true
    if (!root.appLibrary) return out
    var rows = root.appLibrary.sortedEntries("")
    for (var i = 0; i < rows.length; i++) {
      var id = String((rows[i].entry && rows[i].entry.id) || "")
      if (id) out[id] = true
    }
    return out
  }

  function rebuild() {
    if (!root.appLibrary) { root.allRows = []; root.favoritePool = []; root.frequentPool = []; return }
    // sortedEntries returns search rows ({ entry, score, key, name }), not the
    // DesktopEntry itself — the entry is one level down. With no query it is
    // already alphabetical; with one it is ranked by the shell's fuzzy matcher.
    var matches = root.appLibrary.sortedEntries(root.filterText)
    var now = Date.now()
    var out = []
    for (var i = 0; i < matches.length; i++) {
      var entry = matches[i].entry
      var id = String((entry && entry.id) || "")
      if (!id) continue
      out.push({
        id: id,
        kind: "app",
        name: root.appLibrary.entryName(entry),
        subtext: root.appLibrary.entrySubtext(entry),
        icon: String(entry.icon || ""),
        iconUrl: "",
        monogram: "",
        score: Usage.effectiveScore(root.usage[id], now),
        isNew: root.newIds[id] === true
      })
    }

    var agents = root.agentRows()
    // Unfiltered, agents interleave alphabetically with apps (sortedEntries
    // orders apps by lowercased name, so re-sorting the merge reproduces it).
    // Filtered, matching agents lead: they are few, and typing "cla" should put
    // Claude Code in front rather than three rows down.
    if (root.searching) {
      out = Agents.sortMatches(agents, root.filterText).concat(out)
    } else {
      out = agents.concat(out)
      out.sort(function(a, b) {
        var an = String(a.name || "").toLowerCase()
        var bn = String(b.name || "").toLowerCase()
        if (an < bn) return -1
        if (an > bn) return 1
        return 0
      })
    }

    root.allRows = out

    // Menu commands compete for the Frequently used tab on the same terms as
    // apps, and can be pinned to the Favorites tab on the same terms too: a
    // Screenshot you run every day belongs in either. Only ones that have
    // actually been run are ranked, so that tab does not fill with verbs.
    var pool = out.slice()
    for (var c = 0; c < root.menuLeaves.length; c++) {
      var leaf = root.menuLeaves[c]
      var leafScore = Usage.effectiveScore(root.usage[leaf.id], now)
      if (leafScore <= 0) continue
      var scored = ({})
      for (var key in leaf) scored[key] = leaf[key]
      scored.score = leafScore
      pool.push(scored)
    }
    root.frequentPool = root.pickFrequent(pool)

    // Pins are resolved against the same pools the grid draws from, so one
    // whose app was uninstalled — or whose menu row is currently hidden behind
    // a `when:` — stops appearing instead of drawing a dead tile.
    //
    // A pinned app is NOT filtered out of Frequently used. That tab is a
    // readout of what you actually launch, and editing it to avoid repeating a
    // tile would make it lie.
    root.favoritePool = Favorites.resolve(root.favorites, [out, root.menuLeaves])
    root.clampSelection()
  }

  // Agents ship marks for a couple of providers only, so the rest get a
  // monogram tile rather than nine identical terminal icons.
  function agentIconUrl(definition) {
    if (!definition) return ""
    // A custom agent may point at a file; a bare name falls through to the
    // themed lookup the app tiles already use.
    var custom = String(definition.icon || "")
    if (custom.indexOf("file://") === 0) return custom
    if (custom.charAt(0) === "/") return Util.fileUrl(custom)
    if (!definition.asset) return ""
    var dir = root.omarchyPath + "/shell/plugins/agents/assets/"
    var light = root.isLightSurface() ? dir + definition.asset + "-light.svg" : ""
    // Same convention the agents panel uses: <id>-light.svg on light surfaces
    // when one ships, otherwise <id>.svg.
    if (light && definition.asset === "codex") return Util.fileUrl(light)
    return Util.fileUrl(dir + definition.asset + ".svg")
  }

  function isLightSurface() {
    var c = root.background
    function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return (0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)) >= 0.5
  }

  // A themed icon name (not a path) is resolved by AppLibrary like any app icon.
  function agentThemedIcon(definition) {
    var custom = String((definition && definition.icon) || "")
    if (!custom || custom.charAt(0) === "/" || custom.indexOf("file://") === 0) return ""
    return custom
  }

  // The monogram is the fallback: only drawn when no mark and no themed icon.
  function agentMonogram(definition) {
    if (!definition) return ""
    if (definition.asset || String(definition.icon || "").length > 0) return ""
    return definition.monogram
  }

  // The roster can change while a probe is in flight (the config file loads
  // after open() has already started one), so queue instead of dropping it.
  function probeAgents() {
    if (agentProbe.running) { root.agentProbePending = true; return }
    root.agentsLoaded = false
    agentProbe.running = true
  }

  function agentRows() {
    var now = Date.now()
    var out = []
    for (var i = 0; i < root.installedAgents.length; i++) {
      var definition = Agents.definitionFor(root.agentRoster, String(root.installedAgents[i]))
      if (!definition) continue
      var id = Agents.rowId(definition.id)
      out.push({
        id: id,
        agentId: definition.id,
        kind: "agent",
        name: definition.name,
        subtext: "Coding agent",
        icon: root.agentThemedIcon(definition),
        iconUrl: root.agentIconUrl(definition),
        monogram: root.agentMonogram(definition),
        argv: definition.argv,
        score: Usage.effectiveScore(root.usage[id], now),
        isNew: root.newIds[id] === true
      })
    }
    if (!root.searching) return out
    var matched = []
    for (var j = 0; j < out.length; j++)
      if (Agents.matches(out[j], root.filterText)) matched.push(out[j])
    return matched
  }

  // Apps with no recorded launch never appear here, so a fresh install shows an
  // empty tab rather than an arbitrary one.
  function pickFrequent(rows) {
    var scored = []
    for (var i = 0; i < rows.length; i++)
      if (rows[i].score > 0) scored.push(rows[i])
    Usage.sortByScore(scored)
    return scored
  }

  function setFilter(next) {
    root.interacted = true
    root.filterText = next
    // Folders are for browsing, search is for finding: a query collapses the
    // tree and matches across every leaf rather than filtering one folder.
    if (root.filterText && root.browsing) root.browsePath = ""
    root.rebuild()
    root.resetSelection()
    allGrid.positionViewAtBeginning()
  }

  function rowsFor(section) {
    if (section === "session") return root.sessionToggles || []
    if (section === "window") return root.windowToggles || []
    if (section === "favorites") return root.favoriteRows || []
    if (section === "frequent") return root.frequentRows || []
    if (section === "system") return root.systemRows || []
    return root.displayRows || []
  }

  // The grids top to bottom. Crossing between them is just a step along this
  // list, which is why the five-way version replaced the hand-written pairs:
  // every boundary used to be its own branch, and adding two rows would have
  // meant four more.
  readonly property var sectionOrder: ["session", "window", "favorites", "frequent", "all", "system"]

  // Only the ones that currently have anything in them — an empty section is
  // skipped rather than trapping the caret.
  function navigableSections() {
    var out = []
    for (var i = 0; i < root.sectionOrder.length; i++) {
      var name = root.sectionOrder[i]
      // Only the tab actually on screen is in the caret's path. The other one
      // is not hidden behind a scroll, it is not drawn at all, and a collapsed
      // strip draws neither — so Down out of the search field lands straight in
      // the applications.
      if (root.isStripSection(name) && (!root.stripOpen || root.activeTab !== name)) continue
      if (root.rowsFor(name).length > 0) out.push(name)
    }
    return out
  }

  // ------------------------------------------------------ menu navigation

  function enterFolder(menuId) {
    if (!menuId) return
    root.browsePath = menuId
    root.select("all", 0)
    allGrid.positionViewAtBeginning()
  }

  // Up one level, and out of browse mode entirely at the top.
  function goBack() {
    if (!root.browsing) return
    var entry = root.menuItems[root.browsePath]
    var parent = entry ? entry.parent : "root"
    root.browsePath = (!parent || parent === "root") ? "" : parent
    root.select("all", 0)
    allGrid.positionViewAtBeginning()
  }

  function leaveBrowse() {
    root.browsePath = ""
    root.select("all", 0)
  }

  // "Install › Development" for the folder in view, shown where the "All apps"
  // label normally sits.
  function browseTitle() {
    if (!root.browsing) return ""
    var trail = Menu.breadcrumb(root.menuItems, root.browsePath)
    var name = Menu.labelFor(root.menuItems[root.browsePath])
    return trail ? trail + " › " + name : name
  }

  function reloadMenu() {
    var merged = Menu.merge(root.menuDefaults, root.menuCustom)
    root.menuItems = merged.items
    root.menuOrder = merged.order
    // A menu that shrank under us could leave the browsed folder gone.
    if (root.browsing && !root.menuItems[root.browsePath]) root.leaveBrowse()
    root.evaluateGuards()
  }

  // One bash process for every `when:` and `checked:` in the menu. Evaluated on
  // load rather than on open, so summoning the launcher never waits on it: the
  // whole batch is ~0.3s here, which is fine in the background and would not be
  // fine in front of the user.
  function evaluateGuards() {
    // Process ignores a command change while it is running, and `collected`
    // belongs to the run in flight, so a second evaluation cannot overwrite the
    // first — it would discard the lines already read and never start, and the
    // surviving tail would land as the whole answer. Every id lost that way
    // goes back to showing. Wait for the run in flight instead.
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = Menu.guardScript(root.menuItems)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  function isStripSection(section) {
    return section === "favorites" || section === "frequent"
  }

  function rowAt(section, index) {
    var rows = root.rowsFor(section) || []
    if (index < 0 || index >= rows.length) return null
    return rows[index]
  }

  function selectedRow() {
    return root.rowAt(root.selectedSection, root.selectedIndex)
  }

  function select(section, index) {
    root.selectedSection = section
    root.selectedIndex = index
  }

  function resetSelection() {
    // rowsFor() rather than a property: this runs while properties are still
    // being initialised — the favorites pool takes its default long before
    // anything declared further down the file has a binding — and reading a
    // property that does not exist yet throws instead of returning empty.
    var strip = root.rowsFor(root.activeTab)
    if (root.stripOpen && strip.length > 0) { root.select(root.activeTab, 0); return }
    // A query can match commands and no applications at all. Leaving the caret
    // on an empty grid would mean Enter did nothing while a result sat visible
    // in the strip, so the selection follows the results.
    if (root.rowsFor("all").length === 0 && root.rowsFor("system").length > 0) {
      root.select("system", 0)
      return
    }
    root.select("all", 0)
  }

  function clampSelection() {
    var rows = root.rowsFor(root.selectedSection) || []
    if (rows.length === 0) { root.resetSelection(); return }
    if (root.selectedIndex >= rows.length) root.selectedIndex = rows.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  // Arrow keys move within a section; up/down cross between them, keeping the
  // column so the caret lands where the eye expects.
  function moveSelection(dx, dy) {
    root.interacted = true
    var columns = Math.max(1, panel.columns)
    var rows = root.rowsFor(root.selectedSection)
    if (rows.length === 0) return

    if (dx !== 0) {
      var wanted = root.selectedIndex + dx
      // Inside the strip the two tabs behave as one continuous run of tiles:
      // walking off either end crosses to the other tab rather than stopping
      // dead. That is the whole keyboard story for tabs — no new binding, and
      // it reads the same way the titles do, left to right.
      if (root.isStripSection(root.selectedSection) && (wanted < 0 || wanted >= rows.length)) {
        var across = Favorites.otherTab(root.selectedSection)
        var acrossRows = root.rowsFor(across)
        // An empty tab is not somewhere to strand the caret.
        if (acrossRows.length > 0) {
          root.showTab(across)
          root.select(across, wanted < 0 ? acrossRows.length - 1 : 0)
          return
        }
      }
      root.selectedIndex = Math.max(0, Math.min(rows.length - 1, wanted))
      return
    }

    var column = root.selectedIndex % columns
    var sections = root.navigableSections()
    var at = sections.indexOf(root.selectedSection)

    if (dy > 0) {
      // Still a row below inside this grid?
      if (root.selectedIndex + columns < rows.length) {
        root.selectedIndex += columns
        return
      }
      if (at < 0 || at + 1 >= sections.length) return
      var next = sections[at + 1]
      root.select(next, Math.min(column, root.rowsFor(next).length - 1))
      return
    }

    if (root.selectedIndex >= columns) {
      root.selectedIndex -= columns
      return
    }
    if (at <= 0) return
    // Land on the previous grid's *last* row, which is what sits directly
    // above, not its first.
    var prev = sections[at - 1]
    var prevRows = root.rowsFor(prev)
    var lastRowStart = Math.floor((prevRows.length - 1) / columns) * columns
    root.select(prev, Math.min(lastRowStart + column, prevRows.length - 1))
  }

  // ----------------------------------------------------------------- tabs

  // Clicking a title while the strip is shut opens it on that tab, so the
  // titles double as "open me here" and the toggle is only ever needed to
  // close. Switching to a tab you are already on, while open, does nothing.
  function showTab(tab) {
    var wanted = Favorites.validTab(tab)
    if (!wanted) return
    root.viewInteracted = true
    root.interacted = true
    var changed = root.activeTab !== wanted
    root.stripCollapsed = false
    root.activeTab = wanted
    // Even the default title is an explicit choice if the saved view is late.
    root.persistView()
    if (!changed) return
    // The caret cannot stay in a grid that is sliding off screen.
    if (root.isStripSection(root.selectedSection)) {
      var rows = root.rowsFor(wanted)
      if (rows.length > 0) root.select(wanted, 0)
      else root.resetSelection()
    }
  }

  function toggleStrip() {
    root.viewInteracted = true
    root.interacted = true
    root.stripCollapsed = !root.stripCollapsed
    // Collapsing takes the caret with it rather than leaving it on a grid
    // nobody can see.
    if (root.stripCollapsed && root.isStripSection(root.selectedSection)) root.resetSelection()
  }

  // File reads can finish after pools or user input. Restore the preference
  // only while it cannot undo a choice, and move a caret off the hidden tab.
  function restoreView(raw) {
    var tab = Favorites.parseView(raw)
    if (!tab || root.viewInteracted || root.interacted) return
    root.activeTab = tab
    root.resetSelection()
  }

  function persistView() {
    viewFile.setText(Favorites.serializeView(root.activeTab))
  }

  // ------------------------------------------------------------ launching

  function launch(row) {
    if (!row) return
    if (row.kind === "toggle") { root.runToggle(row); return }
    if (row.kind === "folder") { root.enterFolder(row.menuId); return }
    if (row.kind === "command") { root.runCommand(row); return }
    if (row.kind === "agent") { root.launchAgent(row); return }
    root.usage = Usage.record(root.usage, row.id, Date.now())
    root.persistUsage()
    root.dismiss()
    if (root.appLibrary) root.appLibrary.launch(row.id, row.name)
  }

  // Agents are CLIs, so they go into a terminal through omarchy-launch-tui with
  // the shared org.omarchy.agent app-id — the same window class Omarchy's own
  // agent keybinding produces, so existing window rules still apply. Starting in
  // ~/Work mirrors omarchy-agent: agents refuse to remember trust for $HOME.
  function launchAgent(row) {
    if (!row) return
    root.usage = Usage.record(root.usage, row.id, Date.now())
    root.persistUsage()
    root.dismiss()

    var quoted = []
    for (var i = 0; i < row.argv.length; i++) quoted.push(Util.shellQuote(String(row.argv[i])))
    Util.execDetached('[[ -d "$HOME/Work" ]] && cd "$HOME/Work"; exec omarchy-launch-tui --app-id=org.omarchy.agent ' + quoted.join(" "))
  }

  // Menu rows are plain shell commands, run exactly the way the menu plugin
  // runs them (Menu.qml runAction) so a row behaves the same in both places.
  // They can be pinned like anything else: "Screenshot" belongs in Favorites if
  // that is what you reach for.
  function runCommand(row) {
    if (!row || !row.action) return
    root.usage = Usage.record(root.usage, row.id, Date.now())
    root.persistUsage()
    root.dismiss()
    Util.execDetached(row.action)
  }

  // A toggle stays open: flipping Do Not Disturb and having the launcher vanish
  // would make it a menu item, not a switch. The state is re-read after a beat
  // because the toggle scripts write their flag and notify asynchronously.
  function runToggle(row) {
    if (!row || !row.action || row.available === false) return
    Util.execDetached(row.action)
    // Re-read repeatedly rather than once. Most toggles write their flag and
    // are done inside a frame, but omarchy-toggle-nightlight resends the
    // temperature up to ten times at 0.2s intervals waiting for a freshly
    // started hyprsunset to stop overriding it — a single check at 200ms would
    // read the state it was about to leave.
    toggleSettle.tries = 6
    toggleSettle.restart()
  }

  Timer {
    id: toggleSettle
    property int tries: 0
    interval: 320
    repeat: true
    onTriggered: {
      root.readToggles()
      toggleSettle.tries -= 1
      if (toggleSettle.tries <= 0) toggleSettle.stop()
    }
  }

  function readToggles() {
    if (toggleProc.running) return
    toggleProc.collected = ""
    toggleProc.command = ["bash", "-lc", Toggles.stateScript()]
    toggleProc.running = true
  }

  // Sets the default and launches it — that is what the omarchy command does.
  function setDefaultAgent(row) {
    if (!row || !row.agentId) return
    root.dismiss()
    Util.execDetached("omarchy default agent " + Util.shellQuote(row.agentId))
  }

  function launchSelected() {
    root.launch(root.selectedRow())
  }

  // .desktop Actions ("New Window", "New Incognito Window", ...). AppLibrary's
  // gtk-launch path can't address an action, so run the action's own argv
  // under the same uwsm scope the shell uses for apps.
  function launchAction(row, action) {
    if (!row || !action) return
    root.usage = Usage.record(root.usage, row.id, Date.now())
    root.persistUsage()
    root.dismiss()

    var argv = action.command || []
    if (argv.length > 0) {
      var quoted = []
      for (var i = 0; i < argv.length; i++) quoted.push(Util.shellQuote(String(argv[i])))
      Util.execDetached("uwsm-app -- " + quoted.join(" "))
    } else {
      // No parsed argv (unusual); let Quickshell run it however it can.
      try { action.execute() } catch (e) { console.warn("app-grid: action execute failed:", e) }
    }
  }

  function actionsFor(row) {
    if (!row) return []
    var entry = DesktopEntries.byId(row.id)
    return (entry && entry.actions) ? entry.actions : []
  }

  function removeEntry(row) {
    if (!row) return
    root.dismiss()
    if (root.appLibrary) root.appLibrary.remove(row.id, row.name)
  }

  // Frecency is on screen again, so the way to disown a bad entry is back with
  // it. Reset Favorites is the same idea for the other tab; both are in the
  // Omarchy menu, and this is the per-row version.
  function resetUsage(row) {
    if (!row) return
    root.usage = Usage.forget(root.usage, row.id)
    root.persistUsage()
    root.rebuild()
  }

  // ------------------------------------------------------- new-app badges

  function refreshNewIds() {
    if (!root.seenLoaded) return
    var live = root.liveIdMap()
    var next = ({})
    for (var id in live) if (root.seenIds[id] !== true) next[id] = true
    root.newIds = next
  }

  // Ids worth keeping state for. Deliberately wider than liveIdMap():
  // that one is the "just added" badge domain, and menu commands do not belong
  // in it — they are never badged, and folding 269 of them in would report the
  // whole menu as new the first time this runs. But their scores still have to
  // survive the prune below, or every command's ranking would die on close.
  function scorableIdMap() {
    var out = root.liveIdMap()
    // Guards control visibility, not existence. Include hidden commands.
    var commands = Menu.leafRows(root.menuItems, root.menuOrder, ({}), ({}))
    for (var i = 0; i < commands.length; i++) out[commands[i].id] = true

    // An empty/inaccessible app list has no readiness signal from the host.
    // Preserve that domain rather than interpreting startup as mass removal.
    var appsReady = root.appLibrary && root.appLibrary.sortedEntries("").length > 0
    var menuReady = root.menuDefaultsLoaded && root.menuCustomLoaded
    var saved = Object.keys(root.usage).concat(root.favorites)
    for (var j = 0; j < saved.length; j++) {
      var id = String(saved[j])
      if (Menu.menuIdOf(id)) {
        if (!menuReady) out[id] = true
      } else if (Agents.agentIdOf(id)) {
        if (!root.agentsLoaded || agentProbe.running) out[id] = true
      } else if (!appsReady) out[id] = true
    }
    return out
  }

  function markAllSeen() {
    var live = root.liveIdMap()
    if (root.appLibrary && root.appLibrary.sortedEntries("").length > 0 && root.agentsLoaded) {
      root.seenIds = live
      root.newIds = ({})
      seenFile.setText(Usage.serializeSeen(live))
    }
    // An app that is gone has no score worth keeping.
    var scorable = root.scorableIdMap()
    var pruned = Usage.prune(root.usage, scorable)
    if (JSON.stringify(pruned) !== JSON.stringify(root.usage)) {
      root.usage = pruned
      root.persistUsage()
    }
    // Nor a pin. Same domain as the scores on purpose: an entry that is gone
    // for good goes, one that is merely hidden behind a `when:` right now stays
    // pinned, because it will be back.
    if (root.favoritesLoaded) {
      var keptPins = Favorites.prune(root.favorites, scorable)
      if (keptPins.length !== root.favorites.length) {
        root.favorites = keptPins
        root.persistFavorites()
      }
    }
  }

  function persistUsage() {
    usageFile.setText(Usage.serializeUsage(root.usage))
  }

  // ------------------------------------------------------------ favorites

  function isFavorite(id) {
    return Favorites.contains(root.favorites, id)
  }

  // Pinning takes effect where you can see it: the row reflows under the
  // pointer rather than waiting for the launcher to close. That costs a
  // rebuild, which is the same work a launch already does.
  function toggleFavorite(row) {
    if (!row || !Favorites.pinnable(row.kind)) return
    root.interacted = true
    root.favorites = Favorites.toggle(root.favorites, String(row.id))
    root.persistFavorites()
    root.rebuild()
  }

  function persistFavorites() {
    favoritesFile.setText(Favorites.serialize(root.favorites))
  }

  Component.onCompleted: Util.execDetached("mkdir -p " + Util.shellQuote(root.stateDir))

  // Non-login shell on purpose: the shell's PATH already carries the mise
  // shims, and sourcing the profile would touch ~/.local/share, which the
  // desktop-entry watcher monitors.
  Process {
    id: agentProbe
    command: ["bash", "-c", Agents.probeCommand(root.agentRoster)]
    stdout: SplitParser {
      onRead: function(line) {
        var id = String(line || "").trim()
        if (id.length > 0) root.pendingAgents.push(id)
      }
    }
    onStarted: root.pendingAgents = []
    onExited: function(exitCode, exitStatus) {
      // command -v may return 1 when the last optional agent is absent.
      if (exitStatus === 0 && (exitCode === 0 || exitCode === 1)) {
        root.installedAgents = root.pendingAgents.slice()
        root.agentsLoaded = true
      } else root.agentsLoaded = false
      root.refreshNewIds()
      root.rebuild()
      if (root.agentProbePending) {
        root.agentProbePending = false
        agentProbe.running = true
      }
    }
  }

  FileView {
    path: root.agentConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.customAgents = Agents.parseCustom(text())
      root.probeAgents()
    }
    onFileChanged: reload()
    onLoadFailed: {
      root.customAgents = []
      root.rebuild()
    }
  }

  Process {
    id: toggleProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { toggleProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) return
      root.toggleState = Toggles.parseState(toggleProc.collected)
    }
  }

  Process {
    id: guardProc
    property string collected: ""

    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }

    onExited: function(exitCode, exitStatus) {
      // A batch that was killed rather than finished only told us about the rows
      // it reached, and a row whose `when:` went unanswered shows. Keep the last
      // complete set rather than let a half-read one through. A signal leaves
      // the exit code at 0, so the status is what tells us.
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var parsed = Menu.parseGuards(guardProc.collected)
      root.whenResults = parsed.when
      root.checkedResults = parsed.checked
      // Hidden rows change what the favorites row and the flattened search can
      // draw from, so the app list has to be rebuilt against the new answers.
      root.rebuild()
      root.clampSelection()

      // Run the evaluation that had to stand aside. Deferred a turn so the
      // process is settled before its command is set again.
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }

  // The shipped menu, and the user's extensions on top of it. Both watched, so
  // adding a row to omarchy-menu.jsonc shows up in the launcher the same way it
  // shows up in the menu — without a shell restart.
  FileView {
    path: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var parsed = Menu.parse(text())
      root.menuDefaultsLoaded = parsed !== null
      if (parsed !== null) root.menuDefaults = parsed
      root.reloadMenu()
    }
    onFileChanged: reload()
    onLoadFailed: { root.menuDefaultsLoaded = false }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var parsed = Menu.parse(text())
      root.menuCustomLoaded = parsed !== null
      if (parsed !== null) root.menuCustom = parsed
      root.reloadMenu()
    }
    onFileChanged: reload()
    onLoadFailed: { root.menuCustomLoaded = false }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/defaults/agent"
    watchChanges: true
    printErrors: false
    onLoaded: root.defaultAgent = String(text() || "").trim()
    onFileChanged: reload()
    onLoadFailed: root.defaultAgent = ""
  }

  FileView {
    id: usageFile
    path: root.stateDir + "/usage.json"
    atomicWrites: true
    printErrors: false
    onLoaded: { root.usage = Usage.parseUsage(text()); root.rebuild() }
    onLoadFailed: { root.usage = ({}); root.rebuild() }
  }

  FileView {
    id: seenFile
    path: root.stateDir + "/seen.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = Usage.parseSeen(text())
      root.seenIds = parsed || ({})
      root.seenLoaded = true
      // A missing/corrupt file means first run: adopt the current list as the
      // baseline instead of badging every installed app as new.
      if (!parsed) root.markAllSeen()
      else root.refreshNewIds()
      root.rebuild()
    }
    onLoadFailed: {
      root.seenIds = ({})
      root.seenLoaded = true
      root.markAllSeen()
      root.rebuild()
    }
  }

  FileView {
    id: favoritesFile
    path: root.stateDir + "/favorites.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.favorites = Favorites.parse(text()) || []
      root.favoritesLoaded = true
      root.rebuild()
    }
    onLoadFailed: {
      root.favorites = []
      root.favoritesLoaded = true
      root.rebuild()
    }
  }

  // Which tab was open last. Its own file so favorites.json stays a list of
  // ids and nothing else — that file is meant to be readable and hand-editable
  // as exactly what it looks like.
  //
  // No file means this is a first run: the default below stands, and Favorites
  // is what opens. Landing on an empty tab that explains itself is how the
  // feature gets discovered; the applications you already reach for are one
  // click away on the other title.
  FileView {
    id: viewFile
    path: root.stateDir + "/view.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.restoreView(text())
    }
  }

  // The app set changed under us — a package landed, a web app was added, an
  // entry was removed. Reflow immediately; that is the whole point.
  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      root.refreshNewIds()
      root.rebuild()
    }
  }

  // ------------------------------------------------------------------ UI

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-app-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Whole columns only, so the grid sits centered without a ragged gutter.
    // The scroll bar lives in the margin beside it.
    readonly property int maxGridWidth: Math.min(Style.space(880), panel.width - Style.gapsOut * 2 - root.contentMargin * 2 - root.scrollBarWidth - Style.spacing.md)
    readonly property int columns: Math.max(1, Math.floor(maxGridWidth / root.cellWidth))
    readonly property int gridWidth: columns * root.cellWidth

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: panel.gridWidth + root.contentMargin * 2 + root.scrollBarWidth + Style.spacing.md
      height: Math.min(root.cardMaxHeight, root.cardChrome + root.cardGridRows * root.cellHeight)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: contextMenu.hide()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          root.interacted = true
          if (contextMenu.visible) {
            if (event.key === Qt.Key_Escape) { contextMenu.hide(); event.accepted = true }
            return
          }

          if (event.key === Qt.Key_Escape) {
            // Unwind one level at a time: query, then folder, then close.
            if (root.filterText) root.setFilter("")
            else if (root.browsing) root.goBack()
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace && !root.filterText && root.browsing) {
            root.goBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.launchSelected()
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.moveSelection(1, 0); event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.moveSelection(-1, 0); event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveSelection(0, 1); event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveSelection(0, -1); event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.resetSelection(); event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.select("all", Math.max(0, root.displayRows.length - 1)); event.accepted = true
          } else if (event.key === Qt.Key_Menu) {
            contextMenu.showForSelection(); event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ---------------------------------------------------------- header

        // ------------------------------------------------------- toggles

        // Above the search field, and split in two: the session row acts on the
        // machine, the window row on one window you cannot currently see. The
        // window row is labelled with its target for exactly that reason.

        Text {
          id: sessionLabel
          anchors { top: parent.top; left: parent.left }
          height: root.sectionLabelHeight
          verticalAlignment: Text.AlignVCenter
          text: "Session"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        GridView {
          id: sessionRow
          anchors { top: sessionLabel.bottom; horizontalCenter: parent.horizontalCenter }
          width: panel.gridWidth
          height: root.compactCellAtRest
          cellWidth: root.compactCellWidth
          cellHeight: root.compactCellAtRest
          interactive: false
          clip: true
          model: root.sessionToggles
          delegate: toggleTileComponent

          property string section: "session"
        }

        Text {
          id: windowLabel
          visible: root.showWindowToggles
          anchors { top: sessionRow.bottom; left: parent.left }
          height: visible ? root.sectionLabelHeight : 0
          verticalAlignment: Text.AlignVCenter
          // Space for this row is reserved whether or not a window is focused,
          // so the card cannot resize when the state batch lands a beat after
          // the grid is already on screen.
          text: root.windowTarget ? root.windowTarget : "No window focused"
          color: root.foreground
          opacity: root.windowTarget ? 0.45 : 0.3
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        GridView {
          id: windowRow
          visible: root.showWindowToggles
          anchors { top: windowLabel.bottom; horizontalCenter: parent.horizontalCenter }
          width: panel.gridWidth
          height: visible ? root.compactCellAtRest : 0
          cellWidth: root.compactCellWidth
          cellHeight: root.compactCellAtRest
          interactive: false
          clip: true
          model: root.windowToggles
          delegate: toggleTileComponent

          property string section: "window"
        }

        Rectangle {
          id: togglesRule
          anchors { top: windowRow.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: Style.spacing.xs
          height: root.ruleHeight
          color: root.foreground
          opacity: 0.12
        }

        Item {
          id: header
          anchors { top: togglesRule.bottom; left: parent.left; right: parent.right }
          height: root.headerHeight

          Text {
            id: query
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            width: parent.width - counter.width - Style.spacing.lg
            text: root.filterText || "Search apps…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }

          Rectangle {
            id: caret
            anchors.verticalCenter: query.verticalCenter
            x: Math.min(query.x + query.contentWidth + Style.space(2), query.x + query.width)
            width: Math.max(1, Style.space(1))
            height: Style.font.heading
            color: root.foreground
            visible: root.filterText.length > 0
            opacity: 0.8
            SequentialAnimation on opacity {
              running: caret.visible
              loops: Animation.Infinite
              NumberAnimation { to: 0.05; duration: 520 }
              NumberAnimation { to: 0.8; duration: 520 }
            }
          }

          Text {
            id: counter
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            text: {
              // While browsing, the count that matters is the folder in view.
              if (root.browsing) {
                var n = root.displayRows.length
                return n + (n === 1 ? " item" : " items")
              }
              var agents = 0
              for (var i = 0; i < root.allRows.length; i++)
                if (root.allRows[i].kind === "agent") agents++
              var apps = root.allRows.length - agents
              var label = apps + (apps === 1 ? " app" : " apps")
              if (agents > 0) label += " · " + agents + (agents === 1 ? " agent" : " agents")
              return label
            }
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Rectangle {
          id: headerRule
          anchors { top: header.bottom; left: parent.left; right: parent.right }
          height: Math.max(1, Style.space(1))
          color: root.foreground
          opacity: 0.12
        }

        // ------------------------------------------------ favorites / frequent

        // Two sections that used to be one, and are one again: same slot, same
        // height budget, two titles parked at opposite ends of the same line.
        // Clicking a title slides the tiles across under them rather than
        // stacking a second grid below, which is what keeps the applications
        // from being pushed off the bottom of the card by a section you are not
        // looking at.

        // The toggle sits in the gap above the titles, not beside them: the
        // right-hand end of the title line belongs to "Frequently used". It
        // does not move between open and shut, so it is never chasing the
        // pointer that just clicked it.
        Item {
          id: stripToggleRow
          visible: root.showStrip
          anchors { top: headerRule.bottom; left: parent.left; right: parent.right }
          height: visible ? root.stripToggleHeight : 0

          Text {
            id: stripToggle
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            // Nerd Font chevrons, the same private-use block as the pin stars.
            // Down while the section is showing, right while it is folded away.
            text: root.stripCollapsed ? "\uf054" : "\uf078"
            color: root.foreground
            opacity: toggleArea.containsMouse ? 1 : 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Behavior on opacity { NumberAnimation { duration: 90 } }

            MouseArea {
              id: toggleArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleStrip()
            }
          }
        }

        Item {
          id: tabBar
          visible: root.showStrip
          anchors { top: stripToggleRow.bottom; left: parent.left; right: parent.right }
          height: visible ? root.sectionLabelHeight : 0

          component TabTitle: Text {
            required property string tabId
            color: root.foreground
            opacity: root.activeTab === tabId && !root.stripCollapsed
              ? 1 : (titleArea.containsMouse ? 0.7 : 0.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Behavior on opacity { NumberAnimation { duration: root.stripSlideMs; easing.type: Easing.OutCubic } }
            MouseArea {
              id: titleArea
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showTab(parent.tabId)
            }
          }

          TabTitle {
            id: favoritesTab
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            tabId: "favorites"
            text: "Favorites"
          }
          TabTitle {
            id: frequentTab
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            tabId: "frequent"
            text: "Frequently used"
          }

          // Travels between the two titles on the same curve the tiles travel
          // on, so the motion reads as one movement rather than two.
          Rectangle {
            id: tabUnderline
            visible: root.stripOpen
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.xs
            x: root.activeTab === "frequent" ? frequentTab.x : favoritesTab.x
            width: root.activeTab === "frequent" ? frequentTab.width : favoritesTab.width
            height: Math.max(1, Style.space(2))
            radius: height / 2
            color: root.accent

            Behavior on x { NumberAnimation { duration: root.stripSlideMs; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: root.stripSlideMs; easing.type: Easing.OutCubic } }
          }
        }

        // The viewport is one tab wide and the track is two, so switching is a
        // translation rather than a swap: nothing is created or destroyed, and
        // both grids keep their scroll position.
        //
        // Its height animates as well, and `allArea` below is anchored top and
        // bottom — so the rows this gives up are handed to the applications on
        // the same curve, and the card itself never changes height.
        Item {
          id: stripViewport
          // Visible on the strip being there at all, NOT on it being open:
          // collapsing has to leave the item alive long enough for its height
          // to animate down to nothing, and `stripVisibleRows` is already 0
          // while collapsed. Hiding it here instead would snap.
          visible: root.showStrip
          anchors { top: tabBar.bottom; horizontalCenter: parent.horizontalCenter }
          width: panel.gridWidth
          height: visible ? root.stripVisibleRows * root.cellHeight : 0
          clip: true

          Behavior on height { NumberAnimation { duration: root.stripSlideMs; easing.type: Easing.OutCubic } }

          Row {
            id: stripTrack
            height: stripViewport.height
            x: root.activeTab === "frequent" ? -stripViewport.width : 0

            Behavior on x { NumberAnimation { duration: root.stripSlideMs; easing.type: Easing.OutCubic } }

            Item {
              width: stripViewport.width
              height: stripViewport.height

              GridView {
                id: favoritesGrid
                anchors.fill: parent
                cellWidth: root.cellWidth
                cellHeight: root.cellHeight
                clip: true
                model: root.favoriteRows
                delegate: tileComponent
                boundsBehavior: Flickable.StopAtBounds

                // Nothing caps how much you can pin, so this is where "as many
                // as you like" stops being free: the tab takes every row it
                // needs down to leaving one row of applications, and scrolls
                // from there.
                interactive: root.activeTab === "favorites"
                  && root.favoriteRowsNeeded > root.stripVisibleRows

                property string section: "favorites"
              }

              // Nothing pinned. This is the only place the star is explained,
              // and it is why an empty Favorites tab is drawn rather than
              // hidden — a section that appears only once you have already
              // found the feature teaches nobody.
              Text {
                visible: root.favoritePool.length === 0
                anchors.centerIn: parent
                horizontalAlignment: Text.AlignHCenter
                text: "Click the \uf005 on any app to pin it here"
                color: root.foreground
                opacity: 0.35
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Item {
              width: stripViewport.width
              height: stripViewport.height

              GridView {
                id: frequentGrid
                anchors.fill: parent
                cellWidth: root.cellWidth
                cellHeight: root.cellHeight
                interactive: false
                clip: true
                model: root.frequentRows
                delegate: tileComponent
                boundsBehavior: Flickable.StopAtBounds

                property string section: "frequent"
              }

              // A fresh install has launched nothing, so this tab has nothing
              // to rank yet. Saying so beats an empty rectangle.
              Text {
                visible: root.frequentRows.length === 0
                anchors.centerIn: parent
                horizontalAlignment: Text.AlignHCenter
                text: "Apps you open will show up here"
                color: root.foreground
                opacity: 0.35
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Rectangle {
          id: sectionRule
          visible: root.showStrip
          anchors { top: stripViewport.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: visible ? Style.spacing.sm : 0
          height: visible ? Math.max(1, Style.space(1)) : 0
          color: root.foreground
          opacity: 0.12
        }

        // ------------------------------------------------------- all apps

        // Browsing a folder turns this label into a breadcrumb with a Back
        // target beside it. Escape and Backspace do the same job, but neither
        // is discoverable with a mouse, and this section exists for the mouse.
        Item {
          id: allLabel
          visible: root.showStrip || root.browsing
          anchors { top: sectionRule.bottom; left: parent.left; right: parent.right }
          height: visible ? root.sectionLabelHeight : 0

          Text {
            id: backButton
            visible: root.browsing
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            text: "‹ Back"
            color: root.accent
            opacity: backArea.containsMouse ? 1 : 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              id: backArea
              anchors.fill: parent
              anchors.margins: -Style.spacing.sm
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goBack()
            }
          }

          Text {
            anchors {
              left: backButton.visible ? backButton.right : parent.left
              leftMargin: backButton.visible ? Style.spacing.md : 0
              right: parent.right
              verticalCenter: parent.verticalCenter
            }
            text: root.browsing ? root.browseTitle() : "All apps"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Item {
          id: allArea
          anchors {
            top: allLabel.visible ? allLabel.bottom : headerRule.bottom
            bottom: systemRule.top
            left: parent.left
            right: parent.right
            topMargin: Style.spacing.md
            bottomMargin: Style.spacing.xs
          }

          // Snap the viewport to whole rows so the last visible row is never
          // sliced in half — the scroll bar is what says "there is more".
          readonly property int visibleRows: Math.max(1, Math.floor(height / root.cellHeight))

          GridView {
            id: allGrid
            anchors.horizontalCenter: parent.horizontalCenter
            y: 0
            width: panel.gridWidth
            height: allArea.visibleRows * root.cellHeight
            clip: true
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            model: root.displayRows
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: root.cellHeight * 4
            delegate: tileComponent

            property string section: "all"
          }

          // Scroll bar: track in the right margin, handle sized by how much of
          // the list fits. Drag it, or click the track to jump.
          Rectangle {
            id: scrollTrack
            visible: allGrid.contentHeight > allGrid.height
            anchors {
              right: parent.right
              top: allGrid.top
              bottom: allGrid.bottom
            }
            width: root.scrollBarWidth
            radius: width / 2
            color: root.foreground
            opacity: 0.1

            readonly property real maxContentY: Math.max(1, allGrid.contentHeight - allGrid.height)

            MouseArea {
              anchors.fill: parent
              onClicked: function(mouse) {
                var ratio = Math.max(0, Math.min(1, (mouse.y - scrollHandle.height / 2) / Math.max(1, scrollTrack.height - scrollHandle.height)))
                allGrid.contentY = ratio * scrollTrack.maxContentY
              }
            }
          }

          Rectangle {
            id: scrollHandle
            visible: scrollTrack.visible
            x: scrollTrack.x
            width: scrollTrack.width
            radius: width / 2
            color: root.foreground
            opacity: handleArea.pressed ? 0.5 : (handleArea.containsMouse ? 0.38 : 0.26)

            height: Math.max(Style.space(28), scrollTrack.height * Math.min(1, allGrid.height / Math.max(1, allGrid.contentHeight)))
            y: scrollTrack.y + (allGrid.contentY / scrollTrack.maxContentY) * (scrollTrack.height - height)

            Behavior on opacity { NumberAnimation { duration: 90 } }

            MouseArea {
              id: handleArea
              anchors.fill: parent
              hoverEnabled: true
              preventStealing: true

              property real grabOffset: 0

              onPressed: function(mouse) { handleArea.grabOffset = mouse.y }
              onPositionChanged: function(mouse) {
                if (!handleArea.pressed) return
                // Work in track space and drive contentY directly; binding the
                // handle's y to both the drag and the view would loop.
                var trackY = scrollHandle.y + mouse.y - handleArea.grabOffset - scrollTrack.y
                var span = Math.max(1, scrollTrack.height - scrollHandle.height)
                var ratio = Math.max(0, Math.min(1, trackY / span))
                allGrid.contentY = ratio * scrollTrack.maxContentY
              }
            }
          }
        }

        Text {
          anchors.centerIn: allArea
          visible: root.displayRows.length === 0
          text: root.browsing
            ? "Nothing here"
            : (root.filterText ? "No apps match “" + root.filterText + "”" : "No applications found")
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---------------------------------------------------------- footer

        // --------------------------------------------------- system strip

        // Pinned rather than scrolled in with the apps: reaching it by
        // scrolling past every application would be worse than the menu this
        // is meant to replace. Anchored bottom-up so it collapses to nothing
        // when there is no menu to show.

        Rectangle {
          id: systemRule
          visible: root.systemRows.length > 0
          anchors { bottom: systemLabel.top; left: parent.left; right: parent.right }
          anchors.bottomMargin: visible ? Style.spacing.xs : 0
          height: visible ? Math.max(1, Style.space(1)) : 0
          color: root.foreground
          opacity: 0.12
        }

        Text {
          id: systemLabel
          visible: systemRule.visible
          anchors { bottom: systemGrid.top; left: parent.left }
          height: visible ? root.sectionLabelHeight : 0
          verticalAlignment: Text.AlignVCenter
          text: root.searching
            ? "System · " + root.systemRows.length + (root.systemRows.length === 1 ? " match" : " matches")
            : "System"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        GridView {
          id: systemGrid
          visible: systemRule.visible
          anchors { bottom: footer.top; horizontalCenter: parent.horizontalCenter }
          width: panel.gridWidth
          height: visible ? systemGrid.visibleRows * root.compactCellHeight : 0
          cellWidth: root.compactCellWidth
          cellHeight: root.compactCellHeight
          clip: true
          model: root.systemRows
          delegate: compactTileComponent
          boundsBehavior: Flickable.StopAtBounds

          // Two rows is the ceiling: the nine folders fit in one at full width,
          // and a long list of search matches scrolls rather than eating the
          // application grid.
          readonly property int neededRows: Math.max(1, Math.ceil(root.systemRows.length / Math.max(1, panel.columns)))
          readonly property int visibleRows: Math.min(2, systemGrid.neededRows)

          property string section: "system"
        }

        Item {
          id: footer
          anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
          height: root.footerHeight

          Text {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            text: root.browsing
              ? "‹ back · ↵ open · type to search everything · esc up one level"
              : "type to search · ↵ launch · right-click for actions · esc close"
            color: root.foreground
            opacity: 0.35
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            visible: contextMenu.newCount > 0
            text: contextMenu.newCount + " new"
            color: root.accent
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ------------------------------------------------------------ tile

        Component {
          id: tileComponent

          Item {
            id: tile
            required property var modelData
            required property int index

            readonly property string section: GridView.view ? GridView.view.section : "all"
            readonly property bool selected: root.selectedSection === tile.section && root.selectedIndex === tile.index
            // A folder is navigation and a toggle is a switch; neither is a
            // thing you launch, and neither has ever been in the top row.
            readonly property bool pinnable: Favorites.pinnable(tile.modelData.kind)
            readonly property bool pinned: root.isFavorite(tile.modelData.id)

            width: root.cellWidth
            height: root.cellHeight

            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.spacing.xs
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
              color: tile.selected ? Style.selectedFill : (hover.hovered ? Style.hoverFill : "transparent")
              border.width: tile.selected ? Math.max(1, Style.selectedBorderWidth) : 0
              border.color: Style.selectedBorderColor
            }

            // Above the tile's own MouseArea so the star's click target wins.
            // Everything else in here is inert — an image and two labels — so
            // clicks anywhere but the star still fall through to it.
            Column {
              z: 1
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Item {
                width: root.iconSize
                height: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter

                Image {
                  anchors.fill: parent
                  visible: !monogram.visible
                  source: tile.modelData.iconUrl
                    ? tile.modelData.iconUrl
                    : (root.appLibrary ? root.appLibrary.iconSource(tile.modelData.icon) : "")
                  sourceSize.width: root.iconSize * 2
                  sourceSize.height: root.iconSize * 2
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                  mipmap: true
                }

                // Agents without a shipped mark get a monogram rather than yet
                // another generic terminal icon.
                Rectangle {
                  id: monogram
                  visible: String(tile.modelData.monogram || "").length > 0
                  anchors.centerIn: parent
                  width: Math.round(root.iconSize * 0.82)
                  height: width
                  radius: Math.max(Style.space(6), width * 0.22)
                  color: Style.normalFill
                  border.width: Math.max(1, Style.normalBorderWidth)
                  border.color: Style.normalBorderColor

                  Text {
                    anchors.centerIn: parent
                    text: tile.modelData.monogram
                    color: root.foreground
                    opacity: 0.9
                    // A menu glyph is drawn to fill its em box and carries its
                    // own font; two capital letters of a monogram need neither.
                    font.family: tile.modelData.iconFont ? tile.modelData.iconFont : root.fontFamily
                    font.pixelSize: Math.round(monogram.width * (tile.modelData.glyphScale ? tile.modelData.glyphScale : 0.42))
                  }
                }

                // Inside a folder, some tiles open and some run. Without this
                // the two are indistinguishable — Development lists JavaScript
                // (a folder) beside Go (a command) with nothing to tell them
                // apart. Same marker and same anchoring rule as the strip.
                Text {
                  visible: tile.modelData.kind === "folder"
                  anchors { left: parent.right; verticalCenter: parent.verticalCenter }
                  anchors.leftMargin: Style.space(3)
                  text: "›"
                  color: root.accent
                  opacity: 0.9
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(root.iconSize * 0.38)
                }

                // "Just added": this .desktop file appeared since the last
                // time the grid was closed. It sits in the left corner because
                // the star took the right one — this badge clears itself the
                // next time the launcher closes, and a pin does not.
                Rectangle {
                  visible: tile.modelData.isNew === true
                  anchors { left: parent.left; top: parent.top }
                  anchors.leftMargin: -Style.space(2)
                  anchors.topMargin: -Style.space(2)
                  width: Style.space(9)
                  height: width
                  radius: width / 2
                  color: root.accent
                  border.width: Math.max(1, Style.space(1))
                  border.color: root.background
                }

                // The pin marker: hollow while the pointer is over the tile,
                // filled once pinned and then drawn whether or not it is — what
                // you pinned should be readable without sweeping the pointer
                // across the grid to find out.
                //
                // A Nerd Font glyph, the same way the System rows draw theirs;
                // the shared menu font is one by default. Hidden while
                // searching, when the grid is a list of results rather than a
                // place you arrange things.
                Text {
                  visible: tile.pinnable && !root.searching && (hover.hovered || tile.pinned)
                  anchors { right: parent.right; top: parent.top }
                  anchors.rightMargin: -Style.space(3)
                  anchors.topMargin: -Style.space(3)
                  text: tile.pinned ? "\uf005" : "\uf006"
                  color: tile.pinned ? root.accent : root.foreground
                  opacity: tile.pinned ? 1 : (pinArea.containsMouse ? 0.95 : 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(root.iconSize * 0.3)

                  // Its own target, and it keeps the click: pinning something
                  // is not a reason to launch it. Right-click is left alone, so
                  // the context menu still opens over the star.
                  MouseArea {
                    id: pinArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    onClicked: root.toggleFavorite(tile.modelData)
                  }
                }
              }

              Text {
                width: root.cellWidth - Style.spacing.md * 2
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                text: tile.modelData.name
                color: root.foreground
                opacity: tile.selected ? 1 : 0.85
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
              }
            }

            HoverHandler {
              id: hover
              onHoveredChanged: {
                if (!hovered || contextMenu.visible) return
                root.interacted = true
                root.select(tile.section, tile.index)
              }
            }

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(mouse) {
                root.select(tile.section, tile.index)
                if (mouse.button === Qt.RightButton) {
                  var point = tile.mapToItem(content, mouse.x, mouse.y)
                  contextMenu.showAt(point.x, point.y)
                } else {
                  root.launch(tile.modelData)
                }
              }
            }
          }
        }

        // ---------------------------------------------------- toggle tile

        // On is carried by a filled pill plus the accent colour, not by colour
        // alone — a toggle whose only difference is hue is unreadable to anyone
        // who cannot separate the two.
        Component {
          id: toggleTileComponent

          Item {
            id: ttile
            required property var modelData
            required property int index

            readonly property bool on: ttile.modelData.on === true
            readonly property bool available: ttile.modelData.available !== false
            readonly property string section: GridView.view ? GridView.view.section : "session"
            readonly property bool selected: root.selectedSection === ttile.section && root.selectedIndex === ttile.index

            width: root.compactCellWidth
            height: root.compactCellAtRest
            opacity: ttile.available ? 1 : 0.4

            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.spacing.xs
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
              color: ttile.selected ? Style.selectedFill
                   : (toggleHover.hovered && ttile.available ? Style.hoverFill : "transparent")
              border.width: ttile.selected ? Math.max(1, Style.selectedBorderWidth) : 0
              border.color: Style.selectedBorderColor
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.xs

              Rectangle {
                id: pill
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.round(root.compactIconSize * 1.5)
                height: Math.round(root.compactIconSize * 0.92)
                radius: height / 2
                color: ttile.on ? root.accent : "transparent"
                opacity: ttile.on ? 0.22 : 1
                border.width: ttile.on ? 0 : Math.max(1, Style.normalBorderWidth)
                border.color: Style.normalBorderColor

                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                  anchors.centerIn: parent
                  text: String(ttile.modelData.monogram || "")
                  color: ttile.on ? root.accent : root.foreground
                  opacity: ttile.on ? 1 : 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(root.compactIconSize * 0.62)
                }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: ttile.modelData.name
                color: root.foreground
                opacity: ttile.on ? 1 : 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: root.compactCellWidth - Style.spacing.md
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 1
              }
            }

            HoverHandler {
              id: toggleHover
              onHoveredChanged: {
                if (!hovered || contextMenu.visible) return
                root.interacted = true
                root.select(ttile.section, ttile.index)
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: ttile.available ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: {
                root.select(ttile.section, ttile.index)
                root.runToggle(ttile.modelData)
              }
            }
          }
        }

        // ---------------------------------------------- system strip tile

        // A folder and a command look almost alike, so the chevron carries the
        // whole difference: with one, the tile opens; without, it runs.
        Component {
          id: compactTileComponent

          Item {
            id: ctile
            required property var modelData
            required property int index

            readonly property bool selected: root.selectedSection === "system" && root.selectedIndex === ctile.index

            width: root.compactCellWidth
            height: root.compactCellHeight

            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.spacing.xs
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
              color: ctile.selected ? Style.selectedFill : (compactHover.hovered ? Style.hoverFill : "transparent")
              border.width: ctile.selected ? Math.max(1, Style.selectedBorderWidth) : 0
              border.color: Style.selectedBorderColor
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.xs

              Item {
                width: root.compactIconSize
                height: root.compactIconSize
                anchors.horizontalCenter: parent.horizontalCenter

                Text {
                  anchors.centerIn: parent
                  text: String(ctile.modelData.monogram || "")
                  color: root.foreground
                  opacity: 0.9
                  font.family: ctile.modelData.iconFont ? ctile.modelData.iconFont : root.fontFamily
                  font.pixelSize: Math.round(root.compactIconSize * 0.72)
                }

                Text {
                  visible: ctile.modelData.kind === "folder"
                  // Anchored off the icon's right edge rather than inset into
                  // it: pinning the chevron's own right edge to the box put it
                  // on top of the glyph, since a Nerd Font glyph fills its em.
                  // A left anchor plus a gap cannot overlap however wide it is.
                  anchors { left: parent.right; verticalCenter: parent.verticalCenter }
                  anchors.leftMargin: Style.space(4)
                  text: "›"
                  color: root.accent
                  opacity: 0.9
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(root.compactIconSize * 0.62)
                }
              }

              Text {
                width: root.compactCellWidth - Style.spacing.md
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                text: ctile.modelData.name
                color: root.foreground
                opacity: ctile.selected ? 1 : 0.82
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              // Only while searching: a flattened match needs to say where it
              // came from, but a top-level folder does not.
              Text {
                visible: root.searching
                width: root.compactCellWidth - Style.spacing.md
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                // The folder the command sits in, not the whole trail. A tile
                // this narrow turned "Setup › Defaults › Agent" into
                // "…aults › Agent", which spends the width on an elision
                // marker and half a word. The name above already carries the
                // specifics; this only has to say where it lives.
                text: String(ctile.modelData.parentLabel || ctile.modelData.subtext || "")
                color: root.foreground
                opacity: 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                maximumLineCount: 1
              }
            }

            HoverHandler {
              id: compactHover
              onHoveredChanged: {
                if (!hovered || contextMenu.visible) return
                root.interacted = true
                root.select("system", ctile.index)
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.select("system", ctile.index)
                root.launch(ctile.modelData)
              }
            }
          }
        }

        // ---------------------------------------------------- context menu

        MouseArea {
          anchors.fill: parent
          visible: contextMenu.visible
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: contextMenu.hide()
        }

        Rectangle {
          id: contextMenu
          visible: false
          z: 10

          property var row: null
          property var items: []
          readonly property int newCount: {
            var n = 0
            for (var id in root.newIds) n++
            return n
          }

          function hide() {
            contextMenu.visible = false
            contextMenu.row = null
            contextMenu.items = []
          }

          function showForSelection() {
            var target = root.selectedRow()
            if (!target) return
            contextMenu.buildFor(target)
            contextMenu.x = (content.width - contextMenu.width) / 2
            contextMenu.y = (content.height - contextMenu.height) / 2
            contextMenu.visible = true
          }

          function showAt(px, py) {
            var target = root.selectedRow()
            if (!target) return
            contextMenu.buildFor(target)
            contextMenu.x = Math.max(0, Math.min(px, content.width - contextMenu.width))
            contextMenu.y = Math.max(0, Math.min(py, content.height - contextMenu.height))
            contextMenu.visible = true
          }

          function buildFor(target) {
            contextMenu.row = target

            // A folder only opens. A command only runs — there is no desktop
            // entry behind it, so no .desktop actions to offer and nothing for
            // omarchy-remove-launcher-entry to remove.
            if (target.kind === "folder") {
              contextMenu.items = [{ label: "Open " + target.name, kind: "launch", action: null }]
              return
            }
            if (target.kind === "command") {
              var commandEntries = [
                { label: "Run " + target.name, kind: "launch", action: null },
                contextMenu.favoriteEntry(target)
              ]
              if (root.usage[target.id])
                commandEntries.push({ label: "Reset usage ranking", kind: "reset", action: null })
              contextMenu.items = commandEntries
              return
            }

            var entries = [{ label: "Open " + target.name, kind: "launch", action: null }]

            // An agent has no desktop entry: no .desktop actions to offer, and
            // nothing for omarchy-remove-launcher-entry to remove.
            if (target.kind === "agent") {
              if (root.defaultAgent !== target.agentId)
                entries.push({ label: "Set as default agent", kind: "default-agent", action: null })
              entries.push(contextMenu.favoriteEntry(target))
              if (root.usage[target.id])
                entries.push({ label: "Reset usage ranking", kind: "reset", action: null })
              contextMenu.items = entries
              return
            }

            var actions = root.actionsFor(target)
            for (var i = 0; i < actions.length; i++)
              entries.push({ label: String(actions[i].name || "Action"), kind: "action", action: actions[i] })
            entries.push(contextMenu.favoriteEntry(target))
            if (root.usage[target.id])
              entries.push({ label: "Reset usage ranking", kind: "reset", action: null })
            entries.push({ label: "Remove from launcher…", kind: "remove", action: null })
            contextMenu.items = entries
          }

          // The star is the fast way to pin something; this is the discoverable
          // one, and the only one a keyboard can reach — the Menu key opens
          // this over whatever is selected. Pinning and frecency are separate
          // tabs now, so a row can offer both actions at once: pin it to the
          // shelf, or disown its score in the ranking.
          function favoriteEntry(target) {
            return root.isFavorite(target.id)
              ? { label: "Remove from favorites", kind: "unfavorite", action: null }
              : { label: "Add to favorites", kind: "favorite", action: null }
          }

          function run(item) {
            var target = contextMenu.row
            contextMenu.hide()
            if (!target || !item) return
            if (item.kind === "launch") root.launch(target)
            else if (item.kind === "action") root.launchAction(target, item.action)
            else if (item.kind === "default-agent") root.setDefaultAgent(target)
            else if (item.kind === "favorite" || item.kind === "unfavorite") root.toggleFavorite(target)
            else if (item.kind === "reset") root.resetUsage(target)
            else if (item.kind === "remove") root.removeEntry(target)
          }

          width: Math.min(Style.space(280), content.width)
          height: menuColumn.height + Style.spacing.sm * 2
          radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
          color: root.background
          border.width: Math.max(1, Style.normalBorderWidth)
          border.color: root.border

          MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

          Column {
            id: menuColumn
            y: Style.spacing.sm
            width: parent.width

            Repeater {
              model: contextMenu.items

              delegate: Rectangle {
                required property var modelData
                width: menuColumn.width
                height: Style.spacing.popupRowHeight
                color: itemHover.hovered ? Style.hoverFill : "transparent"

                Text {
                  anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Style.spacing.rowPaddingX
                    rightMargin: Style.spacing.rowPaddingX
                  }
                  text: modelData.label
                  color: modelData.kind === "remove" ? Color.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                HoverHandler { id: itemHover }
                MouseArea {
                  anchors.fill: parent
                  onClicked: contextMenu.run(modelData)
                }
              }
            }
          }
        }
      }
    }
  }

  onFavoriteRowsChanged: if (!root.interacted) root.resetSelection()
  onFrequentRowsChanged: if (!root.interacted) root.resetSelection()

  // Keep the keyboard selection inside the visible rows of the grids that can
  // scroll. Favorites is one of them now: pin enough and it runs out of room.
  function revealSelection() {
    if (root.selectedSection === "all") allGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    else if (root.selectedSection === "system") systemGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    else if (root.selectedSection === "favorites") favoritesGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    else if (root.selectedSection === "frequent") frequentGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
  }

  onSelectedIndexChanged: root.revealSelection()
  onSelectedSectionChanged: root.revealSelection()
}
