#!/bin/zsh
# Installed health checks. Optional argument: directory of public voice fixtures.
set -euo pipefail
cd "$(dirname "$0")"
H="./PTTHelper.app/Contents/MacOS/ptt-helper"
PY="./runtime/bin/python3"
TMP_CFG="$(mktemp -t f5-selftest)"
trap 'rm -f "$TMP_CFG"' EXIT
K_PTT_CONFIG="$TMP_CFG" "$H" selftest
"$PY" -I tests/test_recovery.py
codesign --verify --deep --strict PTTHelper.app
"$PY" -I - <<'PY'
import io,json,urllib.request,wave
base='http://127.0.0.1:8866'
with urllib.request.urlopen(base+'/api/state',timeout=5) as r:status=json.load(r)
assert status['ready'] is True
assert 'enrolled-speaker-filter' in status['capabilities']
stream=io.BytesIO()
with wave.open(stream,'wb') as wav:
 wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(b'\0\0'*16000)
for route in ['/api/turn?draft=1','/api/turn?draft=1&quiet=1']:
 req=urllib.request.Request(base+route,data=stream.getvalue(),headers={'Content-Type':'audio/wav'})
 with urllib.request.urlopen(req,timeout=20) as r:answer=json.load(r)
 assert answer['heard']=='',answer
print('PASS: service readiness, speaker capability and silence on both speech routes')
print('Voice status:',status['voice'])
PY
if [[ $# -gt 0 ]]; then
 "$PY" -I tests/voice_guard.py "$1"
 "$PY" -I tests/voice_service.py "$1"
fi
echo "CHECKS PASSED. Physical button, enrollment and real-room accuracy require your own microphone check."
