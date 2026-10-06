"""Optional local DeepFilterNet3 trial, independent of speaker matching."""
import json
import subprocess
import tempfile
from pathlib import Path
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

def process(samples, root):
    root=Path(root)
    try:
        enabled=json.loads((root/'state/noise-trial.json').read_text()).get('enabled') is True
    except FileNotFoundError:
        enabled=True
    except (OSError,ValueError):
        enabled=False
    if not enabled or len(samples)<800:
        return samples, {'noise_reduction':'off'}
    x=np.asarray(samples,dtype=np.float32)
    rms=float(np.sqrt(np.mean(x*x))); peak=float(np.max(np.abs(x)))
    if rms<1e-5:
        return x, {'noise_reduction':'deepfilter-silence'}
    gain=min(32.,max(1.,.06/rms),.95/max(peak,1e-9))
    model=root/'models/deepfilter-trial'
    try:
        # Private disposable files: CLI has no in-memory interface. The trailing
        # pad flushes synthesis delay; crop preserves every original sample.
        with tempfile.TemporaryDirectory(prefix='myf5-noise-') as directory:
            p=Path(directory); source=p/'input.wav'
            sf.write(source,resample_poly(np.pad(x*gain,(0,1600)),3,1),48000,subtype='FLOAT')
            subprocess.run([str(model/'deep-filter'),'-m',str(model/'DeepFilterNet3_onnx.tar.gz'),'-D','-o',str(p/'out'),str(source)],check=True,timeout=min(30,max(3,len(x)/16000)),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            out,rate=sf.read(p/'out/input.wav',dtype='float32')
            if rate!=48000: raise ValueError('unexpected output format')
            out=resample_poly(out,1,3)
            if len(out)<len(x) or not np.isfinite(out).all(): raise ValueError('invalid output')
            out=out[:len(x)]/gain
            # Never let a failed/silenced denoiser erase an audible utterance.
            if float(np.sqrt(np.mean(out*out)))<rms*.01:
                raise ValueError('suppression erased input')
            return out, {'noise_reduction':'deepfilter3-trial','noise_gain':round(gain,3)}
    except (OSError,ValueError,subprocess.SubprocessError):
        return x, {'noise_reduction':'raw-fallback'}
