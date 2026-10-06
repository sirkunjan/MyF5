#!/bin/zsh
for LABEL in com.f5.recovery com.f5 com.f5.ears; do
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
done
echo "F5 stopped and removed from login. Your F5 files are preserved."
