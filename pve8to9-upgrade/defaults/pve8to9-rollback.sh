#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/pve8to9-rollback.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "================================================================="
echo " Starting Proxmox VE 8 → 9 Rollback on $(hostname)"
echo "================================================================="

# -----------------------
# 1. Locate latest backup
# -----------------------
BACKUP_BASE="/root"
LATEST_BACKUP=$(ls -1td "$BACKUP_BASE"/pve8to9-backup-* 2>/dev/null | head -n 1 || true)

if [[ -z "$LATEST_BACKUP" ]]; then
    echo "[ERROR] No pve8to9-backup-* directory found. Cannot rollback."
    exit 1
fi

echo "[*] Using backup directory: $LATEST_BACKUP"

# -----------------------
# 2. Restore configuration files
# -----------------------
echo "[*] Restoring APT sources..."
cp -a "$LATEST_BACKUP"/sources.list* /etc/apt/ 2>/dev/null || true
if [ -d "$LATEST_BACKUP"/sources.list.d ]; then
    cp -a "$LATEST_BACKUP"/sources.list.d /etc/apt/ 2>/dev/null || true
fi

echo "[*] Restoring Proxmox configs..."
cp -a "$LATEST_BACKUP"/etc-pve /etc/pve 2>/dev/null || true

echo "[*] Restoring network interfaces..."
cp -a "$LATEST_BACKUP"/interfaces /etc/network/interfaces 2>/dev/null || true

# -----------------------
# 3. Reinstall packages from backup versions
# -----------------------
echo "[*] Restoring package versions..."
if [[ -f "$LATEST_BACKUP/pkg-versions.txt" ]]; then
    apt-get update -y
    while read pkg ver; do
        apt-get install -y "$pkg=$ver" || true
    done < "$LATEST_BACKUP/pkg-versions.txt"
else
    echo "[WARNING] pkg-versions.txt not found. Skipping package restore."
fi

# -----------------------
# 4. Final cleanup
# -----------------------
echo "[*] Cleaning up..."
apt-get autoremove -y
apt-get autoclean -y

echo "================================================================="
echo " Rollback completed on $(hostname)"
echo " Logs saved to $LOGFILE"
echo "================================================================="
