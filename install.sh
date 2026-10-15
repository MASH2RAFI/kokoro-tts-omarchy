#!/usr/bin/env bash
# Kokoro TTS — Omarchy shell plugin installer (mash2rafi.kokoro).
#
#   ./install.sh               install or update
#   ./install.sh --dry-run     show what it detected and would do; change nothing
#   ./install.sh --gpu=KIND    force the PyTorch build: nvidia | amd | intel | cpu
#   ./install.sh --uninstall   remove the plugin and its Python environment
#
# Picks CUDA (NVIDIA), ROCm (discrete AMD), XPU (Intel Arc / Core Ultra) or CPU
# automatically. Safe to re-run: every step skips work that is already done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="mash2rafi.kokoro"
PLUGIN_SRC="$SCRIPT_DIR"   # this repo is the plugin folder itself
PLUGIN_DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
KOKORO_HOME="$HOME/.local/share/kokoro-tts"
VENV="$KOKORO_HOME/venv"
PY="$VENV/bin/python"

export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-600}"
export UV_HTTP_RETRIES="${UV_HTTP_RETRIES:-5}"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

retry() {
  local attempt
  for attempt in 1 2 3; do
    "$@" && return 0
    warn "attempt $attempt failed; retrying in 10 s…"
    sleep 10
  done
  return 1
}

plugin_enabled() {
  omarchy plugin list 2>/dev/null | awk -v id="$PLUGIN_ID" '$1 == id && $2 == "enabled" { f = 1 } END { exit !f }'
}

MODE="install"; DRY_RUN=0; GPU_OVERRIDE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) MODE="uninstall" ;;
    --cpu) GPU_OVERRIDE="cpu" ;;
    --gpu=*) GPU_OVERRIDE="${arg#--gpu=}" ;;
    -h|--help) usage ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done
case "$GPU_OVERRIDE" in ""|nvidia|amd|intel|cpu) ;; *) die "--gpu must be nvidia, amd, intel or cpu" ;; esac

command -v omarchy >/dev/null && [[ -d "$HOME/.config/omarchy" ]] \
  || die "Omarchy was not found. For other desktops use the universal kokoro-tts package."

# --------------------------------------------------------------------------- uninstall

if [[ "$MODE" == "uninstall" ]]; then
  step "Uninstalling Kokoro TTS"
  plugin_enabled && omarchy plugin disable "$PLUGIN_ID" >/dev/null && ok "plugin disabled"
  for path in "$PLUGIN_DST" "$VENV" "$KOKORO_HOME/backups"; do
    if [[ -e "$path" ]]; then rm -rf "$path"; ok "removed $path"; fi
  done
  rmdir "$KOKORO_HOME" 2>/dev/null || true
  omarchy restart shell >/dev/null 2>&1 && ok "shell restarted"
  echo
  echo "Kept: ~/.config/omarchy/kokoro-tts.json (settings), espeak-ng and uv, and ~/.cache/huggingface (model)."
  exit 0
fi

# --------------------------------------------------------------------------- detection

step "Detecting your system"
[[ -f "$PLUGIN_SRC/manifest.json" && -f "$PLUGIN_SRC/kokoro_worker.py" ]] \
  || die "plugin files not found next to this script in $PLUGIN_SRC"
[[ "$(uname -m)" == x86_64 || "$(uname -m)" == aarch64 ]] || die "unsupported CPU architecture $(uname -m)"
ARCH="$(uname -m)"

gpu_list() {
  if [[ -n "${KOKORO_FAKE_GPUS+set}" ]]; then printf '%s\n' "$KOKORO_FAKE_GPUS" | tr ';' '\n'; return; fi
  lspci -nn 2>/dev/null | grep -Ei 'VGA|3D controller|Display controller' | while read -r line; do
    case "$line" in
      *'[10de:'*) echo "nvidia|$line" ;;
      *'[1002:'*) echo "amd|$line" ;;
      *'[8086:'*) echo "intel|$line" ;;
    esac
  done
}
GPUS="$(gpu_list)"
[[ -n "$GPUS" ]] && while IFS='|' read -r _ desc; do info "GPU: ${desc#*: }"; done <<<"$GPUS"

nvidia_driver_major() {
  if [[ -n "${KOKORO_FAKE_NVIDIA_DRIVER:-}" ]]; then echo "$KOKORO_FAKE_NVIDIA_DRIVER"; return; fi
  command -v nvidia-smi >/dev/null || { echo 0; return; }
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1 | tr -dc '0-9' || echo 0
}

TORCH_KIND="cpu"; TORCH_WHY="no supported GPU found"
if [[ -n "$GPU_OVERRIDE" ]]; then
  TORCH_KIND="$GPU_OVERRIDE"; TORCH_WHY="forced with --gpu"
elif grep -q '^nvidia|' <<<"$GPUS"; then
  TORCH_KIND="nvidia"; TORCH_WHY="NVIDIA GPU"
elif grep -Eiq '^amd\|.*(Radeon (RX|Pro|VII)|Instinct|Navi [0-9]+ \[Radeon)' <<<"$GPUS"; then
  TORCH_KIND="amd"; TORCH_WHY="discrete AMD GPU"
elif grep -Eiq '^intel\|.*(Arc|DG2|Battlemage|Alchemist|Data Center GPU)' <<<"$GPUS"; then
  TORCH_KIND="intel"; TORCH_WHY="Intel Arc / Core Ultra GPU"
elif grep -q '^amd|' <<<"$GPUS"; then
  TORCH_WHY="AMD integrated graphics are not worth the ~4 GB ROCm download; use --gpu=amd to try"
elif grep -q '^intel|' <<<"$GPUS"; then
  TORCH_WHY="Intel UHD/Iris graphics are not supported by PyTorch XPU"
fi

index_has_torch() {
  # Fetch first, then search (a curl | grep -q pipe fails under pipefail on an early match).
  local page
  page="$(curl -fsSL --max-time 60 --retry 2 "https://download.pytorch.org/whl/$1/torch/" 2>/dev/null)" || return 1
  grep -Eq "torch-[0-9.]+(%2B|\\+)$1-cp312-cp312-[^\"]*$ARCH\\.whl" <<<"$page"
}

TORCH_INDEX=""
case "$TORCH_KIND" in
  nvidia)
    drv="$(nvidia_driver_major)"
    if [[ "$ARCH" != x86_64 ]]; then TORCH_KIND="cpu"; TORCH_WHY="CUDA on $ARCH is not handled; using CPU"
    elif (( drv >= 580 )); then TORCH_WHY="NVIDIA driver $drv → CUDA 13 build"
    elif (( drv >= 525 )); then TORCH_INDEX="https://download.pytorch.org/whl/cu126"; TORCH_WHY="NVIDIA driver $drv → CUDA 12.6 build"
    elif (( drv > 0 )); then TORCH_KIND="cpu"; TORCH_WHY="NVIDIA driver $drv is too old (need ≥ 525); using CPU"
    else TORCH_WHY="NVIDIA GPU without nvidia-smi; CUDA build (falls back to CPU at runtime)"
    fi ;;
  amd)
    [[ "$ARCH" == x86_64 ]] || die "ROCm builds are x86_64 only"
    for v in 7.4 7.3 7.2 7.1 7.0 6.4 6.3; do
      if index_has_torch "rocm$v"; then TORCH_INDEX="https://download.pytorch.org/whl/rocm$v"; break; fi
    done
    [[ -n "$TORCH_INDEX" ]] || die "could not reach the PyTorch ROCm index (network?)"
    TORCH_WHY="$TORCH_WHY → ${TORCH_INDEX##*/} build" ;;
  intel)
    [[ "$ARCH" == x86_64 ]] || die "XPU builds are x86_64 only"
    TORCH_INDEX="https://download.pytorch.org/whl/xpu"; TORCH_WHY="$TORCH_WHY → XPU build" ;;
esac
[[ "$TORCH_KIND" == cpu && "$ARCH" == x86_64 ]] && TORCH_INDEX="https://download.pytorch.org/whl/cpu"
info "PyTorch: $TORCH_KIND — $TORCH_WHY"

if (( DRY_RUN )); then
  step "Dry run — nothing was changed. Would install:"
  info "Packages:   espeak-ng, uv (pacman)"
  info "Python env: $VENV (Python 3.12)"
  info "PyTorch:    $TORCH_KIND from ${TORCH_INDEX:-PyPI}"
  info "Plugin:     $PLUGIN_DST"
  exit 0
fi

# --------------------------------------------------------------------------- packages + python

step "System packages"
need=()
for pkg in espeak-ng uv; do pacman -Q "$pkg" >/dev/null 2>&1 || need+=("$pkg"); done
if (( ${#need[@]} )); then
  info "Installing: ${need[*]} (sudo will ask for your password)"
  sudo pacman -S --needed --noconfirm "${need[@]}"
fi
ok "espeak-ng and uv"

step "Python 3.12 environment ($VENV)"
mkdir -p "$KOKORO_HOME"
[[ -x "$PY" ]] || uv venv --python 3.12 "$VENV"
"$PY" -c 'import sys; assert sys.version_info[:2] == (3, 12)' || die "$VENV is not Python 3.12 — delete it and re-run"
ok "environment ready"

step "PyTorch ($TORCH_KIND) and Kokoro"
current="$("$PY" -c 'import torch; print(torch.__version__)' 2>/dev/null || true)"
case "$TORCH_KIND" in
  cpu) want_tag="${TORCH_INDEX:++cpu}" ;;
  amd) want_tag="+${TORCH_INDEX##*/}" ;;
  intel) want_tag="+xpu" ;;
  nvidia) want_tag="${TORCH_INDEX:++${TORCH_INDEX##*/}}" ;;
esac
if [[ -n "$current" ]] && { [[ -n "$want_tag" && "$current" == *"$want_tag"* ]] \
     || [[ -z "$want_tag" && "$current" != *+cpu* && "$current" != *+rocm* && "$current" != *+xpu* ]]; }; then
  ok "PyTorch $current already installed"
else
  [[ -n "$current" ]] && info "Replacing PyTorch $current"
  retry uv pip install --python "$PY" --reinstall-package torch torch ${TORCH_INDEX:+--index-url "$TORCH_INDEX"}
fi
retry uv pip install --python "$PY" "kokoro>=0.9.4" soundfile "misaki[en]"
ok "packages installed"

step "spaCy English model"
if ! "$PY" -c 'import spacy; spacy.load("en_core_web_sm")' >/dev/null 2>&1; then
  VIRTUAL_ENV="$VENV" PATH="$VENV/bin:$PATH" retry "$PY" -m spacy download en_core_web_sm
fi
ok "en_core_web_sm"

step "Kokoro-82M weights (~330 MB)"
retry "$PY" -c '
from huggingface_hub import hf_hub_download
for name in ("config.json", "kokoro-v1_0.pth", "voices/af_heart.pt"):
    hf_hub_download("hexgrad/Kokoro-82M", name)
'
"$PY" -c '
import torch
dev = "CPU"
if torch.cuda.is_available():
    dev = torch.cuda.get_device_name(0) + (" (ROCm)" if getattr(torch.version, "hip", None) else " (CUDA)")
elif hasattr(torch, "xpu") and torch.xpu.is_available():
    dev = torch.xpu.get_device_name(0) + " (XPU)"
print("    ✓ model downloaded · torch", torch.__version__, "· device:", dev)
'

# --------------------------------------------------------------------------- plugin

step "Omarchy plugin ($PLUGIN_DST)"
if [[ "$(realpath "$PLUGIN_SRC")" == "$(realpath -m "$PLUGIN_DST")" ]]; then
  # Added with `omarchy plugin add <url>`: this checkout already is the plugin; `omarchy plugin update` pulls it.
  ok "running from the installed checkout; nothing to copy"
else
  if [[ -d "$PLUGIN_DST" ]] && ! diff -rq --exclude __pycache__ --exclude .git "$PLUGIN_SRC" "$PLUGIN_DST" >/dev/null 2>&1; then
    # Keep backups out of the plugins folder: Omarchy scans every non-hidden folder there.
    backup="$KOKORO_HOME/backups/$PLUGIN_ID.$(date +%s)"
    mkdir -p "$KOKORO_HOME/backups"; mv "$PLUGIN_DST" "$backup"; warn "previous version saved to $backup"
  fi
  mkdir -p "$PLUGIN_DST"
  for entry in "$PLUGIN_SRC"/* "$PLUGIN_SRC"/.[!.]*; do
    [[ -e "$entry" && "${entry##*/}" != .git ]] && cp -r "$entry" "$PLUGIN_DST/"
  done
  rm -rf "$PLUGIN_DST/__pycache__"
fi
omarchy plugin validate "$PLUGIN_DST" >/dev/null || die "plugin failed validation"
if ! plugin_enabled; then
  cp "$HOME/.config/omarchy/shell.json" "$HOME/.config/omarchy/shell.json.bak.$(date +%s)" 2>/dev/null || true
  omarchy plugin enable "$PLUGIN_ID" >/dev/null
fi
# The panel is keepLoaded, so Omarchy does not hot-reload it.
omarchy restart shell >/dev/null 2>&1 || warn "run: omarchy restart shell"
ok "plugin installed, enabled and loaded"

printf '\n\033[1;32mKokoro TTS is installed.\033[0m\n'
cat <<EOF
  • Click the 󰗋 bar icon to open it; right-click it to speak the selected text.
  • Hotkey command: omarchy-shell shell call $PLUGIN_ID speakSelection ""
  • Uninstall:      $0 --uninstall
EOF
