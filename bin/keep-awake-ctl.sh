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
#   keep-awake-ctl.sh set-poll <seconds>
#   keep-awake-ctl.sh set-display <0|1>
#   keep-awake-ctl.sh set-cpu-threshold <percent|0>
#   keep-awake-ctl.sh set-cpu-duration <polls>
#   keep-awake-ctl.sh set-keepalive <0|1>
#   keep-awake-ctl.sh set-keepalive-host <host>
#   keep-awake-ctl.sh set-keepalive-interval <seconds>
#   keep-awake-ctl.sh set-notify <0|1>
#   keep-awake-ctl.sh set-notify-target <phone-or-email>
#   keep-awake-ctl.sh set-notify-battery <percent>

set -e

CONFIG="$HOME/.config/keep-awake-agents/config"
CONFIG_DIR="$(dirname "$CONFIG")"
PAUSE_FLAG="$HOME/Library/Application Support/keep-awake/paused"
LABEL="com.keepawake.agents"

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
  set-poll)
    set_var POLL_INTERVAL "$2"
    restart_daemon
    ;;
  set-display)
    set_var PREVENT_DISPLAY_SLEEP "$2"
    restart_daemon
    ;;
  set-cpu-threshold)
    set_var CPU_IDLE_THRESHOLD "$2"
    restart_daemon
    ;;
  set-cpu-duration)
    set_var CPU_IDLE_DURATION "$2"
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
  set-notify)
    set_var NOTIFY_IMESSAGE "$2"
    restart_daemon
    ;;
  set-notify-target)
    set_var NOTIFY_TARGET "$2"
    restart_daemon
    ;;
  set-notify-battery)
    set_var NOTIFY_BATTERY_PCT "$2"
    restart_daemon
    ;;
  *)
    echo "usage: $0 {pause|resume|toggle|set-poll N|set-display 0|1|set-cpu-threshold N|set-cpu-duration N|set-keepalive 0|1|set-keepalive-host HOST|set-keepalive-interval N|set-notify 0|1|set-notify-target PHONE|set-notify-battery PCT}" >&2
    exit 1
    ;;
esac
