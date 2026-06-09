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
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
CONFIG_FILE="$HOME/.config/keep-awake-agents/config"

# Defaults (overridable from config file).
POLL_INTERVAL=15
PREVENT_DISPLAY_SLEEP=0
EXTRA_PATTERNS=()
# Activity detection. Keep the Mac awake while agents are *working*, and let it
# sleep once they're genuinely idle. "Working" = the agent process subtree burned
# CPU-time since the last poll, OR a fresh heartbeat exists (keep-awake-heartbeat.sh).
# Idle after AGENT_IDLE_MINUTES with neither signal. 0 = never idle-sleep.
AGENT_IDLE_MINUTES=""        # blank -> resolved below (legacy fallback, else 5)
HEARTBEAT_WINDOW_SECS=180    # a heartbeat newer than this counts as "working"
CPU_DELTA_EPSILON_SECS=1     # subtree must gain > this many CPU-seconds per poll
# Mode bundles the flags below (desk|cafe|lockedin); set by keep-awake-ctl.sh.
# The daemon is flag-driven — MODE is informational (logged only).
MODE=desk
# Legacy pre-mode knob — still read so old configs keep their idle tolerance.
CPU_IDLE_DURATION=""
# Network keepalive: send a ping every NETWORK_KEEPALIVE_INTERVAL seconds while
# awake. Keeps cellular hotspot connections alive (iPhones/Androids drop idle
# clients) and prevents Wi-Fi from disconnecting on inactivity — including with
# the lid closed on AC power. Set to 0 to disable.
NETWORK_KEEPALIVE=0
NETWORK_KEEPALIVE_HOST=8.8.8.8
NETWORK_KEEPALIVE_INTERVAL=30
# Keep the Mac awake with the lid closed, incl. on battery, while agents are
# active (via `pmset disablesleep`). Released when idle/paused/below floor/exit.
# Needs one-time setup: keep-awake-ctl.sh setup-lid-closed
BATTERY_LID_CLOSED=0
# On battery, release the lid-closed override at/below this % (0 = never).
BATTERY_FLOOR_PCT=15
# On battery, also release after this many hours of continuous hold, as a
# backstop against a jammed daemon (0 = no cap). Re-arms when agents idle.
LID_CLOSED_MAX_HOURS=8

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

# --- Activity detection (replaces CPU%) ---------------------------------------
# CPU% is a lifetime average, and agents idle the CPU while waiting on the model;
# instead we track cumulative CPU-*time* across the agent process subtree plus a
# heartbeat file, and call the session idle only after AGENT_IDLE_MINUTES of
# genuine silence.

# Echo every pid in the subtree(s) rooted at the given (newline-separated) pids.
# Iterative BFS via `pgrep -P` (bash 3.2: no recursion niceties).
get_subtree_pids() {
  local roots=$1
  [ -z "$roots" ] && return 0
  local seen=" " frontier="$roots" next pid kids
  while [ -n "$frontier" ]; do
    next=""
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      case "$seen" in *" $pid "*) continue ;; esac
      seen="$seen$pid "
      kids=$(pgrep -P "$pid" 2>/dev/null || true)
      [ -n "$kids" ] && next="$next$kids"$'\n'
    done <<EOF
$frontier
EOF
    frontier="$next"
  done
  printf '%s\n' $seen
}

# Echo "<pid> <cpu_seconds>" for the comma-joined pid list, parsing ps cputime
# "[H+:]MM:SS[.ss]" into integer seconds.
sample_subtree_cputime() {
  local pids_csv=$1
  [ -z "$pids_csv" ] && return 0
  ps -o pid=,cputime= -p "$pids_csv" 2>/dev/null | awk '
    {
      n = split($2, a, ":")
      if (n == 3)      s = a[1]*3600 + a[2]*60 + a[3]
      else if (n == 2) s = a[1]*60 + a[2]
      else             s = a[1]
      printf "%s %d\n", $1, s
    }'
}

# Echo the total positive CPU-seconds the subtree gained since prev_cpu_sample.
# A brand-new pid counts its whole cputime (a child that spawned, worked, and
# exited within one poll window is still real activity).
subtree_cpu_delta() {
  local cur=$1
  # Pass the previous sample via the environment, not `-v`: macOS awk rejects
  # literal newlines in -v assignments, and the sample is multi-line.
  KAA_PREV_SAMPLE="${prev_cpu_sample:-}" awk '
    BEGIN {
      n = split(ENVIRON["KAA_PREV_SAMPLE"], lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], kv, " "); was[kv[1]] = kv[2]
      }
    }
    {
      if ($1 in was) { d = $2 - was[$1]; if (d > 0) total += d }
      else           { total += $2 }
    }
    END { printf "%d", total + 0 }
  ' <<EOF
$cur
EOF
}

# Echo 1 if the heartbeat file was touched within HEARTBEAT_WINDOW_SECS.
heartbeat_fresh() {
  [ -f "$HEARTBEAT_FILE" ] || { echo 0; return; }
  local mtime now age
  mtime=$(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null) || { echo 0; return; }
  now=$(date '+%s'); age=$(( now - mtime ))
  if [ -n "$mtime" ] && [ "$age" -ge 0 ] && [ "$age" -lt "${HEARTBEAT_WINDOW_SECS:-180}" ]; then
    echo 1
  else
    echo 0
  fi
}

# Refresh last_active from whichever signal is newer: a fresh heartbeat (its
# mtime) or real CPU-time movement in the subtree this poll. Mutates globals
# last_active and prev_cpu_sample.
update_activity() {
  local subtree_csv=$1 now cur_sample delta hb_mtime
  now=$(date '+%s')
  if [ "$(heartbeat_fresh)" = "1" ]; then
    hb_mtime=$(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
    if [ "${hb_mtime:-0}" -gt "${last_active:-0}" ] 2>/dev/null; then last_active=$hb_mtime; fi
  fi
  cur_sample=$(sample_subtree_cputime "$subtree_csv")
  if [ -n "$subtree_csv" ]; then
    delta=$(subtree_cpu_delta "$cur_sample")
    if [ "${delta:-0}" -gt "${CPU_DELTA_EPSILON_SECS:-1}" ] 2>/dev/null; then last_active=$now; fi
  fi
  prev_cpu_sample=$cur_sample
}

# Echo 1 if the session counts as working now (within the idle window).
# AGENT_IDLE_MINUTES=0 means never idle-sleep while agents are running.
agent_is_active() {
  [ "${AGENT_IDLE_MINUTES:-5}" = "0" ] && { echo 1; return; }
  local now idle_secs
  now=$(date '+%s'); idle_secs=$(( now - ${last_active:-0} ))
  [ "$idle_secs" -lt 0 ] && idle_secs=0
  if [ "$idle_secs" -lt "$(( ${AGENT_IDLE_MINUTES:-5} * 60 ))" ]; then echo 1; else echo 0; fi
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

get_battery_pct() {
  pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%'
}

is_on_ac() {
  pmset -g batt 2>/dev/null | grep -q 'AC Power' && echo 1 || echo 0
}

# Toggle macOS's kernel lid-close sleep override (pmset disablesleep). This is
# the only thing that keeps the Mac awake with the lid shut on battery — power
# assertions (caffeinate) can't. No-op unless BATTERY_LID_CLOSED=1; caches state
# to avoid a sudo call every poll; warns once if the sudo rule isn't installed.
set_disablesleep() {
  [ "${BATTERY_LID_CLOSED:-0}" = "1" ] || return
  local want=$1
  [ "${disablesleep_state:-}" = "$want" ] && return
  if sudo -n /usr/bin/pmset -a disablesleep "$want" 2>/dev/null; then
    disablesleep_state=$want
    disablesleep_warned=0
    log "lid-closed override → disablesleep $want"
    if [ "$want" = "1" ]; then
      # Read the flag back (no root needed) to confirm the kernel honored it,
      # rather than trusting pmset's exit code — catches a future macOS change.
      local actual; actual=$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $NF; exit}')
      [ "${actual:-0}" = "1" ] || log "WARN: pmset accepted but SleepDisabled='${actual:-unset}' — lid-close may NOT be blocked (macOS change?)"
    fi
  elif [ "$want" = "1" ] && [ "${disablesleep_warned:-0}" = "0" ]; then
    disablesleep_warned=1
    log "WARN: lid-closed mode on but can't set disablesleep — run: keep-awake-ctl.sh setup-lid-closed"
  fi
}

# Engage the lid-close override for this poll. On battery it honors two safety
# limits: a charge floor (don't drain to empty) and a max-hours backstop (don't
# hold forever if something jams). On AC neither applies — just hold.
hold_lid_closed() {
  [ "${BATTERY_LID_CLOSED:-0}" = "1" ] || return
  if [ "$(is_on_ac)" = "1" ]; then
    lid_closed_capped=0; disablesleep_since=""   # AC: no battery limits, reset timer
    set_disablesleep 1
    return
  fi
  # --- on battery ---
  local batt; batt=$(get_battery_pct)
  if [ -n "$batt" ] && [ "${BATTERY_FLOOR_PCT:-0}" -gt 0 ] 2>/dev/null \
     && [ "$batt" -le "${BATTERY_FLOOR_PCT:-0}" ] 2>/dev/null; then
    set_disablesleep 0   # below floor — let it sleep, save the battery
    return
  fi
  if [ "${lid_closed_capped:-0}" = "1" ]; then
    return   # backstop already tripped this run; stays released until agents idle
  fi
  if [ "${LID_CLOSED_MAX_HOURS:-0}" -gt 0 ] 2>/dev/null; then
    local now; now=$(date '+%s')
    [ -n "${disablesleep_since:-}" ] || disablesleep_since=$now
    if [ "$(( now - disablesleep_since ))" -ge "$(( LID_CLOSED_MAX_HOURS * 3600 ))" ]; then
      lid_closed_capped=1
      set_disablesleep 0
      log "lid-closed: ${LID_CLOSED_MAX_HOURS}h backstop reached on battery — releasing (re-arms when agents idle or you plug in)"
      return
    fi
  fi
  set_disablesleep 1
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
  set_disablesleep 0
  lid_closed_capped=0; disablesleep_since=""   # fresh backstop window next run
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

# Everything below is runtime. Sourcing with KAA_LIB_ONLY=1 loads just the
# functions/defaults above (used by the test harness) and skips the loop.
if [ "${KAA_LIB_ONLY:-0}" != "1" ]; then

# Resolve the idle window: an explicit AGENT_IDLE_MINUTES wins; else fall back to
# a legacy CPU_IDLE_DURATION (poll counts) so upgraders keep their tolerance;
# else default 5 minutes.
if [ -z "${AGENT_IDLE_MINUTES:-}" ]; then
  if [ -n "${CPU_IDLE_DURATION:-}" ] && [ "${CPU_IDLE_DURATION}" -gt 0 ] 2>/dev/null; then
    AGENT_IDLE_MINUTES=$(( (CPU_IDLE_DURATION * POLL_INTERVAL + 59) / 60 ))
    log "NOTE: legacy CPU_IDLE_DURATION → AGENT_IDLE_MINUTES=${AGENT_IDLE_MINUTES} (set AGENT_IDLE_MINUTES in config to silence)"
  else
    AGENT_IDLE_MINUTES=5
  fi
fi

log "started (pid $$, poll ${POLL_INTERVAL}s, mode=${MODE:-desk}, idle=${AGENT_IDLE_MINUTES}m/hb${HEARTBEAT_WINDOW_SECS}s, prevent_display=${PREVENT_DISPLAY_SLEEP}, keepalive=${NETWORK_KEEPALIVE}/${NETWORK_KEEPALIVE_HOST}/${NETWORK_KEEPALIVE_INTERVAL}s, lid_closed=${BATTERY_LID_CLOSED:-0}/floor${BATTERY_FLOOR_PCT:-0}%/max${LID_CLOSED_MAX_HOURS:-0}h, extra_patterns=${#EXTRA_PATTERNS[@]})"
prev_status=""
since_ts=""
last_active=0
prev_cpu_sample=""
disablesleep_state=""
disablesleep_warned=0
disablesleep_since=""
lid_closed_capped=0
set_disablesleep 0   # clear any override left behind by a hard kill

while true; do
  if [ -f "$PAUSE_FLAG" ]; then
    stop_caffeinate
    stop_keepalive
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
    # Build the agent process subtree (agents + descendants: subagents, MCP
    # servers, bash/build jobs) and refresh the activity timestamp from real
    # CPU-time movement and/or a fresh heartbeat.
    root_pids=$(printf '%s\n' "$matches" | awk '{print $1}')
    subtree_pids=$(get_subtree_pids "$root_pids")
    subtree_csv=$(printf '%s\n' $subtree_pids | tr '\n' ',' | sed 's/,$//')
    # Seed last_active when agents first appear, so a session that opens and
    # immediately waits on the model isn't called idle before the first delta.
    if [ "$prev_status" != "working" ] && [ "$prev_status" != "idle-agents" ]; then
      last_active=$(date '+%s')
    fi
    update_activity "$subtree_csv"

    if [ "$(agent_is_active)" = "1" ]; then
      start_caffeinate
      start_keepalive
      hold_lid_closed
      if [ "$prev_status" != "working" ]; then
        since_ts=$(now_ts)
        log "WORKING — agents active:"
        while IFS= read -r line; do
          [ -n "$line" ] && log "  $line"
        done <<< "$matches"
        prev_status=working
      fi
      printf '%s\n' "$matches" | write_state working "$since_ts"
    else
      # Agents running but quiet past AGENT_IDLE_MINUTES — release the wakelock
      # so the Mac can sleep (saves battery). Re-arms the moment activity returns.
      stop_caffeinate
      stop_keepalive
      if [ "$prev_status" != "idle-agents" ]; then
        since_ts=$(now_ts)
        log "IDLE — agents quiet >=${AGENT_IDLE_MINUTES}m (no CPU-time, no heartbeat)"
        prev_status=idle-agents
      fi
      printf '%s\n' "$matches" | write_state idle "$since_ts"
    fi
  else
    stop_caffeinate
    stop_keepalive
    if [ "$prev_status" != "no-agents" ]; then
      since_ts=$(now_ts)
      log "idle — no agents, system may sleep"
      prev_status=no-agents
    fi
    printf '' | write_state idle "$since_ts"
  fi

  sleep "$POLL_INTERVAL"
done

fi   # end KAA_LIB_ONLY runtime guard
