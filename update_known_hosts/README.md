# update_known_hosts.sh

This script updates SSH `known_hosts` entries for every node in a Proxmox VE cluster. It extracts node names from `/etc/pve/corosync.conf`, removes existing SSH host keys, fetches new ones, and refreshes cluster certificates.

## Prerequisites

- `ssh-keygen`
- `pvecm`

## Usage

Run on a Proxmox VE cluster node as the `root` user:

```bash
bash update_known_hosts.sh
```

The script will iterate through all cluster nodes, update their SSH host keys, and call `pvecm updatecerts` to refresh certificates.
