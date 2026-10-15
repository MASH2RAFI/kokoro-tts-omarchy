import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Voices.js" as Voices

// Kokoro TTS app window + the long-running Kokoro worker it drives.
// keepLoaded: true keeps this item (and the loaded model) alive while the
// window is closed, so the bar widget and keybindings can speak instantly.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: manifest && manifest.id ? manifest.id : "mash2rafi.kokoro"
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string pythonPath: settings.pythonPath || (homeDir + "/.local/share/kokoro-tts/venv/bin/python")
  readonly property string workerPath: decodeURIComponent(Qt.resolvedUrl("kokoro_worker.py").toString().replace(/^file:\/\//, ""))

  // Worker / model state
  property string modelState: "stopped"   // stopped | starting | loading | ready | error
  property string device: ""
  property string deviceName: ""
  property string player: ""
  property var players: []
  property string warningText: ""
  property bool workerAlive: false
  property var pendingCommands: []
  property bool speaking: false   // stays true while paused
  property bool paused: false
  property real position: 0      // playhead, seconds
  property real duration: 0      // audio generated so far, seconds
  property bool complete: false  // generation finished; duration is final
  property int jobId: 0
  property string progressText: ""
  property string lastResult: ""
  property string lastSaved: ""
  property string errorText: ""
  property string lastStderr: ""
  property string page: "speak"

  // Main window opens with a short fade and zoom.
  property real openAmount: root.opened ? 1 : 0
  Behavior on openAmount { NumberAnimation { duration: root.opened ? 200 : 0; easing.type: Easing.OutCubic } }

  readonly property var fakeBar: QtObject {
    readonly property color foreground: Color.foreground
    readonly property color background: Color.background
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: Style.font.family
  }

  // ---------------------------------------------------------------- settings

  FileView {
    id: settingsFile
    path: root.homeDir + "/.config/omarchy/kokoro-tts.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) writeAdapter()
    }

    JsonAdapter {
      id: settings
      property string voice: "af_heart"
      property real speed: 1.0
      property real volume: 1.0
      property string device: "auto"
      property bool autoPlay: true
      property bool saveAudio: false
      property string saveDir: "~/Music/Kokoro"
      property int unloadAfterMinutes: 10
      property bool preload: false
      property string hotkeySource: "selection"
      property bool floatingBar: true
      property real skipSeconds: 5
      property string player: "auto"
      property string pythonPath: ""
      property string lastText: ""
    }
  }

  function resetSettings() {
    settings.voice = "af_heart"
    settings.speed = 1.0
    settings.volume = 1.0
    settings.device = "auto"
    settings.autoPlay = true
    settings.saveAudio = false
    settings.saveDir = "~/Music/Kokoro"
    settings.unloadAfterMinutes = 10
    settings.preload = false
    settings.hotkeySource = "selection"
    settings.floatingBar = true
    settings.skipSeconds = 5
    settings.player = "auto"
  }

  // ---------------------------------------------------------------- worker

  Process {
    id: worker
    command: [root.pythonPath, root.workerPath]
    stdinEnabled: true
    // VIRTUAL_ENV lets misaki/spaCy install any missing language data into
    // the Kokoro venv instead of failing with "No virtual environment found".
    environment: ({
      "PYTHONUNBUFFERED": "1",
      "VIRTUAL_ENV": root.pythonPath.replace(/\/bin\/python[0-9.]*$/, "")
    })
    stdout: SplitParser {
      onRead: function(data) { root.handleEvent(data) }
    }
    stderr: SplitParser {
      onRead: function(data) {
        var line = String(data || "").trim()
        if (line.length) root.lastStderr = line
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.workerAlive = false
      // A request that arrived while an unload was shutting the worker down
      // is queued; start a fresh worker for it instead of dropping it.
      if (root.unloading && root.pendingCommands.length > 0) {
        root.unloading = false
        root.modelState = "starting"
        root.device = ""
        worker.running = true
        return
      }
      root.unloading = false
      root.speaking = false
      root.paused = false
      root.pendingCommands = []
      if (root.modelState !== "stopped" && exitCode !== 0) {
        root.modelState = "error"
        root.errorText = "Kokoro worker exited (" + exitCode + ")"
          + (root.lastStderr ? ": " + root.lastStderr : "")
      } else {
        root.modelState = "stopped"
      }
      root.device = ""
    }
  }

  function send(command) {
    var line = JSON.stringify(command) + "\n"
    if (root.workerAlive) {
      worker.write(line)
      return
    }
    var queue = root.pendingCommands.slice()
    queue.push(line)
    root.pendingCommands = queue
    if (!worker.running) {
      root.errorText = ""
      root.lastStderr = ""
      root.modelState = "starting"
      worker.running = true
    }
  }

  function loadModel() {
    root.send({ cmd: "load", device: settings.device })
  }

  property bool unloading: false

  function unloadModel() {
    if (!worker.running) return
    // From here on, send() queues instead of writing to the exiting worker.
    root.unloading = true
    root.workerAlive = false
    root.modelState = "stopped"
    worker.write(JSON.stringify({ cmd: "quit" }) + "\n")
    worker.signal(15)
  }

  function handleEvent(raw) {
    var ev
    try { ev = JSON.parse(raw) } catch (e) { return }
    switch (ev.event) {
    case "hello":
      root.workerAlive = true
      root.players = ev.players || []
      root.player = ev.player || ""
      var queue = root.pendingCommands
      root.pendingCommands = []
      for (var i = 0; i < queue.length; i++) worker.write(queue[i])
      break
    case "loading":
      root.modelState = "loading"
      root.device = ev.device || ""
      break
    case "ready":
      root.modelState = "ready"
      root.device = ev.device || ""
      root.deviceName = ev.deviceName || ""
      break
    case "position":
      if (ev.id !== root.jobId) break
      root.position = ev.seconds || 0
      root.duration = ev.total || 0
      root.complete = !!ev.complete
      root.progressText = (root.paused ? "Paused · " : "Speaking · ") + root.clock(root.position)
        + " / " + root.clock(root.duration) + (root.complete ? "" : "…")
      break
    case "paused":
      root.paused = true
      break
    case "resumed":
      root.paused = false
      break
    case "warning":
      root.warningText = ev.message || ""
      break
    case "started":
      root.speaking = true
      root.paused = false
      root.progressText = "Generating…"
      break
    case "chunk":
      if (ev.id !== root.jobId) break
      root.modelState = "ready"
      root.duration = ev.audioSeconds || 0
      if (!settings.autoPlay) root.progressText = "Generating · " + root.clock(root.duration)
      break
    case "done":
      if (ev.id !== root.jobId) break
      root.speaking = false
      root.paused = false
      root.device = ev.device || root.device
      root.progressText = ""
      root.lastResult = Number(ev.audioSeconds).toFixed(1) + " s of audio in "
        + Number(ev.generateSeconds).toFixed(1) + " s (" + ev.realtime + "× real time, "
        + String(ev.device || "").toUpperCase() + ")"
      root.lastSaved = ev.saved || ""
      break
    case "stopped":
      if (ev.id !== root.jobId) break
      root.speaking = false
      root.paused = false
      root.progressText = ""
      root.lastResult = "Stopped"
      break
    case "error":
      if (ev.id !== undefined && ev.id !== root.jobId) break
      if (ev.id !== undefined) { root.speaking = false; root.paused = false }
      root.progressText = ""
      root.errorText = ev.message || "Unknown error"
      if (!root.opened) Quickshell.execDetached(["notify-send", "-a", "Kokoro TTS", "Kokoro TTS", root.errorText])
      break
    }
  }

  Timer {
    id: idleUnload
    interval: Math.max(1, settings.unloadAfterMinutes) * 60000
    running: settings.unloadAfterMinutes > 0 && worker.running && !root.speaking
    onTriggered: root.unloadModel()
  }

  // ---------------------------------------------------------------- speech API
  // Also reachable from a keybinding:
  //   omarchy-shell shell call mash2rafi.kokoro speakSelection ""

  function speak(text) {
    var t = String(text || "").trim()
    if (!t.length) {
      root.errorText = "Nothing to speak"
      return "empty"
    }
    root.errorText = ""
    root.warningText = ""
    root.lastSaved = ""
    root.jobId += 1
    root.speaking = true
    root.paused = false
    root.position = 0
    root.duration = 0
    root.complete = false
    root.progressText = root.modelState === "ready" ? "Generating…" : "Loading model…"
    root.send({
      cmd: "speak",
      id: root.jobId,
      text: t,
      voice: Voices.isKnown(settings.voice) ? settings.voice : "af_heart",
      speed: settings.speed,
      volume: settings.volume,
      device: settings.device,
      player: settings.player,
      play: settings.autoPlay,
      saveDir: settings.saveAudio ? settings.saveDir : ""
    })
    return "ok"
  }

  function stop(arg) {
    if (worker.running) worker.write(JSON.stringify({ cmd: "stop" }) + "\n")
    root.speaking = false
    root.paused = false
    root.progressText = ""
    return "ok"
  }

  function pause(arg) {
    if (!root.speaking || root.paused || !root.workerAlive) return "idle"
    worker.write(JSON.stringify({ cmd: "pause" }) + "\n")
    return "ok"
  }

  function resume(arg) {
    if (!root.paused || !root.workerAlive) return "idle"
    worker.write(JSON.stringify({ cmd: "resume" }) + "\n")
    return "ok"
  }

  // Jump the playhead by `seconds` (negative = back); clamps to the clip.
  function skip(seconds) {
    if (!root.speaking || !root.workerAlive) return "idle"
    worker.write(JSON.stringify({ cmd: "seek", delta: Number(seconds) || 0 }) + "\n")
    return "ok"
  }

  // For keybindings: omarchy-shell shell call mash2rafi.kokoro skipBack ""
  function skipBack(arg) { return root.skip(-(Number(arg) || settings.skipSeconds)) }
  function skipForward(arg) { return root.skip(Number(arg) || settings.skipSeconds) }

  function clock(seconds) {
    var t = Math.max(0, Math.floor(seconds))
    var sec = t % 60
    return Math.floor(t / 60) + ":" + (sec < 10 ? "0" : "") + sec
  }

  // For a keybinding: omarchy-shell shell call mash2rafi.kokoro togglePause ""
  function togglePause(arg) {
    return root.paused ? root.resume("") : root.pause("")
  }

  // For scripts: omarchy-shell shell call mash2rafi.kokoro statusJson ""
  function statusJson(arg) {
    return JSON.stringify({
      model: root.modelState, device: root.device, deviceName: root.deviceName,
      player: root.player, warning: root.warningText, speaking: root.speaking, paused: root.paused,
      position: root.position, duration: root.duration,
      progress: root.progressText, last: root.lastResult, saved: root.lastSaved,
      error: root.errorText
    })
  }

  // Toggle-friendly: a second press while speaking stops playback.
  function speakSelection(arg) {
    if (root.speaking) return root.stop("")
    return root.readClipboard(settings.hotkeySource !== "clipboard", function(text) { root.speak(text) })
  }

  function speakClipboard(arg) {
    if (root.speaking) return root.stop("")
    return root.readClipboard(false, function(text) { root.speak(text) })
  }

  property var clipboardCallback: null

  function readClipboard(primary, callback) {
    if (clipboardProc.running) return "busy"
    root.clipboardCallback = callback
    clipboardProc.command = primary
      ? ["wl-paste", "--primary", "--no-newline"]
      : ["wl-paste", "--no-newline"]
    clipboardProc.running = true
    return "ok"
  }

  Process {
    id: clipboardProc
    stdout: StdioCollector {
      onStreamFinished: {
        var cb = root.clipboardCallback
        root.clipboardCallback = null
        if (cb) cb(this.text)
      }
    }
  }

  Process {
    id: openFolderProc
  }

  function openSaveFolder() {
    var dir = String(settings.saveDir || "~/Music/Kokoro").replace(/^~/, root.homeDir)
    openFolderProc.command = ["sh", "-c", "mkdir -p \"$1\" && xdg-open \"$1\"", "sh", dir]
    openFolderProc.running = true
  }

  // ---------------------------------------------------------------- host hooks

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (payload.action === "speakSelection") {
      root.speakSelection("")
      Qt.callLater(function() { if (root.shell) root.shell.hide(root.pluginId) })
      return
    }
    if (payload.page === "speak" || payload.page === "settings") root.page = payload.page
    closingFromHost = false
    root.opened = true
    Qt.callLater(function() { textInput.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    if (textInput.text !== settings.lastText) settings.lastText = textInput.text
    root.opened = false
    closingFromHost = false
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else root.close()
  }

  Component.onCompleted: {
    if (settings.preload) root.loadModel()
  }

  // ---------------------------------------------------------------- UI

  SelectionBar {
    host: root
    settings: settings
  }

  readonly property string statusText: {
    switch (root.modelState) {
    case "starting": return "Starting Kokoro…"
    case "loading": return "Loading model on " + (root.device || "…").toUpperCase() + "…"
    case "ready": return "Ready · " + (root.deviceName || root.device.toUpperCase())
      + (root.player ? " · audio via " + root.player : "")
    case "error": return "Error"
    default: return "Model not loaded — loads on first use"
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mash2rafi-kokoro"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      opacity: root.openAmount
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.requestClose()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(620), panel.width - Style.gapsOut * 6)
      height: Math.min(Style.space(600), panel.height - Style.gapsOut * 6)
      radius: Style.cornerRadius
      // Frosted glass, matching the floating bar (Hyprland blurs the "mash2rafi-kokoro" layer).
      color: Util.alpha(Color.popups.background, 0.62)
      borderSpec: Border.flat(Util.alpha(Color.popups.text, 0.22), Math.max(1, Style.space(1)))
      padding: Style.spacing.panelPadding + Style.space(6)
      opacity: root.openAmount
      scale: 0.96 + 0.04 * root.openAmount

      GlassSheen { radius: card.radius }

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      FocusScope {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true

        Keys.onEscapePressed: root.requestClose()

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(14)

          // Header
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            Text {
              text: "󰗋"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.display
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)
              Text {
                text: "Kokoro TTS"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                Layout.fillWidth: true
                text: root.statusText
                color: root.modelState === "error" ? Color.urgent : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            ButtonGroup {
              options: [
                { value: "speak", label: "Speak" },
                { value: "settings", label: "Settings" }
              ]
              value: root.page
              onChanged: function(v) { root.page = v }
            }
          }

          // ---------------- Speak page
          ColumnLayout {
            visible: root.page === "speak"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(10)

            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              color: Style.normalFill
              border.width: Style.normalBorderWidth
              border.color: textInput.activeFocus ? Style.focusBorderColor : Style.normalBorderColor
              radius: Style.cornerRadius

              ScrollView {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                clip: true

                TextArea {
                  id: textInput
                  text: settings.lastText
                  placeholderText: "Type or paste text to speak…  (Ctrl+Enter to speak, Esc to close)"
                  placeholderTextColor: Color.muted
                  color: Color.foreground
                  selectionColor: Style.selectionFill
                  selectedTextColor: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  wrapMode: TextArea.Wrap
                  padding: Style.space(10)
                  background: null
                  Keys.onPressed: function(event) {
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        && (event.modifiers & Qt.ControlModifier)) {
                      root.speak(textInput.text)
                      event.accepted = true
                    } else if (event.key === Qt.Key_Escape) {
                      root.requestClose()
                      event.accepted = true
                    }
                  }
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.controlGap

              Dropdown {
                Layout.preferredWidth: Style.space(250)
                showLabel: false
                options: Voices.options()
                value: settings.voice
                onChanged: function(v) { settings.voice = v }
              }

              Text {
                text: Number(settings.speed).toFixed(2) + "×"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Item { Layout.fillWidth: true }

              Button {
                text: "Paste"
                iconText: "󰅌"
                bordered: true
                tooltipText: "Replace the text with the clipboard"
                onClicked: root.readClipboard(false, function(t) { textInput.text = t })
              }

              Button {
                text: "Clear"
                bordered: true
                onClicked: { textInput.text = ""; textInput.forceActiveFocus() }
              }

              Button {
                text: root.speaking ? "Stop" : "Speak"
                iconText: root.speaking ? "󰓛" : "󰐊"
                bordered: true
                active: true
                onClicked: root.speaking ? root.stop("") : root.speak(textInput.text)
              }
            }

            // While speaking: back / pause-resume / forward, then the status line.
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.controlGap

              Button {
                visible: root.speaking && settings.autoPlay
                iconText: "󰑟"
                bordered: true
                verticalPadding: Style.space(3)
                tooltipText: "Back " + settings.skipSeconds + " s"
                onClicked: root.skipBack("")
              }

              Button {
                visible: root.speaking && settings.autoPlay
                iconText: root.paused ? "󰐊" : "󰏤"
                bordered: true
                verticalPadding: Style.space(3)
                tooltipText: root.paused ? "Resume" : "Pause"
                onClicked: root.togglePause("")
              }

              Button {
                visible: root.speaking && settings.autoPlay
                iconText: "󰈑"
                bordered: true
                verticalPadding: Style.space(3)
                tooltipText: "Forward " + settings.skipSeconds + " s"
                onClicked: root.skipForward("")
              }

              Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.errorText.length ? root.errorText
                  : (root.progressText.length ? root.progressText
                  : (root.warningText.length ? root.warningText : root.lastResult))
                color: root.errorText.length || (!root.progressText.length && root.warningText.length)
                  ? Color.urgent : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            RowLayout {
              Layout.fillWidth: true
              visible: root.lastSaved.length > 0
              Text {
                Layout.fillWidth: true
                text: "Saved " + root.lastSaved
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
              Button {
                text: "Open folder"
                bordered: true
                onClicked: root.openSaveFolder()
              }
            }
          }

          // ---------------- Settings page
          ScrollView {
            id: settingsScroll
            visible: root.page === "settings"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
              width: settingsScroll.availableWidth
              spacing: Style.space(12)

              PanelSectionHeader { text: "Voice" }

              SettingRow {
                label: "Voice"
                description: "41 voices across 7 languages; the voice sets the language"
                Dropdown {
                  Layout.preferredWidth: Style.space(250)
                  showLabel: false
                  options: Voices.options()
                  value: settings.voice
                  onChanged: function(v) { settings.voice = v }
                }
              }

              SettingRow {
                label: "Speed"
                description: speedSlider.liveValue.toFixed(2) + "×"
                PanelSlider {
                  id: speedSlider
                  Layout.preferredWidth: Style.space(250)
                  bar: root.fakeBar
                  minimum: 0.5
                  maximum: 2.0
                  step: 0.05
                  value: settings.speed
                  onReleased: function(v) { settings.speed = Math.round(v * 100) / 100 }
                  WheelToScroll { flick: settingsScroll.contentItem }
                }
              }

              SettingRow {
                label: "Volume"
                description: Math.round(volumeSlider.liveValue * 100) + "%"
                PanelSlider {
                  id: volumeSlider
                  Layout.preferredWidth: Style.space(250)
                  bar: root.fakeBar
                  minimum: 0
                  maximum: 1.5
                  step: 0.05
                  value: settings.volume
                  onReleased: function(v) { settings.volume = Math.round(v * 100) / 100 }
                  WheelToScroll { flick: settingsScroll.contentItem }
                }
              }

              SettingRow {
                label: "Play audio"
                description: "Stream speech to the speakers while it generates"
                ToggleSwitch {
                  checked: settings.autoPlay
                  onToggled: settings.autoPlay = !settings.autoPlay
                }
              }

              SettingRow {
                label: "Audio output"
                description: root.players.length ? "Found: " + root.players.join(", ") : "Detected when the model starts"
                ButtonGroup {
                  options: [
                    { value: "auto", label: "Auto" },
                    { value: "pw-cat", label: "PipeWire" },
                    { value: "paplay", label: "Pulse" },
                    { value: "aplay", label: "ALSA" }
                  ]
                  value: settings.player
                  onChanged: function(v) { settings.player = v }
                }
              }

              PanelSectionHeader { text: "Saving" }

              SettingRow {
                label: "Save WAV files"
                description: "Keep a copy of every clip"
                ToggleSwitch {
                  checked: settings.saveAudio
                  onToggled: settings.saveAudio = !settings.saveAudio
                }
              }

              SettingRow {
                label: "Folder"
                enabled: settings.saveAudio
                opacity: enabled ? 1 : 0.5
                TextField {
                  Layout.preferredWidth: Style.space(250)
                  text: settings.saveDir
                  onEditingFinished: settings.saveDir = text
                }
              }

              PanelSectionHeader { text: "Model" }

              SettingRow {
                label: "Device"
                description: "Auto: NVIDIA/AMD, then Intel, then CPU. Any GPU error falls back to CPU."
                ButtonGroup {
                  options: [
                    { value: "auto", label: "Auto" },
                    { value: "cuda", label: "NVIDIA/AMD" },
                    { value: "xpu", label: "Intel" },
                    { value: "cpu", label: "CPU" }
                  ]
                  value: settings.device
                  onChanged: function(v) {
                    settings.device = v
                    if (worker.running) root.loadModel()
                  }
                }
              }

              SettingRow {
                label: "Unload when idle"
                description: unloadSlider.liveValue < 1 ? "Never — keep the model in memory"
                  : "After " + Math.round(unloadSlider.liveValue) + " min without speech (frees ~1 GB VRAM)"
                PanelSlider {
                  id: unloadSlider
                  Layout.preferredWidth: Style.space(250)
                  bar: root.fakeBar
                  minimum: 0
                  maximum: 60
                  step: 1
                  integer: true
                  value: settings.unloadAfterMinutes
                  onReleased: function(v) { settings.unloadAfterMinutes = Math.round(v) }
                  WheelToScroll { flick: settingsScroll.contentItem }
                }
              }

              SettingRow {
                label: "Load at login"
                description: "Preload the model when the shell starts"
                ToggleSwitch {
                  checked: settings.preload
                  onToggled: settings.preload = !settings.preload
                }
              }

              SettingRow {
                label: root.statusText
                Button {
                  text: worker.running ? "Unload model" : "Load model"
                  bordered: true
                  onClicked: worker.running ? root.unloadModel() : root.loadModel()
                }
              }

              PanelSectionHeader { text: "Hotkey" }

              SettingRow {
                label: "Speak-selection reads"
                description: "Right-click the bar icon, or bind: omarchy-shell shell call mash2rafi.kokoro speakSelection \"\""
                ButtonGroup {
                  options: [
                    { value: "selection", label: "Selection" },
                    { value: "clipboard", label: "Clipboard" }
                  ]
                  value: settings.hotkeySource
                  onChanged: function(v) { settings.hotkeySource = v }
                }
              }

              SettingRow {
                label: "Floating bar on selection"
                description: "Show a play/pause button next to the pointer when you select text; right-click it for quick settings"
                ToggleSwitch {
                  checked: settings.floatingBar
                  onToggled: settings.floatingBar = !settings.floatingBar
                }
              }

              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(6)
                Item { Layout.fillWidth: true }
                Button {
                  text: "Reset to defaults"
                  bordered: true
                  onClicked: root.resetSettings()
                }
              }
            }
          }
        }
      }
    }
  }

  // Sits over a slider inside the scrolling settings page: the mouse wheel
  // scrolls the page instead of silently changing the slider's value.
  // Buttons pass through, so click and drag still work.
  component WheelToScroll: MouseArea {
    property Flickable flick: null
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    onWheel: function(wheel) {
      if (!flick) return
      var maxY = Math.max(0, flick.contentHeight - flick.height)
      flick.contentY = Math.max(0, Math.min(maxY, flick.contentY - wheel.angleDelta.y))
    }
  }

  // One labelled settings row: label + optional description on the left,
  // the control (default children) on the right.
  component SettingRow: RowLayout {
    id: row
    property string label: ""
    property string description: ""
    default property alias control: slot.data
    Layout.fillWidth: true
    spacing: Style.space(12)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(2)
      Text {
        Layout.fillWidth: true
        text: row.label
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        visible: row.description.length > 0
        text: row.description
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }

    RowLayout {
      id: slot
      Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
    }
  }
}
