# Verification — 6 October 2026

Donor: Apple Silicon, macOS 27.0.1. Gift minimum: macOS Tahoe 26.2.

Human tests passed keyboard start/finish, Enter completion, Powerbeats Pro and
Nope Vibe start/finish with their microphones, and switching macOS default inputs.
Nope Vibe Music → Dictation passed. Powerbeats Music → Dictation was not separately
confirmed. The previously observed microphone/Siri popups were absent in the
successful final headset tests; other settings, devices and macOS versions remain
unverified.

Noise reduction: bundled DeepFilterNet3 v0.5.6 native arm64 CLI with bounded input
gain, delay flushing, original-length cropping, finite output validation and raw
fallback for errors or near-total suppression. Synthetic public SpeechBrain
fixtures transcribed correctly at normal volume, 8% volume, equal-energy white
noise, and soft speech plus noise. Local 2.72-second denoiser tests took roughly
0.14 seconds including process startup. Human headphone test preserved both
“The blue notebook is on the table” and “Now I am speaking more softly.” A loud
YouTube/TV test preserved the sentences and the user reported no video words.

A live multi-person test did transcribe other speakers. Noise reduction does not
provide speaker identity or reliable overlap extraction. Voice matching remains
off and unfinished shadow/profile-bank code is excluded. No enrollment required.

Bluetooth finishing uses current-input UID matching and narrow bluetoothd AT+CHUP
log observation during capture. It does not open RFCOMM or alter connections.
This workaround depends on system log availability and may change across OS
versions. No claim of universal Bluetooth support or tested Tahoe execution.

The gift contains no donor profiles, journals, dictations, diagnostic reports,
recordings or signing private keys. It is ad-hoc signed and not Apple notarized.
Recipient microphone/accessibility permissions and hardware tests are required.
Actual OS reboot/sleep and recipient OS execution have not been tested.

Automated release results are appended after the final package checks.

Final release checks passed: native selftests; five recovery tests; installed service readiness and silence routes; ad-hoc gift signature; 248-native-binary linkage audit with no external non-system dependencies or symlinks; maximum deployment target 26.2; installer syntax; relocated folder with spaces running offline, absent donor profile, no enrollment required, correct public-fixture ASR, and noise reduction on/off/on. No recipient installation or hardware validation was performed.
