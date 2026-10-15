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
  {"cmd": "pause"} | {"cmd": "resume"} | {"cmd": "seek", "delta": -5.0}
  {"cmd": "stop"} | {"cmd": "quit"}

stdout (events)
  hello{pid, players, player, clipboard} loading{device} ready{device, deviceName}
  started chunk done stopped paused resumed position{seconds, total, complete}
  clipboard{reqId, text} warning{message} error{message}

Hardware: CUDA (NVIDIA) and ROCm (AMD) both appear to PyTorch as "cuda";
Intel GPUs use "xpu". Any GPU failure falls back to the CPU.
Audio: pw-cat (PipeWire) > paplay (PulseAudio) > aplay (ALSA), raw float32.
"""
import json
import os
import fcntl
import shutil
import subprocess
import sys
import tempfile
import threading
import time

os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

SAMPLE_RATE = 24000
BLOCK_SAMPLES = SAMPLE_RATE // 50          # 20 ms per write to the player
F_SETPIPE_SZ = getattr(fcntl, "F_SETPIPE_SZ", 1031)
PIPE_BYTES = 8192                          # ~85 ms of audio in flight, so pause/seek feel instant
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
        # Playback state for the current job, guarded by self.cond.
        self.cond = threading.Condition()
        self.job = 0
        self.buf = None
        self.pos = 0
        self.gen_done = True
        self.paused = False
        self.volume = 1.0

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
    # Generated audio collects in self.buf; a playback thread feeds the player
    # from the playhead self.pos in small blocks, so pause and seek act within
    # ~0.1 s while generation keeps running ahead.

    def open_player(self, wanted):
        name = pick_player(wanted)
        if name is None:
            emit("warning", message="No audio player found (need pw-cat, paplay or aplay); not playing")
            return None
        # stderr goes to a file: aplay reports every underrun (e.g. while paused),
        # which could fill an unread pipe and block it.
        log = tempfile.TemporaryFile()
        player = subprocess.Popen(PLAYERS[name], stdin=subprocess.PIPE, stderr=log)
        player.log = log
        try:
            fcntl.fcntl(player.stdin.fileno(), F_SETPIPE_SZ, PIPE_BYTES)
        except (OSError, AttributeError):
            pass
        return player

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
            player.log.seek(0)
            detail = player.log.read().decode(errors="replace").strip().splitlines()
            emit("error", message="Audio playback failed (%s exit %s)%s" % (
                os.path.basename(player.args[0]), player.returncode,
                ": " + detail[-1] if detail else ""))

    def _play(self, job, player):
        import numpy as np

        last_report = 0.0
        while True:
            with self.cond:
                while not self.cancel.is_set() and (
                        self.paused or (self.pos >= len(self.buf) and not self.gen_done)):
                    self.cond.wait(0.2)
                if self.cancel.is_set() or (self.pos >= len(self.buf) and self.gen_done):
                    return
                block = self.buf[self.pos:self.pos + BLOCK_SAMPLES]
                self.pos += len(block)
                volume = self.volume
            out = block if volume == 1.0 else np.clip(block * volume, -1.0, 1.0)
            try:
                player.stdin.write(out.astype("float32").tobytes())
                player.stdin.flush()
            except (BrokenPipeError, ValueError, OSError):
                return
            now = time.time()
            if now - last_report >= 0.25:
                last_report = now
                self.report_position(job)

    def report_position(self, job):
        with self.cond:
            pos, total, complete = self.pos, len(self.buf), self.gen_done
        emit("position", id=job, seconds=round(pos / SAMPLE_RATE, 2),
             total=round(total / SAMPLE_RATE, 2), complete=complete)

    def pause(self):
        with self.cond:
            if self.player is None:
                emit("warning", message="Nothing is playing")
                return
            self.paused = True
            self.cond.notify_all()
        emit("paused")

    def resume(self):
        with self.cond:
            self.paused = False
            self.cond.notify_all()
        emit("resumed")

    def seek(self, delta):
        with self.cond:
            if self.player is None:
                return
            self.pos = max(0, min(len(self.buf), self.pos + int(float(delta) * SAMPLE_RATE)))
            self.cond.notify_all()
        self.report_position(self.job)

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
        play = bool(req.get("play", True))
        save_dir = str(req.get("saveDir") or "").strip()

        with self.cond:
            self.job = job
            self.buf = np.zeros(0, dtype="float32")
            self.pos = 0
            self.gen_done = False
            self.paused = False
            self.volume = max(0.0, float(req.get("volume", 1.0)))

        started = time.time()
        first_audio = None
        emit("started", id=job, voice=voice, chars=len(text), device=self.device)
        playback = None
        if play:
            self.player = self.open_player(req.get("player", "auto"))
            if self.player is not None:
                playback = threading.Thread(target=self._play, args=(job, self.player), daemon=True)
                playback.start()
        pipe = self.pipeline(voice[0])
        try:
            for index, result in enumerate(pipe(text, voice=voice, speed=speed, split_pattern=r"\n+")):
                if self.cancel.is_set():
                    break
                if result.audio is None:
                    continue
                audio = result.audio.detach().cpu().numpy().astype("float32")
                if first_audio is None:
                    first_audio = time.time() - started
                with self.cond:
                    self.buf = np.concatenate((self.buf, audio))
                    total = len(self.buf)
                    self.cond.notify_all()
                emit("chunk", id=job, index=index, graphemes=result.graphemes[:120],
                     audioSeconds=round(total / SAMPLE_RATE, 2))
        finally:
            with self.cond:
                self.gen_done = True
                self.cond.notify_all()

        generated = time.time() - started
        if self.cancel.is_set():
            self.close_player(kill=True)
            emit("stopped", id=job)
            return
        saved = self.save([self.buf], save_dir, voice) if save_dir and len(self.buf) else ""
        if playback is not None:
            playback.join()  # through any pauses; stop() ends it early
        self.close_player(kill=self.cancel.is_set())
        if self.cancel.is_set():
            emit("stopped", id=job)
            return
        audio_seconds = len(self.buf) / SAMPLE_RATE
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
        with self.cond:
            self.cancel.set()
            self.cond.notify_all()
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
        elif cmd == "pause":
            worker.pause()
        elif cmd == "resume":
            worker.resume()
        elif cmd == "seek":
            worker.seek(req.get("delta", 0))
        elif cmd == "stop":
            worker.stop()
        elif cmd == "quit":
            break
    worker.stop()


if __name__ == "__main__":
    main()
