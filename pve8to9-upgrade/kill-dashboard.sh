#!/usr/bin/env bash
set -euo pipefail

PORT=8080

echo "Killing Python dashboard processes..."

pkill -f pve-upgrade-dashboard.py >/dev/null 2>&1 || [[ $? -eq 1 ]]
fuser -k "${PORT}/tcp" 2>/dev/null || [[ $? -eq 1 ]]
fuser -k "$((PORT + 1))/tcp" 2>/dev/null || [[ $? -eq 1 ]]

echo "Dashboard processes cleaned up."
