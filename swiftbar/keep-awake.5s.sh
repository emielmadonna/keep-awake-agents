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
[ -z "$poll" ] && poll=15
[ -z "$display" ] && display=0

# Current state + per-app session counts.
status=unknown; since=""; claude_n=0; codex_n=0; other_n=0
if [ -f "$STATE_FILE" ]; then
  status=$(awk -F= '$1=="status"{print $2; exit}' "$STATE_FILE")
  since_raw=$(awk -F= '$1=="since"{sub(/^since=/,"",$0); print; exit}' "$STATE_FILE")
  # Reformat "2026-05-15 16:46:24" → "4:46 PM" (12-hour, no seconds).
  since=$(date -j -f "%Y-%m-%d %H:%M:%S" "$since_raw" "+%-I:%M %p" 2>/dev/null)
  [ -z "$since" ] && since="$since_raw"
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
    echo "Since $since | color=gray"
    echo "Pause | shell=$CTL param1=pause terminal=false refresh=true"
    ;;
  paused)
    echo ":pause.circle:"
    echo "---"
    echo "Paused — Mac can sleep | size=13"
    echo "Since $since | color=gray"
    echo "Resume | shell=$CTL param1=resume terminal=false refresh=true"
    ;;
  *)
    echo ":moon.zzz:"
    echo "---"
    echo "Idle — Mac can sleep | size=13"
    [ -n "$since" ] && echo "Since $since | color=gray"
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
