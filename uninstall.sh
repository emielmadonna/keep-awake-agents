#!/bin/bash
# uninstall.sh — remove keep-awake-agents completely.
# Does NOT uninstall SwiftBar itself (it's a generic tool you might use for other plugins).

set -e

LABEL="com.keepawake.agents"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN="$HOME/bin/keep-awake-agents.sh"
CTL="$HOME/bin/keep-awake-ctl.sh"
HEARTBEAT="$HOME/bin/keep-awake-heartbeat.sh"
PLUGIN="$HOME/Library/Application Support/SwiftBar/Plugins/keep-awake.5s.sh"
STATE_DIR="$HOME/Library/Application Support/keep-awake"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Stopping daemon"
launchctl unload "$PLIST" 2>/dev/null || true

say "Removing files"
rm -f "$PLIST" "$BIN" "$CTL" "$HEARTBEAT" "$PLUGIN"
rm -rf "$STATE_DIR"

# Strip the Claude Code activity hook (if present and jq is available).
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  if jq '
        if .hooks then
          (if .hooks.PostToolUse then .hooks.PostToolUse = [.hooks.PostToolUse[] | select(([.hooks[]?.command] | any(test("keep-awake-heartbeat"))) | not)] else . end)
          | (if .hooks.UserPromptSubmit then .hooks.UserPromptSubmit = [.hooks.UserPromptSubmit[] | select(([.hooks[]?.command] | any(test("keep-awake-heartbeat"))) | not)] else . end)
        else . end
      ' "$SETTINGS" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS"; say "Removed Claude Code activity hook"
  else rm -f "$tmp"; fi
fi

# Remove the lid-closed sudoers rule (if set up) and make sure sleep is back on.
if [ -f "/etc/sudoers.d/keep-awake-agents" ]; then
  say "Removing lid-closed sudoers rule (needs sudo)"
  sudo /usr/bin/pmset -a disablesleep 0 2>/dev/null || true
  sudo rm -f "/etc/sudoers.d/keep-awake-agents" 2>/dev/null || true
fi

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

# Remove SwiftBar from Login Items (installed by install.sh).
osascript -e 'tell application "System Events" to delete login item "SwiftBar"' 2>/dev/null || true

# Quit SwiftBar so the ☕ icon disappears immediately.
if pgrep -x SwiftBar >/dev/null 2>&1; then
  osascript -e 'tell application "SwiftBar" to quit' 2>/dev/null || true
fi

say "Uninstalled."
