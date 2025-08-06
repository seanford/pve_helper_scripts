#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/seanford/pve_helper_scripts.git"
REPO_DIR="/root/pve_helper_scripts"
SCRIPT_DIR="$REPO_DIR/pve8to9-upgrade"
REMOTE_PATH="/root/pve8to9-upgrade.sh"
LOG_DIR="/root/pve-upgrade-logs"
BACKUP_BASE="/root/pve-upgrade-backups"
DASHBOARD_PORT=8080
DRY_RUN=false
NO_UPDATE=false
FORCE_VENV=false
SNAPSHOT=false
DASHBOARD_PYTHON="python3"

# -----------------------
# Logging
# -----------------------
function log {
    local MSG="[`date '+%F %T'`] $1"
    echo "$MSG"
    echo "$MSG" >> "$LOG_DIR/upgrade.log"
}

function usage {
    echo "Usage: $0 [--dry-run] [--no-update] [--force-venv] [--snapshot]"
    exit 1
}

# -----------------------
# Prerequisites
# -----------------------
function install_prereqs {
    log "Checking prerequisites..."
    apt-get update -y
    for pkg in python3 python3-pip git tar zip curl wget; do
        if ! dpkg -s $pkg &>/dev/null; then
            log "Installing missing package: $pkg"
            apt-get install -y $pkg
        fi
    done
    if ! python3 -c "import websockets" &>/dev/null; then
        log "Installing Python websockets via apt..."
        apt-get install -y python3-websockets
    fi
    local ver
    ver=$(python3 -c "import websockets; print(websockets.__version__)" 2>/dev/null || echo "0")
    log "Detected websockets version: $ver"
    if $FORCE_VENV || [ "$ver" != "0" ] && [ "$(printf '%s\n' "10.0" "$ver" | sort -V | head -n1)" != "10.0" ]; then
        log "Using venv for websockets..."
        apt-get install -y python3-venv
        VENV_DIR="$REPO_DIR/venv"
        python3 -m venv "$VENV_DIR"
        "$VENV_DIR/bin/pip" install --upgrade pip websockets
        DASHBOARD_PYTHON="$VENV_DIR/bin/python"
    else
        DASHBOARD_PYTHON="python3"
    fi
}

# -----------------------
# Self-update
# -----------------------
function self_update {
    if $NO_UPDATE; then
        log "Skipping self-update (--no-update specified)"
        return
    fi
    log "Updating repo..."
    if [ ! -d "$REPO_DIR" ]; then
        git clone "$REPO_URL" "$REPO_DIR"
    else
        cd "$REPO_DIR"
        log "Resetting local changes..."
        git reset --hard HEAD
        git clean -fd
        git fetch --all
        git pull --rebase
        cd -
    fi
    chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py
}


# -----------------------
# Cluster detection
# -----------------------
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

# -----------------------
# Snapshots
# -----------------------
function create_snapshot {
    local NODE=$1
    if ! $SNAPSHOT; then return; fi
    log "Checking if $NODE is a VM..."
    local VMID
    VMID=$(pvecm nodes | grep -w "$NODE" | awk '{print $2}' 2>/dev/null || echo "")
    if [ -z "$VMID" ]; then
        log "$NODE is not a VM, skipping snapshot."
        return
    fi
    local SNAP_NAME="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
    log "Creating snapshot $SNAP_NAME for VM $VMID..."
    qm snapshot "$VMID" "$SNAP_NAME" --description "Snapshot before upgrade"
}

function revert_snapshot {
    local NODE=$1
    log "Reverting $NODE to snapshot..."
    local VMID
    VMID=$(pvecm nodes | grep -w "$NODE" | awk '{print $2}' 2>/dev/null || echo "")
    if [ -z "$VMID" ]; then
        log "$NODE is not a VM."
        return 1
    fi
    local SNAP_NAME
    SNAP_NAME=$(qm listsnapshot "$VMID" | grep "pre-upgrade" | tail -n1 | awk '{print $1}')
    qm rollback "$VMID" "$SNAP_NAME"
}

# -----------------------
# Backup & Rollback
# -----------------------
function backup_node_configs {
    local NODE=$1
    local TS
    TS=$(date +"%Y%m%d-%H%M%S")
    local BACKUP_DIR="$BACKUP_BASE/$NODE/$TS"
    log "Backing up $NODE configs to $BACKUP_DIR"
    ssh "$NODE" "mkdir -p $BACKUP_DIR"
    ssh "$NODE" "cp -a /etc/apt/sources.list* $BACKUP_DIR/ 2>/dev/null || true"
    ssh "$NODE" "cp -a /etc/pve $BACKUP_DIR/etc-pve 2>/dev/null || true"
    ssh "$NODE" "cp -a /etc/network/interfaces $BACKUP_DIR/ 2>/dev/null || true"
    ssh "$NODE" "dpkg --get-selections > $BACKUP_DIR/pkg-selections.txt"
    ssh "$NODE" "apt-mark showmanual > $BACKUP_DIR/pkg-manual.txt"
    ssh "$NODE" "dpkg-query -W -f='\${Package} \${Version}\n' > $BACKUP_DIR/pkg-versions.txt"
}

function rollback_node {
    local NODE=$1
    log "Rolling back $NODE..."
    local LATEST_BACKUP
    LATEST_BACKUP=$(ssh "$NODE" "ls -1t $BACKUP_BASE/$NODE | head -n1" 2>/dev/null || echo "")
    if [ -z "$LATEST_BACKUP" ]; then log "No backup found."; return 1; fi
    local BACKUP_DIR="$BACKUP_BASE/$NODE/$LATEST_BACKUP"
    ssh "$NODE" "cp -a $BACKUP_DIR/sources.list* /etc/apt/ 2>/dev/null || true"
    ssh "$NODE" "cp -a $BACKUP_DIR/etc-pve /etc/pve 2>/dev/null || true"
    ssh "$NODE" "cp -a $BACKUP_DIR/interfaces /etc/network/interfaces 2>/dev/null || true"
    ssh "$NODE" "apt-get update"
    ssh "$NODE" "dpkg --set-selections < $BACKUP_DIR/pkg-selections.txt"
    ssh "$NODE" "apt-mark manual \$(cat $BACKUP_DIR/pkg-manual.txt)"
    ssh "$NODE" "apt-get dselect-upgrade -y"
    while IFS=" " read -r pkg ver; do
        ssh "$NODE" "apt-get install -y $pkg=$ver || true"
    done < <(ssh "$NODE" "cat $BACKUP_DIR/pkg-versions.txt")
}

# -----------------------
# Upgrade Node
# -----------------------
function push_upgrade_script {
    local NODE=$1
    scp "$SCRIPT_DIR/pve8to9-upgrade.sh" "$NODE:$REMOTE_PATH"
    ssh "$NODE" "chmod +x $REMOTE_PATH"
}

function upgrade_node {
    local NODE=$1
    backup_node_configs "$NODE"
    create_snapshot "$NODE"
    log "Upgrading $NODE..."
    echo "STATUS $NODE RUNNING" >> "$LOG_DIR/upgrade.log"
    if ! ssh "$NODE" "bash $REMOTE_PATH" | tee "$LOG_DIR/${NODE}.log"; then
        echo "STATUS $NODE ERROR" >> "$LOG_DIR/upgrade.log"
        read -rp "Upgrade failed on $NODE. Rollback? (y/N): " RB
        if [[ "$RB" =~ ^[Yy]$ ]]; then
            if $SNAPSHOT; then
                read -rp "Rollback via snapshot? (y/N): " RBS
                if [[ "$RBS" =~ ^[Yy]$ ]]; then
                    revert_snapshot "$NODE"
                    return
                fi
            fi
            rollback_node "$NODE"
        fi
        return 1
    fi
    echo "STATUS $NODE DONE" >> "$LOG_DIR/upgrade.log"
}

# -----------------------
# Health Check
# -----------------------
function health_check {
    local TS
    TS=$(date '+%F %T')
    log "HEALTHCHECK BEGIN [$TS]"
    if pvecm status | grep -q "Quorate:   Yes"; then
        log "HEALTHCHECK Cluster quorum: OK"
    else
        log "HEALTHCHECK Cluster quorum: FAIL"
    fi
    for NODE in $(get_nodes); do
        if ping -c1 -W1 "$NODE" &>/dev/null; then
            log "HEALTHCHECK Node $NODE: ONLINE"
        else
            log "HEALTHCHECK Node $NODE: OFFLINE"
        fi
    done
    qm list | awk 'NR>1 {print $1, $2, $3}' | while read ID NAME STATUS; do
        log "HEALTHCHECK VM $NAME ($ID): $STATUS"
    done
    pvesm status | while read line; do
        log "HEALTHCHECK Storage: $line"
    done
    log "HEALTHCHECK END [$TS]"
}

function summary_report {
    local total_nodes success_nodes error_nodes
    total_nodes=$(grep -c "STATUS" "$LOG_DIR/upgrade.log")
    success_nodes=$(grep -c "STATUS .* DONE" "$LOG_DIR/upgrade.log" || true)
    error_nodes=$(grep -c "STATUS .* ERROR" "$LOG_DIR/upgrade.log" || true)
    log "SUMMARY BEGIN"
    log "SUMMARY Total nodes: $total_nodes"
    log "SUMMARY Successful upgrades: $success_nodes"
    log "SUMMARY Errors/Rollbacks: $error_nodes"
    log "SUMMARY END"
}

# -----------------------
# Dashboard
# -----------------------
function start_dashboard {
    log "Starting dashboard..."
    $DASHBOARD_PYTHON "$SCRIPT_DIR/pve-upgrade-dashboard.py" "$DASHBOARD_PORT" "$LOG_DIR" &
    DASHBOARD_PID=$!
    sleep 2
    local IP
    IP=$(hostname -I | awk '{print $1}')
    log "Dashboard at: http://$IP:$DASHBOARD_PORT/pve8to9"
    read -rp "Press Enter after verifying dashboard..."
}

# -----------------------
# Main
# -----------------------
mkdir -p "$LOG_DIR"
> "$LOG_DIR/upgrade.log"

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --no-update) NO_UPDATE=true ;;
        --force-venv) FORCE_VENV=true ;;
        --snapshot) SNAPSHOT=true ;;
        *) usage ;;
    esac
done

install_prereqs
self_update

MODE=$(detect_cluster)
log "Detected mode: $MODE"

if [ "$MODE" = "single" ]; then
    NODE=$(hostname)
    echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"
    start_dashboard
    read -rp "Upgrade this node? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] && upgrade_node "$NODE"
else
    NODES=($(get_nodes))
    for NODE in "${NODES[@]}"; do echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"; done
    echo "Cluster nodes: ${NODES[*]}"
    read -rp "1) This node only  2) All nodes sequentially: " CHOICE
    start_dashboard
    if [ "$CHOICE" = "1" ]; then
        upgrade_node "$(hostname)"
    else
        for NODE in "${NODES[@]}"; do
            push_upgrade_script "$NODE"
            upgrade_node "$NODE"
        done
    fi
fi

log "Upgrade complete. Running health check..."
health_check

# Periodic health re-check (5 times every 5 minutes)
for i in {1..5}; do
    log "Running periodic health check $i/5..."
    sleep 300
    health_check
done

summary_report
wait $DASHBOARD_PID
