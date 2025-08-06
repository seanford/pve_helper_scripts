#!/bin/bash

# This script updates SSH known_hosts entries for all Proxmox cluster nodes.
# It must be run as root on a node that has /etc/pve/corosync.conf.

set -e

# Print an error and exit
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Print a notice (not an error)
info_notice() {
    echo "NOTICE: $1"
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

# Extract Proxmox node hostnames from corosync.conf
get_cluster_nodes() {
    awk '
    $1 == "node" { in_node=1 }
    in_node && $1 == "name:" { print $2 }
    in_node && $0 ~ /}/ { in_node=0 }
    ' "$COROSYNC_CONF"
}

# Update known_hosts on a single node
update_known_hosts() {
    local node_name="$1"
    echo "=========="
    echo "Updating known_hosts for node: $node_name"

    # System-wide known_hosts
    KNOWN_HOSTS_SYS="/etc/ssh/ssh_known_hosts"
    if [[ -e "$KNOWN_HOSTS_SYS" ]]; then
        if ssh-keygen -f "$KNOWN_HOSTS_SYS" -R "$node_name" >/dev/null 2>&1; then
            echo "Removed old SSH key for $node_name from $KNOWN_HOSTS_SYS."
        else
            echo "Warning: Failed to remove $node_name from $KNOWN_HOSTS_SYS (permission denied or not found)."
        fi
    else
        info_notice "$KNOWN_HOSTS_SYS does not exist, skipping."
    fi

    # Root user's known_hosts
    KNOWN_HOSTS_ROOT="/root/.ssh/known_hosts"
    if [[ -e "$KNOWN_HOSTS_ROOT" ]]; then
        if ssh-keygen -f "$KNOWN_HOSTS_ROOT" -R "$node_name" >/dev/null 2>&1; then
            echo "Removed old SSH key for $node_name from $KNOWN_HOSTS_ROOT."
        else
            echo "Warning: Failed to remove $node_name from $KNOWN_HOSTS_ROOT (permission denied or not found)."
        fi
    else
        info_notice "$KNOWN_HOSTS_ROOT does not exist, skipping."
    fi

    # Add the new key for the node
    if /usr/bin/ssh -e none -o HostKeyAlias="$node_name" -o StrictHostKeyChecking=accept-new root@"$node_name" /bin/true 2>/dev/null; then
        echo "Fetched and added new SSH key for $node_name."
    else
        echo "Warning: Unable to fetch SSH key from $node_name. Node may be unreachable or SSH may be misconfigured."
    fi

    # Update cluster certificates
    if pvecm updatecerts -F; then
        echo "Cluster certificates updated."
    else
        error_exit "pvecm updatecerts failed! Check Proxmox cluster status and permissions."
    fi

    echo "known_hosts update completed for $node_name"
    echo ""
}

# Main logic
NODES=()
while read -r node; do
    [[ -n "$node" ]] && NODES+=("$node")
done < <(get_cluster_nodes)

if [[ ${#NODES[@]} -eq 0 ]]; then
    error_exit "No nodes found in $COROSYNC_CONF. Is your cluster configuration correct?"
fi

for node in "${NODES[@]}"; do
    update_known_hosts "$node"
done

echo "known_hosts update process completed for all discovered nodes."
