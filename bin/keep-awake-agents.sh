#!/bin/bash
# keep-awake-agents.sh
#
# Keeps the Mac awake (system + idle sleep) while a Claude Code or Codex CLI
# session is running for the current user. Releases the assertion as soon as
# the last agent exits so the Mac can sleep normally.
#
# Config:          ~/.config/keep-awake-agents/config
# Pause:           touch  "$HOME/Library/Application Support/keep-awake/paused"
# Resume:          rm     "$HOME/Library/Application Support/keep-awake/paused"
# Stop autostart:  launchctl unload ~/Library/LaunchAgents/com.keepawake.agents.plist
# Full uninstall:  run the uninstall.sh that came with this package

set -u

LOG="$HOME/Library/Logs/keep-awake.log"
STATE_DIR="$HOME/Library/Application Support/keep-awake"
STATE_FILE="$STATE_DIR/state"
PAUSE_FLAG="$STATE_DIR/paused"
CAFFEINATE_PID_FILE="$STATE_DIR/caffeinate.pid"
CONFIG_FILE="$HOME/.config/keep-awake-agents/config"

# Defaults (overridable from config file).
POLL_INTERVAL=15
PREVENT_DISPLAY_SLEEP=0
EXTRA_PATTERNS=()

# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

mkdir -p "$STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# Built-in patterns. Tuned to match session-like processes for both the
# desktop apps and the Volta/node CLI shims.
BUILTIN_PATTERNS=(
  '[Cc]laude\.app/Contents/MacOS/claude'   # Claude Code (desktop app and CLI both spawn this)
  'claude-code/.*cli\.js'                    # Claude Code via Volta/node
  '[Cc]odex\.app/.*codex'                    # Codex desktop
  '(^|/)codex( |$)'                          # Codex CLI / direct codex binary
)

# Process-line filters: lines we want to EXCLUDE even if pgrep matched them.
# - /Helpers/disclaimer: Claude's pre-launch wrapper (counted as duplicate)
# - --analytics-default-enabled: Codex's always-running background daemon
EXCLUDE_SUBSTRINGS=(
  '/Helpers/disclaimer'
  '--analytics-default-enabled'
)

# Returns lines of "<pid>  <full command>" for matching agent processes.
get_matched_processes() {
  local uid pids pattern line excl
  uid=$(id -u)
  pids=$(
    {
      for pattern in "${BUILTIN_PATTERNS[@]}" "${EXTRA_PATTERNS[@]:-}"; do
        [ -z "$pattern" ] && continue
        pgrep -f -U "$uid" "$pattern" 2>/dev/null
      done
    } | sort -un
  )
  [ -z "$pids" ] && return 0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    line=$(ps -o pid=,command= -p "$pid" 2>/dev/null | sed -E 's/^[[:space:]]+//')
    [ -z "$line" ] && continue
    local skip=0
    for excl in "${EXCLUDE_SUBSTRINGS[@]}"; do
      [[ "$line" == *"$excl"* ]] && { skip=1; break; }
    done
    [ "$skip" = "1" ] && continue
    printf '%s\n' "$line"
  done <<< "$pids"
}

write_state() {
  # $1 = status (active|idle|paused); remaining stdin = process lines
  local status=$1
  {
    echo "status=$status"
    echo "since=$(date '+%Y-%m-%d %H:%M:%S')"
    while IFS= read -r line; do
      [ -n "$line" ] && echo "process=$line"
    done
  } > "$STATE_FILE"
}

start_caffeinate() {
  if [ -f "$CAFFEINATE_PID_FILE" ] && kill -0 "$(cat "$CAFFEINATE_PID_FILE")" 2>/dev/null; then
    return
  fi
  local flags=(-i -s)
  [ "${PREVENT_DISPLAY_SLEEP:-0}" = "1" ] && flags=(-d -i -s)
  caffeinate "${flags[@]}" &
  local pid=$!
  echo "$pid" > "$CAFFEINATE_PID_FILE"
  log "caffeinate started (pid $pid, flags ${flags[*]})"
}

stop_caffeinate() {
  if [ -f "$CAFFEINATE_PID_FILE" ]; then
    local pid; pid=$(cat "$CAFFEINATE_PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log "caffeinate stopped (pid $pid)"
    fi
    rm -f "$CAFFEINATE_PID_FILE"
  fi
}

cleanup() {
  stop_caffeinate
  printf '' | write_state idle
  exit 0
}
trap cleanup INT TERM

log "started (pid $$, poll ${POLL_INTERVAL}s, prevent_display=${PREVENT_DISPLAY_SLEEP}, extra_patterns=${#EXTRA_PATTERNS[@]})"
prev_status=""

while true; do
  if [ -f "$PAUSE_FLAG" ]; then
    stop_caffeinate
    if [ "$prev_status" != "paused" ]; then
      log "paused (flag file present)"
      printf '' | write_state paused
      prev_status=paused
    fi
    sleep "$POLL_INTERVAL"
    continue
  fi

  matches=$(get_matched_processes || true)

  if [ -n "$matches" ]; then
    start_caffeinate
    if [ "$prev_status" != "active" ]; then
      log "ACTIVE — agents detected:"
      while IFS= read -r line; do
        [ -n "$line" ] && log "  $line"
      done <<< "$matches"
      prev_status=active
    fi
    printf '%s\n' "$matches" | write_state active
  else
    stop_caffeinate
    if [ "$prev_status" != "idle" ]; then
      log "idle — no agents, system may sleep"
      printf '' | write_state idle
      prev_status=idle
    fi
  fi

  sleep "$POLL_INTERVAL"
done
