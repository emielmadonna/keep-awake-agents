#!/bin/bash
# uninstall.sh — remove keep-awake-agents completely.
# Does NOT uninstall SwiftBar itself (it's a generic tool you might use for other plugins).

set -e

LABEL="com.keepawake.agents"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN="$HOME/bin/keep-awake-agents.sh"
CTL="$HOME/bin/keep-awake-ctl.sh"
PLUGIN="$HOME/Library/Application Support/SwiftBar/Plugins/keep-awake.5s.sh"
STATE_DIR="$HOME/Library/Application Support/keep-awake"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Stopping daemon"
launchctl unload "$PLIST" 2>/dev/null || true

say "Removing files"
rm -f "$PLIST" "$BIN" "$CTL" "$PLUGIN"
rm -rf "$STATE_DIR"

read -r -p "Also delete config at ~/.config/keep-awake-agents? [y/N] " reply_cfg
if [[ "$reply_cfg" =~ ^[Yy]$ ]]; then
  rm -rf "$HOME/.config/keep-awake-agents"
fi

read -r -p "Also delete logs at ~/Library/Logs/keep-awake.log? [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
  rm -f "$HOME/Library/Logs/keep-awake.log" \
        "$HOME/Library/Logs/keep-awake.stdout.log" \
        "$HOME/Library/Logs/keep-awake.stderr.log"
fi

# Refresh SwiftBar so the ☕ icon disappears immediately.
if pgrep -x SwiftBar >/dev/null 2>&1; then
  osascript -e 'tell application "SwiftBar" to quit' 2>/dev/null || true
  sleep 1
  open -a SwiftBar 2>/dev/null || true
fi

say "Uninstalled."
