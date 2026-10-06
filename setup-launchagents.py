from pathlib import Path
import os, plistlib, subprocess, urllib.request, json, time
root=Path(__file__).resolve().parent
agents=Path.home()/'Library/LaunchAgents';agents.mkdir(parents=True,exist_ok=True)
uid=os.getuid();state=root/'state';state.mkdir(exist_ok=True)
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','F5_ROOT':str(root),'K_BUTTON_MODEL':str(root/'models/parakeet-tdt-0.6b-v2'),'HF_HUB_OFFLINE':'1','PYTHONNOUSERSITE':'1'}
# Import before registering jobs, so a damaged or incompatible runtime fails clearly.
import mlx.core, parakeet_mlx, numpy, onnxruntime, kaldi_native_fbank
jobs={'com.f5.ears':[str(root/'runtime/bin/python3'),'-I',str(root/'ears/serve.py')],
      'com.f5':[str(root/'PTTHelper.app/Contents/MacOS/ptt-helper'),'run'],
      'com.f5.recovery':[str(root/'runtime/bin/python3'),'-I',str(root/'recovery.py')]}
for label,args in jobs.items():
    obj=dict(Label=label,ProgramArguments=args,EnvironmentVariables=env,RunAtLoad=True,Umask=63,
             StandardOutPath=str(state/(label+'.log')),StandardErrorPath=str(state/(label+'.log')))
    if label.endswith('recovery'):obj['StartInterval']=15
    else:obj.update(KeepAlive=True,ThrottleInterval=10)
    path=agents/(label+'.plist');path.write_bytes(plistlib.dumps(obj))
    subprocess.run(['launchctl','bootout',f'gui/{uid}/{label}'],capture_output=True)
    subprocess.run(['launchctl','enable',f'gui/{uid}/{label}'],check=True)
    # launchd may briefly retain a job after bootout; retry its retirement.
    for delay in (0.5, 1.0, 2.0):
        time.sleep(delay)
        result=subprocess.run(['launchctl','bootstrap',f'gui/{uid}',str(path)],capture_output=True,text=True)
        if result.returncode == 0:break
    else:raise SystemExit(f'Could not start {label}: {result.stderr.strip()}')
for attempt in range(90):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8866/api/state',timeout=2) as response:
            if json.load(response).get('ready'):break
    except Exception:pass
    time.sleep(1)
else:raise SystemExit('Speech service did not start. Check the state/com.f5.ears.log file in the installed MyF5 folder')
print('MyF5 installed. Grant Microphone and Accessibility permission to MyF5 (older grants may say K PTT) in System Settings > Privacy & Security.')
subprocess.run([str(root/'PTTHelper.app/Contents/MacOS/ptt-helper'),'status'])
