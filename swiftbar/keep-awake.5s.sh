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
keepalive=$(awk -F= '/^NETWORK_KEEPALIVE=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
notify=$(awk -F= '/^NOTIFY_IMESSAGE=/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)
[ -z "$poll" ]     && poll=15
[ -z "$display" ]  && display=0
[ -z "$cpu_thr" ]  && cpu_thr=5
[ -z "$cpu_dur" ]  && cpu_dur=120
[ -z "$keepalive" ] && keepalive=0
[ -z "$notify" ]    && notify=0

# Current state + per-app session counts.
status=unknown; duration=""; claude_n=0; codex_n=0; other_n=0; cpu_val=""
if [ -f "$STATE_FILE" ]; then
  status=$(awk -F= '$1=="status"{print $2; exit}' "$STATE_FILE")
  since_raw=$(awk -F= '$1=="since"{sub(/^since=/,"",$0); print; exit}' "$STATE_FILE")
  cpu_val=$(awk -F= '$1=="cpu"{print $2; exit}' "$STATE_FILE")
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

total=$((claude_n + codex_n + other_n))
agent_word="agents"; [ "$total" = "1" ] && agent_word="agent"

# ── Status header ─────────────────────────────────────────────────────────────
case "$status" in
  active)
    echo ":cup.and.saucer.fill:"
    echo "---"
    echo "Keeping Mac awake | size=13"
    [ "$claude_n" -gt 0 ] && echo "Claude Code: $claude_n | color=gray"
    [ "$codex_n"  -gt 0 ] && echo "Codex: $codex_n | color=gray"
    [ "$other_n"  -gt 0 ] && echo "Other: $other_n | color=gray"
    detail=""
    [ -n "$cpu_val" ]   && detail="${cpu_val}% CPU"
    [ -n "$duration" ]  && detail="${detail:+$detail · }${duration}"
    [ -n "$detail" ]    && echo "$detail | color=gray"
    echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
    ;;
  cpu-idle)
    echo ":cup.and.saucer:"
    echo "---"
    echo "Agents idle — Mac can sleep | size=13"
    [ "$claude_n" -gt 0 ] && echo "Claude Code: $claude_n | color=gray"
    [ "$codex_n"  -gt 0 ] && echo "Codex: $codex_n | color=gray"
    [ "$other_n"  -gt 0 ] && echo "Other: $other_n | color=gray"
    [ -n "$cpu_val" ] && echo "${cpu_val}% CPU · idle for $duration | color=gray"
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
    echo "No agents — Mac can sleep | size=13"
    [ -n "$duration" ] && echo "Idle for $duration | color=gray"
    echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
    ;;
esac

echo "---"

# ── Settings ──────────────────────────────────────────────────────────────────

# 1. Auto-sleep — CPU threshold + delay combined in one submenu.
delay_secs=$((cpu_dur * poll))
if [ "$cpu_thr" = "0" ]; then
  echo "Auto-sleep: off"
else
  echo "Auto-sleep: below ${cpu_thr}% for ~${delay_secs}s"
fi
# Threshold options.
for v in 0 3 5 10 20; do
  [ "$v" = "0" ] && label="Off — always stay awake" || label="Below ${v}%"
  if [ "$cpu_thr" = "$v" ]; then
    echo "-- $label | checked=true shell=$CTL param1=set-cpu-threshold param2=${v} terminal=false refresh=true"
  else
    echo "-- $label | shell=$CTL param1=set-cpu-threshold param2=${v} terminal=false refresh=true"
  fi
done
# Delay options (only relevant when threshold is active; shown greyed when off).
# Values are poll counts; labels show wall-clock minutes at current poll interval.
echo "-- ─── sleep after ─── | color=#888888 size=11"
for v in 24 60 120 360; do
  mins=$(( (v * poll + 59) / 60 ))
  label="${mins} min"
  if [ "$cpu_thr" = "0" ]; then
    echo "-- $label | color=gray shell=$CTL param1=set-cpu-duration param2=${v} terminal=false refresh=true"
  elif [ "$cpu_dur" = "$v" ]; then
    echo "-- $label | checked=true shell=$CTL param1=set-cpu-duration param2=${v} terminal=false refresh=true"
  else
    echo "-- $label | shell=$CTL param1=set-cpu-duration param2=${v} terminal=false refresh=true"
  fi
done

# 2. Check interval.
echo "Check every: ${poll}s"
for v in 5 15 30 60; do
  [ "$v" = "60" ] && label="60s (1 min)" || label="${v}s"
  if [ "$poll" = "$v" ]; then
    echo "-- $label | checked=true shell=$CTL param1=set-poll param2=${v} terminal=false refresh=true"
  else
    echo "-- $label | shell=$CTL param1=set-poll param2=${v} terminal=false refresh=true"
  fi
done

# 3. Screen sleep.
if [ "$display" = "1" ]; then
  echo "Screen: stays on"
  echo "-- Stays on | checked=true shell=$CTL param1=set-display param2=1 terminal=false refresh=true"
  echo "-- Dims normally | shell=$CTL param1=set-display param2=0 terminal=false refresh=true"
else
  echo "Screen: dims normally"
  echo "-- Stays on | shell=$CTL param1=set-display param2=1 terminal=false refresh=true"
  echo "-- Dims normally | checked=true shell=$CTL param1=set-display param2=0 terminal=false refresh=true"
fi

# 4. Network keepalive (hotspot / Wi-Fi with lid closed).
if [ "$keepalive" = "1" ]; then
  echo "Network keepalive: on"
  echo "-- On — ping every 30s | checked=true shell=$CTL param1=set-keepalive param2=1 terminal=false refresh=true"
  echo "-- Off | shell=$CTL param1=set-keepalive param2=0 terminal=false refresh=true"
else
  echo "Network keepalive: off"
  echo "-- On — ping every 30s | shell=$CTL param1=set-keepalive param2=1 terminal=false refresh=true"
  echo "-- Off | checked=true shell=$CTL param1=set-keepalive param2=0 terminal=false refresh=true"
fi

# 5. iMessage alerts (unplug + low battery warnings).
if [ "$notify" = "1" ]; then
  echo "iMessage alerts: on"
  echo "-- On | checked=true shell=$CTL param1=set-notify param2=1 terminal=false refresh=true"
  echo "-- Off | shell=$CTL param1=set-notify param2=0 terminal=false refresh=true"
else
  echo "iMessage alerts: off"
  echo "-- On | shell=$CTL param1=set-notify param2=1 terminal=false refresh=true"
  echo "-- Off | checked=true shell=$CTL param1=set-notify param2=0 terminal=false refresh=true"
fi
