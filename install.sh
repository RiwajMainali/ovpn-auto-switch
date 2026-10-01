#!/usr/bin/env bash
#
# ovpn-auto-switch installer. Asks whether this machine is the VM or the
# main PC, then hands off to the matching role script's own installer.
#
# Usage:
#   bash install.sh          (interactive prompt)
#   bash install.sh vm       (non-interactive)
#   bash install.sh host
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Looks for the role script next to this installer, first in its normal
# repo subfolder, then flat in the same directory — the VM-side copy in
# vmShared mirrors just the vm/ subset without the full repo layout.
find_role_script() {
    local subdir="$1" name="$2"
    if [[ -f "$SCRIPT_DIR/$subdir/$name" ]]; then
        echo "$SCRIPT_DIR/$subdir/$name"
    elif [[ -f "$SCRIPT_DIR/$name" ]]; then
        echo "$SCRIPT_DIR/$name"
    fi
}

role="${1:-}"
if [[ -z "$role" ]]; then
    echo "Is this the VM or the main PC? [vm/host]"
    read -r role
fi

case "$role" in
    vm|VM)
        target="$(find_role_script vm ovpn-switch.sh)"
        if [[ -z "$target" ]]; then
            echo "ERROR: could not find vm/ovpn-switch.sh next to this installer." >&2
            exit 1
        fi
        exec bash "$target"
        ;;
    host|HOST|pc|PC|mac|Mac)
        target="$(find_role_script host ovpn-watch.sh)"
        if [[ -z "$target" ]]; then
            echo "ERROR: could not find host/ovpn-watch.sh next to this installer." >&2
            exit 1
        fi
        exec zsh "$target"
        ;;
    *)
        echo "Please answer 'vm' or 'host'." >&2
        exit 1
        ;;
esac
