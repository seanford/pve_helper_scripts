#!/usr/bin/env bash
# AUTO-CREATED DEFAULT (FULL ROBUST LOGIC)
set -euo pipefail
IFS=$'\n\t'

# Prevent unbound variable issues
: "${running:=false}"

LOGFILE="/var/log/pve8to9-rollback.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "================================================================="
echo " Starting Proxmox VE 9 → 8 Rollback on $(hostname)"
echo "================================================================="

# -----------------------
# 1. Safety checks
# -----------------------
CURRENT_VER=$(pveversion | awk '{print $2}' | cut -d'.' -f1)
if [[ "$CURRENT_VER" -lt 9 ]]; then
    echo "[INFO] Node is not running Proxmox 9.x. No rollback required."
    exit 0
fi

# -----------------------
# 2. Locate latest backup
# -----------------------
LATEST_BACKUP=$(ls -dt /root/pve8to9-backup-* 2>/dev/null | head -n 1 || true)
if [[ -z "$LATEST_BACKUP" ]]; then
    echo "[ERROR] No backup found — cannot proceed with rollback."
    exit 1
fi
echo "[OK] Using backup at $LATEST_BACKUP"

# -----------------------
# 3. Restore configuration files
# -----------------------
echo "[*] Restoring configuration files..."
cp -a "$LATEST_BACKUP"/sources.list* /etc/apt/ || true
if [ -d "$LATEST_BACKUP"/sources.list.d ]; then
    cp -a "$LATEST_BACKUP"/sources.list.d /etc/apt/ || true
fi
cp -a "$LATEST_BACKUP"/etc-pve /etc/pve || true
cp -a "$LATEST_BACKUP"/interfaces /etc/network/interfaces || true

# -----------------------
# 4. Update sources to Proxmox 8
# -----------------------
echo "[*] Updating APT sources to Proxmox 8 repos..."
sed -i 's/trixie/bookworm/g' /etc/apt/sources.list
if [ -d /etc/apt/sources.list.d ]; then
    sed -i 's/trixie/bookworm/g' /etc/apt/sources.list.d/*.list || true
fi

# -----------------------
# 5. Refresh packages
# -----------------------
apt-get update -y

# -----------------------
# 6. Downgrade proxmox-ve package
# -----------------------
echo "[*] Downgrading Proxmox VE..."
apt-get install -y proxmox-ve=8.*

# -----------------------
# 7. Cleanup
# -----------------------
apt-get autoremove -y
apt-get autoclean -y

# -----------------------
# 8. Final checks
# -----------------------
NEW_VER=$(pveversion | awk '{print $2}' | cut -d'.' -f1)
if [[ "$NEW_VER" -eq 8 ]]; then
    echo "[SUCCESS] Rollback completed successfully on $(hostname)"
else
    echo "[WARNING] Rollback finished but version check did not return 8.x"
fi

echo "================================================================="
echo " Rollback log saved to $LOGFILE"
echo "================================================================="
