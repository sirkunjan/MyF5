#!/usr/bin/env python3
"""Isolated HTTP + real ASR + native helper regression. No donor job changes."""
import io,json,os,re
from pathlib import Path
import shutil,subprocess,sys,tempfile,time,urllib.request,wave
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1]
FIXTURES=Path(sys.argv[1])
HELPER=Path(sys.argv[2]) if len(sys.argv)>2 else ROOT/'PTTHelper.app/Contents/MacOS/ptt-helper'
PORT=18867

def wav(samples):
    output=io.BytesIO()
    with wave.open(output,'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000)
        f.writeframes((np.clip(samples,-1,1)*32767).astype('<i2').tobytes())
    return output.getvalue()

def words(text):return re.findall(r"[a-z]+",text.lower())

def audio(s,n):return sf.read(FIXTURES/f'spk{s}_snt{n}.wav',dtype='float32')[0]

with tempfile.TemporaryDirectory(prefix='F5 HTTP relocation ') as folder:
    root=Path(folder)
    shutil.copytree(ROOT/'ears',root/'ears',ignore=shutil.ignore_patterns('__pycache__'))
    (root/'models').symlink_to(ROOT/'models');(root/'state').mkdir()
    config=root/'state/config.json'
    settings={'voiceFilterRequired':True,'kBaseURL':f'http://127.0.0.1:{PORT}'}
    config.write_text(json.dumps(settings))
    env=dict(os.environ,K_BUTTON_PORT=str(PORT),K_BUTTON_MODEL=str(ROOT/'models/parakeet-tdt-0.6b-v2'),HF_HUB_OFFLINE='1',F5_ROOT=str(root),K_PTT_CONFIG=str(config))
    def get():
        with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/api/state',timeout=5) as f:return json.load(f)
    def post(route,body):
        request=urllib.request.Request(f'http://127.0.0.1:{PORT}'+route,data=body,headers={'Content-Type':'audio/wav'})
        with urllib.request.urlopen(request,timeout=90) as f:return json.load(f)
    with (root/'server.log').open('w') as log:
        process=subprocess.Popen([str(ROOT/'runtime/bin/python3'),'-I',str(root/'ears/serve.py')],env=env,stdout=log,stderr=log)
        try:
            for _ in range(90):
                if process.poll() is not None:raise RuntimeError((root/'server.log').read_text())
                try:
                    if get()['ready']:break
                except Exception:pass
                time.sleep(1)
            else:raise RuntimeError('speech startup timed out')
            post('/api/voice/calibrate',wav(np.zeros(16000*3,dtype=np.float32)))
            assert not get()['voice']['enrolled']
            print('PASS: room baseline is separate from identity',flush=True)
            enrollment=np.tile(np.concatenate([audio(1,1),audio(1,2)]),5)[:16000*30]
            post('/api/voice/enroll',wav(enrollment))
            expected={3:'At that high level the air is pure.',4:'A thin stripe runs down the middle.',5:'Sunday is the best part of the week.',6:'The pencils have all been used.'}
            for n,text in expected.items():
                answer=post('/api/turn?draft=1&quiet=1',wav(audio(1,n)))
                assert words(answer['heard'])==words(text),answer
            print('PASS: all four held-out owner sentences retained word for word',flush=True)
            diagnostic=post('/api/diagnose',wav(audio(1,3)))
            assert words(diagnostic['protected_text'])==words(expected[3]),diagnostic
            assert words(diagnostic['unfiltered_text'])==words(expected[3]),diagnostic
            diagnostic=post('/api/diagnose',wav(audio(2,3)))
            assert diagnostic['protected_text']=='' and diagnostic['unfiltered_text'],diagnostic
            print('PASS: diagnostic comparison separates unfiltered ASR from protected output',flush=True)

            for scale in [.25,.08]:
                answer=post('/api/turn?draft=1',wav(audio(1,3)*scale))
                assert words(answer['heard'])==words(expected[3]),answer
            paused=np.concatenate([audio(1,3)*.08,np.zeros(64000,dtype=np.float32),audio(1,4)*.08])
            answer=post('/api/turn?draft=1',wav(paused))
            assert words(answer['heard'])==words(expected[3]+' '+expected[4]),answer
            print('PASS: quiet speech retains every word and resumes after a four-second pause',flush=True)
            for n in range(1,7):
                answer=post('/api/turn?draft=1',wav(audio(2,n)))
                assert answer['heard']=='',answer
            print('PASS: six different-speaker sentences rejected by HTTP/ASR pipeline',flush=True)
            owner=audio(1,3);other=audio(2,3)
            answer=post('/api/turn?draft=1',wav(np.concatenate([owner,np.zeros(8000,dtype=np.float32),other])))
            assert words(answer['heard'])==words(expected[3]),answer
            print('PASS: owner then other speaker does not authorize the other speaker',flush=True)
            mixed=owner+np.resize(other,len(owner))*.1
            answer=post('/api/turn?draft=1',wav(mixed))
            print('quieter overlap transcript:',answer['heard'],flush=True)
            assert words(answer['heard'])==words(expected[3]),answer
            print('PASS: quieter overlapping speaker suppressed, target words preserved',flush=True)
            # Three simultaneous competing speech tracks, at normal and quiet
            # overall levels. This reproduced the old half-second chopping bug.
            crowd=sum(np.resize(audio(2,n),len(owner)) for n in [3,4,5])/3
            for level in [1,.08]:
                answer=post('/api/turn?draft=1',wav((owner+crowd*.25)*level))
                assert words(answer['heard'])==words(expected[3]),answer
            print('PASS: three overlapping speech tracks retain every target word at normal and quiet levels',flush=True)
            sample=root/'owner.wav';sample.write_bytes(wav(owner))
            reply=subprocess.run([str(HELPER),'dictate-file',str(sample)],env=env,capture_output=True,text=True,check=True)
            assert expected[3] in reply.stdout,reply.stdout
            print('PASS: native helper → protected HTTP → owner transcription',flush=True)
            # Restart: profile is saved and the room baseline must be measured anew.
            process.terminate();process.wait(timeout=10)
            process=subprocess.Popen([str(ROOT/'runtime/bin/python3'),'-I',str(root/'ears/serve.py')],env=env,stdout=log,stderr=log)
            for _ in range(90):
                try:
                    if get()['ready']:break
                except Exception:pass
                time.sleep(1)
            assert get()['voice']['enrolled'];assert not get()['voice']['calibrated']
            print('PASS: enrollment survives restart; room baseline resets',flush=True)
            # Explicit off-mode preserves the legacy speech route for regression.
            settings['voiceFilterRequired']=False;config.write_text(json.dumps(settings))
            # ears.py targets the donor's 8866, so use its source with only the port changed.
            test=root/'legacy-ears.py';test.write_text((ROOT/'tests/ears.py').read_text().replace('8866',str(PORT)))
            subprocess.run([str(ROOT/'runtime/bin/python3'),'-I',str(test)],env=env,check=True)
            print('PASS: legacy quiet/default routes and silence regression',flush=True)
        finally:
            if process.poll() is None:process.terminate();process.wait(timeout=10)
