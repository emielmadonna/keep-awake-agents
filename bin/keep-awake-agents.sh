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
# CPU-idle threshold: release the wakelock when the combined CPU% of all matched
# processes stays below this value for CPU_IDLE_DURATION consecutive polls.
# Set to 0 to disable (always keep awake while processes are running).
CPU_IDLE_THRESHOLD=5
CPU_IDLE_DURATION=120

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

# Returns the sum of CPU% for all matched processes (one decimal place).
get_matched_cpu() {
  local process_lines=$1
  [ -z "$process_lines" ] && { echo "0.0"; return; }
  local pids pid_list total_cpu
  pids=$(printf '%s\n' "$process_lines" | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
  [ -z "$pids" ] && { echo "0.0"; return; }
  total_cpu=$(ps -o %cpu= -p "$pids" 2>/dev/null \
    | awk '{s+=$1} END{printf "%.1f", s+0}')
  echo "${total_cpu:-0.0}"
}

write_state() {
  # $1 = status (active|cpu-idle|idle|paused); $2 = since timestamp
  # $3 = optional cpu value; stdin = process lines
  local status=$1 since=$2 cpu=${3:-}
  {
    echo "status=$status"
    echo "since=$since"
    [ -n "$cpu" ] && echo "cpu=$cpu"
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

now_ts() { date '+%Y-%m-%d %H:%M:%S'; }

cleanup() {
  stop_caffeinate
  printf '' | write_state idle "$(now_ts)"
  exit 0
}
trap cleanup INT TERM

log "started (pid $$, poll ${POLL_INTERVAL}s, prevent_display=${PREVENT_DISPLAY_SLEEP}, cpu_threshold=${CPU_IDLE_THRESHOLD}%, cpu_duration=${CPU_IDLE_DURATION}, extra_patterns=${#EXTRA_PATTERNS[@]})"
prev_status=""
since_ts=""
cpu_idle_count=0

while true; do
  if [ -f "$PAUSE_FLAG" ]; then
    stop_caffeinate
    cpu_idle_count=0
    if [ "$prev_status" != "paused" ]; then
      since_ts=$(now_ts)
      log "paused (flag file present)"
      prev_status=paused
    fi
    printf '' | write_state paused "$since_ts"
    sleep "$POLL_INTERVAL"
    continue
  fi

  matches=$(get_matched_processes || true)

  if [ -n "$matches" ]; then
    # --- CPU-idle check ---
    if [ "${CPU_IDLE_THRESHOLD:-0}" != "0" ]; then
      total_cpu=$(get_matched_cpu "$matches")
      is_below=$(awk -v cpu="$total_cpu" -v thr="${CPU_IDLE_THRESHOLD}" \
                   'BEGIN{print (cpu+0 < thr+0) ? "1" : "0"}')
      if [ "$is_below" = "1" ]; then
        cpu_idle_count=$((cpu_idle_count + 1))
      else
        cpu_idle_count=0
      fi
    else
      total_cpu=""
      cpu_idle_count=0
    fi

    if [ "${CPU_IDLE_THRESHOLD:-0}" != "0" ] \
       && [ "$cpu_idle_count" -ge "${CPU_IDLE_DURATION:-3}" ]; then
      # Processes are running but have been idle below the CPU threshold.
      stop_caffeinate
      if [ "$prev_status" != "cpu-idle" ]; then
        since_ts=$(now_ts)
        log "CPU-IDLE — agents below ${CPU_IDLE_THRESHOLD}% × ${CPU_IDLE_DURATION} polls (cpu=${total_cpu}%)"
        prev_status=cpu-idle
      fi
      printf '%s\n' "$matches" | write_state cpu-idle "$since_ts" "$total_cpu"
    else
      start_caffeinate
      if [ "$prev_status" != "active" ]; then
        since_ts=$(now_ts)
        log "ACTIVE — agents detected:"
        while IFS= read -r line; do
          [ -n "$line" ] && log "  $line"
        done <<< "$matches"
        prev_status=active
      fi
      printf '%s\n' "$matches" | write_state active "$since_ts" "$total_cpu"
    fi
  else
    stop_caffeinate
    cpu_idle_count=0
    if [ "$prev_status" != "idle" ]; then
      since_ts=$(now_ts)
      log "idle — no agents, system may sleep"
      prev_status=idle
    fi
    printf '' | write_state idle "$since_ts"
  fi

  sleep "$POLL_INTERVAL"
done
