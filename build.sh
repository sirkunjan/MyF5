#!/bin/zsh
# Build the PTT helper into a small .app bundle.
#
# A bundle, not a bare binary, for two measured reasons:
#   1. MediaPlayer / Now Playing arbitration wants a real bundled app.
#   2. macOS lists a bundle by name in Privacy & Security, so the founder can
#      see and tick "K PTT" rather than a nameless executable.
set -e
cd "$(dirname "$0")"

APP="PTTHelper.app"
BIN="$APP/Contents/MacOS/ptt-helper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" state

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MyF5</string>
  <key>CFBundleDisplayName</key><string>MyF5</string>
  <key>CFBundleIdentifier</key><string>com.k.ptt</string>
  <!-- The identifier stays com.k.ptt on purpose. macOS files the Microphone
       and Accessibility permissions he already granted under this name, and
       renaming it would make him approve the same app all over again. The
       folder moved; the identity did not. -->
  <key>CFBundleExecutable</key><string>ptt-helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.2</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>MyF5 uses your microphone for dictation, voice enrollment, and brief room-noise measurements.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MyF5 transcribes your speech locally.</string>
</dict>
</plist>
PLIST

swiftc -O -target arm64-apple-macosx26.2 -o "$BIN" Sources/main.swift Sources/MyF5UI.swift Sources/JournalStore.swift \
  -framework AppKit -framework AVFoundation -framework MediaPlayer \
  -framework CoreAudio -framework AudioToolbox -framework ApplicationServices

# Signing. A STABLE local identity, created once by ./setup-signing.sh, so that
# rebuilding does not make macOS forget the Accessibility permission he granted.
#
# Measured on this Mac, 2026-08-18:
#   ad-hoc      designated => cdhash H"3269a500..."                  <- changes every build
#   self-signed designated => identifier "com.k.ptt" and
#                             certificate root = H"6bb96329..."      <- identical every build
# TCC stores that designated requirement, so the second form keeps matching.
./setup-signing.sh >/dev/null 2>&1 || true
IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
            | awk -F'"' '/K PTT Local Signing/{print $2; exit}')"

before="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier com.k.ptt "$APP" >/dev/null 2>&1
else
  echo "  (no local signing identity — falling back to ad-hoc; permissions will"
  echo "   need re-approving after each build. Run ./setup-signing.sh to fix.)"
  codesign --force --sign - --identifier com.k.ptt "$APP" >/dev/null 2>&1
fi

after="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
mkdir -p state
printf '%s\n' "$after" > state/designated-requirement.txt

echo "built $PWD/$APP"
echo "signed as: ${IDENTITY:-ad-hoc}"
if [ -n "$before" ] && [ "$before" != "$after" ]; then
  # The old permission can no longer match this app, but macOS keeps showing
  # its tick-box as if it did — so ticking it does nothing and there is no way
  # to tell. Clearing it means he gets a fresh, working prompt instead of a
  # dead switch. (This is exactly what went wrong on 2026-08-18: the box was
  # ticked, and the helper was still refused.)
  tccutil reset Accessibility com.k.ptt >/dev/null 2>&1 || true
  echo
  echo "  NOTE: this app's identity changed, so its old permission is void."
  echo "  The stale entry has been cleared for you; approve it once when asked."
  echo "  (This should be the LAST time: the identity is stable from now on.)"
  echo
fi
"$BIN" --help >/dev/null 2>&1 || true
