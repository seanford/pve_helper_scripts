# PVE 8 → 9 Upgrade Orchestrator

A full-featured, interactive upgrade orchestrator for **Proxmox VE clusters or single-node setups**. This tool guides you through the upgrade process from **Proxmox VE 8 to 9**, offering:

- ✅ Pre-checks and config backups
- ✅ Optional VM snapshot creation with automatic rollback on failure
- ✅ Live rollback support (via backup or snapshot)
- ✅ Cluster-aware sequential upgrades
- ✅ Fully interactive, human-friendly prompts
- ✅ A live Web Dashboard to track upgrade status in real time
- ✅ Auto-cleanup of dashboard/websocket processes

---

## 🚀 Quick Start (Recommended)
### 🔗 Interactive Installer (SSH or Console)
```bash
bash <(curl -s https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/pve-upgrade-orchestrator.sh)
```
This will:
- Clone the helper repo (or update it)
- Install prerequisites (Python3, websockets, git, etc.)
- Launch the web dashboard
- Prompt you to upgrade a single node or entire cluster interactively

---

## 🔧 Features
- Automatically detects cluster vs single-node
- Performs pre-flight health checks
- Pushes the upgrade script to each node
- Handles rollback if errors occur
- Web Dashboard:
  - View live upgrade status for each node
  - Pulsing glow highlights nodes in rollback
  - Auto-scrolls to failed/rollback nodes
  - Displays live CPU/RAM/Uptime per node
- Clean rollback:
  - Snapshots are rolled back automatically on failure
  - Restore backup if needed
  - Duration of rollback displayed in dashboard

---

## 📅 Compatibility
- Works on all Proxmox VE 8.x systems
- Supports clusters of any size
- Dashboard is pure Python + WebSockets

---

## 📊 Web Dashboard Access
After launch, you'll see:
```
Dashboard at: http://<your-server-ip>:8080/pve8to9
```
Open that in your browser to track progress.

> 🚫 **Do NOT close your shell session or dashboard will terminate.**

---

## ⚠️ Warnings & Best Practices

### ❌ **DON'T run from Proxmox Web GUI Shell**
- The web GUI shell may block interactive prompts (`read` won't work).
- Always use:
  - ✅ SSH (`ssh root@your-node`) **OR**
  - ✅ Console (via IPMI, KVM, or direct monitor)

### ⚠️ Rollback Recommendations
- **Enable snapshots** with `--snapshot` only if you have VM-level backup capability
- Snapshots are per-VM; backup restore is filesystem-based

### 🚧 Optional Flags
```bash
--dry-run       # Only simulate upgrade steps
--no-update     # Skip auto-updating repo
--snapshot      # Create VM snapshots before upgrade and auto-rollback on failure
--force-venv    # Force use of Python venv for dashboard
```
Example (dry run with snapshots and automatic rollback):
```bash
bash <(curl -s https://raw.githubusercontent.com/seanford/pve_helper_scripts/main/pve8to9-upgrade/pve-upgrade-orchestrator.sh) --dry-run --snapshot
```

---

## 🛡️ Manual Cleanup (if needed)
If dashboard/websocket server is ever stuck or orphaned:
```bash
/root/pve_helper_scripts/pve8to9-upgrade/kill-dashboard.sh
```
This kills:
- All `pve-upgrade-dashboard.py` processes
- Any bound port 8080 or 8081 sockets

---

## 🧍🏼‍⚖️ Rollback After Failure
If a node upgrade fails and snapshots were created (`--snapshot`), the script automatically rolls each VM back to its pre-upgrade snapshot. Otherwise, restore from backups as needed. Rollback duration will be logged and visible in the dashboard.

---

## 🔍 Where Everything Lives
| Path                                   | Purpose                       |
|----------------------------------------|-------------------------------|
| `/root/pve_helper_scripts/`            | Main repo directory          |
| `/root/pve-upgrade-logs/`              | Logs for each upgrade run   |
| `/root/pve-upgrade-backups/<node>/`    | Config backups per node     |
| `/root/pve8to9-upgrade.sh`             | The actual upgrade script   |

---

## 🎓 Credits
Built by Sean Ford ✨  
Bash/Python/WebSocket madness by ChatGPT (powered by lots of caffeine).

---

## ⚡ Need Help?
Open an issue on [GitHub](https://github.com/seanford/pve_helper_scripts/issues) or ping Sean directly.

Happy upgrading!

---
