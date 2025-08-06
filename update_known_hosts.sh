#!/bin/bash

# This script updates SSH known_hosts entries for all Proxmox cluster nodes.
# It must be run as root on a node that has /etc/pve/corosync.conf.

# Exit on any error
set -e

# Function to print errors
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root."
fi

# Check if corosync.conf exists and is readable
COROSYNC_CONF="/etc/pve/corosync.conf"
if [[ ! -r "$COROSYNC_CONF" ]]; then
    error_exit "Cannot read $COROSYNC_CONF. Are you running this on a Proxmox cluster node as root?"
fi

# Function to get Proxmox node hostnames from corosync.conf
get_cluster_nodes() {
    grep -oP '(?<=name: )\S+' "$COROSYNC_CONF"
}

# Function to update known_hosts on a single node
update_known_hosts() {
    local node_name="$1"
    echo "Updating known_hosts on node: $node_name"

    # Remove the existing host key for the specific node from the system-wide known_hosts file
    if ! ssh-keygen -f "/etc/ssh/ssh_known_hosts" -R "$node_name" 2>/dev/null; then
        echo "Warning: Failed to remove $node_name from /etc/ssh/ssh_known_hosts (file may not exist or permission denied)."
    fi

    # Remove the existing host key for the specific node from the root user's known_hosts file
    if ! ssh-keygen -f "/root/.ssh/known_hosts" -R "$node_name" 2>/dev/null; then
        echo "Warning: Failed to remove $node_name from /root/.ssh/known_hosts (file may not exist or permission denied)."
    fi

    # Add the new key for the node
    if ! /usr/bin/ssh -e none -o HostKeyAlias="$node_name" -o StrictHostKeyChecking=accept-new root@"$node_name" /bin/true 2>/dev/null; then
        echo "Warning: Unable to fetch SSH key from $node_name. Node may be unreachable or SSH may be misconfigured."
    fi

    # Run pvecm updatecerts to ensure cluster-wide certificate consistency
    if ! pvecm updatecerts -F; then
        error_exit "pvecm updatecerts failed! Check Proxmox cluster status and permissions."
    fi

    echo "known_hosts update completed for $node_name"
}

# Get the list of nodes from corosync.conf
NODES=()
while read -r node; do
    [[ -n "$node" ]] && NODES+=("$node")
done < <(get_cluster_nodes)

if [[ ${#NODES[@]} -eq 0 ]]; then
    error_exit "No nodes found in $COROSYNC_CONF. Is your cluster configuration correct?"
fi

# Iterate through each node and update known_hosts
for node in "${NODES[@]}"; do
    update_known_hosts "$node"
done

echo "known_hosts update process completed for all discovered nodes."
