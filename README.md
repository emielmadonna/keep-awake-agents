# keep-awake-agents

A tiny macOS daemon that keeps your Mac awake **only** while Claude Code or
Codex CLI is running. The moment the last session exits, the Mac is free to
sleep again — including with the lid closed (on AC power).

One monochrome menu bar icon, one button.

| Icon | Meaning |
|------|---------|
| `:cup.and.saucer.fill:` (☕) | Working — an agent is active, Mac stays awake |
| `:cup.and.saucer:` (☕)      | Idle — agents quiet, Mac can sleep |
| `:moon.zzz:` (💤)            | Nothing running — Mac sleeps normally |
| `:pause.circle:` (⏸)        | Paused |

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
6. Offers to add the activity heartbeat hook to Claude Code (recommended).

No Homebrew needed. No admin password needed.

## Configure

Edit `~/.config/keep-awake-agents/config` (or use the menu dropdown).

### Modes

Pick a mode from the menu bar (or `keep-awake-ctl.sh set-mode NAME`). Each
bundles the right settings; the menu shows **Custom** if you hand-tweak something
under Advanced.

| Mode | What it does | For |
|------|--------------|-----|
| **Desk** | Stay awake while working, sleep when idle. Lid-closed & keepalive off. | Plugged in at a desk (default) |
| **Café** | Lid closed on battery + hotspot kept alive. | Mobile — café, on your phone's hotspot |
| **Locked In** | Never sleep while an agent is running. | A critical run that must not die |

Café and Locked In keep the lid-closed override on, which needs the one-time
[lid-closed setup](#keeping-agents-alive-with-the-lid-closed-on-battery).

### All settings

| Variable | Default | What it does |
|----------|---------|--------------|
| `MODE` | `desk` | Bundle label set by the menu / `set-mode` (informational). |
| `AGENT_IDLE_MINUTES` | `5` | Sleep after this many minutes of no agent activity. `0` = never idle-sleep. |
| `POLL_INTERVAL` | `15` | Seconds between checks. Lower = more responsive. |
| `PREVENT_DISPLAY_SLEEP` | `0` | Set to `1` to also block display sleep (`caffeinate -d`). |
| `EXTRA_PATTERNS` | `()` | Extra `pgrep -f` patterns to match additional processes. |
| `NETWORK_KEEPALIVE` | `0` | **Set to `1` to keep Wi-Fi / hotspot alive.** Pings every `NETWORK_KEEPALIVE_INTERVAL` seconds. |
| `NETWORK_KEEPALIVE_HOST` | `8.8.8.8` | Ping target. Use your router's LAN IP to avoid internet traffic. |
| `NETWORK_KEEPALIVE_INTERVAL` | `30` | Seconds between keepalive pings. |
| `BATTERY_LID_CLOSED` | `0` | **Set to `1` to keep running with the lid closed on battery** (via `pmset disablesleep`). Needs one-time `setup-lid-closed`. |
| `BATTERY_FLOOR_PCT` | `15` | On battery, release the lid-closed override at/below this % so it can't drain to empty. `0` = no floor. |
| `LID_CLOSED_MAX_HOURS` | `8` | On battery, release the override after this many hours of continuous hold (backstop). `0` = no cap. |
| `HEARTBEAT_WINDOW_SECS` | `180` | A heartbeat newer than this counts as "working" (advanced). |
| `CPU_DELTA_EPSILON_SECS` | `1` | Subtree must gain > this many CPU-seconds/poll to count as active (advanced). |

### Keeping your hotspot connected with the lid closed

Enable the network keepalive:

```bash
# in ~/.config/keep-awake-agents/config
NETWORK_KEEPALIVE=1
```

Or click **Network keepalive: off → on** in the menu bar dropdown.

**What this does:** cellular hotspots and some Wi-Fi routers drop clients that
send no traffic (typically after 20–30 s). With the lid closed on AC power the
Mac stays awake via `caffeinate -s` but sends no packets, so the hotspot drops
it. The keepalive pings prevent that.

**Battery note:** `caffeinate -s` only blocks sleep on AC power. To keep running
with the lid closed **on battery**, enable lid-closed mode (below).

### Keeping agents alive with the lid closed on battery

By default macOS forces sleep the moment you close the lid on battery — power
assertions like `caffeinate` stop the idle timer but can't override the
hardware lid-close trigger. The kernel `SleepDisabled` flag (`pmset
disablesleep`) can. This mode flips it on while agents are active and off the
moment they finish.

One-time setup (installs a narrow sudoers rule so the daemon can toggle it
without a password — it grants *only* `pmset disablesleep`, nothing else):

```bash
keep-awake-ctl.sh setup-lid-closed
```

or click **Lid closed on battery → Turn on (one-time setup)…** in the menu bar.
Then it's automatic: while agents run, the Mac stays awake with the lid shut on
battery; it's released when they go idle, when paused, below `BATTERY_FLOOR_PCT`,
after `LID_CLOSED_MAX_HOURS` of continuous hold, and on exit. Undo with
`sudo rm /etc/sudoers.d/keep-awake-agents`.

**On a phone hotspot?** Also turn on `NETWORK_KEEPALIVE` (above). Lid-closed mode
keeps the *Mac* awake so the Wi-Fi radio stays up; the keepalive ping stops the
*hotspot* from dropping you as an idle client. Together: close the lid at a café
and your agents keep running over the hotspot.

> ⚠️ **Heat & drain.** Lid closed on battery means no airflow and no charging.
> The Mac can get hot in a bag and will drain until the floor cuts in. Use it
> for active runs you'll come back to, not indefinite storage.

## How it works

A bash loop polls every `POLL_INTERVAL` seconds for Claude Code / Codex
processes (plus any `EXTRA_PATTERNS`). While one is running and **working**, it
holds `caffeinate -i -s` (and, per mode, the keepalive ping and the lid-closed
override). When the agents go idle or exit, it releases everything so the Mac
can sleep.

**What counts as "working" — not CPU%.** `ps %cpu` is a lifetime average, and
agents sit near 0% CPU while waiting on the model, which is exactly when you
don't want to sleep. Instead the daemon tracks, each poll:

1. **Subtree CPU-time** — cumulative `cputime` across the agent process *and its
   descendants* (subagents, MCP servers, bash/build jobs). Any forward movement
   = real work.
2. **A heartbeat** — an optional Claude Code hook touches a file on every tool
   call / prompt, so even a long zero-CPU wait on the model counts as working.

It's called idle only after `AGENT_IDLE_MINUTES` with neither signal.

### Activity heartbeat (optional, recommended)

The heartbeat lets the daemon tell "working" from "you walked away" precisely, so
the idle window can stay short (saves battery) without ever sleeping mid-task.
The installer offers to add it. To wire it manually, run
`~/bin/keep-awake-heartbeat.sh` from a `PostToolUse` and `UserPromptSubmit` hook
in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/bin/keep-awake-heartbeat.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/bin/keep-awake-heartbeat.sh" }] }]
  }
}
```

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
  For battery, enable [lid-closed mode](#keeping-agents-alive-with-the-lid-closed-on-battery)
  (`BATTERY_LID_CLOSED=1`), which uses `pmset disablesleep`. Mind the heat/drain.
- **Hotspot / Wi-Fi drops?** See the [Keeping your hotspot connected](#keeping-your-hotspot-connected-with-the-lid-closed) section above. Enable `NETWORK_KEEPALIVE=1`.
- The matcher is intentionally narrow. If your agents run under unusual
  wrappers, add a pattern in `EXTRA_PATTERNS` rather than editing the daemon.
- Logs are append-only and uncapped. They're small, but rotate or delete them
  occasionally if you care.

## License

MIT — see [LICENSE](LICENSE).
