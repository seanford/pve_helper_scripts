#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/seanford/pve_helper_scripts.git"
REPO_DIR="/root/pve_helper_scripts"

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Checking prerequisites..."
apt-get update -y
for pkg in git curl; do
    if ! dpkg -s $pkg &>/dev/null; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] Installing missing package: $pkg"
        apt-get install -y $pkg
    fi
done

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Updating repo..."
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
else
    cd "$REPO_DIR"
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] Resetting local changes..."
    if ! git fetch --all || ! git reset --hard origin/main || ! git clean -fdx || ! git pull --force; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] Git update failed — recloning..."
        cd /root
        rm -rf "$REPO_DIR"
        git clone "$REPO_URL" "$REPO_DIR"
    fi
fi

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Cleaning up dashboard processes..."
pkill -f pve-upgrade-dashboard.py >/dev/null 2>&1 || true
fuser -k 8080/tcp >/dev/null 2>&1 || true
fuser -k 8081/tcp >/dev/null 2>&1 || true
echo "[`date '+%Y-%m-%d %H:%M:%S'`] Dashboard cleaned up."

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Launching orchestrator..."
bash "$REPO_DIR/pve8to9-upgrade/pve-upgrade-orchestrator.sh"
