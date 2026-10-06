# MyF5 — local dictation and journaling

## Download the ready-to-use gift

Use [Releases](https://github.com/sirkunjan/MyF5/releases/latest), rather than GitHub’s source-code ZIP. The source repository does not contain the bundled runtime, models, or built app.

Download all three `MyF5-Gift-2026-10-06.zip.part1` / `part2` / `part3` files and **Reassemble MyF5.command** into the same folder. Open the command to assemble and SHA256-verify the gift ZIP. Unzip it, then open **Install MyF5.command**. The full archive is about 2.57 GB; GitHub requires each release asset to be under 2 GiB.

This repository is private. Only you and people you explicitly grant access can download it. AirDrop the original full ZIP if you prefer a single-file transfer.


Apple Silicon Mac, macOS Tahoe 26.2 or later. No Xcode, Homebrew, account,
model downloads, or internet connection is needed for normal installation.

## Install

1. Unzip MyF5 and open **Install MyF5.command**. It installs under ~/MyF5
   and refuses to overwrite an existing installation.
2. Grant Microphone and Accessibility to MyF5 (older entries can say PTTHelper
   or K PTT). This locally signed app is not notarized; review any macOS security
   prompt through Privacy & Security. The installer does not disable Gatekeeper.
3. Follow the welcome screens. No voice enrollment is needed.
4. Place your cursor in a document, press Play/Pause, wait for the tick, speak,
   then press Play/Pause again or Enter in the draft to finish.

## Everyday use

MyF5 follows the default input selected in macOS Sound settings. It does not
manage Bluetooth connections or require an app microphone picker. Words appear
in an editable draft; type corrections, or select words and speak a replacement.
Shift+Enter adds a new line; × discards the draft. The gift inserts approved text
without pressing Enter in the destination app; Settings can enable that behavior.

Noise reduction is enabled. In Settings, uncheck **Reduce background noise** to
use the original audio. Advanced terminal control: ./noise-trial on|off|status.
DeepFilterNet3 reduces noise but does not identify you: other people may still
be transcribed, especially when speaking loudly or at the same time as you.
Experimental legacy voice matching is off by default and is not part of setup.

Menu → Use Play/Pause for Music returns the button to media playback; switch
back to Dictation when ready. Keyboard, Powerbeats Pro, and Nope Vibe passed
human start/finish tests on the donor Mac. Bluetooth compatibility depends on
macOS and the device; Enter remains an alternate finish control. The Bluetooth
finish workaround observes narrowly filtered local bluetoothd hang-up logs only
while recording; it is not a guaranteed public button API.

## Journal and privacy

Switch to Journal mode from the menu to save locally instead of typing.
Entries use Journal/YYYY/MM/DD/audio/<entry-id>.wav and text/journal.md.
Journal audio is the original microphone recording and may contain background
voices. Cursor dictation saves its final text privately before delivery, but does
not retain microphone recordings. Enrollment saves an embedding, not audio.

Noise reduction runs locally through a bundled CLI. Its private temporary audio
files are removed after processing. Forced process termination can interrupt
cleanup. Nothing is uploaded. Review words before sending.

Services start at login and recover idle failures. Required models and runtime
are bundled. Optional Ollama cleanup is disabled and not needed. Source builds
require Xcode Command Line Tools; ordinary use does not. See DEPENDENCIES.md,
VERIFICATION.md and AGENTS.md for dependencies and known validation limits.

## Features and controls

| Control or feature | Behavior |
| --- | --- |
| Mac keyboard Play/Pause | Press once to open dictation; press again to finish and deliver |
| Headphone Play/Pause | Same start/finish behavior; tested with Powerbeats Pro and Nope Vibe |
| Enter in the draft | Finish and deliver |
| Shift+Enter | Insert a new line in the draft |
| × | Discard the current draft |
| Keyboard editing | Edit the draft before sending |
| Spoken correction | Select words in the draft and speak their replacement |
| Live preview | Words appear while you speak; recognition can briefly trail speech |
| Music mode | Give Play/Pause back to music/video; switch back to Dictation from the menu |
| Journal mode | Save dated original audio and linked text locally instead of typing |
| Settings | Font size, spacing, live preview, review, sounds, noise reduction, and destination Enter |
| macOS microphone selection | Use the active default input, including built-in and Bluetooth microphones |
| Login and recovery | Start services at login and recover idle failures |

Headphone instructions: connect the headphones in macOS, check the input in Sound
settings, select MyF5 Dictation mode, place your cursor, press Play/Pause once,
wait for the tick, speak, then press it once again to finish. Use the actual
Play/Pause control rather than a press-and-hold assistant gesture. Test a short
sentence after installation. Hardware and OS differences can affect routing;
if finishing fails, use Enter in the draft and test the Mac keyboard control.

## Technical specification

| Item | Included implementation |
| --- | --- |
| Platform | Apple Silicon arm64; macOS 26.2 or later |
| Interface | Native Swift/AppKit menu bar and editable floating draft |
| Audio capture | AVAudioEngine, macOS default input; 16 kHz mono PCM |
| Speech recognition | Parakeet TDT 0.6B v2 via parakeet-mlx 0.5.2 |
| Compute runtime | Bundled Python 3.11.15, MLX/MLX Metal 0.32.2 |
| Active noise reduction | DeepFilterNet3 with deep-filter v0.5.6 arm64 CLI |
| Noise processing | Bounded gain, 48 kHz processing, delay flush, 16 kHz resampling, original-duration crop |
| Failure behavior | Fall back to original audio if reduction fails or nearly erases input |
| Local service | HTTP 127.0.0.1:8866; bundled models, no remote transcription |
| Voice matching | Experimental legacy WeSpeaker ResNet34; disabled by default |
| Legacy protection components | Hush noise suppression and Silero VAD, used when experimental matching is enabled |
| Button routing | Keyboard media-event interception, MediaPlayer commands, and active-input Bluetooth hang-up log bridge |
| Startup | Three per-user launchd jobs: helper, speech service, recovery |
| Storage | Approximately 3 GB unpacked; allow extra space for the ZIP and installation |
| Memory | 16 GB recommended; workload-dependent, not a measured minimum for every device |
| Install requirements | No Xcode, Homebrew, Python install, model download, subscription, or account |

## What to expect

The donor's tests passed on the Mac microphone, Powerbeats Pro, and Nope Vibe.
Soft speech worked. With a loud video playing, the intended sentences remained
and the user reported no video words. In a live test with another person speaking,
the transcript did include that person's words. These observations describe the
tested setup, not a guarantee for every room, voice, headset, or macOS version.

Noise suppression, speaker verification, and target-speaker extraction are three
separate jobs. Noise suppression reduces unwanted sound. Speaker verification
checks whether speech resembles an enrolled voice. Target-speaker extraction
tries to recover that person's speech when voices overlap. This release provides
noise suppression; it does not promise personal voice isolation or authentication.

Draft text may arrive shortly after speech, especially on longer passages.
The prototype denoiser launches a process per preview; it is not a persistent
streaming model. Short public-fixture tests processed 2.72 seconds in roughly
0.14 seconds for reduction alone. Full transcription delay depends on the Mac,
audio length, and microphone readiness. Wait for the tick before speaking.

## Research options for a future voice-isolation version

These are comparison candidates, not features shipped or proven on your headset:

- Apple AVAudioEngine voice processing and user-controlled Voice Isolation:
  https://developer.apple.com/videos/play/wwdc2023/10235/
  This processes sound; it does not prove which person is speaking.
- SpeechBrain ECAPA-TDNN speaker verification:
  https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb
- CAM++ and ERes2Net speaker-verification families:
  https://github.com/modelscope/3D-Speaker
  Published benchmarks do not establish the best model for your microphones.
- Target-speaker extraction toolkit WeSep:
  https://github.com/wenet-e2e/WeSep
  Its reviewed release is a research preview; validated official pretrained
  packages and production deployment were not available in the reviewed scope.

Before enabling identity filtering, compare enrollment and matching with
consistent audio processing, explicit profiles for different microphones, and
held-out recordings. Measure missed words, rejection of the owner's voice,
acceptance of other speakers, overlap handling, and latency. The interrupted
shadow-matching prototype is excluded from this release. Earlier diagnostics
and microphone/Siri popup failures are development history, not current verified
recipient behavior. Current successful tests had no such popups; Bluetooth
routing still needs testing on the recipient's Mac.
