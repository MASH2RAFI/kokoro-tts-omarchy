# Kokoro TTS — Omarchy plugin

Local text-to-speech for the Omarchy shell, powered by
[hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M). Omarchy-only edition:
for other Quickshell desktops use the universal `kokoro-tts` package.

## Install

```bash
./install.sh --dry-run   # show what it detected; changes nothing
./install.sh             # install or update (asks for sudo once if espeak-ng/uv are missing)
./install.sh --gpu=cpu   # force a build: nvidia | amd | intel | cpu
./install.sh --uninstall
```

It installs `espeak-ng` and `uv` with pacman, creates a Python 3.12 environment in
`~/.local/share/kokoro-tts/venv`, installs the right PyTorch build for your GPU plus Kokoro
and the spaCy English model, downloads the model, then copies `mash2rafi.kokoro/` into
`~/.config/omarchy/plugins/`, enables it and restarts the shell. Re-running is quick and safe;
a changed plugin is backed up to `~/.local/share/kokoro-tts/backups/` first.

| GPU | Build |
|---|---|
| NVIDIA | CUDA 13 (driver ≥ 580), CUDA 12.6 (525–579), CPU (older drivers) |
| AMD Radeon RX / Pro / Instinct | newest ROCm on download.pytorch.org |
| Intel Arc / Core Ultra | XPU |
| Intel UHD/Iris, AMD integrated, none | CPU (~1.3 GB) |

Any GPU error at runtime falls back to the CPU and shows a warning in the app.

## Use

- **Bar icon (󰗋)**: click to open, right-click to speak the selected text (again to stop).
- **App**: type or paste, pick a voice, **Speak** or `Ctrl+Enter`; `Esc` closes.
- **Hotkey**: bind a key to `omarchy-shell shell call mash2rafi.kokoro speakSelection ""`
  (also `speakClipboard ""`, `speak "text"`, `stop ""`, `statusJson ""`).
- Open on settings: `omarchy-shell shell summon mash2rafi.kokoro '{"page":"settings"}'`

## Settings

Settings tab, or `~/.config/omarchy/kokoro-tts.json` (applies live): `voice`, `speed`, `volume`,
`autoPlay`, `player` (`auto`/`pw-cat`/`paplay`/`aplay`), `saveAudio`, `saveDir`,
`device` (`auto`/`cuda`/`xpu`/`cpu`), `unloadAfterMinutes`, `preload`, `hotkeySource`, `pythonPath`.

## Files

`mash2rafi.kokoro/` is a complete, drop-in plugin: `Panel.qml` (window, settings, worker
manager), `BarWidget.qml`, `kokoro_worker.py` (engine: GPU/CPU fallback, audio players,
clipboard), `Voices.js`, `manifest.json`. After editing it, run `omarchy restart shell`:
the panel stays loaded and is not hot-reloaded.
