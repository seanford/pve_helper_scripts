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
# Cleanup dashboard processes
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
        git clone "$REPO_URL" "$REPO_DIR" || {
            log "ERROR: Failed to clone repo."
            exit 1
        }
    else
        cd "$REPO_DIR"
        log "Resetting local changes..."
        if ! git fetch --all || ! git reset --hard origin/main || ! git clean -fdx || ! git pull --force; then
            log "Git update failed — deleting and recloning..."
            cd /root
            rm -rf "$REPO_DIR"
            git clone "$REPO_URL" "$REPO_DIR" || {
                log "ERROR: Failed to reclone repo."
                exit 1
            }
        fi
        cd -
    fi
    chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py
}

# -----------------------
# Validate scripts
# -----------------------
function create_default_scripts {
    log "Creating default upgrade script..."
    cat <<'EOF' > "$SCRIPT_DIR/pve8to9-upgrade.sh"
#!/usr/bin/env bash
set -euo pipefail
LOGFILE="/var/log/pve8to9-upgrade.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "Starting PVE 8 → 9 Upgrade..."
EOF
    chmod +x "$SCRIPT_DIR/pve8to9-upgrade.sh"

    log "Creating default rollback script..."
    cat <<'EOF' > "$SCRIPT_DIR/pve8to9-rollback.sh"
#!/usr/bin/env bash
set -euo pipefail
LOGFILE="/var/log/pve8to9-rollback.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "Starting PVE 8 → 9 Rollback..."
EOF
    chmod +x "$SCRIPT_DIR/pve8to9-rollback.sh"
}

MISSING_SCRIPTS=false

function validate_scripts {
    MISSING_SCRIPTS=false
    if [ ! -f "$SCRIPT_DIR/pve8to9-upgrade.sh" ]; then
        log "ERROR: pve8to9-upgrade.sh missing."
        echo "STATUS ALL_NODES MISSING-UPGRADE-SCRIPT" >> "$LOG_DIR/upgrade.log"
        MISSING_SCRIPTS=true
    fi
    if [ ! -f "$SCRIPT_DIR/pve8to9-rollback.sh" ]; then
        log "ERROR: pve8to9-rollback.sh missing."
        echo "STATUS ALL_NODES MISSING-ROLLBACK-SCRIPT" >> "$LOG_DIR/upgrade.log"
        MISSING_SCRIPTS=true
    fi
    if $MISSING_SCRIPTS; then
        log "Launching dashboard for visual warning..."
        start_dashboard
        echo ""
        read -rp "Scripts missing. Fix them, then press Enter to re-check..." < /dev/tty
        validate_scripts  # re-check after user fixes
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
    grep -Po '(?<=name: )\\S+' /etc/pve/corosync.conf 2>/dev/null | sort -u
}

# -----------------------
# Push scripts & upgrade
# -----------------------
function push_upgrade_script {
    local NODE=$1
    scp "$SCRIPT_DIR/pve8to9-upgrade.sh" "$NODE:$REMOTE_PATH"
    ssh "$NODE" "chmod +x $REMOTE_PATH"
}

function upgrade_node {
    local NODE=$1
    log "Upgrading $NODE..."
    echo "STATUS $NODE RUNNING" >> "$LOG_DIR/upgrade.log"
    if ! ssh "$NODE" "bash $REMOTE_PATH"; then
        echo "STATUS $NODE ERROR" >> "$LOG_DIR/upgrade.log"
        return 1
    fi
    echo "STATUS $NODE DONE" >> "$LOG_DIR/upgrade.log"
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
    read -rp "Press Enter after verifying dashboard..." < /dev/tty
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
validate_scripts

MODE=$(detect_cluster)
log "Detected mode: $MODE"

if [ "$MODE" = "single" ]; then
    NODE=$(hostname)
    echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"
    start_dashboard
    read -rp "Upgrade this node? (y/N): " CONFIRM < /dev/tty
    [[ "$CONFIRM" =~ ^[Yy]$ ]] && push_upgrade_script "$NODE" && upgrade_node "$NODE"
else
    NODES=($(get_nodes))
    for NODE in "${NODES[@]}"; do echo "STATUS $NODE PENDING" >> "$LOG_DIR/upgrade.log"; done
    echo "Cluster nodes: ${NODES[*]}"
    read -rp "1) This node only  2) All nodes sequentially: " CHOICE < /dev/tty
    start_dashboard
    if [ "$CHOICE" = "1" ]; then
        push_upgrade_script "$(hostname)"
        upgrade_node "$(hostname)"
    else
        for NODE in "${NODES[@]}"; do
            push_upgrade_script "$NODE"
            upgrade_node "$NODE"
        done
    fi
fi
