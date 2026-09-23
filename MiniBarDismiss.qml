import QtQuick
import Quickshell
import Quickshell.Wayland

// Transparent full-screen catcher that lives only while a mini-bar is open, so a
// click anywhere else closes it. The real bar's strip is cut out of its input
// region: clicking another bar icon still reaches that icon (and the shell's own
// popout coordinator then closes the mini-bar).
PanelWindow {
  id: win

  property bool open: false
  property var anchorWindowRef: null
  property string barPosition: "top"
  property real barThickness: 0

  signal dismissed()

  readonly property real sw: screen ? screen.width : 0
  readonly property real sh: screen ? screen.height : 0

  screen: anchorWindowRef ? anchorWindowRef.screen : null
  visible: open
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.namespace: "omarchy-minibar-dismiss"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  anchors { top: true; bottom: true; left: true; right: true }

  mask: Region {
    width: win.sw
    height: win.sh
    Region {
      intersection: Intersection.Subtract
      x: win.barPosition === "right" ? win.sw - win.barThickness : 0
      y: win.barPosition === "bottom" ? win.sh - win.barThickness : 0
      width: (win.barPosition === "left" || win.barPosition === "right") ? win.barThickness : win.sw
      height: (win.barPosition === "top" || win.barPosition === "bottom") ? win.barThickness : win.sh
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onPressed: win.dismissed()
  }
}
