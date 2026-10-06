# Dependency map

Play/Pause media button → PTTHelper.app (native arm64 Swift) → AVFoundation microphone recording → local HTTP 127.0.0.1:8866 → optional DeepFilterNet3 noise reduction (on by default) → bundled Python/Parakeet/MLX transcription → floating editor → macOS Accessibility typing. Experimental identity matching is off; enabling the legacy path uses Hush, Silero and WeSpeaker instead.

The helper uses Apple AppKit, Foundation, AVFoundation, MediaPlayer, CoreAudio, AudioToolbox and ApplicationServices. All are supplied by macOS. launchd starts com.f5, com.f5.ears and com.f5.recovery. Recovery uses Python standard-library HTTP, JSON and subprocess modules. The button script uses system zsh.

The original runtime was /Users/k/K-SEED/.venv and model was /Users/k/K/constant K/10_MODELS/Local/parakeet-tdt-0.6b-v2. This gift includes a relocatable CPython distribution and the 52 installed packages in the required dependency closure, including their package metadata/licenses. No dependency on K, K-SEED, or the original user's paths remains in the installed jobs. All package versions are listed in requirements-lock.txt; those pins describe included artifacts, not a requirement to download them.

parakeet-mlx directly needs dacite, huggingface-hub, librosa, mlx, numpy and typer. Their transitive dependencies are bundled, including MLX Metal, SciPy, NumPy, Numba/LLVM, scikit-learn, SoundFile/libsndfile, soxr, HTTP libraries and CLI formatting libraries. F5 parses 16 kHz mono 16-bit PCM WAV directly: ffmpeg is not required by F5's service.

Model: mlx-community/parakeet-tdt-0.6b-v2, converted from NVIDIA parakeet-tdt-0.6b-v2, approximately 2.47 GB decimal weights, unchanged. Model card and tokenizer/config files are included. License CC BY 4.0: attribution to NVIDIA and MLX Community; https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2 and https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 ; license https://creativecommons.org/licenses/by/4.0/ . No model modifications made.

Sources: https://github.com/senstella/parakeet-mlx (Apache 2.0); https://ml-explore.github.io/mlx/build/html/install.html . Upstream MLX generally supports macOS 14+, but the installed MLX binary here targets macOS 26.2 and the gift Swift app has been rebuilt to target macOS 26.2. This package therefore requires macOS Tahoe 26.2+. Older Macs need a separately rebuilt and tested package. 8 GB minimum / 16 GB recommended are packaging estimates, not a vendor guarantee; observed idle service footprint on the donor Mac is around 1.3 GB, with a 6 GB restart ceiling.

Optional cleaner (disabled): Swift Rambler → localhost:11434 Ollama → qwen3:4b-instruct-2507-q4_K_M. It also looks for a K conversation settings file to override that model. Neither Ollama, K, nor this optional model is included or required for the default workflow.

## Voice filtering additions

Hush (Weya AI / pulp-vision): native Apple Silicon libweya_nc.dylib and ONNX model bundle, Apache 2.0. Source https://huggingface.co/weya-ai/hush and https://github.com/pulp-vision/Hush . It suppresses noise and quieter competing speakers; it is not target-speaker-conditioned separation. Model, runtime, LICENSE and NOTICE are under models/hush.

WeSpeaker ResNet34: ONNX 256-dimensional speaker embeddings, https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34 . Code Apache 2.0; upstream pretrained-model guidance attributes VoxCeleb-based weights under CC BY 4.0. Model, LICENSE and NOTICE are under models/speaker. The checkpoint is unchanged. User profiles are generated locally by explicit solo enrollment, then used to gate short audio windows; no automatic identity training from room sound.

Silero VAD: ONNX speech activity detection, MIT, https://github.com/snakers4/silero-vad . Model and license are under models/speaker. ONNX Runtime 1.29.0 and kaldi-native-fbank 1.22.3, plus their dependencies, are included in the bundled Python runtime. No PyTorch or external native libraries are needed for the new path. All 52 package versions are pinned in requirements-lock.txt.

Room baseline: three seconds collected by the Swift helper at startup and following an ears restart; stored as an ambient level statistic, separately from the persistent voice-profile embedding. Raw baseline/enrollment audio is never written to disk by F5. Missing or damaged profiles block transcription while protection is enabled. Voice matching is probabilistic and does not provide biometric authentication, replay detection, guaranteed overlap separation or guaranteed rejection of similar speakers.

## Noise reduction release — 6 October 2026

DeepFilterNet3: unchanged upstream ONNX archive and native aarch64-apple-darwin deep-filter v0.5.6 binary, from https://github.com/Rikorose/DeepFilterNet . MIT/Apache 2.0 code licenses included in models/deepfilter-trial. No Python/PyTorch dependency added; existing SciPy and SoundFile handle 16 ↔ 48 kHz resampling and disposable local WAVs. Noise reduction is enabled by default independently of identity filtering. Hush/Silero/WeSpeaker remain bundled for experimental legacy matching, which is disabled. No models are downloaded at install time.

The native helper also launches the macOS /usr/bin/log tool during Bluetooth microphone capture to observe narrowly filtered bluetoothd hang-up events; this is a compatibility workaround, not guaranteed public event routing.
