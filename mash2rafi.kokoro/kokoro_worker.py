#!/usr/bin/env python3
"""Long-running Kokoro-82M worker shared by the Kokoro TTS front ends
(the Omarchy shell plugin and the standalone Quickshell app).

Protocol: one JSON object per line.

stdin (commands)
  {"cmd": "load", "device": "auto|cuda|rocm|xpu|cpu"}
  {"cmd": "speak", "id": 1, "text": "...", "voice": "af_heart", "speed": 1.0,
   "volume": 1.0, "play": true, "saveDir": "", "device": "auto", "player": "auto"}
  {"cmd": "speakSelection", "source": "selection|clipboard", ...same as speak}
  {"cmd": "clipboard", "source": "selection|clipboard", "reqId": 7}
  {"cmd": "stop"} | {"cmd": "quit"}

stdout (events)
  hello{pid, players, player, clipboard} loading{device} ready{device, deviceName}
  started chunk done stopped clipboard{reqId, text} warning{message} error{message}

Hardware: CUDA (NVIDIA) and ROCm (AMD) both appear to PyTorch as "cuda";
Intel GPUs use "xpu". Any GPU failure falls back to the CPU.
Audio: pw-cat (PipeWire) > paplay (PulseAudio) > aplay (ALSA), raw float32.
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time

os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

SAMPLE_RATE = 24000
REPO_ID = "hexgrad/Kokoro-82M"

_out_lock = threading.Lock()


def emit(event, **fields):
    fields["event"] = event
    with _out_lock:
        sys.stdout.write(json.dumps(fields) + "\n")
        sys.stdout.flush()


# --------------------------------------------------------------------------- audio

# Each player reads headerless mono float32 PCM at SAMPLE_RATE from stdin.
PLAYERS = {
    "pw-cat": ["pw-cat", "--playback", "--raw", "--rate", str(SAMPLE_RATE),
               "--channels", "1", "--format", "f32", "--media-role", "Communication", "-"],
    "paplay": ["paplay", "--raw", "--format=float32le", "--rate=%d" % SAMPLE_RATE,
               "--channels=1", "--client-name=Kokoro TTS"],
    "aplay": ["aplay", "-q", "-t", "raw", "-f", "FLOAT_LE", "-r", str(SAMPLE_RATE), "-c", "1", "-"],
}


def available_players():
    return [name for name in PLAYERS if shutil.which(name)]


def pick_player(wanted="auto"):
    found = available_players()
    if wanted and wanted != "auto":
        return wanted if wanted in found else None
    return found[0] if found else None


# --------------------------------------------------------------------------- clipboard

def clipboard_tool():
    if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-paste"):
        return "wl-paste"
    for tool in ("xclip", "xsel", "wl-paste"):
        if shutil.which(tool):
            return tool
    return None


def read_clipboard(source="selection"):
    primary = source != "clipboard"
    tool = clipboard_tool()
    if tool == "wl-paste":
        cmd = ["wl-paste", "--no-newline"] + (["--primary"] if primary else [])
    elif tool == "xclip":
        cmd = ["xclip", "-o", "-selection", "primary" if primary else "clipboard"]
    elif tool == "xsel":
        cmd = ["xsel", "--primary" if primary else "--clipboard", "--output"]
    else:
        raise RuntimeError("No clipboard tool found (install wl-clipboard, xclip or xsel)")
    out = subprocess.run(cmd, capture_output=True, timeout=5)
    return out.stdout.decode(errors="replace")


# --------------------------------------------------------------------------- worker

class Worker:
    def __init__(self):
        self.model = None
        self.device = None
        self.pipelines = {}
        self.lock = threading.Lock()
        self.cancel = threading.Event()
        self.player = None
        self.thread = None

    # -- model ---------------------------------------------------------------

    @staticmethod
    def gpu_candidates(wanted):
        import torch

        cuda = torch.cuda.is_available()
        xpu = hasattr(torch, "xpu") and torch.xpu.is_available()
        if wanted in ("cuda", "rocm"):
            return ["cuda"] if cuda else []
        if wanted == "xpu":
            return ["xpu"] if xpu else []
        if wanted == "cpu":
            return []
        return (["cuda"] if cuda else []) + (["xpu"] if xpu else [])

    @staticmethod
    def device_name(device):
        import torch

        try:
            if device == "cuda":
                kind = "ROCm" if getattr(torch.version, "hip", None) else "CUDA"
                return "%s (%s)" % (torch.cuda.get_device_name(0), kind)
            if device == "xpu":
                return "%s (XPU)" % torch.xpu.get_device_name(0)
        except Exception:  # noqa: BLE001
            pass
        return "CPU"

    def load(self, wanted="auto"):
        with self.lock:
            try:
                candidates = self.gpu_candidates(wanted) + ["cpu"]
            except Exception as exc:  # noqa: BLE001
                emit("error", message="PyTorch is not usable: %s" % exc)
                return False
            if wanted not in ("auto", "cpu", "", None) and candidates == ["cpu"]:
                emit("warning", message="%s is not available; using the CPU" % wanted.upper())
            if self.model is not None and self.device == candidates[0]:
                emit("ready", device=self.device, deviceName=self.device_name(self.device))
                return True
            for device in candidates:
                if self._load_on(device):
                    return True
            return False

    def _load_on(self, device):
        emit("loading", device=device)
        started = time.time()
        try:
            from kokoro import KModel

            model = KModel(repo_id=REPO_ID).to(device).eval()
        except Exception as exc:  # noqa: BLE001
            if device == "cpu":
                emit("error", message="Failed to load the model: %s" % exc)
            else:
                emit("warning", message="%s failed (%s); falling back" % (device.upper(), exc))
            return False
        self.model, self.device, self.pipelines = model, device, {}
        emit("ready", device=device, deviceName=self.device_name(device),
             seconds=round(time.time() - started, 2))
        return True

    def pipeline(self, lang_code):
        from kokoro import KPipeline

        if lang_code not in self.pipelines:
            self.pipelines[lang_code] = KPipeline(
                lang_code=lang_code, repo_id=REPO_ID, model=self.model
            )
        return self.pipelines[lang_code]

    # -- playback ------------------------------------------------------------

    def open_player(self, wanted):
        name = pick_player(wanted)
        if name is None:
            emit("warning", message="No audio player found (need pw-cat, paplay or aplay); not playing")
            return None
        return subprocess.Popen(PLAYERS[name], stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    def close_player(self, kill=False):
        player, self.player = self.player, None
        if player is None:
            return
        try:
            if kill:
                player.kill()
                return
            player.stdin.close()
            player.wait(timeout=600)
        except Exception:  # noqa: BLE001
            player.kill()
            return
        if player.returncode != 0:
            detail = player.stderr.read().decode(errors="replace").strip().splitlines()
            emit("error", message="Audio playback failed (%s exit %s)%s" % (
                os.path.basename(player.args[0]), player.returncode,
                ": " + detail[-1] if detail else ""))

    # -- speech --------------------------------------------------------------

    def speak(self, req):
        if self.thread is not None and self.thread.is_alive():
            self.stop()
            self.thread.join(timeout=5)
        self.cancel.clear()
        self.thread = threading.Thread(target=self._speak, args=(req,), daemon=True)
        self.thread.start()

    def speak_selection(self, req):
        try:
            req = dict(req, text=read_clipboard(req.get("source", "selection")))
        except Exception as exc:  # noqa: BLE001
            emit("error", id=req.get("id", 0), message=str(exc))
            return
        self.speak(req)

    def _speak(self, req):
        job = req.get("id", 0)
        text = str(req.get("text", "")).strip()
        if not text:
            emit("error", id=job, message="Nothing to speak")
            return
        if self.model is None and not self.load(req.get("device", "auto")):
            emit("error", id=job, message="The model could not be loaded")
            return
        try:
            self._generate(job, text, req)
        except Exception as exc:  # noqa: BLE001
            self.close_player(kill=True)
            if self.device == "cpu" or self.cancel.is_set():
                emit("error", id=job, message="Generation failed: %s" % exc)
                return
            # A GPU failure mid-job (out of memory, driver error): retry on CPU.
            emit("warning", message="%s failed during generation (%s); retrying on CPU"
                 % (self.device.upper(), exc))
            if not self._load_on("cpu"):
                emit("error", id=job, message="Generation failed: %s" % exc)
                return
            try:
                self._generate(job, text, req)
            except Exception as exc2:  # noqa: BLE001
                self.close_player(kill=True)
                emit("error", id=job, message="Generation failed: %s" % exc2)

    def _generate(self, job, text, req):
        import numpy as np

        voice = str(req.get("voice") or "af_heart")
        speed = float(req.get("speed") or 1.0)
        volume = max(0.0, float(req.get("volume", 1.0)))
        play = bool(req.get("play", True))
        save_dir = str(req.get("saveDir") or "").strip()

        started = time.time()
        chunks, samples, first_audio = [], 0, None
        emit("started", id=job, voice=voice, chars=len(text), device=self.device)
        if play:
            self.player = self.open_player(req.get("player", "auto"))
        pipe = self.pipeline(voice[0])
        for index, result in enumerate(pipe(text, voice=voice, speed=speed, split_pattern=r"\n+")):
            if self.cancel.is_set():
                break
            if result.audio is None:
                continue
            audio = result.audio.detach().cpu().numpy().astype("float32")
            if first_audio is None:
                first_audio = time.time() - started
            samples += len(audio)
            if save_dir:
                chunks.append(audio)
            emit("chunk", id=job, index=index, graphemes=result.graphemes[:120],
                 audioSeconds=round(samples / SAMPLE_RATE, 2))
            player = self.player
            if player is not None:
                out = audio if volume == 1.0 else np.clip(audio * volume, -1.0, 1.0)
                try:
                    player.stdin.write(out.astype("float32").tobytes())
                    player.stdin.flush()
                except (BrokenPipeError, ValueError, OSError):
                    break

        generated = time.time() - started
        if self.cancel.is_set():
            self.close_player(kill=True)
            emit("stopped", id=job)
            return
        saved = self.save(chunks, save_dir, voice) if save_dir and chunks else ""
        self.close_player()
        if self.cancel.is_set():
            emit("stopped", id=job)
            return
        audio_seconds = samples / SAMPLE_RATE
        emit("done", id=job, audioSeconds=round(audio_seconds, 2),
             generateSeconds=round(generated, 2),
             firstAudioSeconds=round(first_audio or 0, 2),
             realtime=round(audio_seconds / generated, 1) if generated > 0 else 0,
             saved=saved, device=self.device)

    def save(self, chunks, save_dir, voice):
        import numpy as np
        import soundfile as sf

        try:
            folder = os.path.expanduser(save_dir)
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, "kokoro-%s-%s.wav" % (time.strftime("%Y%m%d-%H%M%S"), voice))
            sf.write(path, np.concatenate(chunks), SAMPLE_RATE)
            return path
        except Exception as exc:  # noqa: BLE001
            emit("error", message="Could not save audio: %s" % exc)
            return ""

    def stop(self):
        self.cancel.set()
        self.close_player(kill=True)


def main():
    worker = Worker()
    emit("hello", pid=os.getpid(), players=available_players(), player=pick_player(),
         clipboard=clipboard_tool())
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            emit("error", message="Bad command: %s" % line[:80])
            continue
        cmd = req.get("cmd")
        if cmd == "load":
            threading.Thread(target=worker.load, args=(req.get("device", "auto"),), daemon=True).start()
        elif cmd == "speak":
            worker.speak(req)
        elif cmd == "speakSelection":
            threading.Thread(target=worker.speak_selection, args=(req,), daemon=True).start()
        elif cmd == "clipboard":
            try:
                emit("clipboard", reqId=req.get("reqId"), text=read_clipboard(req.get("source", "clipboard")))
            except Exception as exc:  # noqa: BLE001
                emit("error", message=str(exc))
        elif cmd == "stop":
            worker.stop()
        elif cmd == "quit":
            break
    worker.stop()


if __name__ == "__main__":
    main()
