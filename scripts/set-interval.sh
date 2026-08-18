#!/bin/bash
set -e

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <minutes>"
    exit 1
fi

minutes=$1
# Guard the arithmetic expansion below: bash evaluates its operand, so a
# non-numeric argument is more than just a wrong number.
if ! [[ "$minutes" =~ ^[0-9]+$ ]] || [[ "$minutes" -lt 1 ]]; then
    echo "Error: interval must be a whole number of minutes, got '$minutes'"
    exit 1
fi

seconds=$((minutes * 60))
plist="$HOME/Library/LaunchAgents/cz.chuchy.aipulse-collect.plist"

if [[ ! -f "$plist" ]]; then
    echo "Error: plist not found at $plist"
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :StartInterval $seconds" "$plist"

launchctl bootout "gui/$(id -u)/cz.chuchy.aipulse-collect" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"

echo "Interval updated to $minutes minute(s) ($seconds seconds)"
