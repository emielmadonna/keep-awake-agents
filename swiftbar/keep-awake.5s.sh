#!/bin/bash
# Minimal SwiftBar plugin for the keep-awake-agents daemon.
# All side effects go through ~/bin/keep-awake-ctl.sh — never invoke commands
# with spaces in argv values directly (SwiftBar splits param= at whitespace).
#
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

STATE_FILE="$HOME/Library/Application Support/keep-awake/state"
CONFIG_FILE="$HOME/.config/keep-awake-agents/config"
CTL="$HOME/bin/keep-awake-ctl.sh"
LAUNCHD_LABEL="com.keepawake.agents"

# Current config (defaults if file/keys missing).
poll=$(awk -F= '/^POLL_INTERVAL=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
display=$(awk -F= '/^PREVENT_DISPLAY_SLEEP=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
agent_idle=$(awk -F= '/^AGENT_IDLE_MINUTES=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
keepalive=$(awk -F= '/^NETWORK_KEEPALIVE=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
batt_lid=$(awk -F= '/^BATTERY_LID_CLOSED=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
[ -z "$poll" ]        && poll=15
[ -z "$display" ]     && display=0
[ -z "$agent_idle" ]  && agent_idle=5
[ -z "$keepalive" ]   && keepalive=0
[ -z "$batt_lid" ]    && batt_lid=0

# Is the launchd daemon currently loaded? If not, we show a "stopped" state
# with a Start button instead of the usual status header.
daemon_running=0
if launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
  daemon_running=1
fi

# Derive the displayed mode by matching current flags against each mode's
# signature. Any hand-tweaked advanced toggle that drifts → "custom", so the
# menu never claims a mode it isn't really in. (Idle minutes is a tuning knob
# within desk/cafe, so it doesn't flip to custom on its own.)
detect_mode() {
  local lid=$1 ka=$2 disp=$3 idle=$4
  if [ "$disp" != "0" ]; then echo custom; return; fi
  if   [ "$lid" = "0" ] && [ "$ka" = "0" ] && [ "$idle" != "0" ]; then echo desk
  elif [ "$lid" = "1" ] && [ "$ka" = "1" ] && [ "$idle" != "0" ]; then echo cafe
  elif [ "$lid" = "1" ] && [ "$ka" = "1" ] && [ "$idle" = "0" ]; then echo lockedin
  else echo custom
  fi
}
mode_now=$(detect_mode "$batt_lid" "$keepalive" "$display" "$agent_idle")

# Classify a process command line into a human-friendly label.
classify_label() {
  local cmd=$1
  if [[ "$cmd" == *"MacOS/claude"* ]] || [[ "$cmd" == *"claude-code/"*"cli.js"* ]]; then
    echo "Claude Code"
  elif [[ "$cmd" == *"Codex.app"* ]] || [[ "$cmd" == *"/codex "* ]] || [[ "$cmd" == *"/codex" ]]; then
    echo "Codex"
  else
    echo "Agent"
  fi
}

# Current state + per-agent rows (each row = one running session).
status=unknown; duration=""
agent_rows=()   # each entry: "<label>|<nickname>"

if [ -f "$STATE_FILE" ]; then
  status=$(awk -F= '$1=="status"{print $2; exit}' "$STATE_FILE")
  since_raw=$(awk -F= '$1=="since"{sub(/^since=/,"",$0); print; exit}' "$STATE_FILE")
  since_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$since_raw" "+%s" 2>/dev/null)
  if [ -n "$since_epoch" ]; then
    delta=$(( $(date "+%s") - since_epoch ))
    [ "$delta" -lt 0 ] && delta=0
    if   [ "$delta" -lt 60 ];    then duration="${delta}s"
    elif [ "$delta" -lt 3600 ];  then duration="$((delta/60))m"
    elif [ "$delta" -lt 86400 ]; then duration="$((delta/3600))h $((delta%3600/60))m"
    else                              duration="$((delta/86400))d $((delta%86400/3600))h"
    fi
  fi

  # First pass: collect (pid, command) pairs in order.
  pids=(); cmds=()
  while IFS= read -r proc; do
    [ -z "$proc" ] && continue
    pid=${proc%% *}; cmd=${proc#* }
    [ -z "$pid" ] && continue
    pids+=("$pid"); cmds+=("$cmd")
  done < <(awk -F= '$1=="process"{sub(/^process=/,"",$0); print}' "$STATE_FILE")

  # Batched cwd lookup (one lsof call for all pids — much cheaper than per-pid).
  # Maps pid → cwd. Use simple parallel arrays to stay portable to bash 3.2.
  cwd_pids=(); cwd_paths=()
  if [ "${#pids[@]}" -gt 0 ]; then
    pids_csv=$(IFS=,; echo "${pids[*]}")
    cur_pid=""
    while IFS= read -r line; do
      case "$line" in
        p*) cur_pid=${line#p} ;;
        n*) if [ -n "$cur_pid" ]; then
              cwd_pids+=("$cur_pid"); cwd_paths+=("${line#n}"); cur_pid=""
            fi ;;
      esac
    done < <(lsof -a -p "$pids_csv" -d cwd -F pn 2>/dev/null)
  fi
  lookup_cwd() {
    local target=$1 i=0
    while [ "$i" -lt "${#cwd_pids[@]}" ]; do
      if [ "${cwd_pids[$i]}" = "$target" ]; then echo "${cwd_paths[$i]}"; return; fi
      i=$((i + 1))
    done
  }

  # Build deduped rows: one row per (label, nickname) combo. Multiple worker
  # processes inside the same project collapse into a single session line, the
  # way the Meta menubar groups by bridge + cwd.
  seen_keys=()
  i=0
  while [ "$i" -lt "${#pids[@]}" ]; do
    pid=${pids[$i]}
    cmd=${cmds[$i]}
    label=$(classify_label "$cmd")
    cwd=$(lookup_cwd "$pid")
    nick=""
    if [ -n "$cwd" ] && [ "$cwd" != "/" ] && [ "$cwd" != "$HOME" ]; then
      nick=$(basename "$cwd")
    fi
    key="$label|$nick"
    dup=0
    for s in "${seen_keys[@]}"; do
      [ "$s" = "$key" ] && { dup=1; break; }
    done
    if [ "$dup" = "0" ]; then
      seen_keys+=("$key")
      agent_rows+=("$label|$nick")
    fi
    i=$((i + 1))
  done
fi

total=${#agent_rows[@]}

# Emit one gray menu line per running agent session: "Claude Code · project".
emit_agents() {
  local entry label nick line
  for entry in "${agent_rows[@]}"; do
    IFS='|' read -r label nick <<< "$entry"
    line="$label"
    [ -n "$nick" ] && line="$line · $nick"
    echo "$line | color=#6E6E73,#98989D"
  done
}

# ── Status header ─────────────────────────────────────────────────────────────
# Frames-style vocabulary: Working / Idle / Paused. The daemon writes status=idle
# both when agents are quiet (process rows present) and when none are running
# (no rows) — we tell them apart by $total.
# Compact rendering: emit everything inside this group, then the awk filter at
# the closing brace shrinks every line to a small font and matching icon size
# (SwiftBar has no global font-size setting, so we do it in one pass here).
{
if [ "$total" = "1" ]; then countlbl="1 agent"; else countlbl="$total agents"; fi
if [ "$daemon_running" = "0" ]; then
  echo ":moon.stars:"
  echo "---"
  echo "Stopped | size=11"
  echo "Start | shell=$CTL param1=start terminal=false refresh=true"
else
  case "$status" in
    working)
      echo ":cup.and.saucer.fill:"
      echo "---"
      echo "Working · $countlbl | size=11"
      echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
      ;;
    paused)
      echo ":pause.circle:"
      echo "---"
      echo "Paused | size=11"
      echo "Resume | shell=$CTL param1=resume terminal=false refresh=true"
      ;;
    *)
      if [ "$total" -gt 0 ]; then
        echo ":cup.and.saucer:"
        echo "---"
        echo "Idle · $countlbl | size=11"
      else
        echo ":moon.zzz:"
        echo "---"
        echo "Nothing running | size=11"
      fi
      echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
      ;;
  esac
fi

echo "---"

# ── Mode ──────────────────────────────────────────────────────────────────────
# One meaningful icon per mode, the active one in green. No label row — compact.
emit_mode() {
  local name=$1 id=$2 icon=$3
  if [ "$mode_now" = "$id" ]; then
    echo "$name | sfimage=$icon sfcolor=#248A3D,#30D158 color=#248A3D,#30D158 shell=$CTL param1=set-mode param2=$id terminal=false refresh=true"
  else
    echo "$name | sfimage=$icon shell=$CTL param1=set-mode param2=$id terminal=false refresh=true"
  fi
}
emit_mode "Desk"      desk     "desktopcomputer"
emit_mode "Café"      cafe     "cup.and.saucer.fill"
emit_mode "Locked In" lockedin "lock.fill"
if [ "$mode_now" = "custom" ]; then
  echo "Custom | sfimage=slider.horizontal.3 sfcolor=#BF5B00,#FF9F0A color=#BF5B00,#FF9F0A"
fi
if [ "$batt_lid" = "1" ]; then
  echo "Lid setup → Advanced | size=11 color=#BF5B00,#FF9F0A"
fi

# ── Advanced ──────────────────────────────────────────────────────────────────
echo "Advanced"

# Sleep-when-idle window (AGENT_IDLE_MINUTES).
case "$agent_idle" in
  0) idle_label="Never (stay awake while running)" ;;
  *) idle_label="After ${agent_idle} min idle" ;;
esac
echo "-- Sleep when idle: $idle_label"
for v in 0 2 5 10; do
  [ "$v" = "0" ] && vl="Never — stay awake while running" || vl="After ${v} min"
  if [ "$agent_idle" = "$v" ]; then
    echo "---- $vl | checked=true shell=$CTL param1=set-agent-idle param2=${v} terminal=false refresh=true"
  else
    echo "---- $vl | shell=$CTL param1=set-agent-idle param2=${v} terminal=false refresh=true"
  fi
done

# Check interval.
echo "-- Check every: ${poll}s"
for v in 5 15 30 60; do
  [ "$v" = "60" ] && vl="60s (1 min)" || vl="${v}s"
  if [ "$poll" = "$v" ]; then
    echo "---- $vl | checked=true shell=$CTL param1=set-poll param2=${v} terminal=false refresh=true"
  else
    echo "---- $vl | shell=$CTL param1=set-poll param2=${v} terminal=false refresh=true"
  fi
done

# Screen sleep.
if [ "$display" = "1" ]; then
  echo "-- Screen: stays on"
  echo "---- Stays on | checked=true shell=$CTL param1=set-display param2=1 terminal=false refresh=true"
  echo "---- Dims normally | shell=$CTL param1=set-display param2=0 terminal=false refresh=true"
else
  echo "-- Screen: dims normally"
  echo "---- Stays on | shell=$CTL param1=set-display param2=1 terminal=false refresh=true"
  echo "---- Dims normally | checked=true shell=$CTL param1=set-display param2=0 terminal=false refresh=true"
fi

# Network keepalive (hotspot / Wi-Fi).
if [ "$keepalive" = "1" ]; then
  echo "-- Stay connected (hotspot/Wi-Fi): on"
  echo "---- On — ping every 30s | checked=true shell=$CTL param1=set-keepalive param2=1 terminal=false refresh=true"
  echo "---- Off | shell=$CTL param1=set-keepalive param2=0 terminal=false refresh=true"
else
  echo "-- Stay connected (hotspot/Wi-Fi): off"
  echo "---- On — ping every 30s | shell=$CTL param1=set-keepalive param2=1 terminal=false refresh=true"
  echo "---- Off | checked=true shell=$CTL param1=set-keepalive param2=0 terminal=false refresh=true"
fi

# Lid closed on battery (pmset disablesleep override).
if [ "$batt_lid" = "1" ]; then
  echo "-- Lid closed on battery: on"
  echo "---- On | checked=true shell=$CTL param1=set-battery-lid-closed param2=1 terminal=false refresh=true"
  echo "---- Off | shell=$CTL param1=set-battery-lid-closed param2=0 terminal=false refresh=true"
  echo "---- Re-run setup… | shell=$CTL param1=setup-lid-closed terminal=true refresh=true"
else
  echo "-- Lid closed on battery: off"
  echo "---- Turn on (one-time setup)… | shell=$CTL param1=setup-lid-closed terminal=true refresh=true"
  echo "---- On (already set up) | shell=$CTL param1=set-battery-lid-closed param2=1 terminal=false refresh=true"
  echo "---- Off | checked=true shell=$CTL param1=set-battery-lid-closed param2=0 terminal=false refresh=true"
fi

# ── Quit / Uninstall ──────────────────────────────────────────────────────────
echo "---"
if [ "$daemon_running" = "1" ]; then
  echo "Quit Keep Awake | shell=$CTL param1=quit terminal=false refresh=true"
else
  echo "Stopped — restart at login or click Start above | color=#6E6E73,#98989D"
fi
echo "Uninstall… | color=#D70015,#FF453A shell=$CTL param1=uninstall terminal=false refresh=true"
} | awk '
NR==1 { print; next }                 # menu-bar icon: leave full size
/^---$/ { print; next }               # separators: leave
{
  has_size = ($0 ~ /[ |]size=/)
  need_sf  = ($0 ~ /sfimage=/ && $0 !~ /sfsize=/)
  if ($0 ~ /\|/) {
    if (!has_size) $0 = $0 " size=10"
    if (need_sf)   $0 = $0 " sfsize=10"
  } else {
    add = "size=10"; if (need_sf) add = add " sfsize=10"
    $0 = $0 " | " add
  }
  print
}'
