# update_known_hosts.sh

This script updates SSH `known_hosts` entries for every node in a Proxmox VE cluster. It extracts node names from `/etc/pve/corosync.conf`, removes existing SSH host keys from both `/etc/ssh/ssh_known_hosts` and `/root/.ssh/known_hosts`, fetches new ones, and refreshes cluster certificates. A summary table is printed at the end showing success or warnings per node.

## Prerequisites

- `ssh-keygen`
- `ssh`
- `pvecm`

## Usage

Run on a Proxmox VE cluster node as the `root` user:

```bash
bash update_known_hosts.sh
```

The script iterates through all cluster nodes, updates their SSH host keys, and calls `pvecm updatecerts` to refresh certificates. A summary table highlights the outcome for each node.
