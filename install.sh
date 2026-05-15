#!/bin/bash
# install.sh — one-shot installer for keep-awake-agents.
#
# Installs a small daemon that keeps your Mac awake while Claude Code or
# Codex CLI is running, and lets it sleep again the moment they exit.
#
# Optional: installs SwiftBar to show a ☕/💤 icon in the menu bar.

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.keepawake.agents"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN_DST="$HOME/bin/keep-awake-agents.sh"
CTL_DST="$HOME/bin/keep-awake-ctl.sh"
PLUGIN_DST="$HOME/Library/Application Support/SwiftBar/Plugins/keep-awake.5s.sh"
STATE_DIR="$HOME/Library/Application Support/keep-awake"
CONFIG_DIR="$HOME/.config/keep-awake-agents"
CONFIG_DST="$CONFIG_DIR/config"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This installer is macOS-only." >&2
  exit 1
fi

say "Installing keep-awake-agents daemon"

# 1. Create directories.
mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" \
         "$STATE_DIR" "$CONFIG_DIR" \
         "$HOME/Library/Application Support/SwiftBar/Plugins"

# 1a. Drop config file if not already present (don't clobber user edits).
if [[ ! -f "$CONFIG_DST" ]]; then
  cp "$REPO_DIR/config.example" "$CONFIG_DST"
  say "  config  → $CONFIG_DST  (defaults)"
else
  say "  config  → $CONFIG_DST  (kept existing)"
fi

# 2. Copy daemon + control helper.
cp "$REPO_DIR/bin/keep-awake-agents.sh" "$BIN_DST"
cp "$REPO_DIR/bin/keep-awake-ctl.sh"    "$CTL_DST"
chmod +x "$BIN_DST" "$CTL_DST"
say "  daemon  → $BIN_DST"
say "  ctl     → $CTL_DST"

# 3. Render and install LaunchAgent.
sed "s|__HOME__|$HOME|g" "$REPO_DIR/launchagent/${LABEL}.plist" > "$PLIST_DST"
say "  plist   → $PLIST_DST"

# 4. Install SwiftBar plugin (works even if SwiftBar itself isn't installed).
cp "$REPO_DIR/swiftbar/keep-awake.5s.sh" "$PLUGIN_DST"
chmod +x "$PLUGIN_DST"
say "  plugin  → $PLUGIN_DST"

# 5. Load LaunchAgent (idempotent).
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"
say "  daemon loaded — launchctl label: $LABEL"

# 6. Offer to install SwiftBar if missing.
SWIFTBAR_APP="/Applications/SwiftBar.app"
if [[ ! -d "$SWIFTBAR_APP" ]]; then
  echo ""
  read -r -p "Install SwiftBar for the menu bar icon? [Y/n] " reply
  reply=${reply:-Y}
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    say "Downloading SwiftBar from GitHub"
    tmp=$(mktemp -d)
    asset_url=$(curl -fsSL https://api.github.com/repos/swiftbar/SwiftBar/releases/latest \
                 | awk -F'"' '/browser_download_url.*\.zip"/{print $4; exit}')
    if [[ -z "$asset_url" ]]; then
      warn "Could not resolve SwiftBar release URL — skipping. Install manually from https://swiftbar.app"
    else
      curl -fsSL "$asset_url" -o "$tmp/SwiftBar.zip"
      unzip -q -o "$tmp/SwiftBar.zip" -d "$tmp"
      mv "$tmp/SwiftBar.app" "$SWIFTBAR_APP"
      xattr -dr com.apple.quarantine "$SWIFTBAR_APP" 2>/dev/null || true
      rm -rf "$tmp"
      say "  installed → $SWIFTBAR_APP"
    fi
  fi
fi

# 7. Configure SwiftBar (hide its own menu icon, set plugin folder) and launch.
if [[ -d "$SWIFTBAR_APP" ]]; then
  defaults write com.ameba.SwiftBar PluginDirectory -string "$HOME/Library/Application Support/SwiftBar/Plugins"
  # Hide the "SwiftBar" label / icon — we only want our coffee cup.
  defaults write com.ameba.SwiftBar HideSwiftBarIcon -bool true
  # Restart SwiftBar so it picks up the new prefs and plugin.
  osascript -e 'tell application "SwiftBar" to quit' 2>/dev/null || true
  sleep 1
  open -a "$SWIFTBAR_APP"
  say "  SwiftBar configured and launched"
fi

echo ""
say "Done."
echo ""
echo "Menu bar:  ☕ awake  •  💤 idle  •  ⏸ paused (monochrome SF Symbols)"
echo "Config:    $CONFIG_DST  (edit then 'launchctl kickstart -k gui/\$(id -u)/$LABEL')"
echo "Pause:     touch \"$STATE_DIR/paused\"  (or click 'Pause' in the dropdown)"
echo "Log:       tail -f ~/Library/Logs/keep-awake.log"
echo "Uninstall: $REPO_DIR/uninstall.sh"
