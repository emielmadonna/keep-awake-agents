#!/bin/bash
# keep-awake-heartbeat.sh — refresh the keep-awake activity heartbeat.
#
# Wired to Claude Code hooks (PostToolUse + UserPromptSubmit) so the keep-awake
# daemon knows an agent is actively working even when local CPU is ~0 (e.g. while
# waiting on the model API). Touching this file bumps its mtime; the daemon
# treats a heartbeat newer than HEARTBEAT_WINDOW_SECS as "working".
#
# Must be fast and must never fail the hook — always exits 0.
d="$HOME/Library/Application Support/keep-awake"
mkdir -p "$d" 2>/dev/null || true
: > "$d/heartbeat" 2>/dev/null || true
exit 0
