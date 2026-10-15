# Kokoro TTS — Omarchy plugin (mash2rafi.kokoro)

Local text-to-speech for the Omarchy shell, powered by
[hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M). Everything runs on this
machine; the model downloads once (~330 MB). Omarchy-only edition: for other Quickshell
desktops use the universal [kokoro-tts](https://github.com/MASH2RAFI/kokoro-tts) package.

## Install

This repo is the plugin folder itself, so either route works. Both need `install.sh` once,
because the plugin needs a Python environment with PyTorch and Kokoro.

**With Omarchy's plugin manager** (updates later with `omarchy plugin update mash2rafi.kokoro`):

```bash
omarchy plugin add https://github.com/MASH2RAFI/kokoro-tts-omarchy
~/.config/omarchy/plugins/mash2rafi.kokoro/install.sh
```

**From a clone:**

```bash
./install.sh --dry-run   # show what it detected; changes nothing
./install.sh             # install or update (asks for sudo once if espeak-ng/uv are missing)
./install.sh --gpu=cpu   # force a build: nvidia | amd | intel | cpu
./install.sh --uninstall
```

It installs `espeak-ng` and `uv` with pacman, creates a Python 3.12 environment in
`~/.local/share/kokoro-tts/venv`, installs the right PyTorch build for your GPU plus Kokoro
and the spaCy English model, and downloads the model. Run from a clone, it then copies the
plugin into `~/.config/omarchy/plugins/mash2rafi.kokoro/` (a changed plugin is backed up to
`~/.local/share/kokoro-tts/backups/` first); run from the installed checkout, it skips the
copy. Finally it enables the plugin and restarts the shell. Re-running is quick and safe.

| GPU | Build |
|---|---|
| NVIDIA | CUDA 13 (driver ≥ 580), CUDA 12.6 (525–579), CPU (older drivers) |
| AMD Radeon RX / Pro / Instinct | newest ROCm on download.pytorch.org |
| Intel Arc / Core Ultra | XPU |
| Intel UHD/Iris, AMD integrated, none | CPU (~1.3 GB) |

Any GPU error at runtime falls back to the CPU and shows a warning in the app.

## Use

- **Bar icon** (󰗋): click to open the app, right-click to speak the selected text
  (right-click again while it speaks to stop).
- **Floating bar**: select text anywhere and a small frosted-glass ▶ pill appears next to
  the pointer. Click it to read the selection aloud; while speaking it shows
  ⏪ ⏯ ⏩ (pause/resume, skip back/forward). Right-click it for quick settings (voice,
  speed, volume, stop, open the app, turn the floating bar off). It hides itself a few
  seconds after speech ends, and never takes keyboard focus from the app you're in.
- **App**: type or paste text, pick a voice, press **Speak** or `Ctrl+Enter`. While speaking,
  the same skip and pause buttons appear. `Esc` closes.
- **Keybinding** (optional), e.g. in `~/.config/hypr/bindings.lua`, bind a key to:

  ```
  omarchy-shell shell call mash2rafi.kokoro speakSelection ""
  ```

  Other methods: `speakClipboard ""`, `speak "some text"`, `togglePause ""`, `skipBack ""`,
  `skipForward ""` (pass a number of seconds to override `skipSeconds`), `stop ""`,
  `statusJson ""` (current state as JSON).
  Open straight to settings: `omarchy-shell shell summon mash2rafi.kokoro '{"page":"settings"}'`.

## Settings

Settings tab, or `~/.config/omarchy/kokoro-tts.json` (editable by hand; changes apply live).

| Key | Default | Meaning |
|---|---|---|
| `voice` | `af_heart` | One of 41 voices (US/UK English, Spanish, French, Hindi, Italian, Portuguese) |
| `speed` | `1.0` | 0.5–2.0 |
| `volume` | `1.0` | 0–1.5 |
| `autoPlay` | `true` | Stream audio to the speakers while generating |
| `player` | `auto` | `auto`, `pw-cat`, `paplay`, `aplay` |
| `saveAudio` / `saveDir` | `false` / `~/Music/Kokoro` | Also save each clip as a WAV file |
| `device` | `auto` | `auto`, `cuda` (NVIDIA or AMD), `xpu` (Intel), `cpu` |
| `unloadAfterMinutes` | `10` | Stop the worker after this long idle (0 = never) to free ~1 GB VRAM |
| `preload` | `false` | Load the model when the shell starts |
| `hotkeySource` | `selection` | What speak-selection reads: `selection` (primary) or `clipboard` |
| `floatingBar` | `true` | Show the play/pause pill when text is selected |
| `skipSeconds` | `5` | How far the skip buttons jump |
| `minSelectionChars` | `12` | Selections shorter than this (not counting spaces) don't show the floating bar |
| `pythonPath` | *(empty)* | Override the Python interpreter (default `~/.local/share/kokoro-tts/venv/bin/python`) |

## Frosted glass

The surfaces are translucent with a light edge out of the box. For the blur behind them,
Hyprland's blur must be on; Omarchy ships it off. To blur only Kokoro and leave windows
unchanged, add to `~/.config/hypr/looknfeel.lua`:

```lua
hl.config({ decoration = { blur = { enabled = true, size = 5, passes = 2, vibrancy = 0.17 } } })
o.window({ class = ".*" }, { no_blur = true })
hl.layer_rule({ match = { namespace = "^mash2rafi-kokoro(-selection)?$" }, blur = true, ignore_alpha = 0.05 })
```

## Files

- `manifest.json` — plugin manifest (at the repo root, as `omarchy plugin add` expects)
- `Panel.qml` — app window, settings, and the worker process manager
- `BarWidget.qml` — bar icon
- `SelectionBar.qml` — floating play/pause/skip pill and its right-click quick-settings card
- `GlassSheen.qml` — highlight overlay for the frosted-glass surfaces
- `kokoro_worker.py` — long-running Python process: loads Kokoro once, GPU/CPU fallback, buffered playback with pause and seek, audio players, clipboard, WAV saving
- `Voices.js` — voice list and labels
- `install.sh` — dependency and model installer

## Editing the code

The panel is `keepLoaded`, so Omarchy does not hot-reload it: after changing
`Panel.qml` run `omarchy restart shell`. The worker (`kokoro_worker.py`) is
restarted automatically the next time the model loads (use **Unload model** in
Settings to force it).

Japanese and Mandarin voices need `misaki[ja]` / `misaki[zh]` and are not listed.
