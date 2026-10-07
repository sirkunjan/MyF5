# MyF5 — local dictation and journaling

## Install the complete app

**Start here: [Download MyF5](https://github.com/sirkunjan/MyF5/releases/tag/v1.0.0-gift.20261006).**

The green **Code → Download ZIP** button and the release's **Source code** links
contain developer source only. They do **not** include the built app, Python
runtime or speech models. Use the release assets below for installation.

### Check your Mac first

Open **Apple menu → About This Mac**. You need an **Apple Silicon** chip
(M1 or later) and **macOS 26.2 or later**. Intel Macs and older macOS versions
are not supported by this package. Allow at least **12 GB free disk space**
for downloading, unpacking and installing; this is a conservative allowance.

### Option A: download from GitHub

1. Open the download link above. If GitHub says **Page not found**, sign in
   again using the link above. This repository is public; no invitation is needed.
2. Under **Assets**, download these **four files** into the same folder:
   - `MyF5-Gift-2026-10-06.zip.part1` (1 GiB)
   - `MyF5-Gift-2026-10-06.zip.part2` (1 GiB)
   - `MyF5-Gift-2026-10-06.zip.part3` (about 421 MB)
   - `Reassemble-MyF5.zip` (small helper ZIP)
3. Wait until all downloads finish. Do not rename or unzip the `.part` files.
4. Double-click `Reassemble-MyF5.zip`, then open the extracted
   **Reassemble MyF5.command**. Keep it in the folder containing all three parts.
   It joins the parts and verifies the checksum before producing
   **MyF5-Gift-2026-10-06.zip**. If it reports a missing part or checksum failure,
   download the missing or damaged files again; do not install an unverified ZIP.
5. Double-click the completed gift ZIP. Open its **MyF5** folder, then open
   **Install MyF5.command**. Keep the whole extracted folder together.

GitHub limits individual release assets to under 2 GiB; the complete gift ZIP
is about 2.57 GB, so it is split into three parts. The standalone `.sha256` and
`Reassemble.MyF5.command` assets are optional; the four files above are sufficient.

### Option B: USB drive or AirDrop

Receive **MyF5-Gift-2026-10-06.zip** (about 2.57 GB), copy it to your Mac,
then unzip it and open **MyF5 → Install MyF5.command**. No reassembly is needed.
This is the same installer as the GitHub download.

### Permissions and first test

1. The installer creates `~/MyF5` and refuses to replace an existing installation.
   If that folder exists, preserve it and ask for update instructions.
2. This app is locally signed and **not notarized by Apple**. If macOS blocks
   opening it, review **System Settings → Privacy & Security** and the available
   **Open Anyway** action for the file you intended to open. Do not disable
   Gatekeeper. If opening is still blocked, report the exact message.
3. Follow MyF5's welcome screens and grant **Microphone** and **Accessibility**
   permissions. Older permission entries may say **PTTHelper** or **K PTT**.
   No voice enrollment is needed. Normal installation requires no Xcode,
   Homebrew, Python install, account, model download or internet connection.
4. In **System Settings → Sound → Input**, select **MacBook Pro Microphone**
   (or your Mac's built-in microphone) for the first test.
5. Open TextEdit, create a document, and place your cursor in it. Select MyF5
   **Dictation** mode from its menu. Press the Mac keyboard **Play/Pause** key,
   wait for the tick and draft, then say **“The blue notebook is on the table.”**
6. Press **Enter in the MyF5 draft**. The draft should close and insert the words
   in TextEdit. It does not send Enter to the destination by default.
7. Repeat, finishing with the Mac **Play/Pause** key. Then connect your headphones,
   select the desired input in macOS Sound, and test their **Play/Pause** button
   once to start and once to finish. Use a quick press, not an assistant hold.

### If something fails

| What you see | What to do |
| --- | --- |
| Source files but no app/runtime/models | Download the release's four installer files, not Source code |
| GitHub Page not found | Use the release link above; public downloads need no invitation |
| Missing part/checksum failure | Finish or repeat the three part downloads; keep their filenames |
| Existing installation warning | Preserve `~/MyF5`; do not delete your journals or settings |
| No draft opens | Check MyF5 is running in Dictation mode and Accessibility is granted |
| Draft opens but no words | Check Microphone permission and macOS Sound input; wait for the tick |
| Headphone finish fails | Finish with Enter; test the Mac keyboard and report headset/OS details |

When reporting a problem, send the exact error or screenshot, Mac chip,
macOS version, downloaded filenames, microphone and button used. Recipient
installation is not yet verified; device compatibility varies.

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

## License

MyF5's original source code is licensed under the [MIT License](LICENSE).
Bundled third-party libraries, runtimes and model weights retain their own
licenses; MIT does not relicense them. See [DEPENDENCIES.md](DEPENDENCIES.md)
and the license/notice files included in the installer. The original 6 October
installer archive is unchanged; this source license is published here separately.
