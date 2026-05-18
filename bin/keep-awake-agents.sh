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
KEEPALIVE_PID_FILE="$STATE_DIR/keepalive.pid"
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
# Network keepalive: send a ping every NETWORK_KEEPALIVE_INTERVAL seconds while
# awake. Keeps cellular hotspot connections alive (iPhones/Androids drop idle
# clients) and prevents Wi-Fi from disconnecting on inactivity — including with
# the lid closed on AC power. Set to 0 to disable.
NETWORK_KEEPALIVE=0
NETWORK_KEEPALIVE_HOST=8.8.8.8
NETWORK_KEEPALIVE_INTERVAL=30
# iMessage notifications: sends a message to NOTIFY_TARGET (phone number like
# +15551234567 or an Apple ID email) when:
#   1. You unplug while keepalive is active (lid-close will drop the hotspot)
#   2. Battery drops below NOTIFY_BATTERY_PCT% while on battery
# Requires the Mac's Messages app to be signed in to iMessage.
NOTIFY_IMESSAGE=0
NOTIFY_TARGET=""
NOTIFY_BATTERY_PCT=20

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

start_keepalive() {
  [ "${NETWORK_KEEPALIVE:-0}" != "1" ] && return
  if [ -f "$KEEPALIVE_PID_FILE" ] && kill -0 "$(cat "$KEEPALIVE_PID_FILE")" 2>/dev/null; then
    return
  fi
  (
    while true; do
      ping -c 1 -t 5 "${NETWORK_KEEPALIVE_HOST:-8.8.8.8}" >/dev/null 2>&1 || true
      sleep "${NETWORK_KEEPALIVE_INTERVAL:-30}"
    done
  ) &
  local pid=$!
  echo "$pid" > "$KEEPALIVE_PID_FILE"
  log "keepalive started (pid $pid, host=${NETWORK_KEEPALIVE_HOST:-8.8.8.8}, interval=${NETWORK_KEEPALIVE_INTERVAL:-30}s)"
}

get_battery_pct() {
  pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%'
}

is_on_ac() {
  pmset -g batt 2>/dev/null | grep -q 'AC Power' && echo 1 || echo 0
}

send_imessage() {
  local msg=$1
  [ "${NOTIFY_IMESSAGE:-0}" != "1" ] && return
  [ -z "${NOTIFY_TARGET:-}" ] && return
  osascript \
    -e "tell application \"Messages\"" \
    -e "  send \"${msg}\" to buddy \"${NOTIFY_TARGET}\" of service \"iMessage\"" \
    -e "end tell" 2>/dev/null || true
  log "iMessage → ${NOTIFY_TARGET}: $msg"
}

stop_keepalive() {
  if [ -f "$KEEPALIVE_PID_FILE" ]; then
    local pid; pid=$(cat "$KEEPALIVE_PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log "keepalive stopped (pid $pid)"
    fi
    rm -f "$KEEPALIVE_PID_FILE"
  fi
}

now_ts() { date '+%Y-%m-%d %H:%M:%S'; }

cleanup() {
  stop_caffeinate
  stop_keepalive
  printf '' | write_state idle "$(now_ts)"
  exit 0
}
trap cleanup INT TERM

log "started (pid $$, poll ${POLL_INTERVAL}s, prevent_display=${PREVENT_DISPLAY_SLEEP}, cpu_threshold=${CPU_IDLE_THRESHOLD}%, cpu_duration=${CPU_IDLE_DURATION}, keepalive=${NETWORK_KEEPALIVE}/${NETWORK_KEEPALIVE_HOST}/${NETWORK_KEEPALIVE_INTERVAL}s, notify=${NOTIFY_IMESSAGE}/${NOTIFY_TARGET:-none}, extra_patterns=${#EXTRA_PATTERNS[@]})"
prev_status=""
since_ts=""
cpu_idle_count=0
prev_ac=$(is_on_ac)
notified_unplug=0
notified_battery=0

while true; do
  if [ -f "$PAUSE_FLAG" ]; then
    stop_caffeinate
    stop_keepalive
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
      stop_keepalive
      if [ "$prev_status" != "cpu-idle" ]; then
        since_ts=$(now_ts)
        log "CPU-IDLE — agents below ${CPU_IDLE_THRESHOLD}% × ${CPU_IDLE_DURATION} polls (cpu=${total_cpu}%)"
        prev_status=cpu-idle
      fi
      printf '%s\n' "$matches" | write_state cpu-idle "$since_ts" "$total_cpu"
    else
      start_caffeinate
      start_keepalive
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
    stop_keepalive
    cpu_idle_count=0
    if [ "$prev_status" != "idle" ]; then
      since_ts=$(now_ts)
      log "idle — no agents, system may sleep"
      prev_status=idle
    fi
    printf '' | write_state idle "$since_ts"
  fi

  # ── iMessage notifications ───────────────────────────────────────────────────
  # Only fire when keepalive is on and the wakelock is active (we're actually
  # holding the connection). Sends two kinds of alerts:
  #   1. Unplugged while keepalive active — lid-close will now drop the hotspot.
  #   2. Battery below threshold while on battery — same risk, different trigger.
  if [ "${NOTIFY_IMESSAGE:-0}" = "1" ] \
     && [ -n "${NOTIFY_TARGET:-}" ] \
     && [ "${NETWORK_KEEPALIVE:-0}" = "1" ] \
     && [ "$prev_status" = "active" ]; then
    current_ac=$(is_on_ac)
    if [ "$current_ac" = "1" ]; then
      # Back on AC — reset flags so notifications fire again next unplug.
      notified_unplug=0
      notified_battery=0
    else
      batt=$(get_battery_pct)
      # Just unplugged.
      if [ "$prev_ac" = "1" ] && [ "$notified_unplug" = "0" ]; then
        send_imessage "⚡ Unplugged (${batt}% battery) — hotspot keepalive only holds on AC. Closing lid will drop the connection."
        notified_unplug=1
      fi
      # Low battery warning.
      if [ "$notified_battery" = "0" ] && [ -n "$batt" ] \
         && [ "$batt" -le "${NOTIFY_BATTERY_PCT:-20}" ] 2>/dev/null; then
        send_imessage "🔋 Battery at ${batt}% — closing the lid will disconnect your hotspot. Plug in to keep it alive."
        notified_battery=1
      fi
    fi
    prev_ac=$current_ac
  fi

  sleep "$POLL_INTERVAL"
done
