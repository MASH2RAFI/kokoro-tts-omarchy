import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Voices.js" as Voices

// Floating play/pause pill that appears next to the pointer when text is
// selected anywhere (the Wayland primary selection). Left-click speaks the
// selection, pauses, or resumes; right-click opens a small card with quick
// settings. Owned by Panel.qml, which runs the worker.
Scope {
  id: bar

  required property var host       // Panel.qml root: speak/pause/resume/stop + state
  required property var settings   // Panel.qml JsonAdapter

  property bool shown: false
  property bool menuOpen: false
  // A selection arrived that has not been spoken yet: play speaks it instead
  // of resuming the paused clip.
  property bool fresh: false
  property var targetScreen: null
  property real pointerX: 0        // pointer in the target screen's logical coordinates
  property real pointerY: 0
  property real dragX: 0           // how far the user dragged the capsule from its spot by the pointer
  property real dragY: 0

  // Frosted glass: a translucent theme tint with a faint light edge. Hyprland
  // blurs what is behind it (layer rule on the "mash2rafi-kokoro-selection" namespace).
  readonly property color glassFill: Util.alpha(Color.popups.background, 0.55)
  readonly property var glassBorder: Border.flat(Util.alpha(Color.popups.text, 0.22), Math.max(1, Style.space(1)))

  readonly property bool active: bar.settings.floatingBar
  readonly property bool playing: bar.host.speaking && !bar.host.paused
  readonly property bool seekable: bar.host.speaking && bar.settings.autoPlay
  // idle → loading (model/generation before the first audio) → speaking ⇄ paused
  readonly property string phase: !bar.host.speaking ? "idle"
    : bar.host.paused ? "paused"
    : bar.host.position > 0 ? "speaking" : "loading"

  // ---------------------------------------------------------------- animation state

  // 0 → 1 as the capsule appears; it fades and shrinks out before the window unmaps.
  property real presence: bar.shown ? 1 : 0
  Behavior on presence {
    NumberAnimation {
      duration: bar.shown ? 240 : 150
      easing.type: bar.shown ? Easing.OutBack : Easing.InCubic
      easing.overshoot: 1.4
    }
  }

  property real cardIn: bar.menuOpen ? 1 : 0
  Behavior on cardIn { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

  property real shakeX: 0
  SequentialAnimation {
    id: shake
    NumberAnimation { target: bar; property: "shakeX"; to: -6; duration: 50 }
    NumberAnimation { target: bar; property: "shakeX"; to: 6; duration: 100 }
    NumberAnimation { target: bar; property: "shakeX"; to: -3; duration: 100 }
    NumberAnimation { target: bar; property: "shakeX"; to: 3; duration: 100 }
    NumberAnimation { target: bar; property: "shakeX"; to: 0; duration: 50 }
  }

  // Speaking: the accent ring pulses. Paused: the main icon breathes.
  property real pulse: 0
  SequentialAnimation on pulse {
    running: bar.phase === "speaking" && bar.shown
    loops: Animation.Infinite
    NumberAnimation { from: 0.15; to: 0.75; duration: 750; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.75; to: 0.15; duration: 750; easing.type: Easing.InOutSine }
  }
  property real breathe: 1
  SequentialAnimation on breathe {
    running: bar.phase === "paused" && bar.shown
    loops: Animation.Infinite
    NumberAnimation { from: 1; to: 0.4; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.4; to: 1; duration: 900; easing.type: Easing.InOutSine }
  }

  function hide() {
    bar.menuOpen = false
    bar.shown = false
  }

  function togglePlay() {
    if (bar.playing) {
      bar.host.pause()
    } else if (bar.host.paused && !bar.fresh) {
      bar.host.resume()
    } else {
      bar.fresh = false
      bar.host.readClipboard(true, function(text) { bar.host.speak(text) })
    }
  }

  onActiveChanged: if (!active) bar.hide()

  Connections {
    target: bar.host
    function onOpenedChanged() { if (bar.host.opened) bar.hide() }
    function onErrorTextChanged() { if (bar.host.errorText.length && bar.shown) shake.restart() }
  }

  // The play/pause icon squishes and pops back whenever it swaps.
  onPlayingChanged: mainButton.popNow()

  // ---------------------------------------------------------------- selection watcher

  // wl-paste runs the script on every primary-selection change and prints
  // "show" for real text, "hide" for empty, whitespace or sensitive content.
  property bool primed: false

  Process {
    id: watcher
    running: bar.active
    command: ["wl-paste", "--primary", "--watch", "sh", "-c",
      "if [ \"$CLIPBOARD_STATE\" = data ] && [ -n \"$(tr -d '[:space:]' | head -c 1)\" ];"
      + " then echo show; else echo hide; fi"]
    stdout: SplitParser {
      onRead: function(data) { bar.selectionChanged(String(data || "").trim()) }
    }
    onRunningChanged: if (!running) bar.primed = false
    onExited: if (bar.active) restartWatcher.restart()
  }

  Timer {
    id: restartWatcher
    interval: 5000
    onTriggered: if (bar.active) watcher.running = true
  }

  function selectionChanged(state) {
    // The first event is whatever was already selected when the watch began.
    if (!bar.primed) { bar.primed = true; return }
    if (state !== "show") {
      bar.fresh = false
      if (!bar.host.speaking && !bar.menuOpen) bar.hide()
      return
    }
    if (bar.host.opened) return
    bar.fresh = true
    settle.restart()
  }

  // Apps update the selection continuously while dragging; wait for it to settle.
  Timer {
    id: settle
    interval: 350
    onTriggered: locate.running = true
  }

  Process {
    id: locate
    command: ["sh", "-c", "printf '{\"cursor\":%s,\"monitors\":%s}' \"$(hyprctl -j cursorpos)\" \"$(hyprctl -j monitors)\""]
    stdout: StdioCollector {
      onStreamFinished: bar.placeAtPointer(this.text)
    }
  }

  function placeAtPointer(raw) {
    var info
    try { info = JSON.parse(raw) } catch (e) { return }
    var cx = Number(info.cursor && info.cursor.x), cy = Number(info.cursor && info.cursor.y)
    var monitors = info.monitors || []
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      var scale = Number(m.scale) || 1
      var rotated = (Number(m.transform) || 0) % 2 === 1
      var w = (rotated ? m.height : m.width) / scale
      var h = (rotated ? m.width : m.height) / scale
      if (cx < m.x || cy < m.y || cx >= m.x + w || cy >= m.y + h) continue
      var screen = null
      for (var j = 0; j < Quickshell.screens.length; j++)
        if (Quickshell.screens[j].name === m.name) screen = Quickshell.screens[j]
      if (!screen) return
      bar.menuOpen = false
      bar.targetScreen = screen
      bar.pointerX = cx - m.x
      bar.pointerY = cy - m.y
      bar.dragX = 0
      bar.dragY = 0
      bar.shown = true
      return
    }
  }

  // Idle pill disappears on its own; it stays while speaking, paused,
  // hovered, or while the settings card is open.
  Timer {
    interval: 4000
    running: bar.shown && !bar.host.speaking && !bar.menuOpen && !pillHover.hovered
    onTriggered: bar.hide()
  }

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: win
    visible: (bar.shown || bar.presence > 0.01) && bar.targetScreen !== null
    screen: bar.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mash2rafi-kokoro-selection"
    WlrLayershell.layer: WlrLayer.Overlay
    // Never take keyboard focus: the selection stays in the app it came from.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Only the pill takes clicks; with the card open the whole screen does,
    // so a click outside closes it.
    mask: bar.menuOpen ? null : pillRegion

    property Region pillRegion: Region { item: pill }

    readonly property real gap: Style.space(14)
    readonly property real edge: Style.space(8)

    MouseArea {
      anchors.fill: parent
      enabled: bar.menuOpen
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: {
        bar.menuOpen = false
        if (!bar.host.speaking) bar.hide()
      }
    }

    BorderSurface {
      id: pill
      readonly property bool below: bar.pointerY + win.gap + height + win.edge <= win.height
      // Anchored on its centre (the play button), so growing the skip buttons
      // expands both sides equally and the play button never moves.
      readonly property real collapsedWidth: mainButton.implicitWidth + contentLeftInset + contentRightInset
      readonly property real homeCenterX: bar.pointerX + win.gap + collapsedWidth / 2
      readonly property real homeY: below ? bar.pointerY + win.gap : bar.pointerY - win.gap - height
      x: Math.max(win.edge, Math.min(win.width - width - win.edge, homeCenterX + bar.dragX - width / 2))
      y: Math.max(win.edge, Math.min(win.height - height - win.edge, homeY + bar.dragY))
      width: controls.implicitWidth + contentLeftInset + contentRightInset
      height: controls.implicitHeight + contentTopInset + contentBottomInset
      radius: height / 2
      // Fully transparent capsule: only the outline and icons are drawn, so
      // Hyprland's ignore_alpha rule leaves the page behind it unblurred.
      color: "transparent"
      borderSpec: bar.glassBorder
      padding: Style.space(3)
      opacity: Math.min(1, bar.presence)
      scale: 0.85 + 0.15 * bar.presence
      transform: Translate { x: bar.shakeX }

      // Accent ring that pulses while speaking and fades out otherwise.
      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(2)
        radius: height / 2
        color: "transparent"
        border.width: Math.max(1, Style.space(2))
        border.color: Color.accent
        opacity: bar.phase === "speaking" ? bar.pulse : 0
        Behavior on opacity { enabled: bar.phase !== "speaking"; NumberAnimation { duration: 250 } }
      }

      HoverHandler { id: pillHover }

      // Drag to move. Takes over from the buttons only once the pointer
      // moves past the drag threshold, so a plain click still plays/pauses.
      DragHandler {
        id: pillDrag
        target: null
        property real startX: 0
        property real startY: 0
        onActiveChanged: {
          if (active) {
            startX = bar.dragX
            startY = bar.dragY
          } else {
            // Drop any overshoot past the screen edge so dragging back responds at once.
            bar.dragX = pill.x + pill.width / 2 - pill.homeCenterX
            bar.dragY = pill.y - pill.homeY
          }
        }
        onTranslationChanged: {
          if (!active) return
          bar.dragX = startX + translation.x
          bar.dragY = startY + translation.y
        }
      }

      // Idle: just play. While speaking it grows skip-back / forward buttons.
      Row {
        id: controls
        x: pill.contentLeftInset
        y: pill.contentTopInset
        spacing: Style.space(2)

        PillButton {
          reveal: bar.seekable ? 1 : 0
          iconText: "󰑟"
          onClicked: { nudgeNow(-1); bar.host.skipBack("") }
          onRightClicked: bar.menuOpen = !bar.menuOpen
        }
        PillButton {
          id: mainButton
          // Loading/generating shows a spinner until the first audio plays.
          iconText: bar.phase === "loading" ? "󰑓" : (bar.playing ? "󰏤" : "󰐊")
          iconSpinning: bar.phase === "loading"
          active: bar.host.speaking
          opacity: bar.phase === "paused" ? bar.breathe : 1
          onClicked: bar.togglePlay()
          onRightClicked: bar.menuOpen = !bar.menuOpen
        }
        PillButton {
          reveal: bar.seekable ? 1 : 0
          iconText: "󰈑"
          onClicked: { nudgeNow(1); bar.host.skipForward("") }
          onRightClicked: bar.menuOpen = !bar.menuOpen
        }
      }
    }

    // ---------------- quick settings card (right-click)
    BorderSurface {
      id: card
      visible: bar.cardIn > 0.01
      opacity: bar.cardIn
      transform: Translate { y: (1 - bar.cardIn) * Style.space(8) * (card.y > pill.y ? 1 : -1) }
      width: Style.space(272)
      height: cardColumn.implicitHeight + contentTopInset + contentBottomInset
      x: Math.max(win.edge, Math.min(win.width - width - win.edge, pill.x + pill.width / 2 - width / 2))
      // Below the capsule when it fits there, otherwise above.
      y: pill.y + pill.height + Style.space(4) + height + win.edge <= win.height
        ? Math.min(win.height - height - win.edge, pill.y + pill.height + Style.space(4))
        : Math.max(win.edge, pill.y - height - Style.space(4))
      radius: Style.cornerRadius
      color: bar.glassFill
      borderSpec: bar.glassBorder
      padding: Style.space(10)

      GlassSheen { radius: card.radius }

      // Swallow clicks so they don't reach the close-on-outside-click area.
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

      ColumnLayout {
        id: cardColumn
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: Style.space(6)

        RowLayout {
          Layout.fillWidth: true
          Text {
            Layout.fillWidth: true
            text: "Kokoro TTS"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            text: bar.host.paused ? "Paused" : (bar.host.speaking ? "Speaking" : bar.host.modelState === "ready" ? "Ready" : "Idle")
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Dropdown {
          Layout.fillWidth: true
          showLabel: false
          options: Voices.options()
          value: bar.settings.voice
          onChanged: function(v) { bar.settings.voice = v }
        }

        QuickSlider {
          label: "Speed"
          readout: liveValue.toFixed(2) + "×"
          minimum: 0.5
          maximum: 2.0
          value: bar.settings.speed
          theme: bar.host.fakeBar
          onCommit: function(v) { bar.settings.speed = v }
        }

        QuickSlider {
          label: "Volume"
          readout: Math.round(liveValue * 100) + "%"
          minimum: 0
          maximum: 1.5
          value: bar.settings.volume
          theme: bar.host.fakeBar
          onCommit: function(v) { bar.settings.volume = v }
        }

        RowLayout {
          Layout.fillWidth: true
          Text {
            Layout.fillWidth: true
            text: "Show on text selection"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          ToggleSwitch {
            checked: bar.settings.floatingBar
            onToggled: bar.settings.floatingBar = !bar.settings.floatingBar
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap
          Text {
            visible: bar.host.speaking
            text: bar.host.clock(bar.host.position) + " / " + bar.host.clock(bar.host.duration)
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Button {
            iconText: "󰓛"
            tooltipText: "Stop"
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(3)
            bordered: true
            enabled: bar.host.speaking
            opacity: enabled ? 1 : 0.5
            onClicked: bar.host.stop("")
          }
          Item { Layout.fillWidth: true }
          Button {
            iconText: "󰏌"
            tooltipText: "Open the Kokoro TTS app"
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(3)
            bordered: true
            onClicked: {
              bar.hide()
              if (bar.host.shell) bar.host.shell.summon(bar.host.pluginId, "{}")
            }
          }
        }
      }
    }
  }

  // Round icon button for the pill.
  component PillButton: Button {
    id: pb
    // 1 = shown; animating to 0 slides the button shut (used by the skip buttons).
    property real reveal: 1
    property real pop: 1
    property real nudge: 0
    iconSize: Style.font.icon
    radius: height / 2
    // Revealed by growing from its own centre (no clipping), so both skip
    // buttons open the same way.
    width: implicitWidth * reveal
    visible: reveal > 0.01
    opacity: reveal
    Behavior on reveal { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    // Hover grows the button a little.
    scale: hot ? 1.08 : 1
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    transform: [
      Scale { origin.x: pb.width / 2; origin.y: pb.height / 2; xScale: pb.pop * pb.reveal; yScale: pb.pop * (0.5 + 0.5 * pb.reveal) },
      Translate { x: pb.nudge }
    ]

    function popNow() { popAnim.restart() }
    function nudgeNow(direction) { nudgeTo.to = 4 * direction; nudgeAnim.restart() }

    SequentialAnimation {
      id: popAnim
      NumberAnimation { target: pb; property: "pop"; to: 0.72; duration: 70; easing.type: Easing.InQuad }
      NumberAnimation { target: pb; property: "pop"; to: 1; duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
    }
    SequentialAnimation {
      id: nudgeAnim
      NumberAnimation { id: nudgeTo; target: pb; property: "nudge"; duration: 70; easing.type: Easing.OutQuad }
      NumberAnimation { target: pb; property: "nudge"; to: 0; duration: 200; easing.type: Easing.OutBack }
    }
  }

  // One compact row: label · slider · readout; the value is saved on release.
  component QuickSlider: RowLayout {
    id: quick
    property var theme: null
    property string label: ""
    property string readout: ""
    property alias minimum: slider.minimum
    property alias maximum: slider.maximum
    property alias value: slider.value
    readonly property alias liveValue: slider.liveValue
    signal commit(real value)
    Layout.fillWidth: true
    spacing: Style.space(6)

    Text {
      Layout.preferredWidth: Style.space(44)
      text: quick.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    PanelSlider {
      id: slider
      Layout.fillWidth: true
      bar: quick.theme
      step: 0.05
      onReleased: function(v) { quick.commit(Math.round(v * 100) / 100) }
    }
    Text {
      Layout.preferredWidth: Style.space(34)
      horizontalAlignment: Text.AlignRight
      text: quick.readout
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
