# Kokoro TTS (mash2rafi.kokoro)

Local text-to-speech for the Omarchy shell, powered by
[hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M).
Everything runs on this machine; the model downloads once (~330 MB) on first use.

## Use

- **Bar icon** (󰗋): click to open the app, right-click to speak the selected text
  (right-click again while it speaks to stop).
- **App**: type or paste text, pick a voice, press **Speak** or `Ctrl+Enter`. `Esc` closes.
- **Keybinding** (optional), e.g. in `~/.config/hypr/bindings.lua`, bind a key to:

  ```
  omarchy-shell shell call mash2rafi.kokoro speakSelection ""
  ```

  Other methods: `speakClipboard ""`, `speak "some text"`, `stop ""`, `statusJson ""` (current state as JSON).
  Open straight to settings: `omarchy-shell shell summon mash2rafi.kokoro '{"page":"settings"}'`.

## Settings

Saved to `~/.config/omarchy/kokoro-tts.json` (editable by hand; changes apply live).

| Key | Default | Meaning |
|---|---|---|
| `voice` | `af_heart` | One of 41 voices (US/UK English, Spanish, French, Hindi, Italian, Portuguese) |
| `speed` | `1.0` | 0.5–2.0 |
| `volume` | `1.0` | 0–1.5 |
| `autoPlay` | `true` | Stream audio to the speakers while generating |
| `saveAudio` / `saveDir` | `false` / `~/Music/Kokoro` | Also save each clip as a WAV file |
| `device` | `auto` | `auto` (GPU if CUDA works), `cuda`, or `cpu` |
| `unloadAfterMinutes` | `10` | Stop the worker after this long idle (0 = never) to free ~1 GB VRAM |
| `preload` | `false` | Load the model when the shell starts |
| `hotkeySource` | `selection` | What speak-selection reads: `selection` (primary) or `clipboard` |
| `pythonPath` | *(empty)* | Override the Python interpreter (default `~/.local/share/kokoro-tts/venv/bin/python`) |

## Files

- `Panel.qml` — app window, settings, and the worker process manager
- `BarWidget.qml` — bar icon
- `kokoro_worker.py` — long-running Python process: loads Kokoro once, streams audio to PipeWire (`pw-cat`), writes WAVs
- `Voices.js` — voice list and labels

## Editing the code

The panel is `keepLoaded`, so Omarchy does not hot-reload it: after changing
`Panel.qml` run `omarchy restart shell`. The worker (`kokoro_worker.py`) is
restarted automatically the next time the model loads (use **Unload model** in
Settings to force it).

## Setup (already done on this machine)

```bash
sudo pacman -S --needed espeak-ng uv
uv venv --python 3.12 ~/.local/share/kokoro-tts/venv
uv pip install --python ~/.local/share/kokoro-tts/venv/bin/python "kokoro>=0.9.4" soundfile "misaki[en]"
VIRTUAL_ENV=~/.local/share/kokoro-tts/venv ~/.local/share/kokoro-tts/venv/bin/python -m spacy download en_core_web_sm
cp -r mash2rafi.kokoro ~/.config/omarchy/plugins/
omarchy plugin enable mash2rafi.kokoro
```

Japanese and Mandarin voices need `misaki[ja]` / `misaki[zh]` and are not listed.
