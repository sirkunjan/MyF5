"""Local enrolled-speaker filtering; never learns from background audio.

Hush removes noise/quieter competing speech; Silero detects speech; WeSpeaker
checks short windows against an explicitly enrolled profile. This is probabilistic
speaker filtering, not biometric authentication or perfect source separation.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import threading
import time

import kaldi_native_fbank as knf
import numpy as np
import onnxruntime as ort

RATE = 16000
MODEL_ID = 'wespeaker-resnet34-v1'

def unit(x):
    x = np.asarray(x, dtype=np.float32).reshape(-1)
    norm = float(np.linalg.norm(x))
    if not np.isfinite(norm) or norm < 1e-8:
        raise ValueError('invalid speaker embedding')
    return x / norm


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    with tmp.open('w') as f:
        os.chmod(tmp, 0o600)
        json.dump(value, f, indent=2)
    tmp.replace(path)


class VoiceGuard:
    def __init__(self, root):
        self.root = Path(root)
        self.profile_path = self.root / 'state/voice-profile.json'
        self.config_path = self.root / 'state/config.json'
        self.lock = threading.RLock()
        self.calibrated = False
        self.room_floor_db = -60.0
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1
        opts.inter_op_num_threads = 1
        self.speaker = ort.InferenceSession(str(self.root/'models/speaker/resnet34.onnx'), opts, providers=['CPUExecutionProvider'])
        self.vad = ort.InferenceSession(str(self.root/'models/speaker/silero_vad.onnx'), opts, providers=['CPUExecutionProvider'])
        self.lib = ctypes.CDLL(str(self.root/'models/hush/libweya_nc.dylib'))
        lib = self.lib
        lib.weya_nc_model_load_from_path.argtypes = [ctypes.c_char_p]
        lib.weya_nc_model_load_from_path.restype = ctypes.c_void_p
        lib.weya_nc_session_create.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_float]
        lib.weya_nc_session_create.restype = ctypes.c_void_p
        lib.weya_nc_get_frame_length.argtypes = [ctypes.c_void_p]
        lib.weya_nc_get_frame_length.restype = ctypes.c_size_t
        lib.weya_nc_process_frame.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float)]
        lib.weya_nc_process_frame.restype = ctypes.c_float
        lib.weya_nc_session_free.argtypes = [ctypes.c_void_p]
        lib.weya_nc_session_free.restype = None
        self.hush = lib.weya_nc_model_load_from_path(os.fsencode(self.root/'models/hush/hush.tar.gz'))
        if not self.hush:
            raise RuntimeError('cannot load Hush model')
        self.profile = None
        self.profile_error = ''
        self._stamp = None
        self.refresh_profile()

    def config(self):
        try:
            return json.loads(self.config_path.read_text())
        except (OSError, ValueError):
            # A damaged settings file must not silently disable protection.
            return {'voiceFilterRequired': True}

    def refresh_profile(self):
        try:
            stamp = self.profile_path.stat().st_mtime_ns
        except FileNotFoundError:
            self.profile = None
            self._stamp = None
            self.profile_error = ''
            return
        if stamp == self._stamp:
            return
        self._stamp = stamp
        try:
            obj = json.loads(self.profile_path.read_text())
            if obj.get('model') != MODEL_ID or obj.get('version') != 1:
                raise ValueError('incompatible voice profile; enroll again')
            centroid = np.asarray(obj['centroid'], dtype=np.float32)
            if centroid.shape != (256,) or not np.all(np.isfinite(centroid)):
                raise ValueError('damaged voice profile; enroll again')
            self.profile = unit(centroid)
            self.profile_error = ''
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.profile = None
            self.profile_error = str(exc)

    def status(self):
        with self.lock:
            self.refresh_profile()
            required = self.config().get('voiceFilterRequired', True) is not False
            return dict(required=required, enrolled=self.profile is not None,
                        calibrated=self.calibrated, room_floor_db=round(self.room_floor_db,1),
                        enrollment_required=required and self.profile is None,
                        error=self.profile_error, model=MODEL_ID)

    def enhance(self, samples):
        x = np.asarray(samples, dtype=np.float32)
        # Hush can suppress an entire quiet foreground sentence. Present it at
        # a bounded analysis level; never boost digital silence or clip peaks.
        rms = float(np.sqrt(np.mean(x*x))) if len(x) else 0.0
        peak = float(np.max(np.abs(x))) if len(x) else 0.0
        if rms > 1e-5 and peak > 0:
            gain = min(32.0, max(1.0, 0.06/rms), 0.95/peak)
            x = x * gain
        session = self.lib.weya_nc_session_create(self.hush, RATE, ctypes.c_float(100.0))
        if not session:
            raise RuntimeError('cannot create noise-suppression session')
        try:
            n = int(self.lib.weya_nc_get_frame_length(session))
            if n != 160:
                raise RuntimeError('unexpected Hush frame length')
            # Include silence to flush causal analysis/synthesis delay (one hop).
            padded = np.pad(x, (0, n*3 + (-len(x)) % n))
            out = np.zeros_like(padded)
            ptr = ctypes.POINTER(ctypes.c_float)
            for at in range(0, len(padded), n):
                a = np.ascontiguousarray(padded[at:at+n])
                b = np.zeros(n,dtype=np.float32)
                self.lib.weya_nc_process_frame(session, a.ctypes.data_as(ptr), b.ctypes.data_as(ptr))
                out[at:at+n] = b
            return out[n:n+len(x)]
        finally:
            self.lib.weya_nc_session_free(session)

    def speech_mask(self, samples):
        x = np.asarray(samples, dtype=np.float32)
        mask = np.zeros(len(x), dtype=bool)
        state = np.zeros((2,1,128),dtype=np.float32)
        context = np.zeros((1,64),dtype=np.float32)
        for at in range(0,len(x),512):
            frame = np.pad(x[at:at+512], (0,max(0,512-len(x[at:at+512])))).reshape(1,-1)
            joined = np.concatenate([context,frame],axis=1)
            prob,state = self.vad.run(None,{'input':joined,'state':state,'sr':np.array(RATE,dtype=np.int64)})
            context=joined[:,-64:]
            if float(prob.reshape(-1)[0]) >= 0.5:
                # Preserve 150 ms around detected speech: soft onsets and
                # unvoiced consonants often precede VAD confidence. Speaker
                # checks still authorize every half-second independently.
                mask[max(0,at-2400):min(len(x),at+512+2400)] = True
        return mask

    def embedding(self, samples):
        x = np.asarray(samples,dtype=np.float32)
        if len(x) < RATE//2:
            raise ValueError('not enough speech to identify a voice')
        opts=knf.FbankOptions()
        opts.frame_opts.samp_freq=RATE
        opts.frame_opts.dither=0
        opts.frame_opts.window_type='hamming'
        opts.mel_opts.num_bins=80
        opts.mel_opts.use_slaney_mel_scale=False
        opts.mel_opts.norm=''
        fbank=knf.OnlineFbank(opts)
        fbank.accept_waveform(RATE,(x*32768).tolist())
        fbank.input_finished()
        feats=np.stack([fbank.get_frame(i) for i in range(fbank.num_frames_ready)]).astype(np.float32)
        feats-=feats.mean(axis=0,keepdims=True)
        return unit(self.speaker.run(['embs'],{'feats':feats[None]})[0])

    def enroll(self, samples):
        with self.lock:
            if not RATE*15 <= len(samples) <= RATE*60:
                raise ValueError('record 15–60 seconds of clean solo speech')
            if np.mean(np.abs(samples) >= 0.99) > 0.01:
                raise ValueError('microphone is clipping; lower the input level and retry')
            clean=self.enhance(samples)
            mask=self.speech_mask(clean)
            voice=np.asarray(samples,dtype=np.float32)[mask]
            if len(voice) < RATE*10:
                raise ValueError('need at least ten seconds of speech; speak continuously and retry')
            refs=[]
            # Overlapping short checks detect speaker changes during enrollment.
            width=RATE*3//2
            original=np.asarray(samples,dtype=np.float32)
            for at in range(0,len(original)-width+1,RATE*3//4):
                # Keep contiguous natural speech; splicing VAD islands creates
                # artificial phoneme transitions. Suppression is used only to
                # locate speech, not to learn a distorted headset identity.
                if float(mask[at:at+width].mean()) < 0.8:
                    continue
                refs.append(self.embedding(original[at:at+width]))
            if len(refs)<3:
                raise ValueError('not enough usable enrollment speech')
            centroid=unit(np.mean(refs,axis=0))
            consistency=[float(v@centroid) for v in refs]
            pairwise=np.stack(refs)@np.stack(refs).T
            pairs=pairwise[np.triu_indices(len(refs),1)]
            # A half-percent boundary tolerance matches the displayed two-decimal
            # scores, avoiding rejection of 0.599/0.449 shown as 0.60/0.45.
            # This affects explicit solo enrollment only, not runtime matching.
            if min(consistency) < 0.595 or float(np.percentile(pairs,10)) < 0.445:
                raise ValueError(f'voice samples did not match consistently (lowest match {min(consistency):.3f}, pairwise match {float(np.percentile(pairs,10)):.3f}). The previous profile was kept. This can also happen with microphone distortion; it does not prove another person was speaking')
            atomic_json(self.profile_path,dict(version=1,model=MODEL_ID,centroid=centroid.tolist(),
                       enrolled_at=time.time(),speech_seconds=round(len(voice)/RATE,1),
                       consistency_min=round(min(consistency),3)))
            self._stamp=None
            self.refresh_profile()
            return self.status()

    def calibrate(self, samples):
        with self.lock:
            if not RATE <= len(samples) <= RATE*10:
                raise ValueError('room sample must be 1–10 seconds')
            clean=self.enhance(samples)
            frames=[20*np.log10(max(float(np.sqrt(np.mean(clean[at:at+320]**2))),1e-8))
                    for at in range(0,len(clean)-320,320)]
            self.room_floor_db=float(np.percentile(frames,20))
            self.calibrated=True
            # Only an acoustic statistic persists; no room recording or identity learning.
            atomic_json(self.root/'state/room-noise.json',dict(version=1,measured_at=time.time(),
                        residual_floor_db=round(self.room_floor_db,2)))
            return self.status()

    def forget(self):
        with self.lock:
            self.profile_path.unlink(missing_ok=True)
            self.refresh_profile()
            return self.status()

    def filter(self, samples, *, required_override=None):
        with self.lock:
            self.refresh_profile()
            cfg=self.config()
            required=(cfg.get('voiceFilterRequired',True) is not False) if required_override is None else bool(required_override)
            if not required:
                return np.asarray(samples,dtype=np.float32),dict(mode='off',accepted=True)
            if self.profile is None:
                return np.zeros(0,dtype=np.float32),dict(mode='enrollment-required',accepted=False)
            clean=self.enhance(samples)
            mask=self.speech_mask(clean)
            # Baseline never raises the gate enough to exclude quiet speech.
            floor=min(-55.0,max(-70.0,self.room_floor_db+6)) if self.calibrated else -65.0
            threshold=float(cfg.get('voiceMatchThreshold',0.60))
            threshold=min(0.95,max(0.45,threshold))
            kept=np.zeros_like(clean)
            accepted=0
            scores=[]
            hop=RATE
            # Every second requires its OWN speech to match; an owner's
            # voice earlier in a long request cannot authorize the whole request.
            for at in range(0,len(clean),hop):
                end=min(len(clean),at+hop)
                if np.count_nonzero(mask[at:end])<RATE*0.12:continue
                # Gate a complete decision window, never individual consonants.
                db=20*np.log10(max(float(np.sqrt(np.mean(clean[at:end]**2))),1e-8))
                if db < floor:continue
                left=max(0,at-RATE);right=min(len(clean),end+RATE)
                voiced=clean[left:right][mask[left:right]]
                if len(voiced)<RATE//2:continue
                score=float(self.embedding(voiced)@self.profile)
                # Independently check the local window where enough speech exists.
                local_left=max(0,at-RATE//4)
                local_right=min(len(clean),end+RATE//4)
                local=clean[local_left:local_right][mask[local_left:local_right]]
                if len(local)>=RATE*0.5:
                    local_score=float(self.embedding(local)@self.profile)
                    # Use real local phonetic context. Repeating
                    # half-second fragments creates unstable embeddings and
                    # falsely vetoes soft syllables from the enrolled speaker.
                    if local_score < 0.35:
                        score=-1.0
                scores.append(score)
                if score>=threshold:
                    kept[at:end]=clean[at:end]*mask[at:end]
                    accepted+=int(np.count_nonzero(mask[at:end]))
            return kept,dict(mode='enrolled-speaker',accepted=accepted>=RATE*0.2,
                        accepted_seconds=round(accepted/RATE,2),threshold=threshold,
                        max_score=round(max(scores),3) if scores else None)
