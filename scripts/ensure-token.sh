#!/bin/bash
set -uo pipefail

# Jediné místo, které se stará o to, aby byl přihlašovací token živý.
#
# Dřív ho nehlídal nikdo. Access token žije osm hodin, sběr běží pořád — takže
# stačilo, aby Mac přes noc spal, a ráno se limity přestaly načítat. Nevypadalo
# to jako porucha: collect.sh nechává při vypršení svítit poslední známé číslo,
# takže to působilo, jako by limity nenaskočily zpátky na nulu.
#
# Obnova existovala od začátku (oauth-login.py --refresh), jen ji nikdo nevolal.
#
# Volají to dvě cesty, refresh-limits.sh a collect.sh. Obě smí volat kdykoli:
# když je token v pořádku, tenhle skript neudělá nic.
#
# Návratový kód: 0 = token je použitelný, 1 = není a je potřeba se přihlásit.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/.local/share/aipulse"
LOG_FILE="$DATA_DIR/collect.log"

# Značka „o tomhle už jsem řekl". Bez ní by upozornění chodilo každých pět minut
# a člověk by ho po půl dni odklikával bez čtení.
ALERT_MARKER="$DATA_DIR/.token-alert"

# O kolik dřív se obnovuje, než token vyprší. Dva intervaly sběru — kdyby se
# čekalo až na vypršení, jeden běh by pokaždé propadl na hraně.
MARGIN=600

# Stopka po odmítnutém refresh tokenu. Obsahuje otisk (sha256) toho tokenu:
# dokud je v klíčence pořád on, další pokus by jen znovu dostal invalid_grant.
# Jiný otisk znamená nové přihlášení a zkouší se znovu.
DEAD_MARKER="$DATA_DIR/.token-dead"

# Připomínka před koncem přihlášení. Server ho po zhruba 27 dnech zahodí celé
# a obnova ho neprodlouží (18. 9. 2026 vypršelo po přihlášení z 22. 8.).
# Kdy přesně, v odpovědi neříká, takže se počítá od času přihlášení.
SIGNED_IN_FILE="$DATA_DIR/.signed-in-at"
REMIND_MARKER="$DATA_DIR/.token-reminder"
REMIND_AFTER=$(( 24 * 86400 ))

log() { echo "[$(date -Iseconds)] token: $1" >> "$LOG_FILE"; }

# Text je vždycky literál, nikdy nic z odpovědi serveru — do osascriptu se nemá
# co dostat cizí řetězec.
alert_once() {
    [ -f "$ALERT_MARKER" ] && return 0
    nohup bash -c '
        out=$(osascript -e "$1" 2>/dev/null)
        case "$out" in
            *"button returned:Přihlásit"*) python3 "$2" ;;
        esac
    ' _ 'display dialog "Vypršelo přihlášení, limity se přestaly načítat." with title "AIPulse" buttons {"Později", "Přihlásit"} default button "Přihlásit" giving up after 3600' "$SCRIPT_DIR/login.py" >/dev/null 2>&1 &
    : > "$ALERT_MARKER"
}

# Druhá půlka je stejně důležitá jako první: značka, která se nikdy nesmaže,
# umlčí i příští poruchu.
alert_clear() {
    [ -f "$ALERT_MARKER" ] || return 0
    rm -f "$ALERT_MARKER"
    osascript -e 'display notification "Přihlášení je zpátky, limity se zase načítají." with title "AIPulse"' >/dev/null 2>&1
}

# Jednou za přihlášení; značku maže až oauth-login.py při novém přihlášení.
remind_if_due() {
    [ -f "$REMIND_MARKER" ] && return 0
    local since
    since=$(cat "$SIGNED_IN_FILE" 2>/dev/null || true)
    [[ "$since" =~ ^[0-9]+$ ]] || return 0
    local age=$(( $(date +%s) - since ))
    [ "$age" -ge "$REMIND_AFTER" ] || return 0
    osascript -e 'display notification "Přihlášení za pár dní vyprší. Přihlas se znovu v aplikaci AIPulse." with title "AIPulse" sound name "Glass"' >/dev/null 2>&1
    : > "$REMIND_MARKER"
    log "připomínka: přihlášení je staré $(( age / 86400 )) dní"
}

# Vteřiny do vypršení. Když záznam chybí nebo se nedá přečíst, vyjde 0 — tedy
# „vypršelo", což je bezpečnější odhad než „platí".
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

# Otisk refresh tokenu pro stopku. Samotný token se nikam nezapisuje.
refresh_fingerprint() {
    security find-generic-password -s "AIPulse-credentials" -a "aipulse" -w 2>/dev/null \
        | python3 -c "
import sys, json, hashlib
try:
    token = json.load(sys.stdin)['claudeAiOauth'].get('refreshToken')
    if token:
        print(hashlib.sha256(token.encode()).hexdigest())
except Exception:
    pass
" 2>/dev/null
}

# Refresh token je jednorázový a při použití se otáčí. Kdo obnoví druhý, najde
# ten svůj už spotřebovaný — a přijde tím o přihlášení. Přesně tak to dopadlo
# 21. 8. 2026 (viz komentář v oauth-login.py); tehdejší oprava jen oddělila
# záznam od Claude Code, souběh uvnitř aipulse nechránila.
#
# A souběh tu reálně hrozí: tenhle skript volá jak collect.sh z plánovače v aplikaci, tak
# refresh-limits.sh, který si spouští sama aplikace AIPulse.app.
#
# mkdir je atomické a macOS nemá flock(1) — stejný postup jako zámek sběru
# v collect.sh.
LOCK_DIR="$DATA_DIR/.token-lock"

release_lock() { rm -rf "$LOCK_DIR"; }

# Čeká, místo aby to vzdal: kdo se sem dostane, token potřebuje. Když čekání
# vyprší, vrátí 1 a volající se rozhodne podle toho, jak je na tom token teď.
acquire_lock() {
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        local owner
        owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            log "uklízím zámek po mrtvém běhu (pid $owner)"
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

remind_if_due

LEFT=$(seconds_left)
[ -z "${LEFT:-}" ] && LEFT=0

if [ "$LEFT" -ge "$MARGIN" ]; then
    alert_clear
    exit 0
fi

# Mrtvý token se znovu nezkouší. Upozornění už odešlo, když stopka vznikla.
if [ -f "$DEAD_MARKER" ]; then
    if [ "$(cat "$DEAD_MARKER" 2>/dev/null)" = "$(refresh_fingerprint)" ]; then
        exit 1
    fi
    rm -f "$DEAD_MARKER"
fi

if ! acquire_lock; then
    # Někdo jiný obnovuje déle než půl minuty. Nepřidávat se k němu druhým
    # pokusem: dva refreshe jsou přesně ta chyba, které se tenhle zámek brání.
    LEFT=$(seconds_left)
    [ -z "${LEFT:-}" ] && LEFT=0
    if [ "$LEFT" -ge "$MARGIN" ]; then
        alert_clear
        exit 0
    fi
    log "obnovu drží jiný běh, přeskakuji"
    exit 1
fi

# Znovu, už pod zámkem: mezi první kontrolou a jeho získáním mohl token obnovit
# někdo jiný. Bez téhle druhé kontroly by se refresh token spotřeboval dvakrát
# za sebou, jen o vteřinu později — což je ta samá chyba, jen hůř k nalezení.
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

log "vyprší za ${LEFT} s, obnovuji"

# Token si oauth-login.py čte i zapisuje sám do klíčenky; nepředává se přes
# argumenty ani prostředí, protože argv je čitelné přes ps. Výstup se zachytává,
# protože skript hlásí i úspěch na stderr a v logu z toho byl řádek bez značky.
refresh_err=$(python3 "$SCRIPT_DIR/oauth-login.py" --refresh 2>&1 >/dev/null)
refresh_rc=$?

if [ $refresh_rc -ne 0 ]; then
    # Odmítnutý refresh token sám od sebe fungovat nezačne. Odlišuje se od
    # „vypršelo", aby bylo z logu poznat, jestli stačí počkat, nebo se přihlásit.
    log "FAILED refresh"
    [ -n "${refresh_err:-}" ] && log "$(printf '%s' "$refresh_err" | tail -1)"
    # Kód 2 = server token odmítl. Stopka zabrání dalším pokusům do přihlášení.
    if [ $refresh_rc -eq 2 ]; then
        refresh_fingerprint > "$DEAD_MARKER"
        log "přihlášení vypršelo, další pokusy stojí do nového přihlášení"
    fi
    alert_once
    exit 1
fi

LEFT=$(seconds_left)
[ -z "${LEFT:-}" ] && LEFT=0
log "obnoven, platí ještě ${LEFT} s"
alert_clear
exit 0
