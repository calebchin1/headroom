#!/bin/sh
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/calebchin1/headroom/main/install.sh | sh
# Downloads the latest release and opens it; the app moves itself to ~/Applications
# and adds a login item. Files fetched with curl aren't quarantined, so there's no Gatekeeper prompt.
set -e

URL="https://github.com/calebchin1/headroom/releases/latest/download/Headroom.zip"

[ "$(uname)" = "Darwin" ] || { echo "This installer is for macOS. On Windows, run this in PowerShell:"; echo "  irm https://raw.githubusercontent.com/calebchin1/headroom/main/install.ps1 | iex"; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || { echo "Headroom needs macOS 13 or newer (you have $(sw_vers -productVersion))."; exit 1; }

TMP=$(mktemp -d)
echo "→ Downloading Headroom…"
curl -fsSL "$URL" -o "$TMP/Headroom.zip"
ditto -x -k "$TMP/Headroom.zip" "$TMP"
xattr -dr com.apple.quarantine "$TMP/Headroom.app" 2>/dev/null || true

echo "→ Installing to ~/Applications…"
open "$TMP/Headroom.app"   # self-installs, adds login item, relaunches from ~/Applications

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -d "$HOME/Applications/Headroom.app" ] && break
  sleep 1
done
if [ -d "$HOME/Applications/Headroom.app" ]; then
  echo "✓ Done! Look for the widget in the top-right of your screen."
  echo "  Click it to switch Claude/Codex · drag to move · right-click for options."
else
  echo "Something went wrong — open $TMP/Headroom.app manually."
  exit 1
fi
