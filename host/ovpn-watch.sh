#!/bin/zsh
#
# Watches ~/Downloads for .ovpn files, moves them into ~/vmShared, and
# prunes .ovpn files in ~/vmShared older than 24 hours. Runs continuously,
# checking once per second, via the com.riwaj.ovpnwatch LaunchAgent.
#
#   Install (run once, by hand):
#       zsh host/ovpn-watch.sh
#
# Also: a `vpninfo` status command, a daily GitHub update check, and log
# trimming to the last 7 days. Never needs sudo — everything here only
# touches files/folders the current user already owns and a user-level
# LaunchAgent.
#
set -u

# Captured at top level, not inside a function: zsh reassigns $0 to the
# current function's name while executing inside one, so ${0:A} would
# resolve to the wrong path if read from within install_mode().
SCRIPT_PATH="${0:A}"

DOWNLOADS="$HOME/Downloads"
DEST="$HOME/vmShared"
BIN_DIR="$HOME/.local/bin"
INSTALL_PATH="$BIN_DIR/ovpn-watch.sh"
VPNINFO_LINK="$BIN_DIR/vpninfo"
STATE_DIR="$HOME/.local/state/ovpn-watch"
STATE_FILE="$STATE_DIR/state"
LOG="$HOME/Library/Logs/ovpn-watch.log"
PLIST_PATH="$HOME/Library/LaunchAgents/com.riwaj.ovpnwatch.plist"
REPO_RAW_URL="https://raw.githubusercontent.com/RiwajMainali/ovpn-auto-switch/main/host/ovpn-watch.sh"

UPDATE_INTERVAL=86400   # seconds between GitHub update checks
LOG_RETENTION_DAYS=7

log() {
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# ---------------------------------------------------------------------------
# Consolidated key=value state file.
# ---------------------------------------------------------------------------
state_get() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    grep "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-
}

state_set() {
    local key="$1" val="$2"
    local tmp="${STATE_FILE}.tmp.$$"
    touch "$STATE_FILE"
    { grep -v "^${key}=" "$STATE_FILE" 2>/dev/null; echo "${key}=${val}"; } > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

set_last_moved() { state_set LAST_MOVED "${1}|$(date +%s)"; }
set_last_deleted() { state_set LAST_DELETED "${1}|$(date +%s)"; }

# ---------------------------------------------------------------------------
# Install mode: run once, by hand. No sudo anywhere in this function.
# ---------------------------------------------------------------------------
install_mode() {
    echo "Installing watcher to $INSTALL_PATH ..."
    mkdir -p "$BIN_DIR"
    install -m 755 "$SCRIPT_PATH" "$INSTALL_PATH"

    echo "Creating vpninfo command..."
    ln -sf "$INSTALL_PATH" "$VPNINFO_LINK"

    echo "Setting up state/log locations..."
    mkdir -p "$STATE_DIR"
    mkdir -p "$(dirname "$LOG")"
    mkdir -p "$DEST"
    touch "$LOG" "$STATE_FILE"

    echo "Writing LaunchAgent..."
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.riwaj.ovpnwatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$INSTALL_PATH</string>
        <string>--watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/ovpn-watch.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/ovpn-watch.err.log</string>
</dict>
</plist>
EOF

    echo "Loading LaunchAgent..."
    launchctl bootout "gui/$(id -u)/com.riwaj.ovpnwatch" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    launchctl enable "gui/$(id -u)/com.riwaj.ovpnwatch"

    sleep 1
    if launchctl print "gui/$(id -u)/com.riwaj.ovpnwatch" 2>/dev/null | grep -q "state = running"; then
        echo "Installed and running."
        echo "Watching $DOWNLOADS every second, moving .ovpn files into $DEST."
        echo "Run 'vpninfo' any time for status. Logs: $LOG"
        echo
        echo "Reminder: ~/Downloads is TCC-protected. If files stop being picked up, grant"
        echo "Full Disk Access to /bin/zsh in System Settings -> Privacy & Security (open -R /bin/zsh)."
    else
        echo "WARNING: LaunchAgent did not report running. Check: launchctl print gui/\$(id -u)/com.riwaj.ovpnwatch" >&2
    fi
}

# ---------------------------------------------------------------------------
# vpninfo
# ---------------------------------------------------------------------------
epoch_to_str() {
    date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

print_vpninfo() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "ovpn-watch: not installed or never run yet."
        return
    fi
    local moved deleted update_check running="no" name epoch
    moved="$(state_get LAST_MOVED)"
    deleted="$(state_get LAST_DELETED)"
    update_check="$(state_get LAST_UPDATE_CHECK)"

    if launchctl print "gui/$(id -u)/com.riwaj.ovpnwatch" 2>/dev/null | grep -q "state = running"; then
        running="yes"
    fi

    echo "ovpn-watch status"
    echo "  running:        $running"
    if [[ -n "$moved" ]]; then
        name="${moved%%|*}"; epoch="${moved##*|}"
        echo "  last moved:     $name at $(epoch_to_str "$epoch")"
    else
        echo "  last moved:     none yet"
    fi
    if [[ -n "$deleted" ]]; then
        name="${deleted%%|*}"; epoch="${deleted##*|}"
        echo "  last deleted:   $name at $(epoch_to_str "$epoch")"
    else
        echo "  last deleted:   none yet"
    fi
    [[ -n "$update_check" ]] && echo "  last update check: $(epoch_to_str "$update_check")"
}

# ---------------------------------------------------------------------------
# Core watch logic.
# ---------------------------------------------------------------------------
tick() {
    setopt local_options nullglob nocaseglob
    local f base target
    for f in "$DOWNLOADS"/*.ovpn; do
        base="${f:t}"
        target="$DEST/$base"
        if [[ -e "$target" ]]; then
            target="$DEST/${base%.*}_$(date +%Y%m%d%H%M%S).${base##*.}"
        fi
        if mv "$f" "$target" 2>>"$LOG"; then
            log "moved $base -> $target"
            set_last_moved "${target:t}"
        else
            log "ERROR moving $base"
        fi
    done

    find "$DEST" -maxdepth 1 -type f -iname '*.ovpn' -mmin +1440 -print 2>>"$LOG" | while IFS= read -r old; do
        if rm -f "$old" 2>>"$LOG"; then
            log "deleted (>24h old) ${old:t}"
            set_last_deleted "${old:t}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Log retention.
# ---------------------------------------------------------------------------
trim_log() {
    local file="$1"
    [[ -f "$file" ]] || return
    local cutoff
    cutoff="$(date -v-${LOG_RETENTION_DAYS}d +%s 2>/dev/null)" || return
    local tmp="${file}.tmp.$$"
    : > "$tmp"
    local line ts epoch
    while IFS= read -r line; do
        ts="${line:0:19}"
        epoch="$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts" +%s 2>/dev/null)"
        if [[ -z "$epoch" ]] || (( epoch >= cutoff )); then
            echo "$line" >> "$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Update check.
# ---------------------------------------------------------------------------
apply_update_and_restart() {
    local tmp="$1"
    cp -f "$INSTALL_PATH" "${INSTALL_PATH}.bak" 2>/dev/null
    install -m 755 "$tmp" "$INSTALL_PATH"
    rm -f "$tmp"
    log "Update applied, scheduling restart..."

    # Restarting the LaunchAgent kills THIS process (it's the one running
    # as that agent). Hand the restart + verify + rollback-if-needed off
    # to a detached helper so it survives past that.
    local helper uid
    uid="$(id -u)"
    helper="$(mktemp /tmp/ovpn-watch-update-helper-XXXXXX.sh)"
    cat > "$helper" <<EOF
#!/bin/zsh
sleep 1
launchctl bootout "gui/$uid/com.riwaj.ovpnwatch" 2>/dev/null
launchctl bootstrap "gui/$uid" "$PLIST_PATH"
launchctl enable "gui/$uid/com.riwaj.ovpnwatch"
sleep 3
if launchctl print "gui/$uid/com.riwaj.ovpnwatch" 2>/dev/null | grep -q "state = running"; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') Update successful, agent running." >> "$LOG"
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') Update caused agent to fail to start, rolling back." >> "$LOG"
    if [[ -f "${INSTALL_PATH}.bak" ]]; then
        install -m 755 "${INSTALL_PATH}.bak" "$INSTALL_PATH"
        launchctl bootout "gui/$uid/com.riwaj.ovpnwatch" 2>/dev/null
        launchctl bootstrap "gui/$uid" "$PLIST_PATH"
        launchctl enable "gui/$uid/com.riwaj.ovpnwatch"
        sleep 2
        if launchctl print "gui/$uid/com.riwaj.ovpnwatch" 2>/dev/null | grep -q "state = running"; then
            echo "\$(date '+%Y-%m-%d %H:%M:%S') Rollback successful." >> "$LOG"
        else
            echo "\$(date '+%Y-%m-%d %H:%M:%S') Rollback ALSO failed. Manual intervention needed." >> "$LOG"
        fi
    fi
fi
rm -f "$helper"
EOF
    chmod +x "$helper"
    nohup "$helper" >/dev/null 2>&1 &
    disown
}

check_and_apply_update() {
    state_set LAST_UPDATE_CHECK "$(date +%s)"
    command -v curl >/dev/null 2>&1 || { log "Update check: curl not available, skipping."; return; }

    local tmp
    tmp="$(mktemp /tmp/ovpn-watch-update-XXXXXX.sh)"
    if ! curl -fsSL --max-time 15 "$REPO_RAW_URL" -o "$tmp" 2>>"$LOG"; then
        log "Update check: failed to fetch latest version."
        rm -f "$tmp"
        return
    fi
    if [[ ! -s "$tmp" ]]; then
        log "Update check: fetched file was empty, skipping."
        rm -f "$tmp"
        return
    fi

    local remote_hash local_hash
    remote_hash="$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}')"
    local_hash="$(shasum -a 256 "$INSTALL_PATH" 2>/dev/null | awk '{print $1}')"

    if [[ -z "$remote_hash" || "$remote_hash" == "$local_hash" ]]; then
        rm -f "$tmp"
        return
    fi

    log "Update check: new version detected, validating..."
    if ! zsh -n "$tmp" 2>>"$LOG"; then
        log "Update check: fetched file failed syntax check, NOT applying."
        rm -f "$tmp"
        return
    fi

    apply_update_and_restart "$tmp"
}

maybe_daily_maintenance() {
    local last now
    last="$(state_get LAST_UPDATE_CHECK)"
    now="$(date +%s)"
    if [[ -z "$last" ]] || (( now - last >= UPDATE_INTERVAL )); then
        trim_log "$LOG"
        check_and_apply_update
    fi
}

# ---------------------------------------------------------------------------
# Watch mode: the long-running loop, managed by the LaunchAgent.
# ---------------------------------------------------------------------------
watch_mode() {
    mkdir -p "$DEST" "$STATE_DIR" "$(dirname "$LOG")"
    touch "$LOG" "$STATE_FILE"
    log "ovpn-watch started, watching $DOWNLOADS"

    while true; do
        tick
        maybe_daily_maintenance
        sleep 1
    done
}

# ---------------------------------------------------------------------------
if [[ "${0:t}" == "vpninfo" ]]; then
    print_vpninfo
    exit 0
fi

case "${1:-}" in
    --watch)
        watch_mode
        ;;
    "")
        install_mode
        ;;
    *)
        echo "Usage: $0 [--watch]" >&2
        exit 1
        ;;
esac
