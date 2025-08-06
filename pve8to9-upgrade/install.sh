#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ========================
# Configurable parameters
# ========================
REPO_URL="${REPO_URL:-https://github.com/seanford/pve_helper_scripts.git}"
REPO_DIR="${REPO_DIR:-/root/pve_helper_scripts}"
REPO_BRANCH="${REPO_BRANCH:-main}"
LOG_FILE="${LOG_FILE:-/var/log/pve_helper_scripts_install.log}"
RESET_SCRIPTS=false
DRY_RUN=false

# ========================
# Logging function
# ========================
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

# ========================
# Parse flags
# ========================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset-scripts)
            RESET_SCRIPTS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --repo-url=*)
            REPO_URL="${1#*=}"
            shift
            ;;
        --repo-dir=*)
            REPO_DIR="${1#*=}"
            shift
            ;;
        --repo-branch=*)
            REPO_BRANCH="${1#*=}"
            shift
            ;;
        --log-file=*)
            LOG_FILE="${1#*=}"
            shift
            ;;
        *)
            break
            ;;
    esac
done

# ========================
# Root privilege check
# ========================
if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root." >&2
    exit 1
fi

log "Beginning install.sh (main branch) with repo: $REPO_URL, dir: $REPO_DIR, branch: $REPO_BRANCH"

# ========================
# Prerequisite check
# ========================
log "Checking prerequisites..."
if ! $DRY_RUN; then
    apt-get update -y || { log "ERROR: apt-get update failed"; exit 1; }
fi
for pkg in git curl python3; do
    if ! dpkg -s $pkg &>/dev/null; then
        log "Installing missing package: $pkg"
        if ! $DRY_RUN; then
            apt-get install -y $pkg || { log "ERROR: Failed to install $pkg"; exit 1; }
        fi
    fi
done

# ========================
# Repo preparation
# ========================
log "Preparing repo..."
if [ ! -d "$REPO_DIR" ]; then
    log "Repo not found — cloning..."
    if ! $DRY_RUN; then
        git clone "$REPO_URL" "$REPO_DIR" || { log "ERROR: git clone failed"; exit 1; }
    fi
else
    cd "$REPO_DIR"
    log "Checking for repo updates..."
    if ! $DRY_RUN; then
        git fetch origin "$REPO_BRANCH" >/dev/null 2>&1 || { log "ERROR: git fetch failed"; exit 1; }
        LOCAL_HASH=$(git rev-parse HEAD)
        REMOTE_HASH=$(git rev-parse origin/"$REPO_BRANCH")
        if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
            log "Updating to latest commit..."
            git reset --hard origin/"$REPO_BRANCH" || { log "ERROR: git reset failed"; exit 1; }
            git clean -fdx || { log "ERROR: git clean failed"; exit 1; }
        else
            log "Repo already up to date — skipping pull."
        fi
    fi
fi

LIVE_UPGRADE="$REPO_DIR/pve8to9-upgrade/pve8to9-upgrade.sh"
LIVE_ROLLBACK="$REPO_DIR/pve8to9-upgrade/pve8to9-rollback.sh"
DEF_UPGRADE="$REPO_DIR/pve8to9-upgrade/defaults/pve8to9-upgrade.sh"
DEF_ROLLBACK="$REPO_DIR/pve8to9-upgrade/defaults/pve8to9-rollback.sh"

# ========================
# Check defaults integrity
# ========================
log "Checking defaults integrity..."
DEFAULTS_OK=true
for file in "$DEF_UPGRADE" "$DEF_ROLLBACK"; do
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        log "Missing or empty default: $(basename "$file")"
        DEFAULTS_OK=false
    fi
done

if ! $DEFAULTS_OK; then
    log "Restoring missing/corrupted default scripts from GitHub..."
    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$DEF_UPGRADE")"
        curl -sSL -o "$DEF_UPGRADE" "https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/defaults/pve8to9-upgrade.sh" || { log "ERROR: curl for DEF_UPGRADE failed"; exit 1; }
        curl -sSL -o "$DEF_ROLLBACK" "https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/defaults/pve8to9-rollback.sh" || { log "ERROR: curl for DEF_ROLLBACK failed"; exit 1; }
        chmod +x "$DEF_UPGRADE" "$DEF_ROLLBACK"
    fi
    log "Defaults restored."
fi

# ========================
# Update live scripts from defaults
# ========================
log "Ensuring upgrade/rollback scripts are up to date..."
update_script() {
    local TARGET=$1
    local SOURCE=$2
    local FILE_NAME
    FILE_NAME=$(basename "$TARGET")
    local DEFAULT_SIG="AUTO-CREATED DEFAULT"
    # Function: Updates live script from default unless customized or --reset-scripts is used
    if $RESET_SCRIPTS; then
        log "--reset-scripts: Forcing update of $FILE_NAME from defaults."
        if ! $DRY_RUN; then
            cp "$SOURCE" "$TARGET"
            chmod +x "$TARGET"
        fi
        return
    fi

    if [ ! -f "$TARGET" ]; then
        log "$FILE_NAME missing — copying from defaults."
        if ! $DRY_RUN; then
            cp "$SOURCE" "$TARGET"
            chmod +x "$TARGET"
        fi
    elif grep -q "$DEFAULT_SIG" "$TARGET"; then
        log "$FILE_NAME is default — updating from defaults."
        if ! $DRY_RUN; then
            cp "$SOURCE" "$TARGET"
            chmod +x "$TARGET"
        fi
    else
        log "$FILE_NAME customized — leaving untouched."
    fi
}

update_script "$LIVE_UPGRADE" "$DEF_UPGRADE"
update_script "$LIVE_ROLLBACK" "$DEF_ROLLBACK"

# ========================
# Clean up dashboard processes
# ========================
log "Cleaning up dashboard processes..."
if ! $DRY_RUN; then
    pkill -f pve-upgrade-dashboard.py >/dev/null 2>&1 || true
    fuser -k 8080/tcp >/dev/null 2>&1 || true
    fuser -k 8081/tcp >/dev/null 2>&1 || true
fi
log "Dashboard cleaned up."

# ========================
# Launch orchestrator
# ========================
log "Launching orchestrator..."
if ! $DRY_RUN; then
    bash "$REPO_DIR/pve8to9-upgrade/pve-upgrade-orchestrator.sh" "$@"
else
    log "DRY RUN: Orchestrator launch would be here."
fi

# ========================
# End of script
# ========================
