import QtQuick
import qs.Ui
import qs.Commons

// One group's button on the real bar — plus the mini-bar window it opens.
Item {
  id: root

  required property var groupData
  property var hostBarRef: null
  property var serviceRef: null
  property bool open: false
  property bool placeholder: false
  property string sectionName: "left"

  signal toggleRequested()
  signal manageRequested()
  signal closeRequested()

  readonly property string face: groupData.face || "glyph"
  readonly property string glyph: groupData.glyph || "󰀻"
  readonly property string label: groupData.label || ""
  readonly property string faceText: face === "text" ? label : (face === "both" ? glyph + "  " + label : glyph)
  readonly property alias miniBar: mini
  // Sum of every hosted member's own notification/alert count (see
  // MiniBar.badgeCountFor) — members stay alive while collapsed, so this
  // keeps updating even while the group's strip is closed.
  readonly property bool badgeEnabled: groupData.badge !== false
  readonly property int badgeCount: mini.totalBadgeCount
  readonly property bool badgeUrgent: mini.anyUrgent

  // Hover tooltip: on by default only for a glyph-only face (text faces already
  // say the name), always off while the group is open (it would sit on the strip).
  readonly property bool tipEnabled: groupData.tooltip === undefined ? face === "glyph" : groupData.tooltip === true
  readonly property string tipText: tipEnabled && !open ? label : ""

  onOpenChanged: if (open && hostBarRef && buttonLoader.item) hostBarRef.hideTooltip(buttonLoader.item)

  // Members feed a Repeater inside the mini-bar; rebuilding it recreates every
  // hosted widget, so only hand it a new array when the contents really changed.
  property var membersModel: []
  readonly property string membersSig: JSON.stringify(groupData.members || [])
  onMembersSigChanged: membersModel = groupData.members || []
  Component.onCompleted: membersModel = groupData.members || []

  // A drag-drop reorder lands here immediately — see MiniBar.qml's `reordered`
  // signal — so the strip re-sorts in the same frame the user drops, instead of
  // waiting on the shell.json round-trip (which still happens, just in the
  // background; persisting the identical order back is a no-op the user never
  // has to wait through).
  function applyLocalReorder(order) {
    var byId = {}
    for (var i = 0; i < membersModel.length; i++) byId[membersModel[i].id] = membersModel[i]
    var next = []
    for (var j = 0; j < order.length; j++) if (byId[order[j]]) { next.push(byId[order[j]]); delete byId[order[j]] }
    for (var leftoverId in byId) next.push(byId[leftoverId])
    membersModel = next
  }

  // A drag out of the strip lands here immediately — see MiniBar.qml's
  // `removedLocally` signal — same "don't wait on the rebuild" idea as
  // applyLocalReorder above.
  function removeLocalMember(wid) {
    membersModel = membersModel.filter(function(m) { return m.id !== wid })
  }

  function hostedItem(index) { return mini.hostedItem(index) }

  function handlePress(button) {
    if (button === Qt.RightButton) manageRequested()
    else toggleRequested()
  }

  implicitWidth: buttonLoader.item ? buttonLoader.item.implicitWidth : 0
  implicitHeight: buttonLoader.item ? buttonLoader.item.implicitHeight : (hostBarRef ? hostBarRef.barSize : 26)

  Loader {
    id: buttonLoader
    anchors.fill: parent
    sourceComponent: root.face === "glyph" ? iconButton : textButton
  }

  // Aggregate badge for the group — same look as a single plugin's own badge
  // (Lookout, e.g.), just fed by the sum across every hosted member instead
  // of one widget's own count.
  Rectangle {
    id: groupBadge
    visible: root.badgeEnabled && root.badgeCount > 0
    width: Math.max(Style.space(12), badgeText.implicitWidth + Style.space(4))
    height: Style.space(12)
    radius: height / 2
    color: root.badgeUrgent ? Color.urgent : Color.accent
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -Style.space(2)
    anchors.topMargin: -Style.space(2)
    z: 10

    Text {
      id: badgeText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.badgeCount > 99 ? "99+" : String(root.badgeCount)
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Component {
    id: iconButton
    BarIconButton {
      bar: root.hostBarRef
      text: root.glyph
      tooltipText: root.tipText
      onPressed: function(button) { root.handlePress(button) }
    }
  }

  Component {
    id: textButton
    WidgetButton {
      bar: root.hostBarRef
      text: root.faceText
      tooltipText: root.tipText
      onPressed: function(button) { root.handlePress(button) }
    }
  }

  MiniBar {
    id: mini
    anchorItem: root
    hostBarRef: root.hostBarRef
    serviceRef: root.serviceRef
    gid: root.groupData.gid || ""
    members: root.membersModel
    orientation: root.groupData.orientation || "auto"
    memberDisplay: root.groupData.memberDisplay || "native"
    badgeMode: root.groupData.badgeMode || "sum"
    sectionName: root.sectionName
    open: root.open && !root.placeholder
    onDismissed: root.closeRequested()
    onReordered: function(order) { root.applyLocalReorder(order) }
    onRemovedLocally: function(wid) { root.removeLocalMember(wid) }
  }

  MiniBarDismiss {
    open: root.open && !root.placeholder
    anchorWindowRef: mini.anchorWindow
    barPosition: mini.pos
    barThickness: mini.realThickness
    onDismissed: root.closeRequested()
  }
}
