import QtQuick
import Quickshell
import Quickshell.Io

// Headless half of Mini-Bar. Third-party bar widgets are not handed the widget
// catalog, but service plugins are — including the real QML Components — so this
// object holds that snapshot and serves it to the widget half. It also runs the
// membership helper (bin/minibar-ops), the one place shell.json gets rewritten.
QtObject {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null

  readonly property string selfId: "jmthomas00.minibar"
  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/minibar"
  readonly property var widgets: barWidgetRegistry ? barWidgetRegistry.widgets : ({})
  readonly property int revision: barWidgetRegistry ? barWidgetRegistry.revision : 0

  property string lastOpsMessage: ""
  property string lastOpsError: ""
  property bool opsBusy: false

  // A membership/appearance change rewrites bar.layout, which makes the shell
  // rebuild EVERY widget — including Mini-Bar itself and whichever of its
  // manager/mini-bar strip was open. Confirmed live: one write reliably drives
  // MORE than one full widget-recreation pass (and, with it, more than one
  // recreation of this very Service object — it isn't keepLoaded, so it does not
  // survive that either). A "reopen this" note kept as a QML property dies with
  // whichever pass's Service instance held it; see bin/minibar-ops's `remember`/
  // `forget` for why this is a small file under ~/.local/state/minibar instead —
  // BarWidget.qml reads it back directly, so this object doesn't need to survive
  // for the resume to work.
  signal opsFinished(int code, string text)

  function rememberManager(gid, screenName) { runOps(["remember", "manager", gid, screenName || ""]) }
  function rememberStrip(gid, screenName) { runOps(["remember", "strip", gid, screenName || ""]) }
  function forgetManager() { runOps(["forget", "manager"]) }
  function forgetStrip() { runOps(["forget", "strip"]) }

  function newGroupId() {
    return "g" + Date.now().toString(36) + Math.floor(Math.random() * 1296).toString(36)
  }

  // jq's own error line is the useful part ("no such group"); drop the file path noise.
  function _tidy(text) {
    var m = /error \(at [^)]*\): ([^\n]*)/.exec(text)
    return m ? m[1] : text
  }

  function componentFor(id) {
    var entry = widgets[String(id)]
    return entry ? entry.component : null
  }

  function metaFor(id) {
    var entry = widgets[String(id)]
    return entry && entry.metadata ? entry.metadata : null
  }

  function displayName(id) {
    var meta = metaFor(id)
    return meta && meta.displayName ? String(meta.displayName) : String(id)
  }

  function categoryOf(id) {
    var meta = metaFor(id)
    return meta && meta.category ? String(meta.category) : "Plugin"
  }

  function defaultsFor(id) {
    var meta = metaFor(id)
    return meta && meta.defaults ? meta.defaults : ({})
  }

  // --- membership ops --------------------------------------------------------
  // One helper invocation at a time; each rewrites shell.json atomically and the
  // shell reloads it, so overlapping runs would race.
  property var _queue: []

  function runOps(args, done) {
    var next = _queue.slice()
    next.push({ args: args, done: done || null })
    _queue = next
    _pump()
  }

  function _pump() {
    if (opsProc.running || _queue.length === 0) return
    var job = _queue[0]
    _queue = _queue.slice(1)
    opsProc.job = job
    opsProc.command = [root.sourceDir + "/bin/minibar-ops"].concat(job.args)
    opsBusy = true
    watchdog.restart()
    opsProc.running = true
  }

  // The op can outlive the widget that asked for it (the shell rebuilds widgets
  // when the layout changes), so bookkeeping happens BEFORE any callback runs and
  // a dead caller can never leave the queue stuck.
  property Process opsProc: Process {
    property var job: null
    stdout: StdioCollector { id: opsOut }
    stderr: StdioCollector { id: opsErr }
    onExited: function(code) {
      watchdog.stop()
      var text = (code === 0 ? opsOut.text : (opsErr.text || opsOut.text)).trim()
      var finished = job
      root.lastOpsMessage = text
      root.lastOpsError = code === 0 ? "" : ("FAILED: " + root._tidy(text))
      root.opsBusy = root._queue.length > 0
      root.opsFinished(code, text)
      if (finished && finished.done) {
        try { finished.done(code, text) } catch (e) { console.log("[minibar] ops callback dropped: " + e) }
      }
      Qt.callLater(root._pump)
    }
  }

  property Timer watchdog: Timer {
    interval: 20000
    onTriggered: {
      root.opsProc.running = false
      root.opsBusy = false
      root.lastOpsError = "FAILED: the shell.json update timed out"
    }
  }
}
