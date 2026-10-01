#!/usr/bin/env bash
#
# Removes everything ovpn-switch.sh (the VM-side auto-switcher) installed:
# its systemd service, the deployed binary, state, pidfile, and logs — and
# stops whatever OpenVPN connection it's currently managing.
#
# Does NOT touch files in /mnt/hgfs/vmShared itself (including
# ovpn-switch.sh, the installer) since that folder is shared with the host
# — delete those by hand if you want them gone too.
#
# Run once, by hand, inside the VM:
#   bash /mnt/hgfs/vmShared/ovpn-switch-uninstall.sh
#
set -u

INSTALL_PATH="/usr/local/bin/ovpn-switch.sh"
VPNINFO_LINK="/usr/local/bin/vpninfo"
STATE_DIR="/var/lib/ovpn-switch"
LOG="/var/log/ovpn-switch.log"
OVPN_LOG="/var/log/ovpn-switch-openvpn.log"
PIDFILE="$STATE_DIR/openvpn.pid"
SERVICE_NAME="ovpn-switch.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

echo "This will:"
echo "  - stop and remove the ovpn-switch systemd service"
echo "  - stop whatever OpenVPN connection it's currently managing"
echo "  - delete $INSTALL_PATH (+ .bak), $VPNINFO_LINK, $STATE_DIR, $LOG, $OVPN_LOG"
echo "It will NOT touch files in /mnt/hgfs/vmShared (including ovpn-switch.sh itself)."
echo
read -r -p "Continue? [y/N] " answer
case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted, nothing changed."; exit 0 ;;
esac

sudo -v || { echo "ERROR: sudo authentication failed." >&2; exit 1; }

echo "Stopping systemd service (if present)..."
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true

echo "Stopping any OpenVPN process it's managing..."
if [[ -f "$PIDFILE" ]]; then
    pid="$(sudo cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && sudo kill -0 "$pid" 2>/dev/null; then
        sudo kill -TERM "$pid" 2>/dev/null || true
        w=0
        while sudo kill -0 "$pid" 2>/dev/null && (( w < 5 )); do
            sleep 1
            w=$((w+1))
        done
        sudo kill -0 "$pid" 2>/dev/null && sudo kill -KILL "$pid" 2>/dev/null
    fi
fi
sudo pkill -f "openvpn --config" 2>/dev/null || true

echo "Removing systemd unit..."
sudo rm -f "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

echo "Removing installed binary, vpninfo command, state, and logs..."
sudo rm -f "$INSTALL_PATH" "${INSTALL_PATH}.bak" "$VPNINFO_LINK"
sudo rm -rf "$STATE_DIR"
sudo rm -f "$LOG" "$OVPN_LOG"

echo "Cleaning up any leftover temp files (failure notifications, update checks)..."
sudo rm -f /tmp/ovpn-switch-fail-* /tmp/ovpn-switch-update-*

echo
echo "Done. All ovpn-switch traces removed from this VM."
echo "(The installer at /mnt/hgfs/vmShared/ovpn-switch.sh was left alone — delete it yourself if you want that gone too.)"
