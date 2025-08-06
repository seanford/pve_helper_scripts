#!/usr/bin/env python3
import asyncio
import json
import os
import re
import socketserver
import subprocess
import sys
import threading
from http.server import SimpleHTTPRequestHandler
from urllib.parse import urlparse

import websockets
from websockets.exceptions import WebSocketException

if len(sys.argv) < 3:
    print("Usage: pve-upgrade-dashboard.py <port> <log_dir>")
    sys.exit(1)
try:
    PORT = int(sys.argv[1])
except ValueError:
    print(f"Invalid port '{sys.argv[1]}'. Port must be an integer.")
    sys.exit(1)
LOG_DIR = sys.argv[2]
if not os.path.isdir(LOG_DIR):
    print(f"Log directory '{LOG_DIR}' does not exist.")
    sys.exit(1)
LOG_FILE = os.path.join(LOG_DIR, "upgrade.log")
UPGRADE_PATH = "/pve8to9"

clients = set()

TEMPLATE_FILE = os.path.join(os.path.dirname(__file__), "dashboard.html")


def load_dashboard_html():
    try:
        with open(TEMPLATE_FILE) as f:
            template = f.read()
    except OSError as e:
        print(f"Failed to load dashboard template '{TEMPLATE_FILE}': {e}")
        sys.exit(1)
    return template.replace("{WS_PORT}", str(PORT + 1))


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == UPGRADE_PATH or parsed.path == UPGRADE_PATH + "/":
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()
            html = load_dashboard_html()
            self.wfile.write(html.encode())
        else:
            self.send_error(404, "Not found")


async def log_watcher():
    last = ""
    position = 0
    content = ""
    while True:
        try:
            with open(LOG_FILE) as f:
                f.seek(position)
                new_data = f.read()
                position = f.tell()
            if new_data:
                content += new_data
                payload = parse_log(content)
                if payload != last:
                    last = payload
                    if clients:
                        await asyncio.gather(
                            *(client.send(payload) for client in clients)
                        )
        except OSError as e:
            print(f"Failed to read log file '{LOG_FILE}': {e}")
        except WebSocketException as e:
            print(f"WebSocket error while sending updates: {e}")
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
            current_timestamp = re.search(r"\[(.*?)\]", line)
            if current_timestamp:
                current_timestamp = current_timestamp.group(1)
            current_check = []
        elif "HEALTHCHECK END" in line:
            in_health = False
            if current_check:
                health_checks.append(
                    {"timestamp": current_timestamp, "items": current_check}
                )
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
        node_data.append(
            {
                "name": node,
                "status": status_dict[node]["status"],
                "online": "ONLINE" if is_online(node) else "OFFLINE",
                "cpu": cpu,
                "ram": ram,
                "uptime": uptime,
            }
        )

    return json.dumps(
        {"nodes": node_data, "health_checks": health_checks, "summary": summary_lines}
    )


def get_cpu_usage(node):
    try:
        cmd = ["ssh", node, "top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4}'"]
        output = (
            subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        )
        return round(float(output), 1)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"Failed to get CPU usage for {node}: {e}")
        return 0.0


def get_ram_usage(node):
    try:
        cmd = ["ssh", node, "free | grep Mem | awk '{print $3/$2 * 100.0}'"]
        output = (
            subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        )
        return round(float(output), 1)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"Failed to get RAM usage for {node}: {e}")
        return 0.0


def get_uptime(node):
    try:
        cmd = ["ssh", node, "uptime -p"]
        output = (
            subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        )
        return output
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"Failed to get uptime for {node}: {e}")
        return "N/A"


def is_online(node):
    try:
        cmd = ["ping", "-c", "1", "-W", "1", node]
        subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"Node {node} is offline or unreachable: {e}")
        return False


async def ws_handler(websocket, path):
    clients.add(websocket)
    try:
        await websocket.wait_closed()
    finally:
        clients.remove(websocket)


def start_http():
    try:
        with socketserver.TCPServer(("", PORT), Handler) as httpd:
            httpd.serve_forever()
    except OSError as e:
        print(f"Failed to start HTTP server on port {PORT}: {e}")
        sys.exit(1)


def start_ws():
    asyncio.set_event_loop(asyncio.new_event_loop())
    try:
        start_server = websockets.serve(ws_handler, "0.0.0.0", PORT + 1)
        asyncio.get_event_loop().run_until_complete(start_server)
    except OSError as e:
        print(f"Failed to start WebSocket server on port {PORT + 1}: {e}")
        sys.exit(1)
    asyncio.get_event_loop().create_task(log_watcher())
    asyncio.get_event_loop().run_forever()


threading.Thread(target=start_http, daemon=True).start()
start_ws()
