# keep-awake-agents

A tiny macOS daemon that keeps your Mac awake **only** while Claude Code or
Codex CLI is running. The moment the last session exits, the Mac is free to
sleep again — including with the lid closed (on AC power).

One monochrome menu bar icon, one button.

| Icon | Meaning |
|------|---------|
| `:cup.and.saucer.fill:` (☕) | An agent is running — Mac will not sleep |
| `:moon.zzz:` (💤)            | Idle — Mac can sleep normally |
| `:pause.circle:` (⏸)        | Paused — daemon won't keep awake regardless |

## Install

```bash
git clone https://github.com/emielmadonna/keep-awake-agents.git
cd keep-awake-agents
./install.sh
```

The installer:

1. Drops a small bash daemon at `~/bin/keep-awake-agents.sh`.
2. Registers a LaunchAgent (`com.keepawake.agents`) so it starts at login.
3. Drops a SwiftBar plugin for the menu bar icon.
4. Writes a default config at `~/.config/keep-awake-agents/config`.
5. Offers to download SwiftBar from its GitHub release if you don't have it.

No Homebrew needed. No admin password needed.

## Configure

Edit `~/.config/keep-awake-agents/config` (or click **Settings…** in the menu
dropdown). Three knobs:

| Variable | Default | What it does |
|----------|---------|--------------|
| `POLL_INTERVAL` | `15` | Seconds between checks. Lower = more responsive, more CPU. |
| `EXTRA_PATTERNS` | `()` | Extra `pgrep -f` patterns. Useful for keeping awake while a render, training, or sync job runs. |
| `PREVENT_DISPLAY_SLEEP` | `0` | Set to `1` to also block display sleep (`caffeinate -d`). |

After editing, restart the daemon:

```bash
launchctl kickstart -k gui/$(id -u)/com.keepawake.agents
```

## How it works

A bash loop polls every `POLL_INTERVAL` seconds. If it finds a process
matching any of:

- `node …/@anthropic-ai/claude-code/…/cli.js` (Claude Code), or
- `…/Codex.app/…/codex` (Codex desktop), or
- a binary named `codex` (Codex CLI), or
- any user-defined `EXTRA_PATTERNS`,

…it spawns `caffeinate -i -s` to block idle + system sleep. When no matching
processes remain, it kills `caffeinate`. That's it.

State + audit log live at:

```
~/Library/Logs/keep-awake.log
~/Library/Application Support/keep-awake/state
```

## Turn it off

| What you want | How |
|---------------|-----|
| Pause for now | Click **Pause** in the dropdown, or `touch ~/Library/Application\ Support/keep-awake/paused` |
| Resume | Click **Resume**, or `rm` that file |
| Stop autostart (keep files) | `launchctl unload ~/Library/LaunchAgents/com.keepawake.agents.plist` |
| Uninstall completely | `./uninstall.sh` |

## Caveats

- `caffeinate -s` keeps the Mac awake with the lid closed **only on AC power**.
  Apple enforces battery clamshell sleep at the kernel level. Plug in for long
  overnight runs.
- **Hotspot / Wi-Fi drops while agents are running?** The CPU-idle logic
  releases the wakelock when agents stay below `CPU_IDLE_THRESHOLD` for
  `CPU_IDLE_DURATION` consecutive polls. Because Claude/Codex sit near 0% CPU
  while waiting for an LLM response, a short duration (< ~2 min) can release
  the wakelock mid-request and let the Mac (or hotspot connection) drop. The
  default is set to 120 polls (10 min at 5 s interval) to avoid this. If you
  still see drops, set `CPU_IDLE_THRESHOLD=0` in the config to disable the
  check entirely.
- The matcher is intentionally narrow. If your agents run under unusual
  wrappers, add a pattern in `EXTRA_PATTERNS` rather than editing the daemon.
- Logs are append-only and uncapped. They're small, but rotate or delete them
  occasionally if you care.

## License

MIT — see [LICENSE](LICENSE).
