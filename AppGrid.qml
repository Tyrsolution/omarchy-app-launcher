import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Usage.js" as Usage
import "Agents.js" as Agents

// A centered launcher: a "Frequently used" row on top, then every installed
// application and coding agent below, alphabetical and scrollable.
//
// The app list itself is not ours: the shell's AppLibrary already watches
// DesktopEntries, filters hidden/NoDisplay entries, resolves icon names to
// files (re-indexing after an install), and launches under app-graphical.slice.
// This plugin owns presentation, frecency ordering, and the "just added" badge.
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
  readonly property var agentRoster: Agents.mergeRoster(root.customAgents)
  readonly property string agentConfigPath: Quickshell.env("HOME") + "/.config/omarchy/app-launcher/agents.json"
  // Every app with a recorded launch, widest-first. The visible row is a slice
  // of this: a binding, because rebuild() can run before the window is sized
  // and `panel.columns` is only known once it is.
  property var frequentPool: []
  readonly property var frequentRows: root.searching
    ? []
    : root.frequentPool.slice(0, Math.max(1, panel.columns))

  // Selection spans two grids, so it needs a section as well as an index.
  property string selectedSection: "all"
  property int selectedIndex: 0
  // Usage state loads from disk after the window is up, so the frequent row can
  // appear a moment after open(). Until the user touches anything, let it take
  // the caret; after that, leave the selection where they put it.
  property bool interacted: false

  // Persisted state. `usage` drives the frequent row, `seenIds` drives badges.
  property var usage: ({})
  property var seenIds: ({})
  property bool seenLoaded: false
  property var newIds: ({})

  // Tunable per summon: `omarchy-shell shell toggle tyrsolution.app-launcher '{"iconScale":1.4}'`
  property real iconScale: 1.0
  property string fontFamily: Style.font.menuFamily

  // Searching collapses the two sections into one result grid: ranking by
  // relevance and ranking by frecency at the same time reads as noise.
  readonly property bool searching: root.filterText.length > 0
  readonly property bool showFrequent: !root.searching && root.frequentRows.length > 0

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

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily
    if (Number(payload.iconScale) > 0) root.iconScale = Number(payload.iconScale)

    root.filterText = String(payload.query || "")
    contextMenu.hide()
    root.opened = true

    // Icons for packages installed since the shell started may not be in Qt's
    // theme cache yet; AppLibrary rescans on demand.
    if (root.appLibrary) root.appLibrary.refreshIcons()
    // Re-probe the agent roster on every summon, so an agent installed since
    // the last open shows up without a shell restart.
    root.probeAgents()
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

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------ app list

  function liveIdMap() {
    var out = ({})
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
    if (!root.appLibrary) { root.allRows = []; root.frequentPool = []; return }
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
    root.frequentPool = root.pickFrequent(out)
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

  // Apps with no recorded launch never appear here, so a fresh install shows no
  // section at all rather than an arbitrary one.
  function pickFrequent(rows) {
    var scored = []
    for (var i = 0; i < rows.length; i++)
      if (rows[i].score > 0) scored.push(rows[i])
    Usage.sortByScore(scored)
    return scored
  }

  function setFilter(next) {
    root.filterText = next
    root.rebuild()
    root.resetSelection()
    allGrid.positionViewAtBeginning()
  }

  function rowsFor(section) {
    return section === "frequent" ? root.frequentRows : root.allRows
  }

  function rowAt(section, index) {
    var rows = root.rowsFor(section)
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
    root.select(root.showFrequent ? "frequent" : "all", 0)
  }

  function clampSelection() {
    var rows = root.rowsFor(root.selectedSection)
    if (rows.length === 0) { root.resetSelection(); return }
    if (root.selectedIndex >= rows.length) root.selectedIndex = rows.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  // Arrow keys move within a section; up/down cross the divider, keeping the
  // column so the caret lands where the eye expects it.
  function moveSelection(dx, dy) {
    root.interacted = true
    var columns = Math.max(1, panel.columns)
    var rows = root.rowsFor(root.selectedSection)
    if (rows.length === 0) return

    if (dx !== 0) {
      root.selectedIndex = Math.max(0, Math.min(rows.length - 1, root.selectedIndex + dx))
      return
    }

    var column = root.selectedIndex % columns
    if (dy > 0) {
      if (root.selectedSection === "frequent") {
        if (root.allRows.length === 0) return
        root.select("all", Math.min(column, root.allRows.length - 1))
        return
      }
      root.selectedIndex = Math.min(rows.length - 1, root.selectedIndex + columns)
      return
    }

    if (root.selectedSection === "all" && root.selectedIndex < columns) {
      if (!root.showFrequent) return
      root.select("frequent", Math.min(column, root.frequentRows.length - 1))
      return
    }
    root.selectedIndex = Math.max(0, root.selectedIndex - columns)
  }

  // ------------------------------------------------------------ launching

  function launch(row) {
    if (!row) return
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

  function markAllSeen() {
    var live = root.liveIdMap()
    root.seenIds = live
    root.newIds = ({})
    seenFile.setText(Usage.serializeSeen(live))
    // An app that is gone has no score worth keeping.
    var pruned = Usage.prune(root.usage, live)
    if (JSON.stringify(pruned) !== JSON.stringify(root.usage)) {
      root.usage = pruned
      root.persistUsage()
    }
  }

  function persistUsage() {
    usageFile.setText(Usage.serializeUsage(root.usage))
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
    onExited: {
      root.installedAgents = root.pendingAgents.slice()
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
      height: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)
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
          if (contextMenu.visible) {
            if (event.key === Qt.Key_Escape) { contextMenu.hide(); event.accepted = true }
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
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
            root.select("all", Math.max(0, root.allRows.length - 1)); event.accepted = true
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

        Item {
          id: header
          anchors { top: parent.top; left: parent.left; right: parent.right }
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

        // ------------------------------------------------- frequently used

        Text {
          id: frequentLabel
          visible: root.showFrequent
          anchors { top: headerRule.bottom; left: parent.left }
          height: visible ? root.sectionLabelHeight : 0
          verticalAlignment: Text.AlignVCenter
          text: "Frequently used"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        GridView {
          id: frequentGrid
          visible: root.showFrequent
          anchors { top: frequentLabel.bottom; horizontalCenter: parent.horizontalCenter }
          width: panel.gridWidth
          height: visible ? root.cellHeight : 0
          cellWidth: root.cellWidth
          cellHeight: root.cellHeight
          interactive: false
          clip: true
          model: root.frequentRows
          delegate: tileComponent

          property string section: "frequent"
        }

        Rectangle {
          id: sectionRule
          visible: root.showFrequent
          anchors { top: frequentGrid.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: visible ? Style.spacing.sm : 0
          height: visible ? Math.max(1, Style.space(1)) : 0
          color: root.foreground
          opacity: 0.12
        }

        // ------------------------------------------------------- all apps

        Text {
          id: allLabel
          visible: root.showFrequent
          anchors { top: sectionRule.bottom; left: parent.left }
          height: visible ? root.sectionLabelHeight : 0
          verticalAlignment: Text.AlignVCenter
          text: "All apps"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Item {
          id: allArea
          anchors {
            top: allLabel.visible ? allLabel.bottom : headerRule.bottom
            bottom: footer.top
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
            model: root.allRows
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
          visible: root.allRows.length === 0
          text: root.filterText ? "No apps match “" + root.filterText + "”" : "No applications found"
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---------------------------------------------------------- footer

        Item {
          id: footer
          anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
          height: root.footerHeight

          Text {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            text: "type to search · ↵ launch · right-click for actions · esc close"
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

            Column {
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
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(monogram.width * 0.42)
                  }
                }

                // "Just added": this .desktop file appeared since the last
                // time the grid was closed.
                Rectangle {
                  visible: tile.modelData.isNew === true
                  anchors { right: parent.right; top: parent.top }
                  anchors.rightMargin: -Style.space(2)
                  anchors.topMargin: -Style.space(2)
                  width: Style.space(9)
                  height: width
                  radius: width / 2
                  color: root.accent
                  border.width: Math.max(1, Style.space(1))
                  border.color: root.background
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
            var entries = [{ label: "Open " + target.name, kind: "launch", action: null }]

            // An agent has no desktop entry: no .desktop actions to offer, and
            // nothing for omarchy-remove-launcher-entry to remove.
            if (target.kind === "agent") {
              if (root.defaultAgent !== target.agentId)
                entries.push({ label: "Set as default agent", kind: "default-agent", action: null })
              if (root.usage[target.id]) entries.push({ label: "Reset usage ranking", kind: "reset", action: null })
              contextMenu.items = entries
              return
            }

            var actions = root.actionsFor(target)
            for (var i = 0; i < actions.length; i++)
              entries.push({ label: String(actions[i].name || "Action"), kind: "action", action: actions[i] })
            if (root.usage[target.id]) entries.push({ label: "Reset usage ranking", kind: "reset", action: null })
            entries.push({ label: "Remove from launcher…", kind: "remove", action: null })
            contextMenu.items = entries
          }

          function run(item) {
            var target = contextMenu.row
            contextMenu.hide()
            if (!target || !item) return
            if (item.kind === "launch") root.launch(target)
            else if (item.kind === "action") root.launchAction(target, item.action)
            else if (item.kind === "default-agent") root.setDefaultAgent(target)
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

  onFrequentRowsChanged: if (!root.interacted) root.resetSelection()

  // Keep the keyboard selection inside the visible rows of the all-apps grid.
  onSelectedIndexChanged: if (root.selectedSection === "all") allGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
  onSelectedSectionChanged: if (root.selectedSection === "all") allGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
}
