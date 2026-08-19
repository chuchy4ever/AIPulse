#!/bin/bash

set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# launchd runs with a minimal environment, so a node installed via nvm is not on PATH.
# Take the newest version that actually carries ccusage - older ones are still on disk.
if ! command -v ccusage >/dev/null 2>&1 && [ -d "$HOME/.nvm/versions/node" ]; then
  for candidate in $(ls -d "$HOME/.nvm/versions/node"/*/bin 2>/dev/null | sort -Vr); do
    if [ -x "$candidate/ccusage" ]; then
      PATH="$candidate:$PATH"
      export PATH
      break
    fi
  done
fi

DATA_DIR="$HOME/.local/share/aipulse"
LOG_FILE="$DATA_DIR/collect.log"
TMP_FILE="$DATA_DIR/data.json.tmp"
DATA_FILE="$DATA_DIR/data.json"
TMP_WEEKLY="$DATA_DIR/.tmp.weekly.json"
TMP_DAILY="$DATA_DIR/.tmp.daily.json"
TMP_MONTHLY="$DATA_DIR/.tmp.monthly.json"
TMP_CODEX="$DATA_DIR/.tmp.codex.json"
TMP_ANTHROPIC="$DATA_DIR/.tmp.anthropic.json"
TMP_OPENAI="$DATA_DIR/.tmp.openai.json"

mkdir -p "$DATA_DIR"

{
  echo "[$(date -Iseconds)] Starting collection..."

  ERRORS_FILE="$DATA_DIR/.tmp.errors.json"
  echo "[]" > "$ERRORS_FILE"

  if ccusage weekly --json > "$TMP_WEEKLY" 2>> "$LOG_FILE"; then
    echo "[$(date -Iseconds)] Claude weekly: OK"
  else
    ERROR_MSG="Claude weekly failed"
    echo "[$(date -Iseconds)] ERROR: $ERROR_MSG"
    python3 << EOF
import json
with open("$ERRORS_FILE", 'r') as f:
    errors = json.load(f)
errors.append("$ERROR_MSG")
with open("$ERRORS_FILE", 'w') as f:
    json.dump(errors, f)
EOF
    echo "{\"totals\": {}, \"weekly\": []}" > "$TMP_WEEKLY"
  fi

  if ccusage daily --json > "$TMP_DAILY" 2>> "$LOG_FILE"; then
    echo "[$(date -Iseconds)] Claude daily: OK"
  else
    ERROR_MSG="Claude daily failed"
    echo "[$(date -Iseconds)] ERROR: $ERROR_MSG"
    python3 << EOF
import json
with open("$ERRORS_FILE", 'r') as f:
    errors = json.load(f)
errors.append("$ERROR_MSG")
with open("$ERRORS_FILE", 'w') as f:
    json.dump(errors, f)
EOF
    echo "{\"daily\": []}" > "$TMP_DAILY"
  fi

  if ccusage monthly --json > "$TMP_MONTHLY" 2>> "$LOG_FILE"; then
    echo "[$(date -Iseconds)] Claude monthly: OK"
  else
    ERROR_MSG="Claude monthly failed"
    echo "[$(date -Iseconds)] ERROR: $ERROR_MSG"
    python3 << EOF
import json
with open("$ERRORS_FILE", 'r') as f:
    errors = json.load(f)
errors.append("$ERROR_MSG")
with open("$ERRORS_FILE", 'w') as f:
    json.dump(errors, f)
EOF
    echo "{\"monthly\": []}" > "$TMP_MONTHLY"
  fi

  if ccusage codex daily --json > "$TMP_CODEX" 2>> "$LOG_FILE"; then
    echo "[$(date -Iseconds)] Codex daily: OK"
  else
    ERROR_MSG="Codex daily failed"
    echo "[$(date -Iseconds)] ERROR: $ERROR_MSG"
    python3 << EOF
import json
with open("$ERRORS_FILE", 'r') as f:
    errors = json.load(f)
errors.append("$ERROR_MSG")
with open("$ERRORS_FILE", 'w') as f:
    json.dump(errors, f)
EOF
    echo "{\"daily\": []}" > "$TMP_CODEX"
  fi

  if curl -fsSL --max-time 10 https://status.claude.com/api/v2/summary.json > "$TMP_ANTHROPIC" 2>&1; then
    echo "[$(date -Iseconds)] Anthropic status: OK"
  else
    echo "[$(date -Iseconds)] Anthropic status: FAILED (network/timeout)"
    echo "{}" > "$TMP_ANTHROPIC"
  fi

  if curl -fsS --max-time 10 https://status.openai.com/api/v2/summary.json > "$TMP_OPENAI" 2>&1; then
    echo "[$(date -Iseconds)] OpenAI status: OK"
  else
    echo "[$(date -Iseconds)] OpenAI status: FAILED (network/timeout)"
    echo "{}" > "$TMP_OPENAI"
  fi

  # macOS has no timeout(1), and a CLI that hangs would keep this launchd job
  # alive forever, so bound both auth probes with perl's alarm.
  run_bounded() {
    perl -e 'alarm shift; exec @ARGV' "$@" 2>/dev/null || true
  }

  # codex login status reports on stderr, so dropping it would always read as
  # "not logged in"; both streams are merged and parsed as plain text.
  run_bounded_merged() {
    perl -e 'alarm shift; exec @ARGV' "$@" 2>&1 || true
  }

  CLAUDE_PATH=$(command -v claude 2>/dev/null || true)
  if [ -n "$CLAUDE_PATH" ]; then
    AUTH_OUTPUT=$(run_bounded 10 "$CLAUDE_PATH" auth status)
    [ -n "$AUTH_OUTPUT" ] || AUTH_OUTPUT='{"loggedIn": false}'
    echo "$AUTH_OUTPUT" > "$DATA_DIR/.tmp.auth.json"
  else
    echo '{"loggedIn": false}' > "$DATA_DIR/.tmp.auth.json"
  fi

  CODEX_PATH=$(command -v codex 2>/dev/null || true)
  if [ -n "$CODEX_PATH" ]; then
    run_bounded_merged 10 "$CODEX_PATH" login status > "$DATA_DIR/.tmp.codex.auth.txt"
  else
    echo "" > "$DATA_DIR/.tmp.codex.auth.txt"
  fi

  echo "[$(date -Iseconds)] Aggregating data via Python..."

} >> "$LOG_FILE" 2>&1


python3 << 'PYTHON_SCRIPT' > "$TMP_FILE" 2>> "$LOG_FILE"
import json
import sys
import urllib.request
import urllib.error
import subprocess
from datetime import datetime, timezone, timedelta
from collections import defaultdict
import os

data_dir = os.path.expanduser("~/.local/share/aipulse")

def fetch_api_limits(old_limits=None):
    """Fetch session and weekly limits from Anthropic API."""
    def get_api_token():
        try:
            result = subprocess.run(
                ['security', 'find-generic-password', '-s', 'Claude Code-credentials', '-w'],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                try:
                    creds = json.loads(result.stdout.strip())
                    return creds.get('claudeAiOauth', {}).get('accessToken')
                except:
                    pass
        except:
            pass

        try:
            creds_path = os.path.expanduser('~/.claude/.credentials.json')
            if os.path.exists(creds_path):
                with open(creds_path) as f:
                    creds = json.load(f)
                    return creds.get('claudeAiOauth', {}).get('accessToken')
        except:
            pass

        return None

    if old_limits is None:
        old_limits = {}

    # A failed fetch must not wipe limits that are already on disk: the app would
    # show an empty gauge until the next successful run, and a 429 is routine.
    def keep_previous():
        if old_limits.get('session') or old_limits.get('weekly'):
            return {
                'session': old_limits.get('session'),
                'weekly': old_limits.get('weekly'),
                'fetchedAt': old_limits.get('fetchedAt'),
            }
        return None

    token = get_api_token()
    if not token:
        print(f"[{datetime.now(timezone.utc).isoformat()}] Limits: No token available", file=sys.stderr)
        return keep_previous()

    try:
        url = 'https://api.anthropic.com/api/oauth/usage'
        headers = {
            'Authorization': f'Bearer {token}',
            'anthropic-beta': 'oauth-2025-04-20'
        }
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as response:
            limits_raw = json.load(response)

            session_limit = None
            weekly_limit = None

            for limit in limits_raw.get('limits', []):
                if limit.get('kind') == 'session':
                    session_limit = limit
                elif limit.get('kind') == 'weekly_all':
                    weekly_limit = limit

            limits = {}

            if session_limit:
                limits['session'] = {
                    'percent': session_limit.get('percent'),
                    'resetsAt': limits_raw.get('five_hour', {}).get('resets_at')
                }
            else:
                limits['session'] = old_limits.get('session')

            if weekly_limit:
                limits['weekly'] = {
                    'percent': weekly_limit.get('percent'),
                    'resetsAt': limits_raw.get('seven_day', {}).get('resets_at')
                }
            else:
                limits['weekly'] = old_limits.get('weekly')

            if limits.get('session') or limits.get('weekly'):
                limits['fetchedAt'] = datetime.now(timezone.utc).isoformat()
                print(f"[{datetime.now(timezone.utc).isoformat()}] Limits: OK", file=sys.stderr)
                return limits
            else:
                print(f"[{datetime.now(timezone.utc).isoformat()}] Limits: FAILED no limits in response or fallback", file=sys.stderr)
                return None
    except urllib.error.HTTPError as e:
        print(f"[{datetime.now(timezone.utc).isoformat()}] Limits: FAILED {e.code}", file=sys.stderr)
        return keep_previous()
    except Exception as e:
        print(f"[{datetime.now(timezone.utc).isoformat()}] Limits: FAILED {type(e).__name__}", file=sys.stderr)
        return keep_previous()

def safe_load_json(filepath):
    try:
        with open(filepath, 'r') as f:
            return json.load(f)
    except:
        return {}

def process_service_status(status_raw):
    """Extract status, components (with id), and incidents from summary.json."""
    result = {
        "status": {},
        "components": [],
        "incidents": []
    }
    if not status_raw:
        return result
    if "status" in status_raw:
        result["status"] = status_raw["status"]
    if "components" in status_raw:
        for comp in status_raw["components"]:
            if not comp.get("group", False):
                result["components"].append({
                    "id": comp.get("id"),
                    "name": comp.get("name", ""),
                    "status": comp.get("status", "unknown")
                })
    if "incidents" in status_raw:
        for incident in status_raw["incidents"]:
            result["incidents"].append({
                "name": incident.get("name", ""),
                "status": incident.get("status", ""),
                "impact": incident.get("impact", "")
            })
    return result

old_data = safe_load_json(os.path.join(data_dir, "data.json"))
old_limits = old_data.get("limits") or {}

claude_weekly_data = safe_load_json(os.path.join(data_dir, ".tmp.weekly.json"))
if not claude_weekly_data:
    claude_weekly_data = {"totals": {}, "weekly": []}

claude_daily_data = safe_load_json(os.path.join(data_dir, ".tmp.daily.json"))
if not claude_daily_data:
    claude_daily_data = {"daily": []}

claude_monthly_data = safe_load_json(os.path.join(data_dir, ".tmp.monthly.json"))
if not claude_monthly_data:
    claude_monthly_data = {"monthly": []}

codex_daily_data = safe_load_json(os.path.join(data_dir, ".tmp.codex.json"))
if not codex_daily_data:
    codex_daily_data = {"daily": []}

anthropic_status_raw = safe_load_json(os.path.join(data_dir, ".tmp.anthropic.json"))
anthropic_result = process_service_status(anthropic_status_raw)

openai_status_raw = safe_load_json(os.path.join(data_dir, ".tmp.openai.json"))
openai_result = process_service_status(openai_status_raw)

errors_json = safe_load_json(os.path.join(data_dir, ".tmp.errors.json"))
if not errors_json:
    errors_json = []

def parse_codex_login_status(output):
    """Parse 'codex login status' output into auth dict."""
    result = {"loggedIn": False}
    if "Logged in" in output:
        result["loggedIn"] = True
        if "API key" in output:
            result["method"] = "API key"
        elif "ChatGPT" in output:
            result["method"] = "ChatGPT"
        else:
            result["method"] = None
        parts = output.split(" - ")
        if len(parts) > 1:
            account = parts[-1].strip()
            if "***" in account:
                result["account"] = account
            else:
                result["account"] = None
        else:
            result["account"] = None
    return result

claude_auth = {}
try:
    auth_file = os.path.join(data_dir, ".tmp.auth.json")
    if os.path.exists(auth_file):
        with open(auth_file, 'r') as f:
            auth_output = f.read().strip()
            if auth_output:
                try:
                    claude_auth = json.loads(auth_output)
                except:
                    claude_auth = {"loggedIn": False}
except:
    claude_auth = {"loggedIn": False}

codex_auth = {"loggedIn": False}
try:
    codex_auth_file = os.path.join(data_dir, ".tmp.codex.auth.txt")
    if os.path.exists(codex_auth_file):
        with open(codex_auth_file, 'r') as f:
            codex_output = f.read().strip()
            if codex_output:
                codex_auth = parse_codex_login_status(codex_output)
except:
    codex_auth = {"loggedIn": False}

config_file = os.path.join(data_dir, "config.json")
active_provider = "claude"
try:
    with open(config_file, 'r') as f:
        config = json.load(f)
        active_provider = config.get("activeProvider", "claude")
except:
    pass

generated_at = datetime.now(timezone.utc).isoformat()

limits = fetch_api_limits(old_limits)

output = {
    "generatedAt": generated_at,
    "activeProvider": active_provider,
    "limits": limits,
    "claude": {
        "totals": claude_weekly_data.get("totals", {}),
        "weeklyData": claude_weekly_data.get("weekly", []),
        "dailyData": claude_daily_data.get("daily", []),
        "monthlyData": claude_monthly_data.get("monthly", [])
    },
    "codex": {
        "dailyData": codex_daily_data.get("daily", [])
    },
    "services": {
        "anthropic": anthropic_result,
        "openai": openai_result
    },
    "auth": {
        "claude": claude_auth,
        "codex": codex_auth
    },
    "errors": errors_json
}

by_day_of_week = defaultdict(lambda: {"name": "", "tokens": 0, "cost": 0, "entries": 0})
day_names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

for entry in claude_daily_data.get("daily", []):
    date_str = entry.get("period", "")
    if date_str:
        try:
            dt = datetime.fromisoformat(date_str)
            day_idx = dt.weekday()
            day_name = day_names[day_idx]
            by_day_of_week[day_idx]["name"] = day_name
            by_day_of_week[day_idx]["tokens"] += entry.get("totalTokens", 0)
            by_day_of_week[day_idx]["cost"] += entry.get("totalCost", 0)
            by_day_of_week[day_idx]["entries"] += 1
        except:
            pass

output["aggregations"] = {
    "byDayOfWeek": [by_day_of_week.get(i, {"name": day_names[i], "tokens": 0, "cost": 0, "entries": 0}) for i in range(7)]
}

by_model = defaultdict(lambda: {"tokens": 0, "cost": 0})

for entry in claude_daily_data.get("daily", []):
    for model_breakdown in entry.get("modelBreakdowns", []):
        model_name = model_breakdown.get("modelName", "unknown")
        total = model_breakdown.get("totalTokens", 0)
        if total == 0:
            total = (model_breakdown.get("inputTokens", 0) +
                    model_breakdown.get("outputTokens", 0) +
                    model_breakdown.get("cacheReadTokens", 0) +
                    model_breakdown.get("cacheCreationTokens", 0))
        by_model[model_name]["tokens"] += total
        by_model[model_name]["cost"] += model_breakdown.get("cost", 0)

output["aggregations"]["byModel"] = [
    {"model": k, "tokens": v["tokens"], "cost": v["cost"]}
    for k, v in sorted(by_model.items(), key=lambda x: x[1]["tokens"], reverse=True)
]

current_week_by_model = defaultdict(lambda: {"tokens": 0, "cost": 0})
if claude_weekly_data.get("weekly"):
    last_week_entry = claude_weekly_data["weekly"][-1]
    for model_breakdown in last_week_entry.get("modelBreakdowns", []):
        model_name = model_breakdown.get("modelName", "unknown")
        total = model_breakdown.get("totalTokens", 0)
        if total == 0:
            total = (model_breakdown.get("inputTokens", 0) +
                    model_breakdown.get("outputTokens", 0) +
                    model_breakdown.get("cacheReadTokens", 0) +
                    model_breakdown.get("cacheCreationTokens", 0))
        current_week_by_model[model_name]["tokens"] += total
        current_week_by_model[model_name]["cost"] += model_breakdown.get("cost", 0)

output["aggregations"]["currentWeekByModel"] = [
    {"model": k, "tokens": v["tokens"], "cost": v["cost"]}
    for k, v in sorted(current_week_by_model.items(), key=lambda x: x[1]["tokens"], reverse=True)
]

# Compute currentWeekByDayOfWeek — aggregation for days in the active weekly window
current_week_by_day_of_week = None
if limits:
    try:
        reset_at_str = limits.get('weekly', {}).get('resetsAt')
        if reset_at_str:
            reset_at = datetime.fromisoformat(reset_at_str.replace('Z', '+00:00'))
            window_start = reset_at - timedelta(days=7)

            by_day_in_window = defaultdict(lambda: {"name": "", "tokens": 0, "cost": 0, "entries": 0})
            for entry in claude_daily_data.get("daily", []):
                date_str = entry.get("period", "")
                if date_str:
                    try:
                        dt = datetime.fromisoformat(date_str)
                        # Treat bare dates as UTC
                        if dt.tzinfo is None:
                            dt = dt.replace(tzinfo=timezone.utc)
                        if dt >= window_start and dt < reset_at:
                            day_idx = dt.weekday()
                            day_name = day_names[day_idx]
                            by_day_in_window[day_idx]["name"] = day_name
                            by_day_in_window[day_idx]["tokens"] += entry.get("totalTokens", 0)
                            by_day_in_window[day_idx]["cost"] += entry.get("totalCost", 0)
                            by_day_in_window[day_idx]["entries"] += 1
                    except:
                        pass

            current_week_by_day_of_week = [
                by_day_in_window.get(i, {"name": day_names[i], "tokens": 0, "cost": 0, "entries": 0})
                for i in range(7)
            ]
    except:
        pass

output["aggregations"]["currentWeekByDayOfWeek"] = current_week_by_day_of_week

# Compute Codex totals from daily data
codex_totals = {
    "inputTokens": 0,
    "outputTokens": 0,
    "cacheCreationTokens": 0,
    "cacheReadTokens": 0,
    "totalTokens": 0,
    "totalCost": 0.0
}
for entry in codex_daily_data.get("daily", []):
    codex_totals["inputTokens"] += entry.get("inputTokens", 0)
    codex_totals["outputTokens"] += entry.get("outputTokens", 0)
    codex_totals["cacheCreationTokens"] += entry.get("cacheCreationTokens", 0)
    codex_totals["cacheReadTokens"] += entry.get("cacheReadTokens", 0)
    codex_totals["totalTokens"] += entry.get("totalTokens", 0)
    codex_totals["totalCost"] += entry.get("costUSD", 0)

output["codex"]["totals"] = codex_totals

weekly_history = []
week_map = defaultdict(lambda: {"tokens": 0, "cost": 0})

for entry in claude_weekly_data.get("weekly", []):
    date_str = entry.get("period", "")
    if date_str:
        try:
            dt = datetime.fromisoformat(date_str)
            week_num = dt.isocalendar()[1]
            year = dt.isocalendar()[0]
            week_key = f"{year}-W{week_num}"
            week_map[week_key]["tokens"] += entry.get("totalTokens", 0)
            week_map[week_key]["cost"] += entry.get("totalCost", 0)
        except:
            pass

for week_key in sorted(week_map.keys(), key=lambda w: (int(w.split('-')[0]), int(w.split('-')[1][1:]))):
    weekly_history.append({
        "week": week_key,
        "tokens": week_map[week_key]["tokens"],
        "cost": week_map[week_key]["cost"]
    })

output["aggregations"]["weeklyHistory"] = weekly_history[-12:]

# Build monthly history
monthly_history = []
month_map = defaultdict(lambda: {"tokens": 0, "cost": 0})

for entry in claude_monthly_data.get("monthly", []):
    period_str = entry.get("period", "")
    if period_str:
        try:
            month_key = period_str if len(period_str) >= 7 else ""
            if month_key:
                month_map[month_key]["tokens"] += entry.get("totalTokens", 0)
                month_map[month_key]["cost"] += entry.get("totalCost", 0)
        except:
            pass

for month_key in sorted(month_map.keys()):
    monthly_history.append({
        "month": month_key,
        "tokens": month_map[month_key]["tokens"],
        "cost": month_map[month_key]["cost"]
    })

output["aggregations"]["monthlyHistory"] = monthly_history


print(json.dumps(output, indent=2))
PYTHON_SCRIPT

if [ -s "$TMP_FILE" ]; then
  mv "$TMP_FILE" "$DATA_FILE"
  echo "[$(date -Iseconds)] Data written to $DATA_FILE" >> "$LOG_FILE"
else
  echo "[$(date -Iseconds)] ERROR: $TMP_FILE is empty, not overwriting $DATA_FILE" >> "$LOG_FILE"
  rm -f "$TMP_FILE"
  exit 1
fi

rm -f "$TMP_WEEKLY" "$TMP_DAILY" "$TMP_MONTHLY" "$TMP_CODEX" "$TMP_ANTHROPIC" "$TMP_OPENAI" "$ERRORS_FILE" "$DATA_DIR/.tmp.auth.json" "$DATA_DIR/.tmp.codex.auth.txt"

echo "[$(date -Iseconds)] Collection complete." >> "$LOG_FILE"
