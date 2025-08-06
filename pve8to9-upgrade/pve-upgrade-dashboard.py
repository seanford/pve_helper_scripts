#!/usr/bin/env python3
import sys, os, time, threading, asyncio, websockets
from http.server import SimpleHTTPRequestHandler
import socketserver

PORT = int(sys.argv[1])
LOG_DIR = sys.argv[2]
LOG_FILE = os.path.join(LOG_DIR, "upgrade.log")

clients = set()

HTML_PAGE = """<!DOCTYPE html>
<html>
<head>
<title>Proxmox Upgrade Dashboard</title>
<style>
body { font-family: sans-serif; background: #111; color: #eee; padding: 20px; }
h1 { color: #0f0; }
.grid { display: flex; flex-wrap: wrap; gap: 10px; }
.node { padding: 15px; border-radius: 8px; min-width: 200px; text-align: center; }
.PENDING { background: #444; }
.RUNNING { background: #225577; }
.DONE { background: #227722; }
.ERROR { background: #772222; }
.ONLINE { border: 2px solid #0f0; }
.OFFLINE { border: 2px solid #f00; }
</style>
</head>
<body>
<h1>Proxmox Cluster Upgrade Progress</h1>
<div id="grid" class="grid"></div>
<script>
var ws = new WebSocket("ws://" + location.hostname + ":%(wport)s");
ws.onmessage = function(event) {
  var lines = event.data.trim().split("\\n");
  var html = "";
  lines.forEach(line => {
    var parts = line.split(" ");
    if (parts.length >= 3 && parts[0] === "STATUS") {
      html += `<div class="node ${parts[2]}"><strong>${parts[1]}</strong><br>${parts[2]}</div>`;
    }
  });
  document.getElementById("grid").innerHTML = html;
};
</script>
</body>
</html>
""" % {"wport": PORT+1}

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path in ['/', '/index.html']:
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode())
        else:
            super().do_GET()

async def log_watcher():
    last = ""
    while True:
        try:
            with open(LOG_FILE) as f:
                content = f.read()
            if content != last:
                last = content
                await asyncio.wait([client.send(content) for client in clients])
        except:
            pass
        await asyncio.sleep(1)

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
