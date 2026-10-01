#!/bin/zsh
#
# Watches ~/Downloads for .ovpn files, moves them into ~/vmShared, and
# prunes .ovpn files in ~/vmShared older than 24 hours. Runs continuously,
# checking once per second. Managed by the com.riwaj.ovpnwatch LaunchAgent.

set -u

DOWNLOADS="$HOME/Downloads"
DEST="$HOME/vmShared"
LOG="$HOME/Library/Logs/ovpn-watch.log"

mkdir -p "$DEST"
mkdir -p "$(dirname "$LOG")"

log() {
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

while true; do
    # Move any .ovpn files (case-insensitive) from Downloads to vmShared.
    setopt local_options nullglob nocaseglob
    for f in "$DOWNLOADS"/*.ovpn; do
        base="${f:t}"
        target="$DEST/$base"
        if [[ -e "$target" ]]; then
            target="$DEST/${base%.*}_$(date +%Y%m%d%H%M%S).${base##*.}"
        fi
        if mv "$f" "$target" 2>>"$LOG"; then
            log "moved $base -> $target"
        else
            log "ERROR moving $base"
        fi
    done

    # Delete .ovpn files in vmShared older than 24 hours (1440 minutes).
    find "$DEST" -maxdepth 1 -type f -iname '*.ovpn' -mmin +1440 -print 2>>"$LOG" | while IFS= read -r old; do
        if rm -f "$old" 2>>"$LOG"; then
            log "deleted (>24h old) ${old:t}"
        fi
    done

    sleep 1
done
