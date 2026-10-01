#!/usr/bin/env bash
#
# OpenVPN auto-switcher.
#
#   Install (run once, by hand, inside the VM):
#       bash /mnt/hgfs/vmShared/ovpn-switch.sh
#
#   Installs itself to /usr/local/bin and runs as a root systemd service
#   from then on (--watch mode), watching /mnt/hgfs/vmShared every second
#   for a new .ovpn file and switching the active OpenVPN connection to it.
#
set -u

WATCH_DIR="/mnt/hgfs/vmShared"
INSTALL_PATH="/usr/local/bin/ovpn-switch.sh"
STATE_DIR="/var/lib/ovpn-switch"
LOG="/var/log/ovpn-switch.log"
OVPN_LOG="/var/log/ovpn-switch-openvpn.log"
PIDFILE="$STATE_DIR/openvpn.pid"
ACTIVE_FILE="$STATE_DIR/active"
FAILED_FILE="$STATE_DIR/last_failed"
SERVICE_NAME="ovpn-switch.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG"
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

    echo "Setting up state/log locations..."
    sudo mkdir -p "$STATE_DIR"
    sudo touch "$LOG" "$OVPN_LOG"
    sudo chmod 644 "$LOG" "$OVPN_LOG"

    echo "Writing systemd service..."
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=OpenVPN auto-switcher
After=network.target

[Service]
ExecStart=$INSTALL_PATH --watch
Restart=always
RestartSec=2
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
        echo "Logs: $LOG (switch events), $OVPN_LOG (openvpn output)."
    else
        echo "WARNING: service did not start cleanly. Check: sudo systemctl status $SERVICE_NAME" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Watch mode: runs forever as root, via systemd.
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

get_active() { cat "$ACTIVE_FILE" 2>/dev/null || true; }
set_active() { echo "$1" > "$ACTIVE_FILE"; }
clear_active() { rm -f "$ACTIVE_FILE"; }

is_failed_unchanged() {
    local f="$1"
    [[ -f "$FAILED_FILE" ]] || return 1
    local fp fm m
    IFS='|' read -r fp fm < "$FAILED_FILE"
    [[ "$f" == "$fp" ]] || return 1
    m="$(stat -c %Y "$f" 2>/dev/null || echo "")"
    [[ "$m" == "$fm" ]]
}

set_failed() {
    local path="$1" m
    m="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
    echo "${path}|${m}" > "$FAILED_FILE"
}
clear_failed() { rm -f "$FAILED_FILE"; }

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

watch_mode() {
    mkdir -p "$STATE_DIR"
    touch "$LOG" "$OVPN_LOG"
    log "ovpn-switch watcher started, watching $WATCH_DIR"

    while true; do
        tick "$(get_active)"
        sleep 1
    done
}

# ---------------------------------------------------------------------------
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
