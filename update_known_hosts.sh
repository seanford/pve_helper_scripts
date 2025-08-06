#!/bin/bash

# Function to get Proxmox node hostnames from corosync.conf
get_cluster_nodes() {
    # Extract node names from corosync.conf (usually located in /etc/pve/corosync.conf)
    # The 'name:' field within the 'nodelist' section provides the node's hostname
    grep -oP '(?<=name: )\S+' /etc/pve/corosync.conf
}

# Function to update known_hosts on a single node
update_known_hosts() {
    local node_name=$1
    echo "Updating known_hosts on node: $node_name"

    # Remove the existing host key for the specific node from the system-wide known_hosts file
    ssh-keygen -f "/etc/ssh/ssh_known_hosts" -R "$node_name"

    # Remove the existing host key for the specific node from the root user's known_hosts file
    ssh-keygen -f "/root/.ssh/known_hosts" -R "$node_name"

    # Add the new key for the node
    # Replace 'root@$node_name' with the actual user and address for SSH if not root
    /usr/bin/ssh -e none -o 'HostKeyAlias='$node_name' -o "StrictHostKeyChecking=accept-new" root@$node_name /bin/true 2>/dev/null

    # Run pvecm updatecerts to ensure cluster-wide certificate consistency
    pvecm updatecerts -F

    echo "known_hosts update completed for $node_name"
}

# Get the list of nodes from corosync.conf
NODES=($(get_cluster_nodes))

# Iterate through each node and update known_hosts
for node in "${NODES[@]}"; do
    update_known_hosts "$node"
done

echo "known_hosts update process completed for all discovered nodes."
