#!/bin/zsh
# Quits UsageRings and removes the app, its login item and its saved settings.
pkill -x UsageRings 2>/dev/null || true
launchctl bootout "gui/$(id -u)/local.usagerings" 2>/dev/null || true
rm -rf "$HOME/Applications/UsageRings.app" "$HOME/Library/LaunchAgents/local.usagerings.plist"
defaults delete local.usagerings 2>/dev/null || true
echo "UsageRings removed."
