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
NO_DASHBOARD=false
DASHBOARD_PYTHON="python3"
VENV_DIR="$SCRIPT_DIR/venv"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# -----------------------
# Parse Flags
# -----------------------
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --no-update) NO_UPDATE=true ;;
        --force-venv) FORCE_VENV=true ;;
        --snapshot) SNAPSHOT=true ;;
        --no-dashboard) NO_DASHBOARD=true ;;
    esac
done

# -----------------------
# Cleanup dashboard
# -----------------------
function cleanup_dashboard {
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] Cleaning up dashboard processes..."
    pkill -f pve-upgrade-dashboard.py >/dev/null 2>&1 || true
    fuser -k ${DASHBOARD_PORT}/tcp >/dev/null 2>&1 || true
    fuser -k $((DASHBOARD_PORT+1))/tcp >/dev/null 2>&1 || true
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] Dashboard cleaned up."
}
trap cleanup_dashboard EXIT

# -----------------------
# Logging
# -----------------------
function log {
    local MSG="[`date '+%F %T'`] $1"
    echo "$MSG"
    echo "$MSG" >> "$LOG_DIR/upgrade.log"
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
    if $FORCE_VENV; then
        if ! dpkg -s python3-venv &>/dev/null; then
            log "Installing missing package: python3-venv"
            apt-get install -y python3-venv
        fi
    else
        if ! python3 -c "import websockets" &>/dev/null; then
            log "Installing Python websockets via apt..."
            apt-get install -y python3-websockets
        fi
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
        if ! git fetch --all || ! git reset --hard origin/main || ! git clean -fdx || ! git pull --force; then
            log "Git update failed — deleting and recloning..."
            cd /root
            rm -rf "$REPO_DIR"
            git clone "$REPO_URL" "$REPO_DIR"
        fi
        cd -
    fi
    chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py
}

# -----------------------
# Refresh known_hosts
# -----------------------
function refresh_known_hosts {
    # Update SSH known_hosts for all cluster nodes
    log "Refreshing SSH known_hosts entries..."
    if ! bash "$REPO_DIR/update_known_hosts/update_known_hosts.sh"; then
        log "WARNING: known_hosts update failed; proceeding anyway"
    fi
}

# -----------------------
# Validate scripts
# -----------------------
function validate_scripts {
    MISSING_SCRIPTS=false

    if [ ! -f "$SCRIPT_DIR/pve8to9-upgrade.sh" ]; then
        log "ERROR: pve8to9-upgrade.sh missing."
        # Log without STATUS prefix so the dashboard ignores this placeholder
        echo "ALL_NODES MISSING-UPGRADE-SCRIPT" >> "$LOG_DIR/upgrade.log"
        MISSING_SCRIPTS=true
    fi
    if [ ! -f "$SCRIPT_DIR/pve8to9-rollback.sh" ]; then
        log "ERROR: pve8to9-rollback.sh missing."
        # Log without STATUS prefix so the dashboard ignores this placeholder
        echo "ALL_NODES MISSING-ROLLBACK-SCRIPT" >> "$LOG_DIR/upgrade.log"
        MISSING_SCRIPTS=true
    fi

    if $MISSING_SCRIPTS; then
        log "Some required scripts are missing. Auto-creating from defaults..."
        DEF_DIR="$SCRIPT_DIR/defaults"
        mkdir -p "$DEF_DIR"

        if [ ! -f "$DEF_DIR/pve8to9-upgrade.sh" ] || [ ! -f "$DEF_DIR/pve8to9-rollback.sh" ]; then
            log "Defaults missing — restoring from GitHub..."
            curl -sSL -o "$DEF_DIR/pve8to9-upgrade.sh" "https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/defaults/pve8to9-upgrade.sh"
            curl -sSL -o "$DEF_DIR/pve8to9-rollback.sh" "https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/defaults/pve8to9-rollback.sh"
            chmod +x "$DEF_DIR"/*.sh
        fi

        cp "$DEF_DIR/pve8to9-upgrade.sh" "$SCRIPT_DIR/pve8to9-upgrade.sh"
        cp "$DEF_DIR/pve8to9-rollback.sh" "$SCRIPT_DIR/pve8to9-rollback.sh"
        chmod +x "$SCRIPT_DIR"/*.sh
        log "Default upgrade/rollback scripts created."
    fi
}

# -----------------------
# Detect cluster
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
# Push & upgrade
# -----------------------
function push_upgrade_script {
    local NODE=$1
    scp "$SCRIPT_DIR/pve8to9-upgrade.sh" "$NODE:$REMOTE_PATH"
    ssh "$NODE" "chmod +x $REMOTE_PATH"
}

function collect_backup {
    local NODE=$1
    log "Collecting backup from $NODE..."
    local REMOTE_BACKUP
    REMOTE_BACKUP=$(ssh "$NODE" "ls -td /root/pve8to9-backup-* 2>/dev/null | head -1")
    if [ -z "$REMOTE_BACKUP" ]; then
        log "No backup directory found on $NODE."
        return
    fi
    local DEST="$BACKUP_BASE/$NODE"
    mkdir -p "$DEST"
    if scp -r "$NODE:$REMOTE_BACKUP" "$DEST/"; then
        log "Backup from $NODE stored at $DEST/$(basename "$REMOTE_BACKUP")"
    else
        log "WARNING: Failed to copy backup from $NODE"
    fi
}

function upgrade_node {
    local NODE=$1
    log "Upgrading $NODE..."
    echo "STATUS $NODE RUNNING" >> "$LOG_DIR/upgrade.log"
    local SNAP_FLAG=""
    if $SNAPSHOT; then SNAP_FLAG="--snapshot"; fi
    if ! ssh "$NODE" "bash $REMOTE_PATH $SNAP_FLAG"; then
        echo "STATUS $NODE ERROR" >> "$LOG_DIR/upgrade.log"
        return 1
    fi
    echo "STATUS $NODE DONE" >> "$LOG_DIR/upgrade.log"
}

# -----------------------
# Dashboard
# -----------------------
function start_dashboard {
    if $NO_DASHBOARD; then
        log "Skipping dashboard (--no-dashboard specified)"
        return
    fi

    log "Starting dashboard..."
    local DASHBOARD_SCRIPT="$SCRIPT_DIR/pve-upgrade-dashboard.py"

    if [ ! -f "$DASHBOARD_SCRIPT" ]; then
        log "ERROR: Dashboard script missing at $DASHBOARD_SCRIPT"
        log "Continuing without dashboard..."
        return
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log "ERROR: Python3 not found — cannot start dashboard."
        log "Continuing without dashboard..."
        return
    fi

    if $FORCE_VENV; then
        log "Setting up Python virtual environment for dashboard..."
        if [ ! -d "$VENV_DIR" ]; then
            python3 -m venv "$VENV_DIR"
        fi
        log "Installing dashboard dependencies..."
        "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1
        "$VENV_DIR/bin/pip" install websockets >/dev/null 2>&1
        DASHBOARD_PYTHON="$VENV_DIR/bin/python"
    fi

    $DASHBOARD_PYTHON "$DASHBOARD_SCRIPT" "$DASHBOARD_PORT" "$LOG_DIR" &
    DASHBOARD_PID=$!
    sleep 2

    if ! ps -p $DASHBOARD_PID >/dev/null 2>&1; then
        log "ERROR: Dashboard process failed to start. Continuing without dashboard..."
        return
    fi

    local IP=$(hostname -I | awk '{print $1}')
    log "Dashboard running at: http://$IP:$DASHBOARD_PORT/pve8to9"
}

# -----------------------
# CLI Progress (no-dashboard)
# -----------------------
function cli_progress {
    local TOTAL=$1
    local CURRENT=$2
    local PERCENT=$(( CURRENT * 100 / TOTAL ))
    local BAR_LENGTH=30
    local FILLED=$(( PERCENT * BAR_LENGTH / 100 ))
    local EMPTY=$(( BAR_LENGTH - FILLED ))
    printf "\r[%-${BAR_LENGTH}s] %d%% (%d/%d)" "$(printf '#%.0s' $(seq 1 $FILLED))" "$PERCENT" "$CURRENT" "$TOTAL"
}

# -----------------------
# Main
# -----------------------
mkdir -p "$LOG_DIR" "$BACKUP_BASE"
> "$LOG_DIR/upgrade.log"

install_prereqs
self_update
refresh_known_hosts
validate_scripts

MODE=$(detect_cluster)
log "Detected mode: $MODE"

if [ "$MODE" = "single" ]; then
    NODE=$(hostname)
    echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"
    start_dashboard
    log "Starting upgrade for $NODE"
    push_upgrade_script "$NODE"
    upgrade_node "$NODE"
else
    NODES=($(get_nodes))
    for NODE in "${NODES[@]}"; do echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"; done
    log "Cluster nodes: ${NODES[*]}"
    start_dashboard
    COUNT=0
    TOTAL=${#NODES[@]}
    for NODE in "${NODES[@]}"; do
        COUNT=$((COUNT+1))
        if $NO_DASHBOARD; then cli_progress $TOTAL $COUNT; fi
        push_upgrade_script "$NODE"
        upgrade_node "$NODE"
    done
    if $NO_DASHBOARD; then echo; fi
fi
