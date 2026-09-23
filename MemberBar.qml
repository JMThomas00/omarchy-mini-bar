import QtQuick
import Quickshell

// The `bar` object handed to every hosted member widget. It mirrors the real bar
// facade's presentation state and re-implements the pieces that only make sense
// for a bar window:
//   * popout coordination stays LOCAL — a member opening its panel must not make
//     the real bar close the mini-bar
//   * click-target registry — first-party panels forward clicks on "the bar strip"
//     to registered widget buttons so you can hop between popups in one click
//   * tooltips — the real bar only shows tooltips for widgets in its own window
QtObject {
  id: mb

  property var hostBar: null
  property string sectionName: "left"
  property var memberIds: []

  // Emitted when a member popup closed and nothing replaced it (click-away, Esc).
  signal popoutDismissed()

  readonly property color foreground: hostBar ? hostBar.foreground : "white"
  readonly property color barForeground: hostBar ? hostBar.barForeground : "white"
  readonly property color background: hostBar ? hostBar.background : "black"
  readonly property color urgent: hostBar ? hostBar.urgent : "red"
  readonly property string fontFamily: hostBar ? hostBar.fontFamily : "monospace"
  readonly property string position: hostBar ? hostBar.position : "top"
  // Deliberately NOT stripVertical. `vertical` tells a widget it's on a real,
  // width-constrained vertical BAR (~28px) and several widgets — including
  // first-party WidgetButton itself — respond by clamping implicitWidth to a
  // bare icon slot and trusting the rest of their own content to fit anyway.
  // Confirmed live with Proxmarchy: its icon+counter Row is never clipped
  // internally, so under that clamp the counter text painted past its own
  // widget's bounds regardless of how generously the strip around it was
  // sized — no host-side cell/strip math can fix a mismatch in what the
  // GUEST itself claims to need. The strip is never width-constrained the
  // way a real vertical bar is (see uniformW), so there's no reason to claim
  // otherwise; widgets report their true content width instead, and the
  // strip already sizes columns off that.
  readonly property bool vertical: false
  readonly property int barSize: hostBar ? hostBar.barSize : 26
  readonly property bool transparent: hostBar ? hostBar.transparent : false
  readonly property bool foregroundAnimationEnabled: hostBar ? hostBar.foregroundAnimationEnabled : true
  readonly property bool centerSectionRevealHeld: false
  readonly property bool centerHoverRevealSuppressed: false
  readonly property var shell: hostBar ? hostBar.shell : null

  // Widgets find their own bar section by searching layoutConfig for their id
  // (Uplink, Waveform, Linecast, Lookout all do) and center their popup on the
  // screen when they can't find themselves. Hosted members are no longer in the
  // real layout, so report them in the section their group sits in.
  readonly property var layoutConfig: {
    var base = hostBar && hostBar.layoutConfig ? hostBar.layoutConfig : ({})
    var out = { left: (base.left || []).slice(), center: (base.center || []).slice(), right: (base.right || []).slice() }
    var section = out[sectionName] ? sectionName : "left"
    for (var i = 0; i < memberIds.length; i++) out[section].push({ id: memberIds[i] })
    return out
  }

  property var clickTargets: []
  property var activePopout: null
  property double lastPressAt: 0

  // --- popouts ---------------------------------------------------------------
  // Switching from member A to member B is a nested call: requestPopout(B)
  // closes A, whose own close cascades synchronously into releasePopout(A) —
  // which used to unconditionally set activePopout=null and arm dismissTimer
  // BEFORE this outer call reaches its own `activePopout = owner` line. If B's
  // own open-panel path deferred even one tick past that (any widget's own
  // Panel/PanelController doing so is legitimate, not a bug on their end),
  // dismissTimer fired first, found activePopout still null, and dismissed the
  // whole group instead of finishing the switch to B — confirmed live: opening
  // a second member closed the group instead of switching to it. `_switching`
  // marks that a request for a NEW owner is already in flight, so A's own
  // release from inside that cascade knows better than to arm the dismiss
  // check — the outer call is about to set activePopout itself.
  property bool _switching: false

  function requestPopout(owner) {
    if (activePopout === owner) return
    dismissTimer.stop()
    if (activePopout) {
      _switching = true
      if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      else if ("close" in activePopout) activePopout.close()
      _switching = false
    }
    activePopout = owner
  }

  function releasePopout(owner) {
    if (activePopout !== owner) return
    activePopout = null
    if (_switching) return
    // Nothing took over. Wait a beat: a click on another member icon closes this
    // popup a hair BEFORE its own press is recorded, and that must not count as
    // "clicked away".
    dismissTimer.restart()
  }

  function closeAllPopouts() {
    dismissTimer.stop()
    var open = activePopout
    activePopout = null
    if (open && "close" in open) open.close()
  }

  property Timer dismissTimer: Timer {
    interval: 90
    onTriggered: {
      if (mb.activePopout === null && Date.now() - mb.lastPressAt > 300) mb.popoutDismissed()
    }
  }

  // --- click targets ---------------------------------------------------------
  function _notePress() { lastPressAt = Date.now() }

  function registerClickTarget(target) {
    if (!target || clickTargets.indexOf(target) !== -1) return
    clickTargets = clickTargets.concat([target])
    if (target.pressed && target.pressed.connect) target.pressed.connect(_notePress)
  }

  function unregisterClickTarget(target) {
    if (target && target.pressed && target.pressed.disconnect) {
      try { target.pressed.disconnect(_notePress) } catch (e) {}
    }
    clickTargets = clickTargets.filter(function(item) { return item !== target })
  }

  // Press the first registered button inside `item` (what a click on it would do).
  // Lets a text label stand in for a hosted widget's own button.
  function pressFirstTargetIn(item, button) {
    for (var i = 0; i < clickTargets.length; i++) {
      var target = clickTargets[i]
      if (!target || !target.triggerPress) continue
      var p = target
      while (p && p !== item) p = p.parent
      if (p === item) { target.triggerPress(button); return true }
    }
    return false
  }

  function targetBelongsToWindow(target, window) {
    return !!target && !!window && target.QsWindow.window === window
  }

  // --- tooltips --------------------------------------------------------------
  property var tooltipTarget: null
  property string tooltipText: ""
  property bool tooltipShown: false
  property var _pendingTarget: null
  property string _pendingText: ""

  function showTooltip(target, text) {
    hideTooltip(tooltipTarget)
    if (!target || !text) return
    _pendingTarget = target
    _pendingText = String(text)
    tipTimer.restart()
  }

  function hideTooltip(target) {
    if (target !== tooltipTarget && target !== _pendingTarget) return
    tipTimer.stop()
    tooltipShown = false
    tooltipTarget = null
    tooltipText = ""
    _pendingTarget = null
    _pendingText = ""
  }

  property Timer tipTimer: Timer {
    interval: 450
    onTriggered: {
      var target = mb._pendingTarget
      if (!target || target.tooltipHovered === false) return
      mb.tooltipTarget = target
      mb.tooltipText = mb._pendingText
      mb.tooltipShown = true
    }
  }

  // --- the rest of the bar surface ------------------------------------------
  function switchPanelFrom(owner, direction) { return false }
  function moduleWidgets(id) { return [] }
  function run(command) { if (hostBar) hostBar.run(command) }
  function setCenterHoverRevealSuppressed(value) {}
}
