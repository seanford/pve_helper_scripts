#!/usr/bin/env bash
PORT=8080
echo "Killing Python dashboard processes..."
pkill -f pve-upgrade-dashboard.py >/dev/null 2>&1 || true
fuser -k ${PORT}/tcp 2>/dev/null || true
fuser -k $((PORT+1))/tcp 2>/dev/null || true
echo "Dashboard processes cleaned up."
