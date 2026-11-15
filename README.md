# UsageRings

A small floating macOS widget that shows how much of your **Claude Code** and **Codex** plan limits you've used — session and weekly — as rings.

- Click to switch between Claude and Codex
- Drag to move · right-click for refresh, opacity, and the usage page
- Refreshes every 5 minutes; turns red past 90%

> **Unofficial.** Not affiliated with Anthropic or OpenAI. It reads the same usage endpoints the official tools use, which aren't public APIs — they can change at any time and break this.

## Install

1. **[Download UsageRings.zip](https://github.com/calebchin1/usage-rings/releases/latest/download/UsageRings.zip)** and double-click it to unzip.
2. Double-click **UsageRings.app**.
3. macOS will say it can't verify the app (it isn't notarized). Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway**, and confirm.

That's it — the app moves itself to `~/Applications`, starts at login, and appears top-right. You can delete the downloaded copy.

**Uninstall:** right-click the widget → **Uninstall UsageRings…**

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- **Claude Code** logged in with a Claude.ai Pro/Max plan, and/or **Codex** logged in with ChatGPT
- API-key logins have no plan limits, so there's nothing to show

## Privacy

Your login never leaves your Mac except to go to Anthropic or OpenAI. The app reuses the token Claude Code stores in your Keychain (`Claude Code-credentials`) and the one Codex stores in `~/.codex/auth.json`, sends it over HTTPS to that provider's usage endpoint, and nothing else. No analytics, no other servers. macOS may ask once to allow Keychain access.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh        # build universal app and launch it (it installs itself)
./build.sh dist   # build dist/UsageRings.zip for sharing
```

## License

MIT
