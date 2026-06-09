#!/bin/bash
# keep-awake-ctl.sh — helper invoked by the SwiftBar plugin.
#
# All paths with spaces live INSIDE this script, so SwiftBar's argv parsing
# (which splits param= values at whitespace) never sees them.
#
# Usage:
#   keep-awake-ctl.sh pause
#   keep-awake-ctl.sh resume
#   keep-awake-ctl.sh toggle
#   keep-awake-ctl.sh quit         (stop daemon for this session)
#   keep-awake-ctl.sh start        (re-load daemon after a quit)
#   keep-awake-ctl.sh uninstall    (confirm + remove everything)
#   keep-awake-ctl.sh set-mode <desk|cafe|lockedin>
#   keep-awake-ctl.sh set-agent-idle <minutes|0>
#   keep-awake-ctl.sh set-poll <seconds>
#   keep-awake-ctl.sh set-display <0|1>
#   keep-awake-ctl.sh set-keepalive <0|1>
#   keep-awake-ctl.sh set-keepalive-host <host>
#   keep-awake-ctl.sh set-keepalive-interval <seconds>
#   keep-awake-ctl.sh set-battery-lid-closed <0|1>
#   keep-awake-ctl.sh setup-lid-closed

set -e

CONFIG="$HOME/.config/keep-awake-agents/config"
CONFIG_DIR="$(dirname "$CONFIG")"
PAUSE_FLAG="$HOME/Library/Application Support/keep-awake/paused"
LABEL="com.keepawake.agents"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

restart_daemon() {
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
}

set_var() {
  # set_var KEY VALUE — idempotent edit of CONFIG
  local var=$1 val=$2 tmp
  mkdir -p "$CONFIG_DIR"
  [ -f "$CONFIG" ] || touch "$CONFIG"
  if grep -q "^${var}=" "$CONFIG" 2>/dev/null; then
    tmp=$(mktemp)
    awk -v v="$var" -v r="${var}=${val}" '$0 ~ "^"v"=" {print r; next} {print}' "$CONFIG" > "$tmp"
    mv "$tmp" "$CONFIG"
  else
    echo "${var}=${val}" >> "$CONFIG"
  fi
}

set_vars() {
  mkdir -p "$CONFIG_DIR"
  [ -f "$CONFIG" ] || touch "$CONFIG"
  local tmp
  tmp=$(mktemp)
  awk -v map="$*" '
    BEGIN {
      n = split(map, pairs, " ")
      for (i = 1; i <= n; i++) {
        eq = index(pairs[i], "=")
        if (eq > 0) {
          k = substr(pairs[i], 1, eq - 1)
          repl[k] = pairs[i]
        }
      }
    }
    {
      eq = index($0, "=")
      if (eq > 0) {
        k = substr($0, 1, eq - 1)
        if (k in repl) {
          print repl[k]
          delete repl[k]
          next
        }
      }
      print
    }
    END { for (k in repl) print repl[k] }
  ' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
}

case "${1:-}" in
  pause)
    mkdir -p "$(dirname "$PAUSE_FLAG")"
    touch "$PAUSE_FLAG"
    ;;
  resume)
    rm -f "$PAUSE_FLAG"
    ;;
  toggle)
    if [ -f "$PAUSE_FLAG" ]; then rm -f "$PAUSE_FLAG"; else
      mkdir -p "$(dirname "$PAUSE_FLAG")"; touch "$PAUSE_FLAG"
    fi
    ;;
  quit)
    # Stop the daemon for the rest of this login session. The plist stays in
    # ~/Library/LaunchAgents, so it auto-loads again at next login. To stop
    # permanently, run uninstall.sh.
    rm -f "$PAUSE_FLAG"
    launchctl unload "$PLIST" 2>/dev/null || true
    ;;
  start)
    # Re-load the daemon after a previous `quit`.
    launchctl load "$PLIST" 2>/dev/null || true
    ;;
  uninstall)
    # Self-contained uninstall driven from the menu bar. Mirrors uninstall.sh
    # but skips the interactive prompts — config + logs are kept so a future
    # reinstall (re-run install.sh) restores your settings. To wipe everything
    # including config and logs, run the bundled uninstall.sh from the repo.
    reply=$(osascript \
      -e 'display dialog "Uninstall Keep Awake Agents?

This stops the daemon and removes the menu bar icon, scripts, and launch agent. Your config and logs are kept." buttons {"Cancel", "Uninstall"} default button "Cancel" cancel button "Cancel" with icon caution with title "Keep Awake Agents"' 2>/dev/null) || exit 0
    case "$reply" in *button\ returned:Uninstall*) ;; *) exit 0 ;; esac

    # Stop the daemon (also disables KeepAlive respawn).
    rm -f "$PAUSE_FLAG"
    launchctl unload "$PLIST" 2>/dev/null || true

    # Remove installed files. Note: we are currently executing keep-awake-ctl.sh
    # itself — unlinking it on Unix is safe, the running shell stays alive.
    rm -f "$PLIST" \
          "$HOME/bin/keep-awake-agents.sh" \
          "$HOME/bin/keep-awake-ctl.sh" \
          "$HOME/bin/keep-awake-heartbeat.sh" \
          "$HOME/Library/Application Support/SwiftBar/Plugins/keep-awake.5s.sh"
    rm -rf "$HOME/Library/Application Support/keep-awake"

    # Remove SwiftBar from Login Items (install.sh added it). Don't uninstall
    # SwiftBar itself — it's a generic tool the user may still want.
    osascript -e 'tell application "System Events" to delete login item "SwiftBar"' 2>/dev/null || true

    # Quit SwiftBar so the menu icon disappears immediately. The plugin file
    # is already gone, so a future SwiftBar launch won't bring our icon back.
    osascript -e 'tell application "SwiftBar" to quit' 2>/dev/null || true
    ;;
  set-poll)
    set_var POLL_INTERVAL "$2"
    restart_daemon
    ;;
  set-display)
    set_var PREVENT_DISPLAY_SLEEP "$2"
    restart_daemon
    ;;
  set-mode)
    case "${2:-}" in
      desk)
        set_vars MODE=desk BATTERY_LID_CLOSED=0 NETWORK_KEEPALIVE=0 PREVENT_DISPLAY_SLEEP=0 AGENT_IDLE_MINUTES=5
        ;;
      cafe)
        set_vars MODE=cafe BATTERY_LID_CLOSED=1 NETWORK_KEEPALIVE=1 PREVENT_DISPLAY_SLEEP=0 AGENT_IDLE_MINUTES=5
        ;;
      lockedin)
        set_vars MODE=lockedin BATTERY_LID_CLOSED=1 NETWORK_KEEPALIVE=1 PREVENT_DISPLAY_SLEEP=0 AGENT_IDLE_MINUTES=0
        ;;
      *)
        echo "unknown mode: ${2:-} (use desk|cafe|lockedin)" >&2; exit 1
        ;;
    esac
    restart_daemon &
    ;;
  set-agent-idle)
    set_var AGENT_IDLE_MINUTES "$2"
    restart_daemon
    ;;
  set-keepalive)
    set_var NETWORK_KEEPALIVE "$2"
    restart_daemon
    ;;
  set-keepalive-host)
    set_var NETWORK_KEEPALIVE_HOST "$2"
    restart_daemon
    ;;
  set-keepalive-interval)
    set_var NETWORK_KEEPALIVE_INTERVAL "$2"
    restart_daemon
    ;;
  set-battery-lid-closed)
    set_var BATTERY_LID_CLOSED "$2"
    restart_daemon
    ;;
  setup-lid-closed)
    # One-time: install a narrowly-scoped sudoers rule so the daemon can toggle
    # macOS's lid-close sleep override (pmset disablesleep) without a password.
    pmset_bin="/usr/bin/pmset"
    sudoers_file="/etc/sudoers.d/keep-awake-agents"
    user_name="$(id -un)"
    rule="${user_name} ALL=(root) NOPASSWD: ${pmset_bin} -a disablesleep 0, ${pmset_bin} -a disablesleep 1"
    echo "Set up 'lid closed on battery' mode"
    echo "──────────────────────────────────"
    echo "Grants passwordless (and nothing else):"
    echo "  sudo ${pmset_bin} -a disablesleep 0|1"
    echo "Written to: ${sudoers_file}"
    echo "Undo anytime: sudo rm ${sudoers_file}"
    echo
    tmp="$(mktemp)"
    printf '%s\n' "$rule" > "$tmp"
    if ! sudo visudo -cf "$tmp" >/dev/null 2>&1; then
      echo "✗ Generated rule failed validation — nothing changed." >&2
      rm -f "$tmp"; exit 1
    fi
    if ! sudo install -m 0440 -o root -g wheel "$tmp" "$sudoers_file"; then
      echo "✗ Could not install sudoers rule." >&2
      rm -f "$tmp"; exit 1
    fi
    rm -f "$tmp"
    echo "✓ Installed."
    if sudo -n "$pmset_bin" -a disablesleep 0 >/dev/null 2>&1; then
      echo "✓ Passwordless toggle confirmed — enabling lid-closed mode."
      set_var BATTERY_LID_CLOSED 1
      restart_daemon
      echo "✓ Done. Close the lid on battery and your agents keep running."
      echo "  (Menu bar → 'Lid closed on battery' now shows On.)"
    else
      echo "⚠ Installed, but couldn't confirm passwordless access (check: sudo -l)."
    fi
    echo
    echo "You can close this window."
    ;;
  *)
    echo "usage: $0 {pause|resume|toggle|quit|start|uninstall|set-mode desk|cafe|lockedin|set-agent-idle N|set-poll N|set-display 0|1|set-keepalive 0|1|set-keepalive-host HOST|set-keepalive-interval N|set-battery-lid-closed 0|1|setup-lid-closed}" >&2
    exit 1
    ;;
esac
