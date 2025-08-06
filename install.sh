#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/seanford/pve_helper_scripts.git"
REPO_DIR="/root/pve_helper_scripts"
ORCHESTRATOR="$REPO_DIR/pve8to9-upgrade/pve-upgrade-orchestrator.sh"

echo "===> Cloning or updating Sean's PVE helper scripts..."
if [ ! -d "$REPO_DIR" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
else
  cd "$REPO_DIR"
  git pull --rebase
  cd -
fi

echo "===> Running orchestrator..."
chmod +x "$ORCHESTRATOR"
"$ORCHESTRATOR"
