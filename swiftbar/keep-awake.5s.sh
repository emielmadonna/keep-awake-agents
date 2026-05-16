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

# Current config (defaults if file/keys missing).
poll=$(awk -F= '/^POLL_INTERVAL=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
display=$(awk -F= '/^PREVENT_DISPLAY_SLEEP=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
cpu_thr=$(awk -F= '/^CPU_IDLE_THRESHOLD=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
cpu_dur=$(awk -F= '/^CPU_IDLE_DURATION=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
[ -z "$poll" ]    && poll=15
[ -z "$display" ] && display=0
[ -z "$cpu_thr" ] && cpu_thr=5
[ -z "$cpu_dur" ] && cpu_dur=3

# Current state + per-app session counts.
status=unknown; duration=""; claude_n=0; codex_n=0; other_n=0; cpu_val=""
if [ -f "$STATE_FILE" ]; then
  status=$(awk -F= '$1=="status"{print $2; exit}' "$STATE_FILE")
  since_raw=$(awk -F= '$1=="since"{sub(/^since=/,"",$0); print; exit}' "$STATE_FILE")
  cpu_val=$(awk -F= '$1=="cpu"{print $2; exit}' "$STATE_FILE")
  # Compute elapsed time as "12m", "1h 23m", "2d 5h".
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
  while IFS= read -r proc; do
    [ -z "$proc" ] && continue
    if [[ "$proc" == *"MacOS/claude"* ]] || [[ "$proc" == *"claude-code/"*"cli.js"* ]]; then
      claude_n=$((claude_n + 1))
    elif [[ "$proc" == *"Codex.app"* ]] || [[ "$proc" == *"/codex "* ]] || [[ "$proc" == *"/codex" ]]; then
      codex_n=$((codex_n + 1))
    else
      other_n=$((other_n + 1))
    fi
  done < <(awk -F= '$1=="process"{sub(/^process=/,"",$0); print}' "$STATE_FILE")
fi

# Top icon + status header + primary toggle.
total=$((claude_n + codex_n + other_n))
agent_word="agents"; [ "$total" = "1" ] && agent_word="agent"

case "$status" in
  active)
    echo ":cup.and.saucer.fill:"
    echo "---"
    echo "$total $agent_word keeping Mac awake | size=13"
    [ "$claude_n" -gt 0 ] && echo "Claude Code: $claude_n | color=gray"
    [ "$codex_n"  -gt 0 ] && echo "Codex: $codex_n | color=gray"
    [ "$other_n"  -gt 0 ] && echo "Other: $other_n | color=gray"
    [ -n "$cpu_val" ] && echo "CPU: ${cpu_val}% | color=gray"
    [ -n "$duration" ] && echo "Awake for $duration | color=gray"
    echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
    ;;
  cpu-idle)
    echo ":cup.and.saucer:"
    echo "---"
    echo "$total $agent_word idle — Mac can sleep | size=13"
    [ "$claude_n" -gt 0 ] && echo "Claude Code: $claude_n | color=gray"
    [ "$codex_n"  -gt 0 ] && echo "Codex: $codex_n | color=gray"
    [ "$other_n"  -gt 0 ] && echo "Other: $other_n | color=gray"
    [ -n "$cpu_val" ] && echo "CPU: ${cpu_val}% (below ${cpu_thr}% threshold) | color=gray"
    [ -n "$duration" ] && echo "Idle for $duration | color=gray"
    echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
    ;;
  paused)
    echo ":pause.circle:"
    echo "---"
    echo "Paused — Mac can sleep | size=13"
    [ -n "$duration" ] && echo "Paused for $duration | color=gray"
    echo "Resume | shell=$CTL param1=resume terminal=false refresh=true"
    ;;
  *)
    echo ":moon.zzz:"
    echo "---"
    echo "Idle — Mac can sleep | size=13"
    [ -n "$duration" ] && echo "Idle for $duration | color=gray"
    echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
    ;;
esac

echo "---"

# Poll interval — parent shows current value, submenu has selectable options.
echo "Poll interval: ${poll}s"
for v in 5 15 30 60; do
  if [ "$poll" = "$v" ]; then
    echo "-- ${v} seconds | checked=true shell=$CTL param1=set-poll param2=${v} terminal=false refresh=true"
  else
    echo "-- ${v} seconds | shell=$CTL param1=set-poll param2=${v} terminal=false refresh=true"
  fi
done

# Display sleep block toggle.
if [ "$display" = "1" ]; then
  echo "Block display sleep: On"
  echo "-- On  | checked=true shell=$CTL param1=set-display param2=1 terminal=false refresh=true"
  echo "-- Off | shell=$CTL param1=set-display param2=0 terminal=false refresh=true"
else
  echo "Block display sleep: Off"
  echo "-- On  | shell=$CTL param1=set-display param2=1 terminal=false refresh=true"
  echo "-- Off | checked=true shell=$CTL param1=set-display param2=0 terminal=false refresh=true"
fi

# CPU-idle threshold — 0 = disabled.
cpu_thr_label="${cpu_thr}%"; [ "$cpu_thr" = "0" ] && cpu_thr_label="Off"
echo "CPU-idle threshold: ${cpu_thr_label}"
for v in 0 3 5 10 20; do
  label="${v}%"; [ "$v" = "0" ] && label="Off (always awake)"
  if [ "$cpu_thr" = "$v" ]; then
    echo "-- $label | checked=true shell=$CTL param1=set-cpu-threshold param2=${v} terminal=false refresh=true"
  else
    echo "-- $label | shell=$CTL param1=set-cpu-threshold param2=${v} terminal=false refresh=true"
  fi
done

# CPU-idle duration (only shown when threshold is active).
if [ "$cpu_thr" != "0" ]; then
  delay_secs=$((cpu_dur * poll))
  echo "CPU-idle delay: ${cpu_dur} polls (~${delay_secs}s)"
  for v in 1 2 3 5; do
    secs=$((v * poll))
    if [ "$cpu_dur" = "$v" ]; then
      echo "-- ${v} polls (~${secs}s) | checked=true shell=$CTL param1=set-cpu-duration param2=${v} terminal=false refresh=true"
    else
      echo "-- ${v} polls (~${secs}s) | shell=$CTL param1=set-cpu-duration param2=${v} terminal=false refresh=true"
    fi
  done
fi
