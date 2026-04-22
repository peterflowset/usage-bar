# UsageBar

A lightweight macOS menu bar app that displays your Claude Code and OpenAI Codex usage at a glance.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Menu Bar Integration**: Minimal footprint with a single icon in your menu bar
- **Claude Code Usage**: Shows 5-hour session and 7-day weekly limits
- **Codex Usage**: Shows primary and secondary rate limit windows
- **Reset Timers**: See when your limits will reset
- **Color-coded Progress**: Green/Orange/Red indicators based on usage level

## Screenshots

*Click the ⚡ icon in your menu bar to see your current usage:*

```
┌──────────────────────────────┐
│ Usage                      ↻ │
├──────────────────────────────┤
│ Claude                       │
│ 5h  ████████░░  42%    3h    │
│ 7d  ██████░░░░  28%    4d    │
│                              │
│ Codex                        │
│ 5h  ██░░░░░░░░  12%    4h    │
│ 7d  █░░░░░░░░░   5%    6d    │
├──────────────────────────────┤
│ 14:32                   Quit │
└──────────────────────────────┘
```

## Requirements

- macOS 14.0 (Sonoma) or later
- Active Claude Code subscription (for Claude usage)
- Active Codex subscription (for Codex usage)

## Installation

### Build from Source

```bash
git clone https://github.com/peterflowset/usage-bar.git
cd usage-bar
swift build -c release
cp .build/release/UsageBar /usr/local/bin/
```

### Run Directly

```bash
swift build -c release
./.build/release/UsageBar &
```

## Setup

The app reads credentials from the standard locations used by the CLI tools:

### Claude Code

Authenticate with Claude Code CLI first:
```bash
claude login
```

This creates `~/.claude/.credentials.json` which UsageBar reads automatically.

### Codex (OpenAI)

Authenticate with Codex CLI first. This creates `~/.codex/auth.json`.

## SwiftBar / xbar Integration

An alternative shell script `usage.5m.sh` is included for use with [SwiftBar](https://github.com/swiftbar/SwiftBar) or [xbar](https://xbarapp.com/).

1. Copy `usage.5m.sh` to your SwiftBar/xbar plugins directory
2. Make it executable: `chmod +x usage.5m.sh`
3. Populate the cache file `~/.claude/usage-cache.json` from a cron job or launchd agent

The cache file must follow this format:

```json
{
  "claude_weekly":  28,
  "claude_session": 42,
  "weekly_reset":   1712419200,
  "session_reset":  1712332800
}
```

- `claude_weekly` / `claude_session`: percent used (0–100)
- `weekly_reset` / `session_reset`: Unix timestamp (seconds since epoch) of the next reset

## How It Works

1. Reads OAuth tokens from CLI credential files
2. Calls the respective usage APIs:
   - Claude: `api.anthropic.com/api/oauth/usage`
   - Codex: `chatgpt.com/backend-api/wham/usage`
3. Displays usage percentages and reset timers in a floating panel

> **⚠️ Note on API stability**
> Both endpoints are **undocumented / internal APIs** used by the official CLIs.
> They may change or disappear without notice. If UsageBar shows "API error"
> after a CLI update, the payload shape or endpoint may have changed.

## Auto-Start

To launch UsageBar automatically on login:

1. Build the release binary
2. Add it to Login Items in System Settings → General → Login Items

Or create a LaunchAgent:

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/io.github.peterflowset.usagebar.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.peterflowset.usagebar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/UsageBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/io.github.peterflowset.usagebar.plist
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.
