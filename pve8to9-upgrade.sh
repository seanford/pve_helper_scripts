#!/usr/bin/env bash
set -euo pipefail

echo "===> Running Proxmox VE 8 to 9 upgrade on $(hostname)..."

# Optional pre-check
if pveversion | grep -q "^pve-manager/9"; then
  echo "This node is already on PVE 9. Skipping."
  exit 0
fi

# Disable enterprise repo
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  mv /etc/apt/sources.list.d/pve-enterprise.list{,.bak}
fi

# Update sources
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF

cat > /etc/apt/sources.list.d/pve9.list <<EOF
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

# Import key
wget -qO - https://enterprise.proxmox.com/debian/proxmox-release-9.x.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/proxmox-release-9.gpg

# Optional LVM fix
/usr/share/pve-manager/migrations/pve-lvm-disable-autoactivation || true

# Upgrade
apt update
apt dist-upgrade -y

# Clean up
apt autoremove --purge -y
echo "Upgrade complete. Please reboot to finalize."
