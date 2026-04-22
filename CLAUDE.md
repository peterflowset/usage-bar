# UsageBar - Project Instructions

## Overview

macOS menu bar app displaying Claude Code and Codex usage limits. Native Swift/SwiftUI app using NSPanel for the popup.

## Build Commands

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run
./.build/release/UsageBar
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

- Claude: `api.anthropic.com/api/oauth/usage` (Bearer token from `~/.claude/.credentials.json`)
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
