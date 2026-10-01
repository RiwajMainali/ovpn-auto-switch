#!/usr/bin/env bash
#
# OpenVPN auto-switcher.
#
#   Install (run once, by hand, inside the VM):
#       bash /mnt/hgfs/vmShared/ovpn-switch.sh
#
#   Installs itself to /usr/local/bin and runs as a root systemd service
#   from then on (--watch mode), watching /mnt/hgfs/vmShared every second
#   for a new .ovpn file and switching the active OpenVPN connection to
#   it. Also: a `vpninfo` status command, a ~60s health watchdog that
#   restarts a dead tunnel, a daily GitHub update check, and log trimming
#   to the last 7 days.
#
set -u

REPO_RAW_URL="https://raw.githubusercontent.com/RiwajMainali/ovpn-auto-switch/main/vm/ovpn-switch.sh"
WATCH_DIR="/mnt/hgfs/vmShared"
BIN_DIR="/usr/local/bin"
INSTALL_PATH="$BIN_DIR/ovpn-switch.sh"
VPNINFO_LINK="$BIN_DIR/vpninfo"
STATE_DIR="/var/lib/ovpn-switch"
STATE_FILE="$STATE_DIR/state"
LOG="/var/log/ovpn-switch.log"
OVPN_LOG="/var/log/ovpn-switch-openvpn.log"
PIDFILE="$STATE_DIR/openvpn.pid"
SERVICE_NAME="ovpn-switch.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

HEALTH_INTERVAL=60      # loop ticks (~1s each) between health checks
UPDATE_INTERVAL=86400   # seconds between GitHub update checks
LOG_RETENTION_DAYS=7

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG"
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
    chmod 644 "$STATE_FILE" 2>/dev/null || true
}

get_active() { state_get ACTIVE; }
set_active() {
    state_set ACTIVE "$1"
    state_set ACTIVE_SINCE "$(date +%s)"
}
clear_active() {
    state_set ACTIVE ""
    state_set ACTIVE_SINCE ""
}

is_failed_unchanged() {
    local f="$1" fp fm m
    fp="$(state_get FAILED_PATH)"
    [[ -z "$fp" ]] && return 1
    [[ "$f" == "$fp" ]] || return 1
    fm="$(state_get FAILED_MTIME)"
    m="$(stat -c %Y "$f" 2>/dev/null || echo "")"
    [[ "$m" == "$fm" ]]
}

set_failed() {
    local path="$1" m
    m="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
    state_set FAILED_PATH "$path"
    state_set FAILED_MTIME "$m"
}
clear_failed() {
    state_set FAILED_PATH ""
    state_set FAILED_MTIME ""
}

# ---------------------------------------------------------------------------
# Install mode: run once, by hand, as the regular user.
# ---------------------------------------------------------------------------
install_mode() {
    echo "Checking for openvpn..."
    if ! command -v openvpn >/dev/null 2>&1; then
        echo "ERROR: openvpn is not installed / not on PATH. Install it (e.g. 'sudo apt install openvpn') and re-run this script." >&2
        exit 1
    fi

    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0")"

    echo "This will ask for your sudo password once, to install the background VPN switcher."
    sudo -v || { echo "ERROR: sudo authentication failed." >&2; exit 1; }

    echo "Installing watcher to $INSTALL_PATH ..."
    sudo install -m 755 "$script_path" "$INSTALL_PATH"

    echo "Creating vpninfo command..."
    sudo ln -sf "$INSTALL_PATH" "$VPNINFO_LINK"

    echo "Setting up state/log locations..."
    sudo mkdir -p "$STATE_DIR"
    sudo chmod 755 "$STATE_DIR"
    sudo touch "$LOG" "$OVPN_LOG" "$STATE_FILE"
    sudo chmod 644 "$LOG" "$OVPN_LOG" "$STATE_FILE"

    echo "Writing systemd service..."
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=OpenVPN auto-switcher
After=network.target

[Service]
ExecStart=$INSTALL_PATH --watch
Restart=always
RestartSec=2
KillMode=process
User=root

[Install]
WantedBy=multi-user.target
EOF

    echo "Enabling and starting the service..."
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"

    sleep 1
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "Installed and running."
        echo "It will now watch $WATCH_DIR every second and auto-start on every boot — no more passwords needed."
        echo "Run 'vpninfo' any time for status. Logs: $LOG (switch events), $OVPN_LOG (openvpn output)."
    else
        echo "WARNING: service did not start cleanly. Check: sudo systemctl status $SERVICE_NAME" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# vpninfo
# ---------------------------------------------------------------------------
pid_alive() {
    [[ -d "/proc/$1" ]]
}

human_duration() {
    local start="$1" now diff d h m
    now="$(date +%s)"
    diff=$(( now - start ))
    d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
    if (( d > 0 )); then echo "${d}d ${h}h"; elif (( h > 0 )); then echo "${h}h ${m}m"; else echo "${m}m"; fi
}

print_vpninfo() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "ovpn-switch: not installed or never run yet."
        return
    fi
    local active since switch health_restart update_check pid running="no"
    active="$(state_get ACTIVE)"
    since="$(state_get ACTIVE_SINCE)"
    switch="$(state_get LAST_SWITCH)"
    health_restart="$(state_get LAST_HEALTH_RESTART)"
    update_check="$(state_get LAST_UPDATE_CHECK)"

    if [[ -f "$PIDFILE" ]]; then
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        [[ -n "$pid" ]] && pid_alive "$pid" && running="yes"
    fi

    echo "ovpn-switch status"
    echo "  running:        $running"
    if [[ -n "$active" ]]; then
        echo "  active config:  $(basename "$active")"
        [[ -n "$since" ]] && echo "  up since:       $(date -d "@$since" '+%Y-%m-%d %H:%M:%S') ($(human_duration "$since"))"
        [[ -n "$switch" ]] && echo "  last switch:    $(date -d "@$switch" '+%Y-%m-%d %H:%M:%S')"
    else
        echo "  active config:  none"
    fi
    [[ -n "$health_restart" ]] && echo "  last auto-restart (health check): $(date -d "@$health_restart" '+%Y-%m-%d %H:%M:%S')"
    [[ -n "$update_check" ]] && echo "  last update check: $(date -d "@$update_check" '+%Y-%m-%d %H:%M:%S')"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "  service:        active"
    else
        echo "  service:        not active"
    fi
}

# ---------------------------------------------------------------------------
# Failure notification (best-effort GUI popup).
# ---------------------------------------------------------------------------
find_gui_user() {
    if command -v loginctl >/dev/null 2>&1; then
        local sess
        for sess in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
            if loginctl show-session "$sess" -p Active 2>/dev/null | grep -q "^Active=yes"; then
                loginctl show-session "$sess" -p Name 2>/dev/null | cut -d= -f2
                return
            fi
        done
    fi
    who 2>/dev/null | awk '{print $1; exit}'
}

notify_failure() {
    local candidate="$1"
    local msg_file="/tmp/ovpn-switch-fail-msg-$$.txt"
    local script_file="/tmp/ovpn-switch-fail-$$.sh"

    {
        echo "OpenVPN switch FAILED for $(basename "$candidate") at $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "Tail of openvpn log:"
        tail -n 20 "$OVPN_LOG" 2>/dev/null
        echo ""
        echo "Press 'd' then Enter to DELETE EVERYTHING in $WATCH_DIR and resume watching."
        echo "Press Enter (or just close this window) to leave the files as-is; this file will not be retried automatically."
    } > "$msg_file"

    cat > "$script_file" <<SCRIPT
#!/usr/bin/env bash
cat "$msg_file"
read -r -n1 answer
echo
if [[ "\$answer" == "d" || "\$answer" == "D" ]]; then
    find "$WATCH_DIR" -maxdepth 1 -iname '*.ovpn' -delete
    echo "Deleted everything in $WATCH_DIR."
    echo "\$(date '+%Y-%m-%d %H:%M:%S') User deleted all files in $WATCH_DIR after failure." >> "$LOG"
fi
rm -f "$msg_file" "$script_file"
SCRIPT
    chmod +x "$script_file"

    local gui_user
    gui_user="$(find_gui_user)"
    if [[ -z "$gui_user" ]]; then
        log "No active desktop session found; skipping terminal popup (see log above for details)."
        return
    fi

    local gui_display="${DISPLAY:-:0}"
    local gui_xauth="/home/$gui_user/.Xauthority"

    local term_cmd=""
    for t in x-terminal-emulator gnome-terminal konsole xfce4-terminal mate-terminal lxterminal xterm; do
        if command -v "$t" >/dev/null 2>&1; then
            term_cmd="$t"
            break
        fi
    done

    if [[ -z "$term_cmd" ]]; then
        log "No terminal emulator found; skipping popup (see log above for details)."
        return
    fi

    case "$term_cmd" in
        gnome-terminal|mate-terminal)
            sudo -u "$gui_user" env DISPLAY="$gui_display" XAUTHORITY="$gui_xauth" "$term_cmd" -- bash "$script_file" >/dev/null 2>&1 &
            ;;
        *)
            sudo -u "$gui_user" env DISPLAY="$gui_display" XAUTHORITY="$gui_xauth" "$term_cmd" -e "bash $script_file" >/dev/null 2>&1 &
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Core switch logic.
# ---------------------------------------------------------------------------
stop_current() {
    if [[ -f "$PIDFILE" ]]; then
        local pid
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            local w=0
            while kill -0 "$pid" 2>/dev/null && (( w < 5 )); do
                sleep 1
                w=$((w+1))
            done
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
        fi
        rm -f "$PIDFILE"
    fi
    pkill -f "openvpn --config" 2>/dev/null || true
}

start_candidate() {
    local candidate="$1"
    : > "$OVPN_LOG"
    openvpn --config "$candidate" --daemon --log "$OVPN_LOG" --writepid "$PIDFILE"
}

wait_for_connection() {
    local waited=0
    while (( waited < 25 )); do
        if grep -q "Initialization Sequence Completed" "$OVPN_LOG" 2>/dev/null; then
            return 0
        fi
        if [[ -f "$PIDFILE" ]] && ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            return 1
        fi
        sleep 1
        waited=$((waited+1))
    done
    return 1
}

attempt_switch() {
    local candidate="$1"; shift
    local all=("$@")
    local prev
    prev="$(get_active)"

    log "Attempting switch to $(basename "$candidate")"
    stop_current
    start_candidate "$candidate"

    if wait_for_connection; then
        log "Connected: $(basename "$candidate")"
        set_active "$candidate"
        state_set LAST_SWITCH "$(date +%s)"
        clear_failed
        local f
        for f in "${all[@]}"; do
            if [[ "$f" != "$candidate" ]]; then
                rm -f "$f"
                log "Deleted stray file $(basename "$f")"
            fi
        done
        if [[ -n "$prev" && "$prev" != "$candidate" && -f "$prev" ]]; then
            rm -f "$prev"
            log "Deleted old config $(basename "$prev")"
        fi
    else
        log "FAILED to connect using $(basename "$candidate")"
        stop_current
        set_failed "$candidate"
        if [[ -n "$prev" && -f "$prev" ]]; then
            log "Restoring previous connection $(basename "$prev")"
            start_candidate "$prev"
            if wait_for_connection; then
                set_active "$prev"
            else
                log "Previous connection also failed to restore."
                stop_current
                clear_active
            fi
        else
            clear_active
        fi
        notify_failure "$candidate"
    fi
}

tick() {
    local active="$1"
    local candidates=()
    local f

    shopt -s nullglob nocaseglob
    for f in "$WATCH_DIR"/*.ovpn; do
        [[ "$f" == "$active" ]] && continue
        is_failed_unchanged "$f" && continue
        candidates+=("$f")
    done
    shopt -u nullglob nocaseglob

    (( ${#candidates[@]} == 0 )) && return 0

    local newest="" newest_mtime=-1 m
    for f in "${candidates[@]}"; do
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        if (( m > newest_mtime )); then
            newest="$f"
            newest_mtime="$m"
        fi
    done

    attempt_switch "$newest" "${candidates[@]}"
}

# ---------------------------------------------------------------------------
# Health watchdog.
# ---------------------------------------------------------------------------
health_check() {
    state_set LAST_HEALTH_CHECK "$(date +%s)"
    local active pid
    active="$(get_active)"
    [[ -z "$active" ]] && return

    pid=""
    [[ -f "$PIDFILE" ]] && pid="$(cat "$PIDFILE" 2>/dev/null)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return
    fi

    if [[ ! -f "$active" ]]; then
        log "Health check: active config $(basename "$active") no longer exists, clearing state."
        clear_active
        return
    fi

    log "Health check: openvpn for $(basename "$active") is not running, restarting..."
    start_candidate "$active"
    if wait_for_connection; then
        set_active "$active"
        state_set LAST_HEALTH_RESTART "$(date +%s)"
        log "Health check: restarted $(basename "$active") successfully."
    else
        log "Health check: failed to restart $(basename "$active")."
        stop_current
        notify_failure "$active"
    fi
}

# ---------------------------------------------------------------------------
# Log retention.
# ---------------------------------------------------------------------------
trim_log() {
    local file="$1"
    [[ -f "$file" ]] || return
    local cutoff
    cutoff="$(date -d "-${LOG_RETENTION_DAYS} days" +%s 2>/dev/null)" || return
    local tmp="${file}.tmp.$$"
    : > "$tmp"
    local line ts epoch
    while IFS= read -r line; do
        ts="${line:0:19}"
        epoch="$(date -d "$ts" +%s 2>/dev/null || echo "")"
        if [[ -z "$epoch" ]] || (( epoch >= cutoff )); then
            echo "$line" >> "$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
    chmod 644 "$file" 2>/dev/null || true
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

    # Restarting the service kills THIS process (KillMode=process still
    # signals the main tracked PID, which is us). Hand the restart +
    # verify + rollback-if-needed off to a detached helper so it survives
    # past that signal.
    local helper
    helper="$(mktemp /tmp/ovpn-switch-update-helper-XXXXXX.sh)"
    cat > "$helper" <<EOF
#!/usr/bin/env bash
sleep 1
systemctl restart "$SERVICE_NAME"
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') Update successful, service active." >> "$LOG"
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') Update caused service to fail to start, rolling back." >> "$LOG"
    if [[ -f "${INSTALL_PATH}.bak" ]]; then
        install -m 755 "${INSTALL_PATH}.bak" "$INSTALL_PATH"
        systemctl restart "$SERVICE_NAME"
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "\$(date '+%Y-%m-%d %H:%M:%S') Rollback successful." >> "$LOG"
        else
            echo "\$(date '+%Y-%m-%d %H:%M:%S') Rollback ALSO failed to start the service. Manual intervention needed." >> "$LOG"
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
    tmp="$(mktemp /tmp/ovpn-switch-update-XXXXXX.sh)"
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
    remote_hash="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"
    local_hash="$(sha256sum "$INSTALL_PATH" 2>/dev/null | awk '{print $1}')"

    if [[ -z "$remote_hash" || "$remote_hash" == "$local_hash" ]]; then
        rm -f "$tmp"
        return
    fi

    log "Update check: new version detected, validating..."
    if ! bash -n "$tmp" 2>>"$LOG"; then
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
# Watch mode: runs forever as root, via systemd.
# ---------------------------------------------------------------------------
watch_mode() {
    mkdir -p "$STATE_DIR"
    touch "$LOG" "$OVPN_LOG" "$STATE_FILE"
    log "ovpn-switch watcher started, watching $WATCH_DIR"

    local health_counter=0
    while true; do
        tick "$(get_active)"

        health_counter=$((health_counter + 1))
        if (( health_counter >= HEALTH_INTERVAL )); then
            health_counter=0
            health_check
        fi

        maybe_daily_maintenance

        sleep 1
    done
}

# ---------------------------------------------------------------------------
if [[ "$(basename "$0")" == "vpninfo" ]]; then
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
