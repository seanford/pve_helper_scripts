#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/pve8to9-rollback.log"
touch "$LOGFILE" || { echo "Cannot create log file $LOGFILE"; exit 1; }
exec > >(tee -a "$LOGFILE") 2>&1

echo "Starting PVE 8 to 9 rollback script at $(date)"

# Check Proxmox VE version
pvever_output=$(pveversion 2>/dev/null || true)
if [[ -z "$pvever_output" ]]; then
    echo "Error: pveversion command failed or returned empty output."
    exit 1
fi
pvever=$(echo "$pvever_output" | grep -oP '\d+' | head -1)

if [[ -z "$pvever" ]]; then
    echo "Error: Could not extract Proxmox VE version from pveversion output."
    exit 1
fi

if [[ "$pvever" -ne 9 ]]; then
    echo "This rollback script is intended for PVE 9 only. Detected version: $pvever"
    exit 1
fi

echo "Detected Proxmox VE version: $pvever"

# Find backup file
BACKUP_DIR="/root/pve8to9-backups"
latest_backup=$(ls -1t "$BACKUP_DIR"/pve8to9-backup-* 2>/dev/null | head -n 1 || true)
if [[ -z "$latest_backup" ]]; then
    echo "No backup found in $BACKUP_DIR. Cannot proceed with rollback."
    exit 1
fi

echo "Using backup: $latest_backup"

# Check required files in backup before restoration
for f in etc/apt/sources.list etc/apt/sources.list.d etc/hosts etc/network/interfaces etc/pve; do
    if [[ ! -e "$latest_backup/$f" ]]; then
        echo "Error: Required backup file or directory missing: $latest_backup/$f"
        exit 1
    fi
done

echo "Restoring system configuration from backup..."

cp -a "$latest_backup/etc/apt/sources.list" /etc/apt/sources.list
cp -a "$latest_backup/etc/apt/sources.list.d/" /etc/apt/sources.list.d/
cp -a "$latest_backup/etc/hosts" /etc/hosts
cp -a "$latest_backup/etc/network/interfaces" /etc/network/interfaces
cp -a "$latest_backup/etc/pve/" /etc/pve/

echo "Restoration complete."

# Edit sources.list safely
if grep -q "trixie" /etc/apt/sources.list; then
    sed -i 's/trixie/bookworm/g' /etc/apt/sources.list
fi

for file in /etc/apt/sources.list.d/*.list; do
    if [[ -f "$file" ]] && grep -q "trixie" "$file"; then
        sed -i 's/trixie/bookworm/g' "$file"
    fi
done

echo "APT sources updated to 'bookworm'."

# Downgrade Proxmox VE
echo "Starting package downgrade to PVE 8..."
if ! apt-get update; then
    echo "Error: apt-get update failed."
    exit 1
fi
if ! apt-get install proxmox-ve=8.* --allow-downgrades; then
    echo "Error: proxmox-ve downgrade failed."
    exit 1
fi

echo "Cleaning up packages..."
apt-get autoremove -y || { echo "Warning: autoremove failed"; }
apt-get autoclean || { echo "Warning: autoclean failed"; }

# Check new version
new_ver_output=$(pveversion 2>/dev/null || true)
new_ver=$(echo "$new_ver_output" | grep -oP '\d+' | head -1)
if [[ "$new_ver" -ne 8 ]]; then
    echo "Warning: Downgrade may not have completed successfully. Detected version: $new_ver"
else
    echo "Rollback to PVE 8 complete. Detected version: $new_ver"
fi

echo "Script completed at $(date)".
