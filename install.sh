#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/seanford/pve_helper_scripts.git"
REPO_DIR="/root/pve_helper_scripts"
REPO_BRANCH="main"

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Checking prerequisites..."
apt-get update -y
for pkg in git curl; do
    if ! dpkg -s $pkg &>/dev/null; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] Installing missing package: $pkg"
        apt-get install -y $pkg
    fi
done

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Preparing repo..."
if [ ! -d "$REPO_DIR" ]; then
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] Repo not found — cloning..."
    git clone "$REPO_URL" "$REPO_DIR"
else
    cd "$REPO_DIR"
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] Checking for repo updates..."
    git fetch origin $REPO_BRANCH >/dev/null 2>&1
    LOCAL_HASH=$(git rev-parse HEAD)
    REMOTE_HASH=$(git rev-parse origin/$REPO_BRANCH)
    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] Updating to latest commit..."
        git reset --hard origin/$REPO_BRANCH
        git clean -fdx
    else
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] Repo already up to date — skipping pull."
    fi
fi

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Cleaning up dashboard processes..."
pkill -f pve-upgrade-dashboard.py >/dev/null 2>&1 || true
fuser -k 8080/tcp >/dev/null 2>&1 || true
fuser -k 8081/tcp >/dev/null 2>&1 || true
echo "[`date '+%Y-%m-%d %H:%M:%S'`] Dashboard cleaned up."

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Launching orchestrator..."
bash "$REPO_DIR/pve8to9-upgrade/pve-upgrade-orchestrator.sh" "$@"
