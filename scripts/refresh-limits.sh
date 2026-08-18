#!/bin/bash
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

DATA_DIR="$HOME/.local/share/aipulse"
DATA_FILE="$DATA_DIR/data.json"
LOG_FILE="$DATA_DIR/collect.log"

log() { echo "[$(date -Iseconds)] limits: $1" >> "$LOG_FILE"; }

TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)

if [ -z "${TOKEN:-}" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
  TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken'])" 2>/dev/null)
fi

if [ -z "${TOKEN:-}" ]; then
  log "FAILED no-token"
  echo "No Claude Code credentials available" >&2
  exit 1
fi

BODY_FILE=$(mktemp)
# The token is passed on stdin, never as a process argument: argv is world-readable via ps.
if ! printf '%s' "$TOKEN" | python3 "$DATA_DIR/fetch-usage.py" "$BODY_FILE"; then
  log "FAILED request"
  rm -f "$BODY_FILE"
  echo "Usage request failed, see $LOG_FILE" >&2
  exit 1
fi

python3 "$DATA_DIR/apply-limits.py" "$BODY_FILE" "$DATA_FILE"
RC=$?
rm -f "$BODY_FILE"

[ $RC -eq 0 ] && log "OK" || log "FAILED write"
exit $RC
