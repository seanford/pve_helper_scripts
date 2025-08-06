#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/pve8to9-upgrade.log"
if ! touch "$LOGFILE" 2>/dev/null; then
    echo "[ERROR] Cannot create log file $LOGFILE. Check permissions." >&2
    exit 1
fi
exec > >(tee -a "$LOGFILE") 2>&1

command -v pveversion >/dev/null 2>&1 || { echo "[ERROR] pveversion command not found!"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "[ERROR] apt-get command not found!"; exit 1; }
command -v pvecm >/dev/null 2>&1 || { echo "[ERROR] pvecm command not found!"; exit 1; }
command -v qm >/dev/null 2>&1 || { echo "[ERROR] qm command not found!"; exit 1; }

SNAPSHOT=false
SNAP_NAME="pre-pve8to9-$(date +%Y%m%d-%H%M%S)"
VM_IDS=""

for arg in "$@"; do
    case $arg in
        --snapshot) SNAPSHOT=true ;;
    esac
done

# Create snapshots for each VM before the upgrade
create_vm_snapshots() {
    VM_IDS=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    for VMID in $VM_IDS; do
        echo "[*] Creating snapshot for VM $VMID..."
        qm snapshot "$VMID" "$SNAP_NAME" >/dev/null 2>&1 || echo "[WARNING] Snapshot failed for VM $VMID"
    done
}

# Roll back VMs to the pre-upgrade snapshots
rollback_vm_snapshots() {
    for VMID in $VM_IDS; do
        echo "[*] Rolling back VM $VMID to snapshot $SNAP_NAME..."
        qm rollback "$VMID" "$SNAP_NAME" >/dev/null 2>&1 || echo "[WARNING] Rollback failed for VM $VMID"
    done
}

# Handle upgrade failures and trigger rollback when enabled
handle_failure() {
    echo "[ERROR] Upgrade failed. Rolling back snapshots..."
    if $SNAPSHOT; then
        rollback_vm_snapshots
    fi
}
trap handle_failure ERR

echo "================================================================="
echo " Starting Proxmox VE 8 → 9 Upgrade on $(hostname)"
echo "================================================================="

# -----------------------
# 1. Safety checks
# -----------------------
echo "[*] Checking Proxmox version..."
CURRENT_VER=""
CURRENT_VER=$(pveversion | awk '{print $2}' | cut -d'.' -f1 2>/dev/null || echo "")
if ! [[ "$CURRENT_VER" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Unable to determine Proxmox major version. Aborting."
    exit 1
fi
if [[ "$CURRENT_VER" -lt 8 ]]; then
    echo "[ERROR] This node is not running Proxmox 8.x. Aborting."
    exit 1
fi
if [[ "$CURRENT_VER" -ge 9 ]]; then
    echo "[INFO] Node is already running Proxmox 9.x. Skipping upgrade."
    exit 0
fi

echo "[*] Checking for pending updates..."
apt-get update
apt-get dist-upgrade -y

echo "[*] Ensuring no package locks..."
if lsof /var/lib/dpkg/lock >/dev/null 2>&1; then
    echo "[ERROR] Package manager lock detected. Please resolve before retry."
    exit 1
fi

echo "[*] Checking cluster status..."
if ! pvecm status | grep -q "Quorate"; then
    echo "[ERROR] Cluster not quorate — ensure connectivity. Aborting."
    exit 1
else
    echo "[OK] Cluster is quorate."
fi

# -----------------------
# Snapshot (optional)
# -----------------------
if $SNAPSHOT; then
    echo "[*] Creating VM snapshots (name: $SNAP_NAME)..."
    create_vm_snapshots
fi

# -----------------------
# 2. Backup configs
# -----------------------
BACKUP_DIR="/root/pve8to9-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "[*] Backing up key configuration files to $BACKUP_DIR..."
if [ -f /etc/apt/sources.list ]; then
    cp -a /etc/apt/sources.list* "$BACKUP_DIR/" || echo "[WARNING] Could not back up sources.list files"
fi
if [ -d /etc/apt/sources.list.d ]; then
    cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" || echo "[WARNING] Could not back up sources.list.d directory"
fi
if [ -d /etc/pve ]; then
    cp -a /etc/pve "$BACKUP_DIR/etc-pve" || echo "[WARNING] Could not back up /etc/pve directory"
fi
if [ -f /etc/network/interfaces ]; then
    cp -a /etc/network/interfaces "$BACKUP_DIR/" || echo "[WARNING] Could not back up network interfaces"
fi
dpkg --get-selections > "$BACKUP_DIR/pkg-selections.txt"
dpkg-query -W -f='${Package} ${Version}\n' > "$BACKUP_DIR/pkg-versions.txt"

# -----------------------
# 3. Update sources to Proxmox 9
# -----------------------
echo "[*] Updating APT sources to Proxmox 9 repos..."
if [ -f /etc/apt/sources.list ]; then
    sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
fi
if [ -d /etc/apt/sources.list.d ]; then
    find /etc/apt/sources.list.d -type f -name '*.list' -exec sed -i 's/bookworm/trixie/g' {} +
fi

# -----------------------
# 4. Update package index
# -----------------------
apt-get update

# -----------------------
# 5. Full distribution upgrade
# -----------------------
echo "[*] Performing dist-upgrade..."
apt-get dist-upgrade -y

# -----------------------
# 6. Cleanup
# -----------------------
echo "[*] Cleaning up old packages..."
apt-get autoremove -y
apt-get autoclean -y

# -----------------------
# 7. Final checks
# -----------------------
NEW_VER=""
NEW_VER=$(pveversion | awk '{print $2}' | cut -d'.' -f1 2>/dev/null || echo "")
if [[ "$NEW_VER" =~ ^9$ ]]; then
    echo "[SUCCESS] Upgrade completed successfully on $(hostname)"
else
    echo "[WARNING] Upgrade finished but version check did not return 9.x"
fi

echo "================================================================="
echo " Upgrade log saved to $LOGFILE"
echo "================================================================="
