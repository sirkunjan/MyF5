"""launchd health check. Repair only idle failures; never change settings or text."""
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT=Path(__file__).resolve().parent
STATE=ROOT/'state'

def decide(health, age, ears_ok, failures, elapsed):
    if health and health.get('setting_up', False): return None
    if not health or any(health.get(k, True) for k in ('capturing','dictation_open','finishing','pending_text')):
        return None
    if not health.get('enabled') or elapsed < 300: return None
    if age > 30: return 'com.f5'
    if not ears_ok and failures >= 3: return 'com.f5.ears'
    return None

def check():
    path=STATE/'recovery.json'
    try: saved=json.loads(path.read_text())
    except (OSError,ValueError): saved={}
    try: health=json.loads((STATE/'health.json').read_text())
    except (OSError,ValueError): return  # Unknown capture state: don't risk dictation.
    try:
        with urllib.request.urlopen('http://127.0.0.1:8866/api/state',timeout=2) as r:
            ears_ok=json.load(r).get('ready') is True
    except Exception: ears_ok=False
    failures=0 if ears_ok else saved.get('failures',0)+1
    age=time.time()-(STATE/'health.json').stat().st_mtime
    action=decide(health,age,ears_ok,failures,time.time()-saved.get('last_restart',0))
    saved.update(failures=failures,checked_at=dt.datetime.now().astimezone().isoformat())
    if action:
        # Re-read immediately before acting; typing may have started during the probe.
        latest=json.loads((STATE/'health.json').read_text())
        if decide(latest,time.time()-(STATE/'health.json').stat().st_mtime,ears_ok,failures,
                  time.time()-saved.get('last_restart',0)) == action:
            result=subprocess.run(['launchctl','kickstart','-k',f'gui/{os.getuid()}/{action}'],capture_output=True,text=True)
            saved.update(last_restart=time.time(),last_action=action,last_result=result.returncode)
            with (STATE/'recovery.log').open('a') as f:
                f.write(json.dumps(dict(at=saved['checked_at'],action=action,result=result.returncode))+'\n')
    tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(saved,indent=2));tmp.replace(path)

if __name__=='__main__':check()
