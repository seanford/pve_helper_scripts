#!/usr/bin/env python3
import sys, os, time, threading, asyncio, websockets, json
from http.server import SimpleHTTPRequestHandler
import socketserver
from urllib.parse import urlparse
import subprocess
import re

PORT = int(sys.argv[1])
LOG_DIR = sys.argv[2]
LOG_FILE = os.path.join(LOG_DIR, "upgrade.log")
UPGRADE_PATH = "/pve8to9"

clients = set()

HTML_PAGE = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>PVE 8 → 9 Upgrade Dashboard</title>
<style>
body {{ font-family: sans-serif; background: #111; color: #eee; padding: 20px; margin-bottom: 100px; }}
h1 {{ color: #0f0; text-shadow: 0 0 10px #0f0; }}
.grid {{ display: flex; flex-wrap: wrap; gap: 10px; }}
.node {{ padding: 15px; border-radius: 8px; min-width: 220px; text-align: center; transition: transform 0.3s ease-in-out; }}
.PENDING {{ background: #444; }}
.RUNNING {{ background: #225577; animation: pulse 1.5s infinite; }}
.DONE {{ background: #227722; }}
.ERROR {{ background: #772222; }}
.ROLLBACK {{ background: #aa5500; animation: rollbackPulse 1.5s infinite; box-shadow: 0 0 10px rgba(255,165,0,0.8); }}
.ROLLBACK-SNAPSHOT {{ background: #aa7700; animation: rollbackPulse 1.5s infinite; box-shadow: 0 0 10px rgba(255,165,0,0.8); }}
.ROLLBACK-BACKUP {{ background: #aa7700; animation: rollbackPulse 1.5s infinite; box-shadow: 0 0 10px rgba(255,165,0,0.8); }}
.ROLLBACK-DONE {{ background: #227722; }}
.ROLLBACK-SKIPPED {{ background: #555555; }}
.MISSING-UPGRADE-SCRIPT, .MISSING-ROLLBACK-SCRIPT {{ background: #ff0000; color: white; animation: blinkMissing 1s infinite; }}
.ONLINE {{ border: 2px solid #0f0; }}
.OFFLINE {{ border: 2px solid #f00; }}
.stats {{ font-size: 0.9em; margin-top: 8px; color: #ccc; }}
.health {{ margin-top: 30px; padding: 15px; border-radius: 8px; background: #222; }}
.health h2 {{ color: #0f0; margin-bottom: 10px; }}
.health-item {{ margin: 3px 0; }}
.ok {{ color: #0f0; }}
.fail {{ color: #f00; }}
.warn {{ color: #ff0; }}
.ok.ok {{ background: rgba(0,255,0,0.1); }}
.fail.fail {{ background: rgba(255,0,0,0.1); }}
.warn.warn {{ background: rgba(255,255,0,0.1); }}
#summary {{ position: fixed; bottom: 0; left: 0; right: 0; background: #000; padding: 10px; border-top: 2px solid #0f0; font-weight: bold; }}
@keyframes pulse {{
  0% {{ transform: scale(1); }}
  50% {{ transform: scale(1.03); }}
  100% {{ transform: scale(1); }}
}}
@keyframes rollbackPulse {{
  0% {{ box-shadow: 0 0 10px rgba(255,165,0,0.8); }}
  50% {{ box-shadow: 0 0 20px rgba(255,165,0,1); }}
  100% {{ box-shadow: 0 0 10px rgba(255,165,0,0.8); }}
}}
@keyframes blinkMissing {{
  0% {{ background-color: #ff0000; }}
  50% {{ background-color: #880000; }}
  100% {{ background-color: #ff0000; }}
}}
</style>
</head>
<body>
<h1>PVE 8 → 9 Upgrade Dashboard</h1>
<div id="grid" class="grid"></div>
<div id="health" class="health" style="display:none;">
<h2>Cluster Health</h2>
<div id="health-content"></div>
</div>
<div id="summary" style="display:none;">
<span id="summary-text"></span>
</div>
<script>
var ws = new WebSocket("ws://" + location.hostname + ":{PORT + 1}");
ws.onmessage = function(event) {{
  var data = JSON.parse(event.data);

  var html = "";
  var rollbackNodeId = null;
  data.nodes.forEach(node => {{
    let colorClass = node.status;
    let nodeId = "node-" + node.name;
    if (node.status.includes("MISSING-UPGRADE-SCRIPT") || node.status.includes("MISSING-ROLLBACK-SCRIPT")) {{
      html += `<div id="${{nodeId}}" class="node ${{colorClass}}">
                 <strong>${{node.name}}</strong><br>
                 🚨 MISSING SCRIPT<br>
                 ${{node.status}}
               </div>`;
    }} else {{
      html += `<div id="${{nodeId}}" class="node ${{colorClass}} ${{node.online}}">
                 <strong>${{node.name}}</strong><br>
                 ${{node.status}}<br>
                 <div class="stats">
                   CPU: ${{node.cpu}}%<br>
                   RAM: ${{node.ram}}%<br>
                   Uptime: ${{node.uptime}}
                 </div>
               </div>`;
    }}
    if (node.status.includes("ROLLBACK")) rollbackNodeId = nodeId;
  }});
  document.getElementById("grid").innerHTML = html;

  if (rollbackNodeId) {{
    setTimeout(() => {{
      document.getElementById(rollbackNodeId).scrollIntoView({{ behavior: "smooth", block: "center" }});
    }}, 300);
  }}

  if (data.health_checks && data.health_checks.length > 0) {{
    document.getElementById("health").style.display = "block";
    var healthHtml = "";
    var lastCheck = null;
    data.health_checks.forEach(check => {{
      healthHtml += `<div class="health-item"><strong>${{check.timestamp}}</strong></div>`;
      check.items.forEach(item => {{
        let cls = "ok";
        let changeCls = "";
        if (item.toLowerCase().includes("fail") || item.toLowerCase().includes("offline")) cls = "fail";
        else if (item.toLowerCase().includes("warn")) cls = "warn";
        if (lastCheck) {{
          let prevItem = lastCheck.items.find(i => i.includes(item.split(":")[0]));
          if (prevItem && prevItem !== item) {{
            if (prevItem.toLowerCase().includes("fail") && item.toLowerCase().includes("ok")) changeCls = "ok";
            else if (prevItem.toLowerCase().includes("offline") && item.toLowerCase().includes("online")) changeCls = "ok";
            else if (prevItem.toLowerCase().includes("ok") && item.toLowerCase().includes("fail")) changeCls = "fail";
            else if (prevItem.toLowerCase().includes("online") && item.toLowerCase().includes("offline")) changeCls = "fail";
            else changeCls = "warn";
          }}
        }}
        healthHtml += `<div class="health-item ${{cls}} ${{changeCls}}">- ${{item}}</div>`;
      }});
      healthHtml += `<hr>`;
      lastCheck = check;
    }});
    document.getElementById("health-content").innerHTML = healthHtml;
  }}

  if (data.summary && data.summary.length > 0) {{
    document.getElementById("summary").style.display = "block";
    document.getElementById("summary-text").innerHTML = data.summary.join(" | ");
  }}
}};
</script>
</body>
</html>
"""

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == UPGRADE_PATH or parsed.path == UPGRADE_PATH + "/":
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode())
        else:
            self.send_error(404, "Not found")

async def log_watcher():
    last = ""
    while True:
        try:
            with open(LOG_FILE) as f:
                content = f.read()
            payload = parse_log(content)
            if payload != last:
                last = payload
                await asyncio.wait([client.send(payload) for client in clients])
        except:
            pass
        await asyncio.sleep(3)

def parse_log(content):
    lines = content.strip().split("\n")
    status_dict = {}
    health_checks = []
    summary_lines = []
    current_check = []
    current_timestamp = None
    in_health = False
    in_summary = False

    for line in lines:
        parts = line.strip().split(" ")
        if len(parts) >= 3 and parts[0] == "STATUS":
            node, status = parts[1], " ".join(parts[2:])
            status_dict[node] = {"status": status}
        elif "HEALTHCHECK BEGIN" in line:
            in_health = True
            current_timestamp = re.search(r'\[(.*?)\]', line)
            if current_timestamp:
                current_timestamp = current_timestamp.group(1)
            current_check = []
        elif "HEALTHCHECK END" in line:
            in_health = False
            if current_check:
                health_checks.append({"timestamp": current_timestamp, "items": current_check})
        elif in_health and line.startswith("["):
            msg = " ".join(parts[2:])
            current_check.append(msg)
        elif "SUMMARY BEGIN" in line:
            in_summary = True
            summary_lines = []
        elif "SUMMARY END" in line:
            in_summary = False
        elif in_summary and line.startswith("["):
            msg = " ".join(parts[2:])
            summary_lines.append(msg)

    node_data = []
    for node in status_dict:
        cpu = get_cpu_usage(node)
        ram = get_ram_usage(node)
        uptime = get_uptime(node)
        node_data.append({
            "name": node,
            "status": status_dict[node]["status"],
            "online": "ONLINE" if is_online(node) else "OFFLINE",
            "cpu": cpu,
            "ram": ram,
            "uptime": uptime
        })

    return json.dumps({"nodes": node_data, "health_checks": health_checks, "summary": summary_lines})

def get_cpu_usage(node):
    try:
        cmd = ["ssh", node, "top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4}'"]
        output = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        return round(float(output), 1)
    except:
        return 0.0

def get_ram_usage(node):
    try:
        cmd = ["ssh", node, "free | grep Mem | awk '{print $3/$2 * 100.0}'"]
        output = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        return round(float(output), 1)
    except:
        return 0.0

def get_uptime(node):
    try:
        cmd = ["ssh", node, "uptime -p"]
        output = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        return output
    except:
        return "N/A"

def is_online(node):
    try:
        cmd = ["ping", "-c", "1", "-W", "1", node]
        subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except:
        return False

async def ws_handler(websocket, path):
    clients.add(websocket)
    try:
        await websocket.wait_closed()
    finally:
        clients.remove(websocket)

def start_http():
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        httpd.serve_forever()

def start_ws():
    asyncio.set_event_loop(asyncio.new_event_loop())
    start_server = websockets.serve(ws_handler, "0.0.0.0", PORT+1)
    asyncio.get_event_loop().run_until_complete(start_server)
    asyncio.get_event_loop().create_task(log_watcher())
    asyncio.get_event_loop().run_forever()

threading.Thread(target=start_http, daemon=True).start()
start_ws()
