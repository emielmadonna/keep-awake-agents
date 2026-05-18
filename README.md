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

Edit `~/.config/keep-awake-agents/config` (or use the menu dropdown).

| Variable | Default | What it does |
|----------|---------|--------------|
| `POLL_INTERVAL` | `15` | Seconds between checks. Lower = more responsive, more CPU. |
| `EXTRA_PATTERNS` | `()` | Extra `pgrep -f` patterns to match additional processes. |
| `PREVENT_DISPLAY_SLEEP` | `0` | Set to `1` to also block display sleep (`caffeinate -d`). |
| `CPU_IDLE_THRESHOLD` | `5` | Release wakelock when CPU % stays below this. `0` = never release. |
| `CPU_IDLE_DURATION` | `120` | Polls below threshold before releasing. At 5 s poll = 10 min. |
| `NETWORK_KEEPALIVE` | `0` | **Set to `1` to keep Wi-Fi / hotspot alive with lid closed.** Sends a ping every `NETWORK_KEEPALIVE_INTERVAL` seconds. |
| `NETWORK_KEEPALIVE_HOST` | `8.8.8.8` | Ping target. Use your router's LAN IP to avoid internet traffic. |
| `NETWORK_KEEPALIVE_INTERVAL` | `30` | Seconds between keepalive pings. |
| `NOTIFY_IMESSAGE` | `0` | Set to `1` to send iMessage alerts to your phone. |
| `NOTIFY_TARGET` | `` | Phone number (`+15551234567`) or Apple ID email to message. |
| `NOTIFY_BATTERY_PCT` | `20` | Battery % that triggers the low-battery alert. |

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

**Battery note:** `caffeinate -s` only blocks sleep on AC power. On battery,
macOS forces sleep when the lid closes regardless. Plug in for lid-closed runs.

### Phone alerts when you unplug

Enable iMessage notifications so your phone warns you the moment you unplug:

```bash
# in ~/.config/keep-awake-agents/config
NOTIFY_IMESSAGE=1
NOTIFY_TARGET=+15551234567   # your own phone number
NOTIFY_BATTERY_PCT=20        # also alert at this battery %
```

You'll get two types of messages:
- **Unplugged alert** — fires the moment you pull the charger while keepalive is on. Tells you the current battery %.
- **Low battery alert** — fires when battery drops below `NOTIFY_BATTERY_PCT` while on battery.

Both reset when you plug back in, so you only get one of each per AC cycle. Requires the Mac's Messages app to be signed in to iMessage.

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
- **Hotspot / Wi-Fi drops?** See the [Keeping your hotspot connected](#keeping-your-hotspot-connected-with-the-lid-closed) section above. Enable `NETWORK_KEEPALIVE=1`.
- The matcher is intentionally narrow. If your agents run under unusual
  wrappers, add a pattern in `EXTRA_PATTERNS` rather than editing the daemon.
- Logs are append-only and uncapped. They're small, but rotate or delete them
  occasionally if you care.

## License

MIT — see [LICENSE](LICENSE).
