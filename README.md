# ovpn-auto-switch

Auto-moves new `.ovpn` configs from Downloads into a VM and hot-swaps the
active OpenVPN connection to them — zero manual steps, zero stored
passwords.

```
Downloads (host) --[host/ovpn-watch.sh]--> vmShared (host) == /mnt/hgfs/vmShared (VM)
                                                                       |
                                                        [vm/ovpn-switch.sh]
                                                                       |
                                                              active openvpn tunnel
```

## Install

One entry point, on either machine:

```sh
bash install.sh
```

It asks whether this is the **VM** or the **main PC** and hands off to the
matching installer. (Non-interactive: `bash install.sh vm` / `bash
install.sh host`.)

- **Host (main PC)**: no `sudo`, ever — everything it does only touches
  files you already own and a user-level `launchd` agent.
- **VM**: asks for your `sudo` password exactly once, to set up a root
  systemd service. Never needed again after that, including across
  reboots — the service already *is* root, so there's nothing to
  re-authenticate.

`install.sh` looks for the role script next to itself, in its normal
`vm/`/`host/` subfolder or flat in the same directory — the copy that
lives in `~/vmShared` (so the VM can reach it) only needs to mirror the
`vm/` subset, not the whole repo.

## `vpninfo`

Installed as a command on both machines — run it any time for a clean
status view.

- **Host**: last file moved into `vmShared`, last file deleted (pruned
  for being >24h old), last update check.
- **VM**: whether a tunnel is up, which config, how long it's been up,
  last switch time, last health-watchdog restart (if any), last update
  check.

## What each side does

### `host/` — Downloads → vmShared (macOS)

Watches `~/Downloads` once a second for `.ovpn` files, moves any it finds
into `~/vmShared`, and deletes `.ovpn` files from `~/vmShared` once
they're older than 24 hours.

**Gotcha:** `~/Downloads` is TCC-protected on macOS. A background
`launchd` job spawning `/bin/zsh` doesn't inherit an interactive
terminal's access to it — grant it once in **System Settings → Privacy &
Security → Full Disk Access** by adding `/bin/zsh` itself (not a terminal
app) as its own entry. Easiest way to locate the binary to drag in:
`open -R /bin/zsh`.

Logs: `~/Library/Logs/ovpn-watch.log`.

### `vm/` — auto-switch the active VPN (Linux)

Watches `/mnt/hgfs/vmShared` once a second for a new `.ovpn` file. When
one shows up it starts `openvpn` with it, confirms the tunnel actually
comes up (watches for OpenVPN's own `Initialization Sequence Completed`
line) before deleting the previous config, and rolls back to the previous
connection if the new file fails to connect — surfacing the failure in a
popped-up terminal (best-effort; falls back to the log) with a one-key
option to wipe the shared folder and start over.

A health watchdog checks roughly every 60s that the active tunnel's
process is still alive and restarts it if it died without a file-switch
event triggering it.

Logs: `/var/log/ovpn-switch.log` (switch events),
`/var/log/ovpn-switch-openvpn.log` (raw openvpn output).

Manage the service directly if needed:

```sh
sudo systemctl status ovpn-switch.service
sudo systemctl stop ovpn-switch.service
sudo systemctl restart ovpn-switch.service
```

Uninstall everything the VM-side installer set up:
`bash /mnt/hgfs/vmShared/ovpn-switch-uninstall.sh` (leaves the shared
folder itself untouched).

## Auto-update

Both sides check `raw.githubusercontent.com` for this repo's `main`
branch roughly once a day, compare a hash against what's installed, and —
if different — syntax-validate the fetched file, swap it in, keep a
`.bak` of the previous version, and restart the service/agent. If the new
version fails to come up, it automatically rolls back to the `.bak`.

**Worth knowing if you fork/modify this**: the VM side runs the updated
script as **root**. Auto-update there means whatever's on `main` executes
as root on the VM on the next check — gated only by who can push to the
repo. That's accepted as-is here since the VM is treated as disposable,
but it's not a property every setup should want by default.

## Design notes

- True "every second" scheduling isn't possible with `cron` (1-minute
  floor) — both scripts loop internally with `sleep 1`; the OS service
  manager (`launchd` / `systemd`) just keeps that one process alive
  rather than spawning a fresh one every second.
- Neither script stores a password anywhere. The host side needs no
  elevated privileges at all; the VM side avoids needing one past install
  time by running the ongoing watcher as a root *system* service rather
  than relying on a cached sudo session or a NOPASSWD sudoers rule.
- The systemd unit uses `KillMode=process` so restarting the watch loop
  (for an update, or manually) never kills the detached `openvpn
  --daemon` child — the active tunnel survives.
- Logs are trimmed to the last 7 days on the same daily cadence as the
  update check.
