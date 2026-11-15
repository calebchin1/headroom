#!/bin/zsh
# Installs UsageRings.app (from this folder) into ~/Applications and starts it at login.
set -euo pipefail
cd "$(dirname "$0")"

NAME=UsageRings
ID=local.usagerings
APP="$HOME/Applications/$NAME.app"
AGENT="$HOME/Library/LaunchAgents/$ID.plist"

[[ -d "$NAME.app" ]] || { echo "$NAME.app not found next to install.sh"; exit 1; }

pkill -x "$NAME" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
cp -R "$NAME.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true   # downloaded copies are blocked otherwise

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$ID</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST

sleep 0.5
open "$APP"
echo "Installed $APP (starts at login). Remove with: zsh uninstall.sh"
