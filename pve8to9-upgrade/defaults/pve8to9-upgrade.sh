#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/pve8to9-upgrade.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "================================================================="
echo " Starting Proxmox VE 8 → 9 Upgrade on $(hostname)"
echo "================================================================="

# -----------------------
# 1. Safety checks
# -----------------------
echo "[*] Checking Proxmox version..."
CURRENT_VER=$(pveversion | awk '{print $2}' | cut -d'.' -f1)
if [[ "$CURRENT_VER" -lt 8 ]]; then
    echo "[ERROR] This node is not running Proxmox 8.x. Aborting."
    exit 1
fi

echo "[*] Checking for pending updates..."
apt-get update -y
apt-get dist-upgrade -y

echo "[*] Ensuring no package locks..."
if lsof /var/lib/dpkg/lock >/dev/null 2>&1; then
    echo "[ERROR] Package manager lock detected. Please resolve before retry."
    exit 1
fi

echo "[*] Checking cluster status..."
if pvecm status | grep -q "Quorate"; then
    echo "[OK] Cluster is quorate."
else
    echo "[WARNING] Cluster not quorate — ensure connectivity."
fi

# -----------------------
# 2. Backup configs
# -----------------------
echo "[*] Backing up key configuration files..."
BACKUP_DIR="/root/pve8to9-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/apt/sources.list* "$BACKUP_DIR/" || true
cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" || true
cp -a /etc/pve "$BACKUP_DIR/etc-pve" || true
cp -a /etc/network/interfaces "$BACKUP_DIR/" || true
dpkg --get-selections > "$BACKUP_DIR/pkg-selections.txt"
dpkg-query -W -f='${Package} ${Version}\n' > "$BACKUP_DIR/pkg-versions.txt"

# -----------------------
# 3. Update sources to Proxmox 9
# -----------------------
echo "[*] Updating APT sources to Proxmox 9 repos..."
sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
if [ -d /etc/apt/sources.list.d ]; then
    sed -i 's/bookworm/trixie/g' /etc/apt/sources.list.d/*.list || true
fi

# -----------------------
# 4. Update package index
# -----------------------
echo "[*] Running apt-get update..."
apt-get update -y

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
echo "[*] Checking Proxmox version post-upgrade..."
NEW_VER=$(pveversion | awk '{print $2}' | cut -d'.' -f1)
if [[ "$NEW_VER" -eq 9 ]]; then
    echo "[SUCCESS] Upgrade completed successfully on $(hostname)"
else
    echo "[WARNING] Upgrade finished but version check did not return 9.x"
fi

echo "================================================================="
echo " Upgrade log saved to $LOGFILE"
echo "================================================================="
