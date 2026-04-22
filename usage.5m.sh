#!/bin/bash

# SwiftBar Plugin: Claude & Codex Usage
# Refresh every 5 minutes (filename: usage.5m.sh)
#
# Reads from ~/.claude/usage-cache.json with the following fields:
#   {
#     "claude_weekly":  <number>,   // percent used in the 7-day window
#     "claude_session": <number>,   // percent used in the 5-hour window
#     "weekly_reset":   <unix_ts>,  // reset timestamp (seconds since epoch)
#     "session_reset":  <unix_ts>   // reset timestamp (seconds since epoch)
#   }
#
# Populate the cache from a cron job or launchd agent that calls the usage APIs.

CLAUDE_CACHE="$HOME/.claude/usage-cache.json"

# Function to format remaining time
format_remaining() {
    local reset_ts="$1"
    if [ -z "$reset_ts" ] || [ "$reset_ts" = "null" ]; then
        echo "-"
        return
    fi

    local now=$(date +%s)
    local diff=$((reset_ts - now))

    if [ $diff -le 0 ]; then
        echo "now"
        return
    fi

    local hours=$((diff / 3600))
    local mins=$(((diff % 3600) / 60))

    if [ $hours -gt 0 ]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

# Initialize values
CLAUDE_WEEKLY="-"
CLAUDE_SESSION="-"
WEEKLY_REMAINING="-"
SESSION_REMAINING="-"

# Read Claude usage from cache
if [ -f "$CLAUDE_CACHE" ]; then
    CLAUDE_WEEKLY=$(jq -r '.claude_weekly // empty' "$CLAUDE_CACHE" 2>/dev/null)
    CLAUDE_SESSION=$(jq -r '.claude_session // empty' "$CLAUDE_CACHE" 2>/dev/null)
    WEEKLY_RESET=$(jq -r '.weekly_reset // empty' "$CLAUDE_CACHE" 2>/dev/null)
    SESSION_RESET=$(jq -r '.session_reset // empty' "$CLAUDE_CACHE" 2>/dev/null)

    # Format percentages
    if [ -n "$CLAUDE_WEEKLY" ] && [ "$CLAUDE_WEEKLY" != "null" ] && [ "$CLAUDE_WEEKLY" != "" ]; then
        CLAUDE_WEEKLY="${CLAUDE_WEEKLY%.*}%"
    else
        CLAUDE_WEEKLY="-"
    fi

    if [ -n "$CLAUDE_SESSION" ] && [ "$CLAUDE_SESSION" != "null" ] && [ "$CLAUDE_SESSION" != "" ]; then
        CLAUDE_SESSION="${CLAUDE_SESSION%.*}%"
    else
        CLAUDE_SESSION="-"
    fi

    # Calculate remaining time
    WEEKLY_REMAINING=$(format_remaining "$WEEKLY_RESET")
    SESSION_REMAINING=$(format_remaining "$SESSION_RESET")
fi

# Menu bar: just a symbol
echo "⚡| size=14"

# Dropdown menu with details
echo "---"
echo "Claude Code | size=13 font=Menlo-Bold"
echo "---"
echo "Weekly (7 days)"
echo "--Usage: ${CLAUDE_WEEKLY} | font=Menlo"
echo "--Resets in: ${WEEKLY_REMAINING} | font=Menlo"
echo "---"
echo "Session (5 hours)"
echo "--Usage: ${CLAUDE_SESSION} | font=Menlo"
echo "--Resets in: ${SESSION_REMAINING} | font=Menlo"
echo "---"
echo "Codex | size=13 font=Menlo-Bold"
echo "--Not configured | color=gray"
echo "---"
echo "🔄 Refresh | refresh=true"
