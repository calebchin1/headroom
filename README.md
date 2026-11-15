# UsageRings

A small floating macOS widget that shows how much of your **Claude Code** and **Codex** plan limits you've used — session and weekly — as rings.

- Click to switch between Claude and Codex
- Drag to move · right-click for refresh, opacity, and the usage page
- Refreshes every 5 minutes; turns red past 90%

> **Unofficial.** Not affiliated with Anthropic or OpenAI. It reads the same usage endpoints the official tools use, which aren't public APIs — they can change at any time and break this.

## Install

1. Download `UsageRings.zip` from [Releases](../../releases/latest) and unzip it.
2. In Terminal:
   ```sh
   cd ~/Downloads/UsageRings
   zsh install.sh
   ```

It installs to `~/Applications` and starts at login. The app isn't notarized, so `install.sh` clears the download quarantine flag for it.

**Uninstall:** `zsh uninstall.sh` from the same folder.

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- **Claude Code** logged in with a Claude.ai Pro/Max plan, and/or **Codex** logged in with ChatGPT
- API-key logins have no plan limits, so there's nothing to show

## Privacy

Your login never leaves your Mac except to go to Anthropic or OpenAI. The app reuses the token Claude Code stores in your Keychain (`Claude Code-credentials`) and the one Codex stores in `~/.codex/auth.json`, sends it over HTTPS to that provider's usage endpoint, and nothing else. No analytics, no other servers. macOS may ask once to allow Keychain access.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh        # build universal app, install, start at login
./build.sh dist   # build dist/UsageRings.zip for sharing
```

## License

MIT
