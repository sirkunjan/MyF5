#!/usr/bin/env python3
"""F5's own ears.

A tiny local transcription service, and the only thing the talk button needs
besides itself. It speaks exactly the two routes the Swift helper already
calls, so the app did not have to change beyond the address it dials:

    GET  /api/state                     -> {"capabilities": [...], "ready": true}
    POST /api/turn?draft=1[&quiet=1]    body: 16 kHz mono 16-bit WAV
                                        -> {"heard": "<the words>"}

Nothing leaves this Mac. Nothing is written down: no transcript, no audio,
no log of what he said. Speaker/noise models and the speech model are
bundled locally; explicit enrollment saves an embedding, not audio.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import mlx.core as mx
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from voice_guard import VoiceGuard
from noise_trial import process as reduce_noise

MODEL_PATH = os.environ.get(
    "K_BUTTON_MODEL",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models", "parakeet-tdt-0.6b-v2"),
)
HOST = "127.0.0.1"
PORT = int(os.environ.get("K_BUTTON_PORT", "8866"))
SAMPLE_RATE = 16000
MAX_BODY = 200 * 1024 * 1024

# --- keeping the memory honest (the 14.87 GB defect, 2026-09-05) -----------
#
# While he talks, the helper re-hears a rolling window every ~450 ms, so
# every decode is a LONGER piece of audio than the last: MLX's Metal buffer
# pool can never reuse a buffer, and it kept every one of them. Measured in
# a 200-turn soak shaped like his real dictation, this process's physical
# footprint went 2.5 GB -> 39.1 GB in 25 seconds. (Plain RSS barely moved,
# 0.99 -> 1.24 GB: Metal pages hide from it. Activity Monitor and the
# kernel's phys_footprint are the numbers that tell the truth.)
#
# Three plain parts: give the buffers back after every transcription, cap
# the pool at load, and — if the footprint ever climbs anyway — stand aside
# for launchd, but never with a dictation in the air.
MLX_CACHE_LIMIT = int(os.environ.get("K_BUTTON_MLX_CACHE_BYTES",
                                     512 * 1024 ** 2))
#: The same soak after the fix sits flat at ~1.9 GB and never drifts. Three
#: times that is room for the longest dictation he has taken (66 s) and
#: still well under the 14.87 GB that starved the Mac this afternoon.
CEILING = int(os.environ.get("K_BUTTON_CEILING_BYTES", 6 * 1024 ** 3))
WATCH_EVERY_S = 20.0
#: He is between clicks if a turn arrived this recently — the window comes
#: every ~450 ms, so three seconds of quiet means the session closed.
SESSION_QUIET_S = 3.0
HEALTH_PATH = os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "state", "health.json")

_model = None
_guard = None
_lock = threading.Lock()          # one model, one inference at a time
_busy = 0                         # turns being heard right now
_last_turn_at = 0.0
_turn_lock = threading.Lock()


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


def release_cache() -> None:
    """Hand MLX's unused Metal buffers back to the OS. Called after every
    transcription — preview window and final pass alike. Never raises:
    housekeeping must never cost him a dictation."""
    try:
        mx.clear_cache()
    except Exception as exc:
        log(f"cache release skipped: {exc}")


def footprint() -> int:
    """What the kernel really ledgers against this process, in bytes —
    Metal pages and compressed pages included, which resident-set size
    leaves out. 0 when the kernel will not say."""
    try:
        import ctypes
        buf = (ctypes.c_uint64 * 64)()
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        if libproc.proc_pid_rusage(os.getpid(), 4, ctypes.byref(buf)) != 0:
            return 0
        return int(buf[9])        # rusage_info_v4: uuid(2), then ri_phys_footprint
    except Exception:
        return 0


def session_open() -> bool:
    """True while a click-to-click dictation could still need us: a turn in
    our hands, a turn moments ago, or the helper saying its microphone is
    open. Nothing here asks the Swift side to change — it already writes
    that file every two seconds."""
    with _turn_lock:
        if _busy or time.time() - _last_turn_at < SESSION_QUIET_S:
            return True
    try:
        if time.time() - os.path.getmtime(HEALTH_PATH) < 10:
            with open(HEALTH_PATH) as fh:
                return bool(json.load(fh).get("capturing"))
    except Exception:
        pass                      # no helper, or a stale file: nothing to protect
    return False


def watch() -> None:
    """If the footprint climbs past the ceiling anyway, release everything;
    if it is still over, exit cleanly so launchd (KeepAlive) brings a fresh
    one back in a second — but only between dictations, never during one."""
    while True:
        time.sleep(WATCH_EVERY_S)
        if footprint() < CEILING:
            continue
        release_cache()
        after = footprint()
        if after < CEILING:
            log(f"released back to {after / 1024 ** 3:.1f} GB")
            continue
        if session_open():
            continue              # he is talking: try again in 20 seconds
        log(f"{after / 1024 ** 3:.1f} GB is over the "
            f"{CEILING / 1024 ** 3:.1f} GB ceiling and will not release — "
            f"standing aside for a fresh start")
        sys.stdout.flush()
        os._exit(0)


def pcm_from_wav(raw: bytes) -> np.ndarray:
    """16-bit PCM samples out of a RIFF/WAVE body, as float32 in [-1, 1].

    Written by hand on purpose: parakeet_mlx's own loader shells out to
    ffmpeg, and the button must not depend on anything else being installed.
    """
    if len(raw) < 44 or raw[0:4] != b"RIFF" or raw[8:12] != b"WAVE":
        # Not a container we know — assume it is already bare PCM.
        return np.frombuffer(raw, "<i2").astype(np.float32) / 32768.0
    pos, channels, bits = 12, 1, 16
    data = b""
    while pos + 8 <= len(raw):
        cid = raw[pos:pos + 4]
        size = int.from_bytes(raw[pos + 4:pos + 8], "little")
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt " and len(body) >= 16:
            channels = int.from_bytes(body[2:4], "little") or 1
            bits = int.from_bytes(body[14:16], "little") or 16
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    if not data:
        return np.zeros(0, dtype=np.float32)
    if bits != 16:
        raise ValueError(f"only 16-bit audio is expected, got {bits}")
    samples = np.frombuffer(data[: len(data) // 2 * 2], "<i2").astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return samples


def hear(raw: bytes, protected: bool = True) -> tuple[str, dict]:
    """The whole job: bytes of speech in, his words out."""
    samples = pcm_from_wav(raw)
    decision = {"mode": "warm-up", "accepted": True}
    if protected:
        if _guard is None:
            raise RuntimeError("voice protection is unavailable")
        samples, decision = _guard.filter(samples)
        if not decision.get("accepted"):
            return "", decision
    if protected and decision.get("mode") == "off":
        samples, noise_decision = reduce_noise(samples, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        decision.update(noise_decision)
    if samples.size < SAMPLE_RATE // 20:      # under 50 ms is not speech
        return "", decision
    audio = mx.array(samples)
    with _lock:
        mel = get_logmel(audio, _model.preprocessor_config)
        results = _model.generate(mel)
        del mel, audio
        release_cache()           # this window's buffers are never reused
    return (results[0].text.strip() if results else ""), decision


class Ears(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "KButtonEars/1.0"

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path in ("/api/state", "/health", "/"):
            self._send(200, {
                "ok": True,
                "ready": _model is not None and _guard is not None,
                "voice": _guard.status() if _guard is not None else {"error": "starting"},
                "service": "f5-ears",
                "instance": os.getpid(),
                "model": os.path.basename(MODEL_PATH),
                # The helper reads this to pick the trace-free route.
                "capabilities": ["quiet-draft-turn", "draft-turn", "enrolled-speaker-filter"],
                # What the memory is doing, and whether it is safe to
                # restart us right now.
                "footprint_gb": round(footprint() / 1024 ** 3, 2),
                "ceiling_gb": round(CEILING / 1024 ** 3, 2),
                "busy": _busy,
                "session_open": session_open(),
            })
        elif path == "/api/voice":
            self._send(200, _guard.status())
        else:
            self._send(404, {"error": "no such route"})

    def do_POST(self) -> None:
        global _busy, _last_turn_at
        path = self.path.split("?", 1)[0]
        if path in ("/api/voice/enroll", "/api/voice/calibrate", "/api/voice/forget"):
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= SAMPLE_RATE * 2 * 65 + 1024:
                self._send(400, {"error": "invalid setup audio size"})
                return
            raw = self.rfile.read(length)
            with _turn_lock:
                active = _busy > 0
            capture_conflict = False
            if path.endswith("calibrate"):
                try:
                    with open(HEALTH_PATH) as f: health = json.load(f)
                    if time.time() - os.path.getmtime(HEALTH_PATH) < 10:
                        capture_conflict = any(health.get(k, False) for k in
                            ("dictation_open", "finishing", "pending_text")) or (
                            health.get("capturing", False) and not health.get("calibrating_room", False))
                except (OSError, ValueError): pass
            if active or capture_conflict or (not path.endswith("calibrate") and session_open()):
                self._send(409, {"error": "finish dictation before changing voice setup"})
                return
            try:
                if path.endswith("forget"):
                    status = _guard.forget()
                elif path.endswith("enroll"):
                    status = _guard.enroll(pcm_from_wav(raw))
                else:
                    status = _guard.calibrate(pcm_from_wav(raw))
                self._send(200, {"ok": True, "voice": status})
            except (ValueError, RuntimeError) as exc:
                self._send(400, {"error": str(exc)})
            return
        if path not in ("/api/turn", "/api/diagnose", "/api/enrollment-preview"):
            self._send(404, {"error": "no such route"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > (SAMPLE_RATE * 2 * 60 + 1024 if path == "/api/diagnose" else MAX_BODY):
            self._send(400, {"error": "no audio"})
            return
        raw = self.rfile.read(length)
        started = time.time()
        with _turn_lock:
            _busy += 1
        try:
            text, decision = hear(raw, protected=path != "/api/enrollment-preview")
            diagnostic = None
            if path == "/api/diagnose":
                unfiltered, _ = hear(raw, protected=False)
                original = pcm_from_wav(raw)
                rms = float(np.sqrt(np.mean(original**2))) if len(original) else 0.0
                import io, wave
                def opening_audio(start, stop):
                    block=original[int(start*SAMPLE_RATE):int(stop*SAMPLE_RATE)]
                    b=io.BytesIO()
                    with wave.open(b,'wb') as w:
                        w.setnchannels(1);w.setsampwidth(2);w.setframerate(SAMPLE_RATE)
                        w.writeframes((np.clip(block,-1,1)*32767).astype('<i2').tobytes())
                    return b.getvalue()
                opening_text,_=hear(opening_audio(0,5),protected=False)
                _, shadow_voice = _guard.filter(original, required_override=True)
                diagnostic = {"shadow_voice_match": shadow_voice, "opening_five_seconds_text": opening_text,
                              "per_second_input_db": [round(20*np.log10(max(float(np.sqrt(np.mean(original[i:i+SAMPLE_RATE]**2))),1e-8)),1) for i in range(0,len(original),SAMPLE_RATE)],
                              "protected_text": text, "unfiltered_text": unfiltered,
                              "voice": decision, "input_db": round(20*np.log10(max(rms,1e-8)),1),
                              "audio_seconds": round(len(original)/SAMPLE_RATE,2)}
        except Exception as exc:                      # never take the button down
            log(f"could not hear: {exc}")
            self._send(500, {"error": str(exc)})
            return
        finally:
            with _turn_lock:
                _busy -= 1
                if path != "/api/enrollment-preview":
                    _last_turn_at = time.time()
        ms = int((time.time() - started) * 1000)
        # Length and timing only — never the words themselves.
        log(f"heard {len(raw)/32000:.1f}s of audio in {ms} ms, {len(text.split())} words; voice accepted={decision.get('accepted')} kept_s={decision.get('accepted_seconds')} score={decision.get('max_score')}")
        self._send(200, diagnostic if diagnostic is not None else {"heard": text, "ok": True, "ms": ms, "quiet": True, "voice": decision})

    def log_message(self, *args) -> None:
        pass                                          # our own log line is enough


def main() -> None:
    global _model, _guard
    log(f"loading {MODEL_PATH}")
    t0 = time.time()
    try:
        mx.set_cache_limit(MLX_CACHE_LIMIT)
    except Exception as exc:
        log(f"cache limit skipped: {exc}")
    _model = from_pretrained(MODEL_PATH)
    _guard = VoiceGuard(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    # Warm the graph on silence so his first real click is not the slow one.
    hear(b"", protected=False)
    try:
        warm = (np.zeros(SAMPLE_RATE // 2, dtype=np.float32) * 32768).astype("<i2").tobytes()
        mel = get_logmel(mx.array(np.frombuffer(warm, "<i2").astype(np.float32) / 32768.0),
                         _model.preprocessor_config)
        _model.generate(mel)
    except Exception as exc:
        log(f"warm-up skipped: {exc}")
    release_cache()
    threading.Thread(target=watch, daemon=True).start()
    log(f"ready on http://{HOST}:{PORT} after {time.time() - t0:.1f}s, "
        f"holding {footprint() / 1024 ** 3:.1f} GB")
    ThreadingHTTPServer((HOST, PORT), Ears).serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
