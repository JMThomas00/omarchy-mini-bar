import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// One Mini-Bar group = one bar entry, so the bar's own drag can put every group
// anywhere. Left-click opens the group's mini-bar, right-click opens the manager.
//
//   {"id":"jmthomas00.minibar","gid":"g1","label":"Network","glyph":"󰈀","face":"both",
//    "orientation":"auto","memberDisplay":"native","tooltip":true,"members":[{"id":"…"}]}
//
// An entry with no `gid` is an unconfigured placeholder (e.g. freshly added from a
// plugin catalog): clicking it offers to turn it into a group.
BarWidget {
  id: root

  readonly property string pluginId: "jmthomas00.minibar"
  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(pluginId) : null

  readonly property string gid: settings && settings.gid ? String(settings.gid) : ""
  readonly property bool configured: gid !== ""
  readonly property var placeholderGroup: ({ gid: "", label: "Mini-Bar", glyph: "󰐕", face: "glyph", members: [] })
  readonly property var groupData: configured ? settings : placeholderGroup

  // Every Mini-Bar entry on the bar, for the manager. Read from the live layout so
  // a change made through one group's widget shows up in all of them.
  readonly property var allGroups: {
    var layout = bar && bar.layoutConfig ? bar.layoutConfig : ({})
    var out = []
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = layout[sections[s]] || []
      for (var i = 0; i < arr.length; i++) {
        var e = arr[i]
        if (e && typeof e === "object" && e.id === pluginId && e.gid) {
          var copy = JSON.parse(JSON.stringify(e))
          copy.section = sections[s]
          out.push(copy)
        }
      }
    }
    return out
  }

  // Which section THIS group sits in decides where the manager opens (a center
  // icon centers it on the screen, a left/right one pins it under the icon), and
  // what hosted members believe about where they live.
  readonly property string barSection: {
    for (var i = 0; i < allGroups.length; i++) if (allGroups[i].gid === gid) return allGroups[i].section
    return "left"
  }

  property bool groupOpen: false
  property bool managerOpen: false

  readonly property string screenName: root.QsWindow.window && root.QsWindow.window.screen ? root.QsWindow.window.screen.name : ""

  // A deliberate close clears any pending resume note too, so a later, unrelated
  // rebuild landing inside the note's TTL window can't reopen something the user
  // just closed. A popout-switch close (another popup taking over) is NOT
  // deliberate in that sense, so it leaves the note alone.
  function close() {
    groupOpen = false
    if (svc) svc.forgetStrip()
  }
  function closeForPopoutSwitch() { groupOpen = false }
  function closeManager() { managerOpen = false; if (svc) svc.forgetManager() }
  function toggleGroup() { if (configured) groupOpen = !groupOpen; else manage() }

  function manage() {
    groupOpen = false
    managerOpen = true
  }

  onGroupOpenChanged: {
    if (!bar) return
    if (groupOpen) bar.requestPopout(root)
    else bar.releasePopout(root)
  }

  // A membership/appearance change rebuilds the whole bar (this widget included);
  // if the manager or this group's own mini-bar was open, the previous instance
  // left a note in bin/minibar-ops's state dir so the rebuilt one can reopen the
  // same thing. Read directly off disk (see Service.qml's comment for why) —
  // each FileView reacts to its own file loading/changing, so this needs neither
  // `svc` nor `configured` to be ready, and needs no polling.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/minibar"

  function _checkResume(kind, rawText, applyFn) {
    if (!configured || !rawText) return
    var note
    try { note = JSON.parse(rawText) } catch (e) { return }
    if (!note || note.gid !== gid) return
    if (Date.now() - note.at > 15000) return
    if (note.screen && screenName && note.screen !== screenName) return
    applyFn()
  }

  FileView {
    id: resumeManagerFile
    path: root.stateDir + "/resume-manager.json"
    watchChanges: true
    printErrors: false
    onLoaded: root._checkResume("manager", text(), root.manage)
    onFileChanged: reload()
  }
  FileView {
    id: resumeStripFile
    path: root.stateDir + "/resume-strip.json"
    watchChanges: true
    printErrors: false
    onLoaded: root._checkResume("strip", text(), function() { root.groupOpen = true })
    onFileChanged: reload()
  }
  // `configured` (settings.gid) can resolve after these already loaded once.
  onConfiguredChanged: {
    if (!configured) return
    _checkResume("manager", resumeManagerFile.text(), manage)
    _checkResume("strip", resumeStripFile.text(), function() { root.groupOpen = true })
  }

  implicitWidth: face.implicitWidth
  implicitHeight: vertical ? face.implicitHeight : barSize

  GroupFace {
    id: face
    groupData: root.groupData
    hostBarRef: root.bar
    serviceRef: root.svc
    placeholder: !root.configured
    sectionName: root.barSection
    open: root.groupOpen
    onToggleRequested: root.toggleGroup()
    onManageRequested: root.manage()
    onCloseRequested: root.close()
  }

  // The mini-bar is transient: leaving the workspace, or any plugin opening a
  // window of its own (overlay, launched app), closes it and any member popup.
  readonly property var ambientLayers: /^(omarchy-(minibar|keyboard-panel|osd|notifications|reminders|polkit|bar|background|lock-preview)|.*-peek$)/
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.groupOpen) return
      var name = event.name
      var data = String(event.data || "")
      if (name === "workspacev2" || name === "workspace" || name === "openwindow") root.close()
      else if (name === "openlayer" && !root.ambientLayers.test(data)) root.close()
    }
  }

  ManagerPanel {
    id: manager
    anchorItem: root
    bar: root.bar
    svc: root.svc
    pluginId: root.pluginId
    groups: root.allGroups
    focusGroupId: root.gid
    open: root.managerOpen
    centerOnBar: root.barSection === "center"
    onCloseRequested: root.closeManager()
  }

  // `qs ipc call minibar.<gid> toggle` (handy for a keybind)
  IpcHandler {
    enabled: root.configured
    target: "minibar." + root.gid
    function toggle(): void { root.toggleGroup() }
    function manage(): void { root.manage() }
    function close(): void { root.close(); root.closeManager() }
    function report(): string {
      return JSON.stringify({
        gid: root.gid, section: root.barSection, pos: root.bar ? root.bar.position : null,
        open: root.groupOpen, manager: root.managerOpen, svc: root.svc !== null,
        members: (root.groupData.members || []).map(function(m) { return m.id }),
        groups: root.allGroups.map(function(g) { return g.gid + ":" + g.section })
      })
    }
  }
}
