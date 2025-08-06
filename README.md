# pve_helper_scripts

A collection of scripts to automate tasks in Proxmox VE.

## Available scripts

### update_known_hosts/update_known_hosts.sh

Updates SSH `known_hosts` entries for all nodes in a Proxmox cluster. Run as root on a node that has `/etc/pve/corosync.conf`. It updates both `/etc/ssh/ssh_known_hosts` and `/root/.ssh/known_hosts`, refreshes cluster certificates, and prints a per-node summary.

Usage:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/update_known_hosts/update_known_hosts.sh)"
```

### pve8to9-upgrade/pve-upgrade-orchestrator.sh

Interactive helper that orchestrates the upgrade from Proxmox VE 8 to 9, complete with a live web dashboard (skip with `--no-dashboard`) and optional rollback support.

Usage:

```bash
bash <(curl -s https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/pve-upgrade-orchestrator.sh)
```

Pass `--no-dashboard` to run without launching the web interface.

To clean up a dashboard/websocket instance manually:

```bash
/root/pve_helper_scripts/pve8to9-upgrade/kill-dashboard.sh
```

See `pve8to9-upgrade/README.md` for full details and additional options.
