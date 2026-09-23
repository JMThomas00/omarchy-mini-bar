import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The secondary bar.
//
// Deliberately a FULL-LENGTH window flush with the real bar's screen edge —
// transparent, with its input region masked down to the strip. First-party
// KeyboardPanel treats its anchor window as "the bar": it reads the window's
// thickness as the bar thickness and the anchor item's position inside it as a
// screen coordinate. Matching that geometry is what lets every hosted widget's
// own popup land in the right place, on all four bar positions.
PanelWindow {
  id: win

  required property Item anchorItem
  property var hostBarRef: null
  property var serviceRef: null
  property string gid: ""               // this group's own id, for the reorder op
  property var members: []              // [{id, ...inline settings}]
  property string orientation: "auto"   // auto | horizontal | vertical
  property string memberDisplay: "native"   // native (the widget's own icon) | name | both
  property string badgeMode: "sum"          // sum (add every member's count) | members (how many have anything)
  property string sectionName: "left"   // bar section the group icon sits in
  property bool open: false
  property alias memberBar: memberBar

  signal dismissed()
  // Fired the instant a drag drops, with the new id order — GroupFace applies
  // it to its own local members array right away (see below) so the reorder
  // looks and feels like the real bar's own drag: no waiting on the
  // shell.json round-trip and the rebuild it triggers a couple of seconds
  // later. Persisting is still queued immediately after this fires; it just
  // no longer gates what the user sees.
  signal reordered(var order)
  // Fired the instant a drag is released outside the strip's own bounds —
  // same "don't wait on the rebuild" idea as `reordered`: GroupFace drops
  // the member from its local model right away so it disappears from the
  // strip immediately, while the actual unassign (which also puts it back
  // on the real bar, next to the group — same place RETURN TO BAR already
  // uses) persists in the background.
  signal removedLocally(string wid)

  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string pos: hostBarRef ? hostBarRef.position : "top"
  readonly property bool barVertical: pos === "left" || pos === "right"
  readonly property bool stripVertical: orientation === "vertical" || (orientation !== "horizontal" && barVertical)
  readonly property bool labelled: memberDisplay === "name" || memberDisplay === "both"
  readonly property real realThickness: anchorWindow ? (barVertical ? anchorWindow.width : anchorWindow.height) : 0
  readonly property real gap: Style.gapsOut
  readonly property real pad: Style.space(4)
  readonly property real cellPad: Style.space(8)
  // Breathing room between a hosted icon and its name label in "both" mode —
  // only needed in a vertical column, where the two sit close enough to read as
  // one glyph. The horizontal row already has enough separation from cellPad.
  readonly property real labelGap: stripVertical ? Style.space(6) : 0
  readonly property real memberCross: hostBarRef ? hostBarRef.barSize : 26
  readonly property real emptyExtent: Style.space(96)

  // Plugins expose their own notification/alert count under whatever property
  // name their author picked — there's no shared convention across the ones
  // installed here (Lookout: unseenCount, Uplink/uptime-kuma: downCount,
  // Plugin Depot: updateCount). Tried in order against the hosted widget's own
  // root item; a group member's `badgeProperty` inline setting (set from the
  // manager panel) overrides this list outright for a widget that uses
  // something else entirely.
  readonly property var badgeCandidates: ["unseenCount", "downCount", "updateCount", "badgeCount", "notificationCount", "unreadCount", "alertCount", "pendingCount", "count"]

  // Some of those candidate names are inherently bad-news (a down host, an
  // active alert) and default to the urgent color with no further signal
  // needed; others (an update count, a plain notification count) are just
  // informational and stay the normal accent color unless the widget itself
  // says otherwise via urgentCandidates/urgentProperty below.
  readonly property var urgentByDefaultNames: ["downCount", "alertCount"]

  // A widget that distinguishes "routine" from "something's actually wrong"
  // (Lookout: hasUnseenPerson) exposes it as its own boolean; same
  // no-shared-convention situation as the count itself, so this is a second,
  // shorter best-effort list, checked the same way.
  readonly property var urgentCandidates: ["hasUnseenPerson", "urgent", "isUrgent", "critical", "hasAlert", "severe"]

  // Name of whichever candidate (or override) actually matched, or null —
  // needed by badgeUrgentFor to fall back on urgentByDefaultNames.
  function badgeSourceFor(hosted, override) {
    if (!hosted) return null
    // "none" is an explicit opt-out, not just "whatever name I typed didn't
    // match anything" — a member can genuinely expose a real count (e.g. an
    // unread-thread total its own author deliberately doesn't badge on) that
    // the auto-detect list still picks up as a false positive, and the fix
    // for that isn't a different property name, it's "don't count this one
    // at all."
    if (override === "none") return null
    if (override) return typeof hosted[override] === "number" && hosted[override] > 0 ? override : null
    for (var i = 0; i < badgeCandidates.length; i++) {
      var val = hosted[badgeCandidates[i]]
      if (typeof val === "number" && val > 0) return badgeCandidates[i]
    }
    return null
  }

  function badgeCountFor(hosted, override) {
    var name = badgeSourceFor(hosted, override)
    return name ? hosted[name] : 0
  }

  function badgeUrgentFor(hosted, badgeOverride, urgentOverride) {
    if (!hosted) return false
    if (urgentOverride) {
      var v = hosted[urgentOverride]
      return typeof v === "boolean" ? v : false
    }
    for (var i = 0; i < urgentCandidates.length; i++) {
      var val = hosted[urgentCandidates[i]]
      if (typeof val === "boolean") return val
    }
    var name = badgeSourceFor(hosted, badgeOverride)
    return name !== null && urgentByDefaultNames.indexOf(name) !== -1
  }

  // Sum of every hosted member's own badge count — what the group's collapsed
  // icon shows. Reads each cell's own `badgeCount`, which is itself a plain
  // property read on `hosted` and so stays reactive to it same as any other
  // binding; only the loop itself needs cellsRevision to re-run on structural
  // changes, since itemAt()/count aren't reactive triggers on their own.
  // Deliberately gated on `c.hosted` (loaded at all), NOT `c.shown`
  // (hosted.visible). Several hosted widgets tie their own `visible` to
  // their containing window's visibility (Window.window.visible), which is
  // right for the STRIP'S rendering — no point painting an icon in a closed
  // strip — but wrong here: confirmed live via a temporary debug IPC hook
  // that hosted.visible flips false the moment the strip closes even though
  // the widget's own count property (unseenCount, updateCount, ...) is
  // completely unaffected. Gating the group-face aggregate on `shown` made
  // the whole point of "stays alive while collapsed" pointless for badges —
  // the aggregate would vanish exactly when it's most useful, right after
  // you close the strip without acting on the notification.
  readonly property int totalBadgeCount: {
    cellsRevision
    var rep = grid.repeater
    if (!rep) return 0
    var total = 0
    for (var i = 0; i < rep.count; i++) {
      var c = rep.itemAt(i)
      if (!c || !c.hosted) continue
      if (win.badgeMode === "members") { if (c.badgeCount > 0) total += 1 }
      else total += c.badgeCount
    }
    return total
  }

  // True if ANY contributing member's own count is flagged urgent — one
  // urgent member is enough to color the whole group's aggregate badge, same
  // as how a single down host matters more than the total count.
  readonly property bool anyUrgent: {
    cellsRevision
    var rep = grid.repeater
    if (!rep) return false
    for (var i = 0; i < rep.count; i++) {
      var c = rep.itemAt(i)
      if (c && c.hosted && c.badgeCount > 0 && c.urgent) return true
    }
    return false
  }
  readonly property string fontFamily: hostBarRef ? hostBarRef.fontFamily : "monospace"
  readonly property color fg: hostBarRef ? hostBarRef.foreground : "white"

  // In a column every row shares the widest row's width, so clicks land the same
  // everywhere. Bumped whenever a cell appears/disappears (itemAt() isn't reactive).
  property int cellsRevision: 0
  readonly property real uniformW: {
    cellsRevision
    var rep = grid.repeater
    if (!rep) return 0
    var widest = 0
    for (var i = 0; i < rep.count; i++) {
      var c = rep.itemAt(i)
      if (c && c.shown) widest = Math.max(widest, c.desiredW)
    }
    return widest
  }

  readonly property real contentW: members.length === 0 ? emptyExtent
    : (stripVertical ? uniformW : grid.implicitWidth)
  readonly property real contentH: members.length === 0 ? memberCross
    : (stripVertical ? grid.implicitHeight : memberCross)
  readonly property real stripW: Math.max(contentW, memberCross) + pad * 2
  readonly property real stripH: Math.max(contentH, memberCross) + pad * 2

  // mapToItem is not reactive, so the icon position is snapshotted on open.
  property real iconAlong: 0
  function syncAnchor() {
    if (!anchorItem || !anchorWindow) return
    var p = anchorItem.mapToItem(anchorWindow.contentItem, anchorItem.width / 2, anchorItem.height / 2)
    iconAlong = barVertical ? p.y : p.x
  }
  onOpenChanged: {
    if (open) {
      win.visible = true
      win._mappedStripW = win.stripW
      win._mappedStripH = win.stripH
      syncAnchor()
    } else {
      win.visible = false
      memberBar.closeAllPopouts()
    }
  }

  // A member's real size can still be settling after the window first maps
  // (confirmed live: Proxmarchy's own guest-count fetch resolving a beat
  // later) — implicitHeight/Width growing after that point does NOT reliably
  // grow the actual mapped Wayland surface (every QML-side property, including
  // this window's own .height/.width, already reactively reports the correct
  // larger value — it's specifically the compositor-visible surface that
  // stays stuck at whatever size it was first mapped at). The only fix found
  // to work: force a real unmap/remap once content settles to a larger size
  // than what was last actually shown, so it applies at the true final size.
  property real _mappedStripW: 0
  property real _mappedStripH: 0
  function _onStripSizeChanged() {
    if (open) syncAnchor()
    if (!open || !visible) return
    if (stripW <= _mappedStripW + 0.5 && stripH <= _mappedStripH + 0.5) return
    remapTimer.restart()
  }
  onStripWChanged: _onStripSizeChanged()
  onStripHChanged: _onStripSizeChanged()
  Timer {
    id: remapTimer
    interval: 16
    onTriggered: {
      if (!win.open) return
      win.visible = false
      Qt.callLater(function() {
        if (!win.open) return
        win._mappedStripW = win.stripW
        win._mappedStripH = win.stripH
        win.visible = true
      })
    }
  }

  readonly property real alongLen: screen ? (barVertical ? screen.height : screen.width) : 1920
  readonly property real alongSize: barVertical ? stripH : stripW
  readonly property real along: Math.max(gap, Math.min(iconAlong - alongSize / 2, alongLen - alongSize - gap))
  readonly property real stripX: barVertical ? (pos === "left" ? realThickness + gap : 0) : along
  readonly property real stripY: barVertical ? along : (pos === "top" ? realThickness + gap : 0)

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "omarchy-minibar"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  anchors {
    top: pos !== "bottom"
    bottom: pos !== "top"
    left: pos !== "right"
    right: pos !== "left"
  }
  implicitHeight: barVertical ? 0 : realThickness + gap + stripH
  implicitWidth: barVertical ? realThickness + gap + stripW : 0
  mask: Region { x: win.stripX; y: win.stripY; width: win.stripW; height: win.stripH }

  MemberBar {
    id: memberBar
    hostBar: win.hostBarRef
    sectionName: win.sectionName
    memberIds: win.members.map(function(m) { return m.id })
    onPopoutDismissed: if (win.open) win.dismissed()
  }

  function hostedItem(index) {
    var rep = grid.repeater
    var cell = rep ? rep.itemAt(index) : null
    return cell ? cell.hosted : null
  }

  // --- drag-to-reorder -------------------------------------------------------
  // A left-button-only overlay per cell (see the delegate below) classifies its
  // own press as a click or a drag; a real drag lands here. Right/middle-click
  // and scroll never reach this overlay at all (acceptedButtons excludes them),
  // so they keep working on the hosted widget exactly as before.
  property int dragFromIndex: -1
  property int dragOverIndex: -1
  readonly property bool dragging: dragFromIndex >= 0
  // True once the drag point has left the visible strip Rectangle (not the
  // window — the window is full-length/edge-flush, way bigger than the
  // strip, so this checks against `strip`'s own bounds). Releasing while
  // true unassigns the member instead of reordering it — the same "drag it
  // off" idiom as removing an item from a dock/taskbar.
  property bool dragOutsideStrip: false

  function beginDrag(index) {
    dragFromIndex = index
    dragOverIndex = index
    dragOutsideStrip = false
  }

  function updateDragOutsideFor(stripPoint) {
    var margin = Style.space(6)
    dragOutsideStrip = stripPoint.x < -margin || stripPoint.y < -margin
      || stripPoint.x > strip.width + margin || stripPoint.y > strip.height + margin
  }

  function updateDragOver(gridPoint) {
    if (dragFromIndex < 0) return
    var p = win.stripVertical ? gridPoint.y : gridPoint.x
    var best = dragFromIndex
    var bestDist = Infinity
    var rep = grid.repeater
    if (!rep) return
    for (var i = 0; i < rep.count; i++) {
      var c = rep.itemAt(i)
      if (!c || !c.shown) continue
      var center = win.stripVertical ? (c.y + c.height / 2) : (c.x + c.width / 2)
      var d = Math.abs(p - center)
      if (d < bestDist) { bestDist = d; best = i }
    }
    dragOverIndex = best
  }

  function commitDrag() {
    var from = dragFromIndex, to = dragOverIndex, outside = dragOutsideStrip
    dragFromIndex = -1
    dragOverIndex = -1
    dragOutsideStrip = false
    if (from < 0 || !serviceRef || gid === "") return

    if (outside) {
      var removedId = win.members[from] ? win.members[from].id : null
      if (!removedId) return
      win.removedLocally(removedId)
      serviceRef.runOps(["unassign", gid, removedId])
      return
    }

    if (to < 0 || from === to) return
    var ids = win.members.map(function(m) { return m.id })
    var moved = ids.splice(from, 1)[0]
    ids.splice(to, 0, moved)
    win.reordered(ids)
    serviceRef.rememberStrip(gid, win.screen ? win.screen.name : "")
    serviceRef.runOps(["reorder", gid, JSON.stringify(ids)])
  }

  function cancelDrag() {
    dragFromIndex = -1
    dragOverIndex = -1
    dragOutsideStrip = false
  }

  function _settingsFor(entry) {
    var merged = {}
    var defaults = serviceRef ? serviceRef.defaultsFor(entry.id) : ({})
    for (var k in defaults) merged[k] = defaults[k]
    for (var j in entry) if (j !== "id") merged[j] = entry[j]
    return merged
  }

  Rectangle {
    id: strip
    x: win.stripX
    y: win.stripY
    width: win.stripW
    height: win.stripH
    radius: Style.cornerRadius
    color: win.hostBarRef ? win.hostBarRef.background : "black"
    border.width: win.dragOutsideStrip ? 2 : 1
    border.color: win.dragOutsideStrip ? Color.urgent : Color.popups.border

    Text {
      visible: win.members.length === 0
      anchors.centerIn: parent
      text: "bar's empty"
      color: win.fg
      opacity: 0.5
      font.family: win.fontFamily
      font.pixelSize: Style.font.body
    }

    // A single-axis list — Column/Row lay out purely off each child's own
    // width/height, with no fixed rows/columns count to go stale against a
    // child's height changing after the strip first opens (confirmed live: a
    // Grid here left the strip sized for whichever member fit at first paint,
    // clipping any member whose own size — e.g. Proxmarchy's guest-count badge
    // — only became known a beat later; Column/Row relayout off actual child
    // geometry instead of a separately-tracked count).
    Loader {
      id: grid
      anchors.centerIn: parent
      readonly property real implicitWidth: item ? item.implicitWidth : 0
      readonly property real implicitHeight: item ? item.implicitHeight : 0
      readonly property var repeater: item ? item.repeater : null
      sourceComponent: win.stripVertical ? columnLayout : rowLayout
    }

    Component {
      id: columnLayout
      Column {
        spacing: 0
        readonly property alias repeater: rep
        Repeater { id: rep; model: win.members; onItemAdded: win.cellsRevision++; onItemRemoved: win.cellsRevision++; delegate: cellDelegate }
      }
    }
    Component {
      id: rowLayout
      Row {
        spacing: 0
        readonly property alias repeater: rep
        Repeater { id: rep; model: win.members; onItemAdded: win.cellsRevision++; onItemRemoved: win.cellsRevision++; delegate: cellDelegate }
      }
    }

    Component {
      id: cellDelegate

      Item {
        id: cell
        required property var modelData
        required property int index
        readonly property var hosted: memberLoader.item
        readonly property bool shown: hosted !== null && hosted.visible
        readonly property string memberName: win.serviceRef ? win.serviceRef.displayName(modelData.id) : modelData.id
        readonly property int badgeCount: win.badgeCountFor(hosted, modelData.badgeProperty)
        readonly property bool urgent: win.badgeUrgentFor(hosted, modelData.badgeProperty, modelData.urgentProperty)
        // Deliberately no `visible: shown` binding here: an Item's `visible`
        // hides its whole subtree, including its own child Loader — confirmed
        // live, this made every strip render permanently empty, because the
        // Loader never got a chance to actually load and let the hosted
        // widget set its OWN `visible` true in the first place (chicken/egg).
        // `width`/`height` already go to 0 when not shown, which is enough:
        // a registered click target with a zero-size bounding box can never
        // match a real click position anyway.

        // A first-party popup that's ALREADY open, when it sees a click ANYWHERE
        // on screen, tries to relay it to whichever registered bar widget's own
        // bounding box the click landed in, before falling back to just closing
        // itself (confirmed live: this relay is how switching between two
        // members works at all, since the open popup's own full-screen overlay
        // sees every click before we do). That check is against the CLICK
        // TARGET'S own geometry — the hosted widget's registered button, which
        // in "name"/"both" display mode is only ever as wide as its native icon,
        // since the name label beside it is OUR OWN separate Text element, not
        // part of the widget's own button. A click on the icon matched and
        // relayed fine; a click on the label fell outside that narrower box, so
        // the relay failed and the open popup just closed instead — taking the
        // whole group with it. Registering the WHOLE cell too widens the target
        // the relay checks against to match what's actually clickable.
        function triggerPress(button) { memberBar.pressFirstTargetIn(cell.hosted, button) }
        Component.onCompleted: memberBar.registerClickTarget(cell)
        Component.onDestruction: memberBar.unregisterClickTarget(cell)

        // Contain whatever a hosted widget actually paints to the space it was
        // given, even when that disagrees with its OWN implicitWidth/Height.
        // Root-caused live: some widgets (Proxmarchy confirmed) report a
        // narrower implicitWidth for a vertical host than what they actually
        // paint — Proxmarchy's own button clamps implicitWidth to a bare icon
        // slot whenever `bar.vertical` reads true (sized for a real, narrow
        // vertical BAR), but its icon+counter Row paints at its full natural
        // width regardless and is never clipped internally, so the counter
        // text bleeds out past its own declared bounds. This is a mismatch in
        // the HOSTED widget's own sizing, not something fixable by computing
        // cell/strip sizes more carefully on this side — no matter how the
        // strip is sized, it can only ever trust what a widget SAYS it needs.
        // Clipping every cell is the containment backstop: a misbehaving
        // widget gets cropped to its own slot instead of spilling into
        // whatever the desktop happens to render behind the strip.
        clip: true

        // The widget's own footprint. Always its real implicitWidth/Height — some
        // widgets (Proxmarchy's guest counter, e.g. "5/17" next to its glyph) are
        // wider than a plain icon, and clamping them to a fixed square made their
        // own content paint past the cell/strip border instead of fitting it.
        readonly property real nativeW: hosted ? hosted.implicitWidth : 0
        readonly property real nativeH: hosted ? (win.stripVertical ? hosted.implicitHeight : win.memberCross) : 0
        readonly property real iconSlot: Math.max(win.memberCross, nativeW)
        readonly property real desiredW: win.memberDisplay === "name" ? label.implicitWidth + win.cellPad * 2
          : win.memberDisplay === "both" ? iconSlot + win.labelGap + label.implicitWidth + win.cellPad * 2
          : Math.max(win.memberCross, nativeW)

        // In a column every cell shares the widest cell's width (uniformW) so
        // clicks land the same everywhere; a row sizes each cell to its own content.
        width: !shown ? 0 : (win.stripVertical ? win.uniformW : desiredW)
        height: !shown ? 0 : (win.labelled ? win.memberCross : nativeH)
        opacity: win.dragFromIndex === cell.index ? (win.dragOutsideStrip ? 0.2 : 0.4) : 1

        // Drop target feedback: highlight whichever cell the drag is over.
        // Not while dragging outside the strip — a reorder isn't what's
        // about to happen then (the strip's own border is the cue instead).
        Rectangle {
          visible: win.dragging && !win.dragOutsideStrip && win.dragOverIndex === cell.index && win.dragFromIndex !== cell.index
          anchors.fill: parent
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 2
          border.color: Color.accent
        }

        // The name. In "name" mode the live widget lies invisibly ON TOP of it
        // (opacity 0 still takes input), so clicks, scrolling and tooltips all
        // still reach the real widget. In "both" mode the icon sits to the left
        // and a click on the name presses that widget's button.
        Text {
          id: label
          visible: win.labelled
          x: win.memberDisplay === "both" ? cell.iconSlot + win.labelGap : win.cellPad
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: cell.memberName
          color: win.fg
          font.family: win.fontFamily
          font.pixelSize: Style.font.body
        }

        // Right/middle-click still goes straight to the hosted widget's own
        // button (left is handled by dragHit above, which classifies its own
        // press as a click vs. a drag before deciding what to do with it).
        MouseArea {
          visible: win.memberDisplay === "both"
          x: cell.iconSlot + win.labelGap
          width: parent.width - cell.iconSlot - win.labelGap
          height: parent.height
          acceptedButtons: Qt.RightButton | Qt.MiddleButton
          onClicked: function(mouse) { memberBar.pressFirstTargetIn(cell.hosted, mouse.button) }
        }

        Loader {
          id: memberLoader
          z: 2
          x: 0
          y: 0
          width: win.memberDisplay === "both" ? cell.iconSlot : parent.width
          height: parent.height
          opacity: win.memberDisplay === "name" ? 0 : 1
          sourceComponent: win.serviceRef ? win.serviceRef.componentFor(cell.modelData.id) : null
          onLoaded: {
            if ("bar" in item) item.bar = memberBar
            if ("moduleName" in item) item.moduleName = cell.modelData.id
            if ("settings" in item) item.settings = win._settingsFor(cell.modelData)
          }
        }

        // Drag-to-reorder, left button only. Sits above everything else in the
        // cell but claims ONLY the left button, so right-click, middle-click and
        // scroll fall straight through to the hosted widget beneath, unaffected.
        // A press classifies itself as a drag (moved past a small threshold) or
        // a plain click (never moved) only once the button is released — a real
        // click is then forwarded to the hosted widget's own registered button,
        // exactly what a direct click on it would have done.
        MouseArea {
          id: dragHit
          z: 3
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton
          hoverEnabled: false
          property point pressPos
          property bool moved: false

          onPressed: function(mouse) { pressPos = Qt.point(mouse.x, mouse.y); moved = false }

          onPositionChanged: function(mouse) {
            if (!pressed) return
            if (!moved && (Math.abs(mouse.x - pressPos.x) > 6 || Math.abs(mouse.y - pressPos.y) > 6)) {
              moved = true
              win.beginDrag(cell.index)
            }
            if (moved) {
              win.updateDragOver(dragHit.mapToItem(grid, mouse.x, mouse.y))
              win.updateDragOutsideFor(dragHit.mapToItem(strip, mouse.x, mouse.y))
            }
          }

          onReleased: function(mouse) {
            if (moved) win.commitDrag()
            else memberBar.pressFirstTargetIn(cell.hosted, mouse.button)
            moved = false
          }

          onCanceled: { win.cancelDrag(); moved = false }
        }
      }
    }
  }

  // Hovering a hosted widget: same bubble the real bar draws. It is placed
  // beyond the strip's OUTER edge — below/above a row, beside a column — so it
  // never sits on top of the icons you are trying to click, and its input region
  // is empty so it can never steal the pointer.
  PopupWindow {
    id: tip
    visible: win.open && memberBar.tooltipShown && memberBar.tooltipText !== ""
    color: "transparent"
    implicitWidth: Math.ceil(bubble.implicitWidth)
    implicitHeight: Math.ceil(bubble.implicitHeight)
    mask: Region {}

    anchor {
      window: win
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        var target = memberBar.tooltipTarget
        if (!target) return
        var w = tip.implicitWidth, h = tip.implicitHeight
        var mid = win.contentItem.mapFromItem(target, target.width / 2, target.height / 2)
        var x, y
        if (win.stripVertical) {
          x = win.pos === "right" ? win.stripX - w - 8 : win.stripX + win.stripW + 8
          y = mid.y - h / 2
        } else {
          x = mid.x - w / 2
          y = win.pos === "bottom" ? win.stripY - h - 8 : win.stripY + win.stripH + 8
        }
        tip.anchor.rect.x = Math.round(x)
        tip.anchor.rect.y = Math.round(y)
      }
    }

    BorderSurface {
      id: bubble
      implicitWidth: tipLabel.implicitWidth + 20
      implicitHeight: tipLabel.implicitHeight + 14
      color: Color.tooltip.background
      borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, 1)
      radius: Style.cornerRadius

      Text {
        id: tipLabel
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: memberBar.tooltipText
        color: Color.tooltip.text
        font.family: memberBar.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
