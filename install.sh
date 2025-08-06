#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/seanford/pve_helper_scripts.git"
REPO_DIR="/root/pve_helper_scripts"
REPO_BRANCH="main"
RESET_SCRIPTS=false

# Parse flags
for arg in "$@"; do
    case $arg in
        --reset-scripts) RESET_SCRIPTS=true ;;
    esac
done

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

LIVE_UPGRADE="$REPO_DIR/pve8to9-upgrade/pve8to9-upgrade.sh"
LIVE_ROLLBACK="$REPO_DIR/pve8to9-upgrade/pve8to9-rollback.sh"
DEF_UPGRADE="$REPO_DIR/pve8to9-upgrade/defaults/pve8to9-upgrade.sh"
DEF_ROLLBACK="$REPO_DIR/pve8to9-upgrade/defaults/pve8to9-rollback.sh"

# 🔍 Check defaults integrity
echo "[`date '+%Y-%m-%d %H:%M:%S'`] Checking defaults integrity..."
DEFAULTS_OK=true
for file in "$DEF_UPGRADE" "$DEF_ROLLBACK"; do
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] Missing or empty default: $(basename "$file")"
        DEFAULTS_OK=false
    fi
done

if ! $DEFAULTS_OK; then
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] Restoring missing/corrupted default scripts from GitHub..."
    mkdir -p "$(dirname "$DEF_UPGRADE")"
    curl -sSL -o "$DEF_UPGRADE" "https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/defaults/pve8to9-upgrade.sh"
    curl -sSL -o "$DEF_ROLLBACK" "https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/defaults/pve8to9-rollback.sh"
    chmod +x "$DEF_UPGRADE" "$DEF_ROLLBACK"
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] Defaults restored."
fi

# 🔄 Update live scripts from defaults
echo "[`date '+%Y-%m-%d %H:%M:%S'`] Ensuring upgrade/rollback scripts are up to date..."
update_script() {
    local TARGET=$1
    local SOURCE=$2
    local FILE_NAME=$(basename "$TARGET")
    local DEFAULT_SIG="AUTO-CREATED DEFAULT"

    if $RESET_SCRIPTS; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] --reset-scripts: Forcing update of $FILE_NAME from defaults."
        cp "$SOURCE" "$TARGET"
        chmod +x "$TARGET"
        return
    fi

    if [ ! -f "$TARGET" ]; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] $FILE_NAME missing — copying from defaults."
        cp "$SOURCE" "$TARGET"
        chmod +x "$TARGET"
    elif grep -q "$DEFAULT_SIG" "$TARGET"; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] $FILE_NAME is default — updating from defaults."
        cp "$SOURCE" "$TARGET"
        chmod +x "$TARGET"
    else
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] $FILE_NAME customized — leaving untouched."
    fi
}

update_script "$LIVE_UPGRADE" "$DEF_UPGRADE"
update_script "$LIVE_ROLLBACK" "$DEF_ROLLBACK"

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Cleaning up dashboard processes..."
pkill -f pve-upgrade-dashboard.py >/dev/null 2>&1 || true
fuser -k 8080/tcp >/dev/null 2>&1 || true
fuser -k 8081/tcp >/dev/null 2>&1 || true
echo "[`date '+%Y-%m-%d %H:%M:%S'`] Dashboard cleaned up."

echo "[`date '+%Y-%m-%d %H:%M:%S'`] Launching orchestrator..."
bash "$REPO_DIR/pve8to9-upgrade/pve-upgrade-orchestrator.sh" "$@"
