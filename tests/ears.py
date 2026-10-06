#!/usr/bin/env python3
"""The button's own ears, proved end to end without a finger on the button.

Speaks a known sentence into a file (never through the speakers), posts it to
both routes the helper uses, and checks the words come back exactly.
"""
import json, pathlib, subprocess, sys, tempfile, urllib.request

BASE = "http://127.0.0.1:8866"
LINE = "We keep the parts that work and polish the ones that do not."
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + name)
    if not ok:
        fails += 1
        if detail:
            print("        " + detail)


def post(route, wav):
    req = urllib.request.Request(BASE + route, data=wav,
                                 headers={"Content-Type": "audio/wav"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


try:
    with urllib.request.urlopen(BASE + "/api/state", timeout=5) as r:
        state = json.loads(r.read())
except Exception as exc:
    print(f"  FAIL  the ears are not answering on {BASE}: {exc}")
    sys.exit(1)

check("the ears answer /api/state", state.get("ready") is True)
check("they advertise the trace-free route",
      "quiet-draft-turn" in state.get("capabilities", []))

wav_path = pathlib.Path(tempfile.gettempdir()) / "k-button-ears-test.wav"
# -o writes a file. Nothing is played out loud.
subprocess.run(["say", "-r", "170", "-o", str(wav_path),
                "--data-format=LEI16@16000", LINE], check=True)
wav = wav_path.read_bytes()

for route in ("/api/turn?draft=1", "/api/turn?draft=1&quiet=1"):
    answer = post(route, wav)
    heard = (answer.get("heard") or "").strip()
    check(f"{route} returns the exact words", heard == LINE, f"heard: {heard!r}")

# One second of true silence, in the same 16 kHz mono container.
pcm = b"\x00\x00" * 16000
head = (b"RIFF" + (36 + len(pcm)).to_bytes(4, "little") + b"WAVEfmt "
        + (16).to_bytes(4, "little") + (1).to_bytes(2, "little")
        + (1).to_bytes(2, "little") + (16000).to_bytes(4, "little")
        + (32000).to_bytes(4, "little") + (2).to_bytes(2, "little")
        + (16).to_bytes(2, "little") + b"data" + len(pcm).to_bytes(4, "little"))
silent = post("/api/turn?draft=1", head + pcm).get("heard", "")
check("silence comes back as nothing", silent.strip() == "", f"heard: {silent!r}")
wav_path.unlink(missing_ok=True)

print("\nall ears tests passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
