#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) UsageRings.app.
#   ./build.sh        build and launch; the app installs itself to ~/Applications + login item
#   ./build.sh dist   build and zip dist/UsageRings.zip (just the app) to send to someone
set -euo pipefail
cd "$(dirname "$0")"

NAME=UsageRings
APP=dist/$NAME.app
TMP=$(mktemp -d)

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13 -o "$TMP/$arch" $NAME.swift 2>&1 \
    | grep -v -e '^$' -e 'deprecated' -e 'DeprecatedDeclaration' -e '^ *[0-9]* |' -e '^ *|' || true
  [[ -x "$TMP/$arch" ]] || { echo "build failed ($arch)"; exit 1; }
done

rm -rf dist
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
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1

if [[ "${1:-}" == dist ]]; then
  (cd dist && ditto -c -k --norsrc --noextattr --keepParent $NAME.app $NAME.zip)
  echo "Built dist/$NAME.zip"
  exit 0
fi

open "$APP"   # copies itself to ~/Applications, registers login item, relaunches
echo "Launched; it installs itself to ~/Applications"

# Retired: the separate Codex widget (merged into UsageRings).
pkill -x CodexRings 2>/dev/null || true
rm -rf "$HOME/Applications/CodexRings.app" "$HOME/Library/LaunchAgents/local.codexrings.plist"
