# ovpn-auto-switch

Two small background services that together move a new `.ovpn` config from
your Mac straight into an active VPN connection inside a VM, with no manual
steps in between.

```
Downloads (host) --[host/ovpn-watch.sh]--> vmShared (host) == /mnt/hgfs/vmShared (VM)
                                                                       |
                                                        [vm/ovpn-switch.sh]
                                                                       |
                                                              active openvpn tunnel
```

## `host/` — Downloads → vmShared (runs on macOS)

Watches `~/Downloads` once a second for `.ovpn` files, moves any it finds
into `~/vmShared` (a VMware Fusion shared folder), and deletes `.ovpn`
files from `~/vmShared` once they're older than 24 hours.

- `ovpn-watch.sh` — the watcher script
- `com.riwaj.ovpnwatch.plist` — launchd job definition (loops internally,
  `RunAtLoad`+`KeepAlive` so it starts at login and restarts if it dies)

### Install

```sh
mkdir -p ~/.local/bin
cp host/ovpn-watch.sh ~/.local/bin/ovpn-watch.sh
chmod +x ~/.local/bin/ovpn-watch.sh

cp host/com.riwaj.ovpnwatch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.riwaj.ovpnwatch.plist
launchctl enable gui/$(id -u)/com.riwaj.ovpnwatch
```

**Gotcha:** `~/Downloads` is a TCC-protected folder on macOS. A background
`launchd` job spawning `/bin/zsh` does not inherit an interactive
terminal's access to it — grant it explicitly once in **System Settings →
Privacy & Security → Full Disk Access** by adding `/bin/zsh` itself (not a
terminal app) as its own entry. Easiest way to locate the binary to drag in:
`open -R /bin/zsh`.

Logs: `~/Library/Logs/ovpn-watch.log`.

## `vm/` — auto-switch the active VPN (runs inside the VM, Linux)

Watches `/mnt/hgfs/vmShared` once a second for a new `.ovpn` file. When one
shows up it starts `openvpn` with it, confirms the tunnel actually comes up
(watches for OpenVPN's own `Initialization Sequence Completed` line) before
deleting the previous config, and rolls back to the previous connection if
the new file fails to connect — surfacing the failure in a popped-up
terminal (best-effort; falls back to a log file) with a one-key option to
wipe the shared folder and start over.

- `ovpn-switch.sh` — both the installer (default) and the watcher itself
  (`--watch`, what systemd actually runs)

### Install

Run once, inside the VM, by hand:

```sh
bash /mnt/hgfs/vmShared/ovpn-switch.sh
```

Asks for your sudo password exactly once, then deploys itself to
`/usr/local/bin/ovpn-switch.sh` and installs/starts `ovpn-switch.service`
— a root systemd service, so no password or cached sudo session is needed
ever again, including across reboots.

Logs: `/var/log/ovpn-switch.log` (switch events),
`/var/log/ovpn-switch-openvpn.log` (raw openvpn output).

### Manage

```sh
sudo systemctl status ovpn-switch.service
sudo systemctl stop ovpn-switch.service
sudo systemctl restart ovpn-switch.service
```

## Design notes

- True "every second" scheduling isn't possible with `cron` (1-minute
  floor) — both scripts loop internally with `sleep 1`; the OS service
  manager (`launchd` / `systemd`) just keeps that one process alive rather
  than spawning a fresh one every second.
- Neither script ever stores a password anywhere. The host side needs no
  elevated privileges at all; the VM side avoids needing one past install
  time by running the ongoing watcher as a root *system* service rather
  than relying on a cached sudo session or a NOPASSWD sudoers rule.
