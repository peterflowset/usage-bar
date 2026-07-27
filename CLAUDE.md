# UsageBar - Project Instructions

## Overview

macOS menu bar app displaying Claude Code and Codex usage limits. Native Swift/SwiftUI app using NSPanel for the popup.

## Build Commands

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run (menu bar app)
./.build/release/UsageBar

# Run in a terminal (ANSI output, refreshes every 60s; --once for a single snapshot)
./.build/release/UsageBar --cli

# Install CLI copy used by the cmux Dock control (~/.config/cmux/dock.json)
cp ./.build/release/UsageBar ~/.local/bin/usagebar

# Install the menu bar app: copy the binary into the bundle, then re-sign.
cp ./.build/release/UsageBar /Applications/UsageBar.app/Contents/MacOS/UsageBar
codesign --force --sign "Apple Development: peter.kassi@icloud.com (LSN94AS8XC)" /Applications/UsageBar.app
```

## Project Structure

```
UsageBar/
├── Package.swift          # Swift Package manifest (macOS 14+)
├── Sources/
│   ├── UsageBar.swift     # Main app (all code in single file)
│   └── Info.plist         # App metadata (LSUIElement for menu bar)
└── usage.5m.sh            # Alternative SwiftBar/xbar plugin
```

## Architecture

- **Single-file app**: Everything in `UsageBar.swift` for simplicity
- **No dependencies**: Pure SwiftUI + AppKit
- **NSPanel**: Non-activating floating panel for the popup
- **Async/await**: Modern Swift concurrency for API calls

## API Endpoints

- Claude: `api.anthropic.com/api/oauth/usage` (Bearer token from `~/.config/usagebar/token`, with unexpired `~/.claude/.credentials.json` as fallback)
- Claude local fallback: `~/.claude/usage-cache.json` (fresh statusline data, no authentication required)
- Codex: `chatgpt.com/backend-api/wham/usage` (Bearer token from `~/.codex/auth.json`)

## Code Style

- Keep everything in single file unless it grows significantly
- Use Swift standard patterns (MARK comments, structs for data)
- Minimal error handling - show "No auth" or "Error" in UI
- Color thresholds: green <60%, orange 60-80%, red >=80%

## Testing

Manual testing only - run the app and verify:
1. Icon appears in menu bar
2. Clicking shows panel with usage data
3. Clicking outside closes panel
4. Refresh button updates data
