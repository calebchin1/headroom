#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) UsageRings.app.
#   ./build.sh        build, install to ~/Applications, start at login
#   ./build.sh dist   build and zip dist/UsageRings.zip to send to someone
set -euo pipefail
cd "$(dirname "$0")"

NAME=UsageRings
OUT=dist/$NAME
APP=$OUT/$NAME.app
TMP=$(mktemp -d)

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13 -o "$TMP/$arch" $NAME.swift 2>&1 \
    | grep -v -e '^$' -e 'deprecated' -e 'DeprecatedDeclaration' -e '^ *[0-9]* |' -e '^ *|' || true
  [[ -x "$TMP/$arch" ]] || { echo "build failed ($arch)"; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"
lipo -create -output "$APP/Contents/MacOS/$NAME" "$TMP/arm64" "$TMP/x86_64"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.usagerings</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
cp install.sh uninstall.sh "$OUT/"
cat > "$OUT/README.txt" <<'TXT'
UsageRings — floating widget showing your Claude Code / Codex plan usage.

Install:    open Terminal, drag this folder in after typing  cd , press Enter, then run:  zsh install.sh
Uninstall:  zsh uninstall.sh

Needs macOS 13+, and Claude Code logged in with a Claude.ai plan and/or Codex logged in with ChatGPT.
Click the widget to switch Claude/Codex, drag to move, right-click for options.
TXT

if [[ "${1:-}" == dist ]]; then
  (cd dist && rm -f $NAME.zip && ditto -c -k --norsrc --noextattr --keepParent $NAME $NAME.zip)
  echo "Built dist/$NAME.zip"
  exit 0
fi

zsh "$OUT/install.sh"

# Retired: the separate Codex widget (merged into UsageRings).
pkill -x CodexRings 2>/dev/null || true
rm -rf "$HOME/Applications/CodexRings.app" "$HOME/Library/LaunchAgents/local.codexrings.plist"
