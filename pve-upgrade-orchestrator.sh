#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REMOTE_PATH="/root/pve8to9-upgrade.sh"
LOG_DIR="/root/pve-upgrade-logs"
DASHBOARD_PORT=8080
DRY_RUN=false

function log {
    local MSG="[`date '+%F %T'`] $1"
    echo "$MSG"
    echo "$MSG" >> "$LOG_DIR/upgrade.log"
}

function usage {
    echo "Usage: $0 [--dry-run]"
    exit 1
}

function detect_cluster {
    if [ -f /etc/pve/corosync.conf ] && grep -q "node" /etc/pve/corosync.conf; then
        echo "cluster"
    else
        echo "single"
    fi
}

function get_nodes {
    grep -Po '(?<=name: )\S+' /etc/pve/corosync.conf 2>/dev/null | sort -u
}

function push_upgrade_script {
    local NODE=$1
    log "PUSHING upgrade script to $NODE..."
    if $DRY_RUN; then
        log "[DRY-RUN] Would copy script to $NODE"
    else
        scp ./pve8to9-upgrade.sh "$NODE:$REMOTE_PATH"
        ssh "$NODE" "chmod +x $REMOTE_PATH"
    fi
}

function check_quorum {
    ssh -o BatchMode=yes "$1" "pvecm status 2>/dev/null | grep -q 'Quorate:   Yes'"
}

function wait_for_quorum {
    log "Waiting for quorum to be restored..."
    while ! check_quorum "$1"; do
        sleep 5
    done
    log "Quorum restored."
}

function node_online {
    ping -c1 -W1 "$1" &>/dev/null
}

function wait_for_node_online {
    log "Waiting for $1 to come back online..."
    while ! node_online "$1"; do
        sleep 5
    done
    log "$1 is online."
}

function upgrade_node {
    local NODE=$1
    log "RUNNING upgrade on $NODE..."
    echo "STATUS $NODE RUNNING" >> "$LOG_DIR/upgrade.log"

    if $DRY_RUN; then
        log "[DRY-RUN] Would run upgrade script on $NODE"
        echo "STATUS $NODE DONE" >> "$LOG_DIR/upgrade.log"
    else
        ssh "$NODE" "bash $REMOTE_PATH" | tee "$LOG_DIR/${NODE}.log" || { echo "STATUS $NODE ERROR" >> "$LOG_DIR/upgrade.log"; return 1; }
        echo "STATUS $NODE DONE" >> "$LOG_DIR/upgrade.log"
    fi
}

function start_dashboard {
    log "Starting WebSocket dashboard on port $DASHBOARD_PORT..."
    python3 ./pve-upgrade-dashboard.py "$DASHBOARD_PORT" "$LOG_DIR" &
    DASHBOARD_PID=$!
    sleep 2
    local IP_ADDR
    IP_ADDR=$(hostname -I | awk '{print $1}')
    log "Dashboard running at: http://$IP_ADDR:$DASHBOARD_PORT"
    echo
    echo ">>> Open the URL above in your browser. Confirm the dashboard loads."
    read -rp "Press Enter once confirmed..."
}

function ping_nodes {
    while true; do
        for NODE in "${NODES[@]}"; do
            if node_online "$NODE"; then
                sed -i "s|STATUS $NODE .*|STATUS $NODE ONLINE|" "$LOG_DIR/upgrade.log"
            else
                sed -i "s|STATUS $NODE .*|STATUS $NODE OFFLINE|" "$LOG_DIR/upgrade.log"
            fi
        done
        sleep 5
    done
}

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        *) usage ;;
    esac
done

mkdir -p "$LOG_DIR"
> "$LOG_DIR/upgrade.log"

MODE=$(detect_cluster)
log "Detected environment: $MODE"

if [ "$MODE" = "single" ]; then
    NODE=$(hostname)
    echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"
    start_dashboard
    read -rp "Upgrade this single node now? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
    upgrade_node "$NODE"
else
    NODES=($(get_nodes))
    for NODE in "${NODES[@]}"; do
        echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"
    done

    echo "Cluster nodes detected: ${NODES[*]}"
    echo "Options:"
    echo "1) Upgrade just this node ($(hostname))"
    echo "2) Upgrade all cluster nodes sequentially"
    read -rp "Choose option (1/2): " CHOICE

    start_dashboard
    ping_nodes &

    if [ "$CHOICE" = "1" ]; then
        upgrade_node "$(hostname)"
    else
        for NODE in "${NODES[@]}"; do
            push_upgrade_script "$NODE"
            upgrade_node "$NODE"
            if ! $DRY_RUN; then
                log "Rebooting $NODE..."
                wait_for_node_online "$NODE"
                wait_for_quorum "$NODE"
            fi
        done
    fi
fi

log "Upgrade complete!"
wait $DASHBOARD_PID
