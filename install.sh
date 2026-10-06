#!/bin/zsh
set -e
cd "$(dirname "$0")"
if [[ "$(uname -m)" != arm64 ]]; then echo "F5 requires an Apple Silicon Mac."; exit 1; fi
MAC_VERSION="$(sw_vers -productVersion)"
MAC_MAJOR="${MAC_VERSION%%.*}"
MAC_TAIL="${MAC_VERSION#*.}"; MAC_MINOR="${MAC_TAIL%%.*}"
if (( MAC_MAJOR < 26 || (MAC_MAJOR == 26 && MAC_MINOR < 2) )); then
  echo "MyF5 requires macOS Tahoe 26.2 or newer."; exit 1
fi
TARGET="$HOME/MyF5"
if [[ "$PWD" == "$HOME/F5" ]]; then TARGET="$PWD"; fi
if [[ "$PWD" != "$TARGET" ]]; then
  if [[ -e "$TARGET" ]]; then echo "A MyF5 folder already exists at $TARGET. Move this gift folder there yourself after saving the existing folder."; exit 1; fi
  /usr/bin/ditto "$PWD" "$TARGET"
  cd "$TARGET"
fi
./runtime/bin/python3 -I setup-launchagents.py
