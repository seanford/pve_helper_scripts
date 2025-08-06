#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/pve8to9-backup-$TS"

echo "Backing up configs to $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
cp -a /etc/apt/sources.list* "$BACKUP_DIR/" || true
cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" || true
cp -a /etc/pve "$BACKUP_DIR/etc-pve" || true
cp -a /etc/network/interfaces "$BACKUP_DIR/" || true

echo "Running PVE 8 → 9 upgrade..."
if pveversion | grep -q "pve-manager/9"; then
    echo "Already on PVE 9. Skipping."
    exit 0
fi

if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    mv /etc/apt/sources.list.d/pve-enterprise.list{,.bak}
fi

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF

cat > /etc/apt/sources.list.d/pve9.list <<EOF
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

wget -qO - https://enterprise.proxmox.com/debian/proxmox-release-9.x.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/proxmox-release-9.gpg

apt update
apt dist-upgrade -y
apt autoremove --purge -y
echo "Upgrade complete. Please reboot."
