#!/bin/bash
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

DATA_DIR="$HOME/.local/share/aipulse"
DATA_FILE="$DATA_DIR/data.json"
LOG_FILE="$DATA_DIR/collect.log"

log() { echo "[$(date -Iseconds)] limits: $1" >> "$LOG_FILE"; }

read_token() {
  security find-generic-password -s "AIPulse-credentials" -a "aipulse" -w 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null
}

TOKEN=$(read_token)

if [ -z "${TOKEN:-}" ]; then
  log "FAILED no-token"
  echo "AIPulse nema vlastni prihlaseni, spust: python3 ~/.local/share/aipulse/oauth-login.py" >&2
  exit 1
fi

# Keeping the token alive is ensure-token.sh's job, because collect.sh needs the
# same thing. With no way to refresh there is no point asking for limits: a dead
# token earns a 401.
if ! "$DATA_DIR/ensure-token.sh"; then
  log "FAILED expired"
  echo "AUTH_EXPIRED" >&2
  exit 1
fi

# After a refresh the Keychain holds a different token than the one read above.
TOKEN=$(read_token)

if [ -z "${TOKEN:-}" ]; then
  log "FAILED no-token"
  echo "AUTH_EXPIRED" >&2
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
