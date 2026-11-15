#!/bin/sh
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/calebchin1/usage-rings/main/install.sh | sh
# Downloads the latest release and opens it; the app moves itself to ~/Applications
# and adds a login item. Files fetched with curl aren't quarantined, so there's no Gatekeeper prompt.
set -e

URL="https://github.com/calebchin1/usage-rings/releases/latest/download/UsageRings.zip"

[ "$(uname)" = "Darwin" ] || { echo "UsageRings is a macOS app."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || { echo "UsageRings needs macOS 13 or newer (you have $(sw_vers -productVersion))."; exit 1; }

TMP=$(mktemp -d)
echo "→ Downloading UsageRings…"
curl -fsSL "$URL" -o "$TMP/UsageRings.zip"
ditto -x -k "$TMP/UsageRings.zip" "$TMP"
xattr -dr com.apple.quarantine "$TMP/UsageRings.app" 2>/dev/null || true

echo "→ Installing to ~/Applications…"
open "$TMP/UsageRings.app"   # self-installs, adds login item, relaunches from ~/Applications

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -d "$HOME/Applications/UsageRings.app" ] && break
  sleep 1
done
if [ -d "$HOME/Applications/UsageRings.app" ]; then
  echo "✓ Done! Look for the widget in the top-right of your screen."
  echo "  Click it to switch Claude/Codex · drag to move · right-click for options."
else
  echo "Something went wrong — open $TMP/UsageRings.app manually."
  exit 1
fi
