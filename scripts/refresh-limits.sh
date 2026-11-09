#!/bin/bash
# Scripts live in the signed app bundle; bytecode caches there would break the signature.
export PYTHONDONTWRITEBYTECODE=1
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  echo "AIPulse nema vlastni prihlaseni, prihlas se v aplikaci AIPulse." >&2
  exit 1
fi

# O živý token se stará ensure-token.sh, protože totéž potřebuje i collect.sh.
# Když se obnovit nedá, nemá smysl se ptát na limity — skončí to 401.
if ! "$SCRIPT_DIR/ensure-token.sh"; then
  log "FAILED expired"
  echo "AUTH_EXPIRED" >&2
  exit 1
fi

# Po obnově je v klíčence jiný token než ten přečtený výš.
TOKEN=$(read_token)

if [ -z "${TOKEN:-}" ]; then
  log "FAILED no-token"
  echo "AUTH_EXPIRED" >&2
  exit 1
fi

BODY_FILE=$(mktemp)
# The token is passed on stdin, never as a process argument: argv is world-readable via ps.
if ! printf '%s' "$TOKEN" | python3 "$SCRIPT_DIR/fetch-usage.py" "$BODY_FILE"; then
  log "FAILED request"
  rm -f "$BODY_FILE"
  echo "Usage request failed, see $LOG_FILE" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/apply-limits.py" "$BODY_FILE" "$DATA_FILE"
RC=$?
rm -f "$BODY_FILE"

[ $RC -eq 0 ] && log "OK" || log "FAILED write"
exit $RC
