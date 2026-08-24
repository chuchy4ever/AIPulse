#!/bin/bash
set -uo pipefail

# The one place that cares whether the sign-in is still alive.
#
# Nothing used to. An access token lives eight hours and collection runs around
# the clock, so a Mac that sleeps through the night wakes up to limits that no
# longer load. It does not look broken: collect.sh keeps the last known figure on
# screen when the token is gone, so it reads as "the limits never went back to
# zero" rather than "the sign-in died at 02:51".
#
# The renewal existed from the start - oauth-login.py --refresh - and no one
# called it.
#
# Two callers: collect.sh and refresh-limits.sh. Both may call it whenever they
# like; with a healthy token this does nothing.
#
# Exit code: 0 the token is usable, 1 it is not and a sign-in is needed.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

DATA_DIR="$HOME/.local/share/aipulse"
LOG_FILE="$DATA_DIR/collect.log"

# "Already said this once." Without it the notification would arrive every five
# minutes and be dismissed unread by lunchtime.
ALERT_MARKER="$DATA_DIR/.token-alert"

# How far ahead of expiry to renew. Two collection intervals - waiting for the
# token to actually die would cost one failed run every time.
MARGIN=600

log() { echo "[$(date -Iseconds)] token: $1" >> "$LOG_FILE"; }

# The text is always a literal, never anything the server said: no foreign string
# has any business reaching osascript.
alert_once() {
    [ -f "$ALERT_MARKER" ] && return 0
    osascript -e 'display notification "Vypršelo přihlášení, limity se přestaly načítat. Spusť: python3 ~/.local/share/aipulse/oauth-login.py" with title "AIPulse" sound name "Basso"' >/dev/null 2>&1
    : > "$ALERT_MARKER"
}

# The second half matters as much as the first: a marker that is never cleared
# silences the next outage too.
alert_clear() {
    [ -f "$ALERT_MARKER" ] || return 0
    rm -f "$ALERT_MARKER"
    osascript -e 'display notification "Přihlášení je zpátky, limity se zase načítají." with title "AIPulse"' >/dev/null 2>&1
}

# Seconds until expiry. A missing or unreadable record yields 0 - "expired",
# which is the safer guess of the two.
seconds_left() {
    security find-generic-password -s "AIPulse-credentials" -a "aipulse" -w 2>/dev/null \
        | python3 -c "
import sys, json, time
try:
    d = json.load(sys.stdin)['claudeAiOauth']
    print(max(0, int(d.get('expiresAt', 0) / 1000 - time.time())))
except Exception:
    print(0)
" 2>/dev/null
}

has_refresh_token() {
    security find-generic-password -s "AIPulse-credentials" -a "aipulse" -w 2>/dev/null \
        | python3 -c "
import sys, json
try:
    print('yes' if json.load(sys.stdin)['claudeAiOauth'].get('refreshToken') else 'no')
except Exception:
    print('no')
" 2>/dev/null
}

# A refresh token is single-use and rotates as it is spent. Whoever refreshes
# second finds their copy already consumed - and loses the sign-in with it. That
# is exactly how this broke on 2026-08-21; the fix back then only moved the record
# away from Claude Code's, which does nothing about two runs here racing.
#
# And they can race: this is called both by collect.sh from launchd and by
# refresh-limits.sh, which the AIPulse app launches on its own.
#
# mkdir is the atomic primitive available - macOS ships no flock(1) - the same
# approach collect.sh uses for its own lock.
LOCK_DIR="$DATA_DIR/.token-lock"

release_lock() { rm -rf "$LOCK_DIR"; }

# Waits rather than giving up: whoever gets here needs the token. When the wait
# runs out it returns 1 and the caller decides based on the token's actual state.
acquire_lock() {
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        local owner
        owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            log "clearing lock left by a dead run (pid $owner)"
            rm -rf "$LOCK_DIR"
            continue
        fi
        if [ "$waited" -ge 30 ]; then
            return 1
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    echo $$ > "$LOCK_DIR/pid"
    trap release_lock EXIT
    return 0
}

LEFT=$(seconds_left)
[ -z "${LEFT:-}" ] && LEFT=0

if [ "$LEFT" -ge "$MARGIN" ]; then
    alert_clear
    exit 0
fi

if ! acquire_lock; then
    # Someone else has been refreshing for over half a minute. Do not pile on with
    # a second attempt: two refreshes are the precise failure this lock prevents.
    LEFT=$(seconds_left)
    [ -z "${LEFT:-}" ] && LEFT=0
    if [ "$LEFT" -ge "$MARGIN" ]; then
        alert_clear
        exit 0
    fi
    log "another run holds the refresh, skipping"
    exit 1
fi

# Again, now under the lock: between the first check and acquiring it someone else
# may have refreshed. Without this second look the refresh token would be spent
# twice in a row, a second apart - the same bug, only harder to find.
LEFT=$(seconds_left)
[ -z "${LEFT:-}" ] && LEFT=0

if [ "$LEFT" -ge "$MARGIN" ]; then
    alert_clear
    exit 0
fi

if [ "$(has_refresh_token)" != "yes" ]; then
    log "FAILED no-refresh-token"
    alert_once
    exit 1
fi

log "expires in ${LEFT}s, refreshing"

# oauth-login.py reads and writes the Keychain itself; nothing is passed through
# arguments or the environment, because argv is world-readable via ps. Its output
# is captured rather than appended straight to the log: it reports success on
# stderr too, which left a line in the log with no timestamp on it.
refresh_err=$(python3 "$DATA_DIR/oauth-login.py" --refresh 2>&1 >/dev/null)
refresh_rc=$?

if [ $refresh_rc -ne 0 ]; then
    # A refused refresh token will not start working on its own. Told apart from
    # "expired" so the log says whether waiting is enough or a sign-in is due.
    log "FAILED refresh"
    [ -n "${refresh_err:-}" ] && log "$(printf '%s' "$refresh_err" | tail -1)"
    alert_once
    exit 1
fi

LEFT=$(seconds_left)
[ -z "${LEFT:-}" ] && LEFT=0
log "refreshed, good for another ${LEFT}s"
alert_clear
exit 0
