# AIPulse

Monitor AI agent usage and limits in your macOS menu bar.

## Overview

AIPulse is a lightweight menu bar application that tracks your spending and quota consumption for coding AI agents—Claude Code and OpenAI Codex. It displays session and weekly usage limits in real time, ensuring you never exceed your budget without knowing it.

AIPulse reads your local agent logs and your own account quota. It runs entirely on your machine and sends nothing to third parties.

## Features

- **Real-time usage tracking** — displays current consumption from Claude Code and Codex
- **Quota alerts** — session and weekly limits with countdown to reset
- **Usage patterns** — graphs by day of week, model breakdown (weekly and total), history by day/week/month
- **Service status** — live incident and component status from Anthropic and OpenAI
- **Flexible display** — five bar styles: text, compact dot, progress bar, battery, or icon + bar
- **Multi-language** — Czech and English, settable in preferences
- **Configurable collection** — choose refresh interval (default 5 minutes via launchd) and work week length
- **Fast limits refresh** — dedicated script fetches quota percentages in under a second
- **Launch at login** — runs as background menu bar app with scheduled data collection

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 5.9+)
- Node.js 18 or later
- [`ccusage`](https://github.com/ryoppippi/ccusage) installed globally — `npm install -g ccusage`.
  AIPulse calls it by name, so `npx` alone is not enough
- Claude Code installed and logged in

## Installation

```bash
git clone https://github.com/chuchy4ever/AIPulse.git
cd AIPulse
./install.sh
```

The script will:

1. Create `~/.local/share/aipulse/` for data and scripts
2. Copy collection scripts and set permissions
3. Migrate data from any old installation
4. Build the app in release mode
5. Create the app bundle at `/Applications/AIPulse.app`
6. Install a launchd job to collect data every 5 minutes (configurable)
7. Code-sign the app with ad-hoc signature
8. Launch the app

## How It Works

```
Claude Code / Codex
    ↓
Local JSONL logs (~/.claude/projects/)
    ↓
ccusage (weekly / daily / monthly)
    ↓
~/.local/share/aipulse/data.json
    ↓
AIPulse app (reads + displays)

OAuth (separate flow):
Keyed in Keychain (by Claude Code)
    ↓
refresh-limits.sh
    ↓
api.anthropic.com/api/oauth/usage
    ↓
Limits object: session%, weekly%, reset times
```

**Collection cycle:**

- Launcher (`launchd`) runs `scripts/collect.sh` every N minutes (default 5, user-configurable via app)
- `collect.sh` calls `ccusage` to parse local logs, fetches service status from status.claude.com and status.openai.com, and writes aggregated JSON to `data.json`
- App reads `data.json` and renders it; you click the menu bar icon to expand a popover
- Limits are fetched on-demand via `refresh-limits.sh` (fast, ~1 sec) using OAuth token from Keychain

**Privacy and security**

- The app reads only local files: `~/.claude/projects/` (agent logs, via `ccusage`) and its own directory `~/.local/share/aipulse/`.
- The only outbound requests are to `api.anthropic.com` (your quota) and `status.claude.com` / `status.openai.com` (service status).
- The OAuth token is never written to disk, never logged, and never sent anywhere except Anthropic's own API.
- No telemetry, no analytics, no third-party services.

**Do not paste `data.json` into a bug report.** It carries your account email,
organisation id and name, and your full spend history. When you report a
problem, quote the error message and the relevant lines of `collect.log`
instead, and strip the `auth` block from anything you attach.

**One thing you should know before installing.** To read your quota, AIPulse uses the OAuth token that Claude Code stores in your macOS Keychain — the same credential your own CLI uses. Anthropic's terms cover using a Claude subscription through Anthropic's own products, and a third-party tool reading that token is not clearly within them. The token stays on your machine and is used only to query your own usage, but this is your call to make, not ours. If you are not comfortable with it, the token history features still work without it — only the session and weekly percentages will be unavailable.

## Configuration

Configuration file: `~/.local/share/aipulse/config.json`

| Key | Type | Values | Default | Meaning |
|---|---|---|---|---|
| `activeProvider` | string | `"claude"`, `"codex"` | `"claude"` | Which provider to display in bar metrics |
| `barMetric` | string | `"weekly"`, `"session"`, `"tokens"` | `"weekly"` | What to show in menu bar: percent to limit or token count |
| `barStyle` | string | `"percentage"`, `"compact"`, `"progressBar"`, `"batteryClassic"`, `"iconWithBar"` | `"percentage"` | Menu bar appearance: text only, dot, bar, battery icon, or icon+text |
| `workDays` | int | 1–7 | 5 | Days per week to use for "daily budget" calculations |
| `refreshMinutes` | int | 5, 10, 15, 30, 60 | 5 | Interval for launchd collection (minutes) |
| `language` | string | `"cs"`, `"en"` | `"cs"` | UI language |
| `historyPeriod` | string | `"day"`, `"week"`, `"month"` | `"week"` | Default view in history tab |

Example:

```json
{
  "activeProvider": "claude",
  "barMetric": "weekly",
  "barStyle": "percentage",
  "language": "en",
  "refreshMinutes": 5,
  "workDays": 5,
  "historyPeriod": "week"
}
```

## Uninstalling

```bash
launchctl bootout "gui/$(id -u)/cz.chuchy.aipulse-collect"
rm -f ~/Library/LaunchAgents/cz.chuchy.aipulse-collect.plist
rm -rf /Applications/AIPulse.app
rm -rf ~/.local/share/aipulse
```

Remove the plist as well, not just the loaded job: `bootout` only unloads it for
this session, so a leftover file gets picked up again at the next login and keeps
running a collector that is no longer there.

Or from the app: Settings → Log Out (removes OAuth session) → quit app → manually delete as above.

## Troubleshooting

**Everything reads zero, history is empty**
- Most often `ccusage` is not installed globally: run `ccusage --version`, and if
  the shell cannot find it, `npm install -g ccusage`
- `collect.sh` records what failed in `~/.local/share/aipulse/collect.log` and in
  the `errors` array of `data.json`; the app does not surface that array yet, so
  read it there

**"Data se nepodařilo načíst" / "Could not load data"**
- Ensure `~/.local/share/aipulse/data.json` exists and is valid JSON
- Run `cat ~/.local/share/aipulse/data.json | jq .` to validate
- Run `~/.local/share/aipulse/collect.sh` manually and check `~/.local/share/aipulse/collect.log`

**No limits showing (percent displays as 0%)**
- Ensure Claude Code is logged in: `claude auth status`
- Run `~/.local/share/aipulse/refresh-limits.sh` manually
- Check `~/.local/share/aipulse/stderr.log` and `stdout.log` for launchd errors

**Launchd not running**
- Check status: `launchctl list cz.chuchy.aipulse-collect`
- View logs: `log stream --predicate 'process == "bash"' --level debug`

**Very old data**
- Increase refresh frequency in Settings → Frequency
- Or run `~/.local/share/aipulse/collect.sh` manually

## License

MIT — Jan Chuchvalec, 2026.
