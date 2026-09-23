import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// The manager: create/restyle groups and move widgets between the bar and a group.
// EVERY change here — appearance or membership — is STAGED into `draft` and only
// written with one Apply click, because any of them rewrites bar.layout and the
// shell rebuilds the whole bar (this panel included) on each write. Batching is
// what keeps typing a label or clicking through display options from reopening
// the panel after every keystroke.
KeyboardPanel {
  id: panel

  property var svc: null
  property string pluginId: ""
  property var groups: []              // every Mini-Bar entry on the bar (from the live layout)
  property string focusGroupId: ""

  signal closeRequested()

  property QtObject ownerObj: QtObject {
    property bool popoutSwitchClosing: false
    function close() { panel.closeRequested() }
    function closeForPopoutSwitch() {
      popoutSwitchClosing = true
      panel.closeRequested()
      Qt.callLater(function() { ownerObj.popoutSwitchClosing = false })
    }
  }
  owner: ownerObj

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color accent: Color.accent
  readonly property string mono: bar ? bar.fontFamily : Style.font.family
  readonly property string nerdFontUrl: "https://www.nerdfonts.com/cheat-sheet"

  // Some widgets resolve their OWN background service via
  // bar.shell.serviceFor(ownId)/firstPartyServiceFor(ownId), which the shell
  // only permits when a plugin is asking for its own service — asking through
  // Mini-Bar's bar.shell fails that check and returns null, so the widget is
  // stuck showing its first-run/default state while hosted. This is enforced
  // by the trusted shell host; there's no fix on Mini-Bar's side, only a
  // warning so it's not a surprise. (Found 2026-09-22 via My Plugins.)
  //
  // No way to ask the shell "does widget X do this" directly — a third-party
  // plugin's own pluginRegistry only ever contains ITS OWN entry, confirmed
  // live (same trust boundary as the serviceFor() call itself). What DOES
  // work: every user-installed plugin lives at a known, fixed path
  // (~/.config/omarchy/plugins/<id>/), and nothing stops Mini-Bar reading a
  // file there directly — that's plain filesystem access, not something the
  // shell's plugin sandbox governs. `bin/minibar-ops compat` greps a
  // candidate's own source for the risky call pattern — the exact grep that
  // originally found all four of these plugins by hand — so this now covers
  // ANY user's installed plugins automatically, not just a hardcoded list
  // seeded from what happened to be installed here.
  property var riskyIds: ({})      // {id: true, ...} — confirmed risky so far
  property var _riskyChecked: ({}) // {id: true, ...} — already asked about, don't re-ask

  function _scanCompat(ids) {
    var toCheck = ids.filter(function(id) { return !_riskyChecked[id] })
    if (toCheck.length === 0 || !svc) return
    var checked = {}
    for (var k in _riskyChecked) checked[k] = true
    for (var i = 0; i < toCheck.length; i++) checked[toCheck[i]] = true
    _riskyChecked = checked
    svc.runOps(["compat", JSON.stringify(toCheck)], function(code, text) {
      if (code !== 0) return
      var risky
      try { risky = JSON.parse(text) } catch (e) { return }
      if (!Array.isArray(risky) || risky.length === 0) return
      var next = {}
      for (var k2 in panel.riskyIds) next[k2] = true
      for (var j = 0; j < risky.length; j++) next[risky[j]] = true
      panel.riskyIds = next
    })
  }

  function warningFor(id) {
    return riskyIds[id] ? "may lose its own live status/settings" : ""
  }

  onCandidatesChanged: _scanCompat(candidates.map(function(c) { return c.id }))
  onElsewhereChanged: _scanCompat(elsewhere.map(function(e) { return e.id }))

  readonly property string note: svc ? svc.lastOpsError : ""

  property string selectedGid: ""
  readonly property var selected: {
    for (var i = 0; i < groups.length; i++) if (groups[i].gid === selectedGid) return groups[i]
    return groups.length > 0 ? groups[0] : null
  }
  readonly property string sel: selected ? selected.gid : ""
  readonly property bool busy: (svc ? svc.opsBusy : false) || settle.running
  property bool confirmDissolve: false

  // Staged changes, applied together in order:
  //   {op:"assign"|"unassign", gid, wid}
  //   {op:"set", gid, key, value}
  //   {op:"reorder", gid, order}
  property var draft: []

  // Drag-to-reorder within "IN THIS GROUP" — same left-button-only classify-
  // click-vs-drag gesture as the live mini-bar strip's own drag (MiniBar.qml),
  // but staged into `draft` like everything else here rather than applied
  // immediately: dragging a grip is a deliberate, discrete gesture, not
  // something that needs an Apply step of its own, but it still shouldn't
  // jump the queue and write to disk (and trigger the rebuild that comes with
  // it) ahead of whatever else is staged.
  property int memberDragFrom: -1
  property int memberDragOver: -1
  readonly property bool memberDragging: memberDragFrom >= 0

  function beginMemberDrag(index) { memberDragFrom = index; memberDragOver = index }

  // Deliberately NOT coordinate-mapping the pointer into the outer column's
  // space and comparing against each row's absolute y — confirmed live that
  // was badly miscalibrated (always landed on the last row; had to drag far
  // past a row to reach it), and this list lives inside a KeyboardPanel
  // (itself a PanelWindow) inside a Flickable, several coordinate-space hops
  // where something was going wrong that wasn't worth chasing further.
  // Instead: purely relative to the SAME MouseArea's own press point — how
  // many row-heights has the pointer moved since grabbing it — which needs no
  // cross-item mapping at all and is immune to whatever that was.
  function updateMemberDragOver(fromIndex, deltaY) {
    if (memberDragFrom < 0) return
    var memberIdx = []
    for (var i = 0; i < memberRepeater.count; i++) {
      var row = memberRepeater.itemAt(i)
      if (row && row.rowState === "member") memberIdx.push(i)
    }
    if (memberIdx.length === 0) return
    var fromPos = memberIdx.indexOf(fromIndex)
    if (fromPos < 0) return

    // Row-to-row step size, measured directly off the real laid-out y of the
    // first and last draggable row, not summed from each row's own height —
    // confirmed live the first version (sum of heights / count) drifted worse
    // the further you dragged, because it left out the Column's own `spacing`
    // between rows entirely. Measuring the actual span end to end folds that
    // spacing (and anything else sitting between rows) in automatically.
    var avgStep = 40
    if (memberIdx.length > 1) {
      var firstRow = memberRepeater.itemAt(memberIdx[0])
      var lastRow = memberRepeater.itemAt(memberIdx[memberIdx.length - 1])
      if (firstRow && lastRow) avgStep = (lastRow.y - firstRow.y) / (memberIdx.length - 1)
    }
    if (avgStep <= 0) return

    var steps = Math.round(deltaY / avgStep)
    var targetPos = Math.max(0, Math.min(memberIdx.length - 1, fromPos + steps))
    memberDragOver = memberIdx[targetPos]
  }

  function commitMemberDrag() {
    var from = memberDragFrom, to = memberDragOver
    memberDragFrom = -1
    memberDragOver = -1
    if (from < 0 || to < 0 || from === to) return
    var order = memberRows.filter(function(r) { return r.state === "member" }).map(function(r) { return r.id })
    var fromId = memberRows[from] ? memberRows[from].id : null
    var toId = memberRows[to] ? memberRows[to].id : null
    var fromIdx = order.indexOf(fromId), toIdx = order.indexOf(toId)
    if (fromIdx < 0 || toIdx < 0) return
    var moved = order.splice(fromIdx, 1)[0]
    order.splice(toIdx, 0, moved)
    stageReorder(order)
  }

  function cancelMemberDrag() { memberDragFrom = -1; memberDragOver = -1 }

  property Timer settleTimer: Timer { id: settle; interval: 800 }
  property Timer dissolveTimer: Timer { id: dissolveReset; interval: 3000; onTriggered: panel.confirmDissolve = false }
  property QtObject opsWatcher: Connections {
    target: panel.svc
    function onOpsFinished() { settle.restart() }
  }

  onOpenChanged: {
    confirmDissolve = false
    cancelMemberDrag()
    if (open) {
      draft = []
      if (focusGroupId !== "") selectedGid = focusGroupId
      syncLabelField()
    } else {
      draft = []
    }
  }

  // The label field is a plain (unbound) TextField so typing isn't fighting a
  // live binding — resync it explicitly whenever the selected group changes.
  // suppressStage guards this programmatic assignment from being mistaken
  // for a real edit and staging a spurious no-op "set" the instant the panel
  // opens or the selected group changes (onTextChanged fires for ANY text
  // change, including one Mini-Bar itself makes, not just typing).
  function syncLabelField() {
    labelField.suppressStage = true
    labelField.text = effectiveValue("label", "")
    labelField.suppressStage = false
  }
  onSelectedGidChanged: { syncLabelField(); cancelMemberDrag() }

  // ---- staging ----------------------------------------------------------
  function hasStaged(op, gid, wid) {
    for (var i = 0; i < draft.length; i++)
      if (draft[i].op === op && draft[i].gid === gid && draft[i].wid === wid) return true
    return false
  }

  function dropStaged(op, gid, wid) {
    draft = draft.filter(function(d) { return !(d.op === op && d.gid === gid && d.wid === wid) })
  }

  // Adding a widget to a group cancels any other staged add of the same widget.
  function stageAdd(wid) {
    if (!selected) return
    var kept = draft.filter(function(d) { return !(d.op === "assign" && d.wid === wid) })
    kept.push({ op: "assign", gid: selected.gid, wid: wid })
    draft = kept
  }

  function stageReturn(gid, wid) {
    if (hasStaged("unassign", gid, wid)) return
    draft = draft.concat([{ op: "unassign", gid: gid, wid: wid }])
  }

  // Appearance settings: stage the new value; a second edit to the same field
  // before Apply just replaces the pending value rather than stacking up.
  function stageSet(key, value) {
    if (!selected) return
    var kept = draft.filter(function(d) { return !(d.op === "set" && d.gid === selected.gid && d.key === key) })
    kept.push({ op: "set", gid: selected.gid, key: key, value: value })
    draft = kept
  }

  // Per-member override for Mini-Bar's own badge-count auto-detect (see
  // MiniBar.qml's badgeCandidates comment) — a manual escape hatch for a
  // plugin whose own property name isn't on that best-effort list. A second
  // edit before Apply replaces the pending value, same as stageSet.
  function stageMemberSet(wid, key, value) {
    if (!selected) return
    var kept = draft.filter(function(d) { return !(d.op === "memberSet" && d.gid === selected.gid && d.wid === wid && d.key === key) })
    kept.push({ op: "memberSet", gid: selected.gid, wid: wid, key: key, value: value })
    draft = kept
  }

  function effectiveMemberValue(gid, wid, key, fallback) {
    for (var i = draft.length - 1; i >= 0; i--) {
      var d = draft[i]
      if (d.op === "memberSet" && d.gid === gid && d.wid === wid && d.key === key) return d.value
    }
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].gid !== gid) continue
      var ms = groups[g].members || []
      for (var m = 0; m < ms.length; m++) if (ms[m].id === wid) return ms[m][key] === undefined ? fallback : ms[m][key]
    }
    return fallback
  }

  // Dragging a row in "IN THIS GROUP" stages a full new order for the
  // SELECTED group; a second drag before Apply just replaces it, same as
  // stageSet. Applied UNDERNEATH assign/unassign staging when building
  // memberRows below — reorder the real members first, then layer "adding"/
  // "leaving" markers on top, so the two kinds of staged change compose.
  function stageReorder(order) {
    if (!selected) return
    var kept = draft.filter(function(d) { return !(d.op === "reorder" && d.gid === selected.gid) })
    kept.push({ op: "reorder", gid: selected.gid, order: order })
    draft = kept
  }

  function effectiveOrder(gid, members) {
    for (var i = draft.length - 1; i >= 0; i--) {
      var d = draft[i]
      if (d.op !== "reorder" || d.gid !== gid) continue
      var byId = {}
      for (var j = 0; j < members.length; j++) byId[members[j].id] = members[j]
      var next = []
      for (var k = 0; k < d.order.length; k++) if (byId[d.order[k]]) { next.push(byId[d.order[k]]); delete byId[d.order[k]] }
      for (var leftoverId in byId) next.push(byId[leftoverId])
      return next
    }
    return members
  }

  // What a control should show: the staged value for the SELECTED group if
  // there is one, else the value already committed to shell.json.
  function effectiveValue(key, fallback) {
    if (!selected) return fallback
    for (var i = draft.length - 1; i >= 0; i--) {
      var d = draft[i]
      if (d.op === "set" && d.gid === selected.gid && d.key === key) return d.value
    }
    var v = selected[key]
    return v === undefined ? fallback : v
  }

  function discard() { draft = [] }

  // ---- talking to the helper -------------------------------------------
  readonly property string screenName: anchorWindow && anchorWindow.screen ? anchorWindow.screen.name : ""

  function apply() {
    if (!svc || busy || draft.length === 0) return
    svc.lastOpsError = ""
    svc.rememberManager(sel, screenName)
    var ops = draft
    draft = []
    svc.runOps(["apply", JSON.stringify(ops)])
  }

  function newGroup() {
    if (!svc || busy) return
    var gid = svc.newGroupId()
    svc.lastOpsError = ""
    svc.rememberManager(gid, screenName)
    svc.runOps(["create", gid, "Group " + (groups.length + 1), sel])
  }

  function dissolve() {
    if (!svc || busy || !selected) return
    var other = ""
    for (var i = 0; i < groups.length; i++) if (groups[i].gid !== selected.gid) { other = groups[i].gid; break }
    svc.lastOpsError = ""
    svc.rememberManager(other, screenName)
    svc.runOps(["apply", JSON.stringify([{ op: "dissolve", gid: selected.gid }])])
  }

  function applyGlyphText(raw) {
    var t = String(raw || "").trim()
    if (t === "") return
    var hex = t.match(/^(?:U\+|0x)?([0-9a-fA-F]{4,6})$/)
    var glyph = hex ? String.fromCodePoint(parseInt(hex[1], 16)) : Array.from(t)[0]
    if (glyph) stageSet("glyph", glyph)
  }

  // ---- derived lists ---------------------------------------------------
  // Rows for the selected group: real members (in their staged drag order, if
  // any), marked if staged to leave, plus staged adds.
  readonly property var memberRows: {
    var out = []
    if (!selected) return out
    var have = {}
    var ms = effectiveOrder(selected.gid, selected.members || [])
    for (var i = 0; i < ms.length; i++) {
      have[ms[i].id] = true
      out.push({ id: ms[i].id, state: hasStaged("unassign", selected.gid, ms[i].id) ? "leaving" : "member" })
    }
    for (var j = 0; j < draft.length; j++) {
      var d = draft[j]
      if (d.op === "assign" && d.gid === selected.gid && !have[d.wid]) out.push({ id: d.wid, state: "adding" })
    }
    return out
  }

  // On the bar right now (not in any group, not already staged into one).
  readonly property var candidates: {
    var layout = bar && bar.layoutConfig ? bar.layoutConfig : ({})
    var staged = {}
    for (var d = 0; d < draft.length; d++) if (draft[d].op === "assign") staged[draft[d].wid] = true
    var cats = {}
    if (selected) for (var m = 0; m < (selected.members || []).length; m++) if (svc) cats[svc.categoryOf(selected.members[m].id)] = true
    var have = {}
    var out = []
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = layout[sections[s]] || []
      for (var i = 0; i < arr.length; i++) {
        var id = typeof arr[i] === "string" ? arr[i] : (arr[i] ? arr[i].id : "")
        if (!id || have[id] || staged[id] || id === pluginId || /\.spacer$/.test(id)) continue
        if (!svc || svc.componentFor(id) === null) continue
        have[id] = true
        var cat = svc.categoryOf(id)
        out.push({ id: id, name: svc.displayName(id), category: cat, suggested: cats[cat] === true, warning: panel.warningFor(id) })
      }
    }
    // Plain alphabetical — easier to scan for one specific plugin by name than
    // a suggested-first/category-grouped order would be. The ★ suggested
    // marker and category still show per-row, just don't drive the sort.
    out.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return out
  }

  // Members of OTHER groups, offered as "move here".
  readonly property var elsewhere: {
    var out = []
    if (!selected) return out
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].gid === selected.gid) continue
      var ms = groups[g].members || []
      for (var i = 0; i < ms.length; i++) {
        if (hasStaged("assign", selected.gid, ms[i].id)) continue
        out.push({ id: ms[i].id, name: svc ? svc.displayName(ms[i].id) : ms[i].id, from: groups[g].label || "Group", warning: panel.warningFor(ms[i].id) })
      }
    }
    return out
  }

  readonly property real footerH: draft.length > 0 ? Style.space(52) : 0

  readonly property var glyphPresets: [
    "󰒓", "󰀻", "󰈀", "󰖩", "󰂯", "󰕾", "󰝚", "󰍹", "󰍺", "󰄀", "󰓅", "󰌾",
    "󰅌", "󰃭", "󰈙", "󰋩", "󰐥", "󰂚", "󰌌", "󰋋", "󰔎", "󰻂", "󰅶", "󰤨"
  ]

  contentWidth: panel.fittedContentWidth(Style.space(560))
  contentHeight: panel.fittedContentHeight(column.implicitHeight + footerH, Style.space(700))

  // Very faint bubbles rising from the bottom — the boozy flourish. Sits
  // behind everything else (declared first, and z below to be safe); none of
  // the content above paints an opaque background of its own, so this shows
  // through the whitespace between rows instead of hiding behind them.
  // `paused` (not `running`) tracks `panel.open` so a closed panel costs
  // nothing but a reopen resumes mid-rise instead of restarting from zero.
  Item {
    id: bubbles
    anchors.fill: parent
    clip: true
    z: -1

    Repeater {
      model: 7
      delegate: Rectangle {
        id: bubble
        required property int index
        property real bx: 0.1 + Math.random() * 0.8
        property real bsize: Style.space(3 + Math.random() * 4)
        property int bspeed: 5000 + Math.random() * 4500
        property int bdelay: Math.random() * 6000

        radius: width / 2
        width: bsize
        height: bsize
        x: bx * Math.max(0, bubbles.width - width)
        color: Qt.rgba(panel.accent.r, panel.accent.g, panel.accent.b, 0.12)

        SequentialAnimation {
          running: true
          paused: !panel.open
          PauseAnimation { duration: bubble.bdelay }
          NumberAnimation {
            target: bubble
            property: "y"
            from: bubbles.height
            to: -bubble.bsize
            duration: bubble.bspeed
            loops: Animation.Infinite
          }
        }
      }
    }
  }

  PanelKeyCatcher {
    id: keys
    anchors.fill: parent
    blocked: labelField.activeFocus || glyphField.activeFocus
    onCloseRequested: panel.closeRequested()

    Flickable {
      id: flick
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: applyBar.top
      anchors.bottomMargin: panel.draft.length > 0 ? Style.space(8) : 0
      contentWidth: width
      contentHeight: column.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      clip: true

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        Row {
          spacing: Style.space(8)
          Text {
            text: ""
            color: panel.accent
            font.family: panel.mono
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            text: "MINI-BAR"
            color: panel.accent
            font.family: panel.mono
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            text: panel.busy ? "· POURING…" : ""
            color: panel.dim
            font.family: panel.mono
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: panel.note !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: panel.mono
          font.pixelSize: Style.font.caption
          text: panel.note
        }

        SectionTitle { text: "GROUPS"; width: parent.width }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: panel.groups
            delegate: Button {
              required property var modelData
              text: (modelData.label || "Group") + " · " + (modelData.members || []).length + " · " + modelData.section
              iconText: modelData.glyph || ""
              bordered: true
              selected: modelData.gid === panel.sel
              foreground: panel.fg
              onClicked: { panel.selectedGid = modelData.gid; panel.confirmDissolve = false }
            }
          }

          Button {
            text: "+ NEW GROUP"
            bordered: true
            foreground: panel.accent
            enabled: !panel.busy
            onClicked: panel.newGroup()
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          color: panel.dim
          font.family: panel.mono
          font.pixelSize: Style.font.caption
          text: panel.groups.length === 0
            ? "No groups yet. Create one, then move widgets from your bar into it."
            : "Each group is its own icon on the bar. Drag it anywhere, like any other widget."
        }

        Column {
          visible: panel.selected !== null
          width: parent.width
          spacing: Style.space(12)

          SectionTitle { text: "APPEARANCE"; width: parent.width }

          Row {
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "LABEL"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
            TextField {
              id: labelField
              width: Style.space(260)
              foreground: panel.fg
              // Was staged on editingFinished (Enter or blur) — confirmed
              // live that's not reliable enough: renaming a group then
              // moving straight to another control sometimes never staged
              // at all. Staging is a cheap, local draft update, not a
              // shell.json write, so there's no reason to wait for a
              // specific dismissal gesture — stage on every keystroke
              // instead, same as every other control in this panel already
              // does immediately on change.
              property bool suppressStage: false
              onTextChanged: if (!suppressStage && panel.selected) panel.stageSet("label", text)
            }
          }

          Row {
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "BAR FACE"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
            ButtonGroup {
              options: [{ value: "glyph", label: "GLYPH" }, { value: "text", label: "TEXT" }, { value: "both", label: "BOTH" }]
              value: panel.effectiveValue("face", "glyph")
              foreground: panel.fg
              accent: panel.accent
              onChanged: function(v) { panel.stageSet("face", v) }
            }
          }

          Row {
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "HOVER TIP"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
            ButtonGroup {
              options: [{ value: "on", label: "ON" }, { value: "off", label: "OFF" }]
              value: {
                var fallback = panel.effectiveValue("face", "glyph") === "glyph"
                return panel.effectiveValue("tooltip", fallback) === true ? "on" : "off"
              }
              foreground: panel.fg
              accent: panel.accent
              onChanged: function(v) { panel.stageSet("tooltip", v === "on") }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "group name on hover"
              color: panel.dim
              font.family: panel.mono
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "BADGE"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
            ButtonGroup {
              options: [{ value: "on", label: "ON" }, { value: "off", label: "OFF" }]
              value: panel.effectiveValue("badge", true) === false ? "off" : "on"
              foreground: panel.fg
              accent: panel.accent
              onChanged: function(v) { panel.stageSet("badge", v === "on") }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "notification count on the group's icon"
              color: panel.dim
              font.family: panel.mono
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            visible: panel.effectiveValue("badge", true) !== false
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "BADGE MODE"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
            ButtonGroup {
              options: [{ value: "sum", label: "SUM" }, { value: "members", label: "COUNT" }]
              value: panel.effectiveValue("badgeMode", "sum")
              foreground: panel.fg
              accent: panel.accent
              onChanged: function(v) { panel.stageSet("badgeMode", v) }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: panel.effectiveValue("badgeMode", "sum") === "members" ? "# of members with something pending" : "add every member's own count together"
              color: panel.dim
              font.family: panel.mono
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "STRIP"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
            ButtonGroup {
              options: [{ value: "auto", label: "AUTO" }, { value: "horizontal", label: "ROW" }, { value: "vertical", label: "COLUMN" }]
              value: panel.effectiveValue("orientation", "auto")
              foreground: panel.fg
              accent: panel.accent
              onChanged: function(v) { panel.stageSet("orientation", v) }
            }
          }

          Row {
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "MEMBERS SHOW"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
            ButtonGroup {
              options: [{ value: "native", label: "ICON" }, { value: "name", label: "NAME" }, { value: "both", label: "BOTH" }]
              value: panel.effectiveValue("memberDisplay", "native")
              foreground: panel.fg
              accent: panel.accent
              onChanged: function(v) { panel.stageSet("memberDisplay", v) }
            }
          }

          Row {
            spacing: Style.space(10)
            Text { width: Style.space(96); text: "GLYPH"; color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption; anchors.top: parent.top; topPadding: Style.space(4) }
            Column {
              spacing: Style.space(6)
              Flow {
                width: Style.space(410)
                spacing: Style.space(2)
                Repeater {
                  model: panel.glyphPresets
                  delegate: Rectangle {
                    required property string modelData
                    width: Style.space(30); height: Style.space(30)
                    radius: Style.cornerRadius
                    readonly property bool chosen: panel.selected && panel.effectiveValue("glyph", "") === modelData
                    color: chosen ? Qt.rgba(panel.accent.r, panel.accent.g, panel.accent.b, 0.22) : (hit.containsMouse ? Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.10) : "transparent")
                    border.width: chosen ? 1 : 0
                    border.color: panel.accent
                    Text {
                      anchors.centerIn: parent
                      text: parent.modelData
                      color: parent.chosen ? panel.accent : panel.fg
                      font.family: panel.mono
                      font.pixelSize: Style.font.icon
                    }
                    MouseArea { id: hit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.stageSet("glyph", parent.modelData) }
                  }
                }
              }
              TextField {
                id: glyphField
                width: Style.space(300)
                placeholderText: "any Nerd Font glyph, or hex (f0493)"
                foreground: panel.fg
                // editingFinished covers BOTH "pressed Enter" and "lost
                // focus" — using just this one signal instead of the
                // Enter-only `accepted` closes a real gap: typing a hex code
                // then clicking straight into something else (Apply, another
                // field) without pressing Enter first silently dropped the
                // edit, since accepted never fired. Confirmed live: "applied,
                // but still shows the old icon."
                onEditingFinished: { panel.applyGlyphText(text); text = ""; focus = false }
              }
              Text {
                text: "Browse all Nerd Font glyphs ↗"
                color: linkHit.containsMouse ? Qt.lighter(panel.accent, 1.3) : panel.accent
                font.family: panel.mono
                font.pixelSize: Style.font.caption
                font.underline: true
                MouseArea {
                  id: linkHit
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: Quickshell.execDetached(["xdg-open", panel.nerdFontUrl])
                }
              }
              Text {
                width: Style.space(410)
                wrapMode: Text.WordWrap
                text: "click a glyph on the site to copy it, then paste it above and press Enter"
                color: panel.dim
                font.family: panel.mono
                font.pixelSize: Style.font.caption
              }
            }
          }

          SectionTitle { text: "IN THIS GROUP"; width: parent.width }

          Text {
            visible: panel.memberRows.length === 0
            color: panel.dim
            font.family: panel.mono
            font.pixelSize: Style.font.body
            text: "Empty. Add widgets from the lists below."
          }

          Text {
            visible: panel.memberRows.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            color: panel.dim
            font.family: panel.mono
            font.pixelSize: Style.font.caption
            text: "The group's own icon sums each member's notification count automatically where it can find one. If a member's count doesn't show up, type its own property name in \"badge\" — leave blank to keep auto-detecting, or type \"none\" to never count that member at all."
          }

          Repeater {
            id: memberRepeater
            model: panel.memberRows

            delegate: Item {
              id: memberRow
              required property var modelData
              required property int index
              readonly property string rowState: modelData.state
              width: column.width
              height: rowContent.implicitHeight + Style.space(6)
              opacity: panel.memberDragFrom === index ? 0.4 : 1

              // Drop target feedback, same idiom as the live strip's own drag.
              Rectangle {
                visible: panel.memberDragging && panel.memberDragOver === memberRow.index && panel.memberDragFrom !== memberRow.index
                anchors.fill: parent
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 2
                border.color: panel.accent
              }

              Row {
                id: rowContent
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                spacing: Style.space(8)

                // Drag handle. Only real members have a stable position to drag
                // (a staged add/return doesn't), and keeping the grip separate
                // from the rest of the row means dragging never fights the
                // Flickable's own scroll gesture or the RETURN/UNDO button.
                Item {
                  id: gripIcon
                  width: Style.space(18)
                  height: parent.height

                  Text {
                    visible: memberRow.rowState === "member"
                    anchors.centerIn: parent
                    text: "⣿"
                    color: gripHit.pressed ? panel.accent : panel.dim
                    font.family: panel.mono
                    font.pixelSize: Style.font.body
                  }
                }

                Text {
                  id: nameText
                  width: parent.width - rowBtn.width - (memberRow.rowState === "member" ? badgeField.width : 0) - Style.space(18) - Style.space(8) * (memberRow.rowState === "member" ? 3 : 2)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: modelData.state === "member" ? panel.fg : panel.accent
                  opacity: modelData.state === "leaving" ? 0.55 : 1
                  font.family: panel.mono
                  font.pixelSize: Style.font.body
                  font.strikeout: modelData.state === "leaving"
                  text: (modelData.state === "adding" ? "＋ " : (modelData.state === "leaving" ? "↩ " : "● "))
                    + (panel.svc ? panel.svc.displayName(modelData.id) : modelData.id)
                    + (modelData.state === "adding" ? "   (staged)" : (modelData.state === "leaving" ? "   (returns to bar)" : ""))
                }
                // Manual override for Mini-Bar's own badge-count auto-detect,
                // only offered for a real (already-committed) member — a
                // staged add/return has no settled property to read yet.
                // Empty means "keep auto-detecting" (see badgeCandidates in
                // MiniBar.qml); this is the escape hatch for the rare plugin
                // that isn't on that list.
                TextField {
                  id: badgeField
                  visible: memberRow.rowState === "member"
                  width: visible ? Style.space(120) : 0
                  foreground: panel.dim
                  placeholderText: "badge: auto"
                  font.pixelSize: Style.font.caption
                  horizontalPadding: Style.space(6)
                  text: memberRow.rowState === "member" ? panel.effectiveMemberValue(panel.sel, modelData.id, "badgeProperty", "") : ""
                  onEditingFinished: panel.stageMemberSet(modelData.id, "badgeProperty", text.trim())
                }
                Button {
                  id: rowBtn
                  text: modelData.state === "member" ? "↩ RETURN TO BAR" : "UNDO"
                  bordered: true
                  foreground: panel.fg
                  onClicked: {
                    if (modelData.state === "member") panel.stageReturn(panel.sel, modelData.id)
                    else if (modelData.state === "leaving") panel.dropStaged("unassign", panel.sel, modelData.id)
                    else panel.dropStaged("assign", panel.sel, modelData.id)
                  }
                }
              }

              // Grab area, widened to cover the grip icon AND the name text —
              // same idea as widening the live strip's click target to the
              // whole cell (MiniBar.qml) so a label isn't a miss: the visible
              // grip glyph stays put in its own narrow column, but you
              // shouldn't have to hit that exact few pixels to start a drag.
              // A sibling overlay on top of `rowContent` rather than a wider
              // child inside it, since a Row lays its children out side by
              // side and can't have one child visually span two others.
              // Stops short of badgeField/rowBtn so their own click/type/
              // focus handling is completely untouched.
              MouseArea {
                id: gripHit
                visible: memberRow.rowState === "member"
                enabled: memberRow.rowState === "member"
                x: 0
                y: 0
                width: gripIcon.width + rowContent.spacing + nameText.width
                height: parent.height
                acceptedButtons: Qt.LeftButton
                // This whole panel scrolls in a Flickable, and Flickable's
                // default behavior is to grab a drag away from a child
                // MouseArea once it moves — confirmed live: pressing and
                // dragging the grip just scrolled the list instead of
                // reordering. This is exactly what preventStealing exists
                // for: a child MouseArea inside a Flickable keeping an
                // in-progress drag instead of the Flickable taking it over.
                preventStealing: true
                // Driven by the shared drag state, not this row's own
                // `moved` — each row has its own MouseArea, and cursor
                // shape follows whichever one the pointer is visually
                // over, not whichever one actually holds the grab. Using
                // the per-row flag meant dragging row A's grip across row
                // B flickered back to the open hand the instant the
                // pointer crossed into B's own (never-pressed) MouseArea.
                cursorShape: panel.memberDragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property real pressY: 0
                property bool moved: false

                onPressed: function(mouse) { pressY = mouse.y; moved = false }

                onPositionChanged: function(mouse) {
                  if (!pressed) return
                  if (!moved && Math.abs(mouse.y - pressY) > 6) {
                    moved = true
                    panel.beginMemberDrag(memberRow.index)
                  }
                  if (moved) panel.updateMemberDragOver(memberRow.index, mouse.y - pressY)
                }

                onReleased: {
                  if (moved) panel.commitMemberDrag()
                  moved = false
                }

                onCanceled: { panel.cancelMemberDrag(); moved = false }
              }
            }
          }

          SectionTitle { text: "ON YOUR BAR NOW"; width: parent.width }

          Text {
            visible: panel.candidates.length === 0
            color: panel.dim
            font.family: panel.mono
            font.pixelSize: Style.font.body
            text: "Bar's fully stocked — nothing left to add."
          }

          Repeater {
            model: panel.candidates
            delegate: Row {
              required property var modelData
              width: column.width
              spacing: Style.space(8)
              Column {
                width: parent.width - addBtn.width - Style.space(8)
                spacing: 0
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: panel.fg
                  opacity: 0.9
                  font.family: panel.mono
                  font.pixelSize: Style.font.body
                  text: modelData.name + "   " + (modelData.suggested ? "★ " : "") + modelData.category.toUpperCase()
                }
                Text {
                  visible: modelData.warning !== ""
                  width: parent.width
                  wrapMode: Text.WordWrap
                  color: Color.urgent
                  font.family: panel.mono
                  font.pixelSize: Style.font.caption
                  text: "⚠ " + modelData.warning + " when grouped"
                }
              }
              Button {
                id: addBtn
                anchors.top: parent.top
                text: "+ ADD"
                bordered: true
                foreground: modelData.warning !== "" ? Color.urgent : panel.accent
                onClicked: panel.stageAdd(modelData.id)
              }
            }
          }

          SectionTitle { visible: panel.elsewhere.length > 0; text: "IN OTHER GROUPS"; width: parent.width }

          Repeater {
            model: panel.elsewhere
            delegate: Row {
              required property var modelData
              width: column.width
              spacing: Style.space(8)
              Column {
                width: parent.width - moveBtn.width - Style.space(8)
                spacing: 0
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: panel.fg
                  opacity: 0.9
                  font.family: panel.mono
                  font.pixelSize: Style.font.body
                  text: modelData.name + "   in " + modelData.from
                }
                Text {
                  visible: modelData.warning !== ""
                  width: parent.width
                  wrapMode: Text.WordWrap
                  color: Color.urgent
                  font.family: panel.mono
                  font.pixelSize: Style.font.caption
                  text: "⚠ " + modelData.warning + " when grouped"
                }
              }
              Button {
                id: moveBtn
                anchors.top: parent.top
                text: "← MOVE HERE"
                bordered: true
                foreground: modelData.warning !== "" ? Color.urgent : panel.accent
                onClicked: panel.stageAdd(modelData.id)
              }
            }
          }

          SectionTitle { text: "LAST CALL"; width: parent.width }

          Button {
            text: panel.confirmDissolve ? "CLICK AGAIN — RETURN ALL WIDGETS AND DELETE" : "DISSOLVE GROUP"
            bordered: true
            foreground: Color.urgent
            enabled: !panel.busy
            onClicked: {
              if (!panel.confirmDissolve) { panel.confirmDissolve = true; dissolveReset.restart(); return }
              panel.confirmDissolve = false
              panel.dissolve()
            }
          }
        }

        Text {
          width: parent.width
          color: panel.dim
          font.family: panel.mono
          font.pixelSize: Style.font.caption
          text: "[ESC] CLOSE   ·   right-click a group on the bar to open this"
        }
      }
    }

    // Membership changes wait here until you press Apply, so several can land in
    // ONE bar rebuild instead of one each.
    Rectangle {
      id: applyBar
      visible: panel.draft.length > 0
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: panel.draft.length > 0 ? Style.space(44) : 0
      radius: Style.cornerRadius
      color: Qt.rgba(panel.accent.r, panel.accent.g, panel.accent.b, 0.12)
      border.width: 1
      border.color: panel.accent

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        color: panel.accent
        font.family: panel.mono
        font.pixelSize: Style.font.body
        font.bold: true
        text: panel.draft.length + " ROUND" + (panel.draft.length === 1 ? "" : "S") + " ON THE TAB"
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)
        Button {
          text: "DISCARD"
          bordered: true
          foreground: panel.fg
          onClicked: panel.discard()
        }
        Button {
          text: "APPLY"
          bordered: true
          selected: true
          foreground: panel.accent
          enabled: !panel.busy
          onClicked: panel.apply()
        }
      }
    }
  }

  // Bracket-titled section header: ┌ TITLE ────────
  component SectionTitle: Item {
    id: title
    property string text: ""
    implicitHeight: label.implicitHeight
    Text {
      id: label
      text: "┌ " + title.text + " "
      color: panel.accent
      font.family: panel.mono
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Rectangle {
      anchors.left: label.right
      anchors.right: parent.right
      anchors.verticalCenter: label.verticalCenter
      height: 1
      color: Qt.rgba(panel.accent.r, panel.accent.g, panel.accent.b, 0.35)
    }
  }
}
